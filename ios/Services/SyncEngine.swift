import Foundation
import Observation

// MARK: - SyncEngine
//
// Owns the pending-operations queue. All mutations are written here first
// (locally, immediately), then flushed to the Pi server when reachable.
// Works without a server configured — ops just stay queued until one appears.
//
// Observable so that Settings — the one place the queue is visible — actually
// redraws when the queue drains or an op is thrown away.

@MainActor
@Observable
final class SyncEngine {

    // MARK: - State

    private(set) var pendingOps: [PendingOperation] = []
    private(set) var isFlushing = false
    var lastFlushError: String?

    /// Ops the queue gave up on, newest last. Nothing here will ever be sent,
    /// so it exists to be shown rather than retried.
    private(set) var droppedOps: [DroppedOperation] = []

    /// Retryable failures get a bounded number of goes. Without a cap, a single
    /// op that never succeeds stalls every op behind it *and* stops `GraftStore`
    /// pulling from the server at all, so the app quietly stops reconciling.
    ///
    /// Only failures the *server* answered with count towards it — see
    /// `OpFailure.unreachable`. A phone with no signal must be able to sit on
    /// its queue indefinitely; the old cap of 8 counted every failed connection,
    /// and since every write and every foreground calls `flush`, a day offline
    /// was enough to throw a real edit away. What the cap is actually for is the
    /// op the server keeps refusing in a way that reads as retryable — a 500 on
    /// one bad row — and 24 tries of that is still a few minutes of flushing,
    /// not a lifetime.
    private static let maxAttempts = 24

    /// Only the most recent drops are worth keeping around for the UI.
    private static let maxDroppedKept = 20

    /// The op whose request is on the wire right now. It stays in `pendingOps`
    /// until it succeeds, so without this `enqueue` could "cancel" a toggle the
    /// server is already applying.
    private var inFlightOpID: String?

    /// Handed the body of every successful response, so the store can read what
    /// the server said back.
    ///
    /// The queue used to throw response bodies away — `let (_, resp)` — which
    /// was fine while a PUT only ever echoed the row back. It is not fine now:
    /// completing a recurring issue answers with a `spawned` replacement that
    /// exists nowhere else until the next full pull, and saving that blind
    /// refetch is the whole reason the server attaches it.
    ///
    /// A callback rather than `flush` returning bodies: four entry points can
    /// start a flush, and the one that cares about an answer is rarely the one
    /// that started it.
    var onResponse: ((PendingOperation, Data) -> Void)?

    // MARK: - Init

    private let session: URLSession
    private let opsFileURL: URL
    private let droppedFileURL: URL

    init(session: URLSession) {
        self.session = session
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        opsFileURL = docs.appendingPathComponent("graft_pending_ops.json")
        droppedFileURL = docs.appendingPathComponent("graft_dropped_ops.json")
        loadOps()
    }

    // MARK: - Enqueueing

    func enqueue(method: String, path: String, body: Data? = nil) {
        let op = PendingOperation(
            id: UUID().uuidString,
            method: method,
            path: path,
            body: body,
            createdAt: Date()
        )

        if method == "DELETE" {
            // The record is going away, so anything queued against it is moot —
            // including its sub-resources, whose requests would only 404.
            pendingOps.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        } else if isToggle(method: method, path: path, body: body) {
            // Archive and favourite are server-side *toggles*, not values being
            // set, so the "newest write supersedes the earlier ones" rule below
            // is exactly wrong for them: archive-then-undo would collapse to a
            // single net flip, leaving the server archived while the phone shows
            // the issue live, and the next pull would re-archive it.
            //
            // Two toggles on the same path are a no-op, so they cancel out.
            // That keeps the queue short and matches local state, which also
            // flipped twice and is back where it started.
            //
            // Unless the earlier one is already being sent: the server is going
            // to apply it either way, so the second toggle has to be sent too
            // for the two ends to agree.
            if let idx = pendingOps.lastIndex(where: {
                $0.method == method && $0.path == path && $0.body == nil
                    && $0.id != inFlightOpID
            }) {
                pendingOps.remove(at: idx)
                saveOps()
                return
            }
        } else if isAppendOnly(path: path) {
            // Nothing to collapse — see `appendOnlyPaths`.
        } else if method == "PUT" || method == "PATCH" {
            // Genuinely idempotent whole-record writes: the newest one carries
            // everything the earlier ones said.
            pendingOps.removeAll { ($0.method == "PUT" || $0.method == "PATCH") && $0.path == path }
        }

        pendingOps.append(op)
        saveOps()
    }

    /// The server-side toggles: `PATCH .../archive` and `PATCH .../favourite`
    /// flip a flag rather than setting one, so neither is safe to treat as
    /// idempotent. Favourite was missing here, which meant pin-then-unpin while
    /// offline collapsed into a single PATCH under the rule below and left the
    /// project pinned on the server and unpinned on the phone.
    private static let togglePaths = ["/archive", "/favourite"]

    /// A request on one of those paths is only a *toggle* when it carries no
    /// body. `favouriteProject` now sends `{"favourite": 1}`, which states a
    /// value: replaying it lands the same way round however long it sat in the
    /// queue, so it belongs under the ordinary newest-supersedes rule below
    /// rather than under the cancel-in-pairs one. A bodyless PATCH — from an
    /// older build's queue, or from `archiveProject`, which still toggles —
    /// keeps the old handling.
    private func isToggle(method: String, path: String, body: Data?) -> Bool {
        method == "PATCH" && body == nil && Self.togglePaths.contains { path.hasSuffix($0) }
    }

    /// Paths where a queued write must never be superseded by a later one.
    ///
    /// `PATCH /api/issues/reorder` is a batch: its body names the issues it
    /// moves and says nothing about the rest. Two drags in two different
    /// projects are two disjoint statements, and collapsing them — which the
    /// newest-supersedes rule would do, since the path is the same both times —
    /// would silently throw the first project's order away.
    private static let appendOnlyPaths = ["/api/issues/reorder"]

    private func isAppendOnly(path: String) -> Bool {
        Self.appendOnlyPaths.contains(path)
    }

    /// Every path with a write still waiting to go out, including the one on
    /// the wire right now.
    ///
    /// Read by `GraftStore` when a pull lands, so a row this phone has changed
    /// and not yet sent is not overwritten by the server's older copy of it.
    var pendingPaths: Set<String> {
        Set(pendingOps.map(\.path))
    }

    // MARK: - Flush

    /// Try to drain the queue to `baseURL`. Silently does nothing if no URL or no ops.
    func flush(to baseURL: String) async {
        guard !baseURL.isEmpty, !pendingOps.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        var problem: String?

        // Every op is read from, and removed from, the LIVE `pendingOps`. Each
        // `await` below is a suspension point on which `enqueue` can append, so
        // taking a snapshot up front and assigning it back at the end would
        // destroy anything queued during the flush — and that op's own flush
        // already gave up, having found `isFlushing` true.
        //
        // `attempted` both drives progress through the queue and lets this pass
        // pick up those late arrivals instead of leaving them until whatever
        // happens to trigger the next flush.
        var attempted = Set<String>()

        while let op = pendingOps.first(where: { !attempted.contains($0.id) }) {
            attempted.insert(op.id)
            do {
                inFlightOpID = op.id
                defer { inFlightOpID = nil }
                let body = try await execute(op, baseURL: baseURL)
                pendingOps.removeAll { $0.id == op.id }
                saveOps()
                if let body, !body.isEmpty { onResponse?(op, body) }
            } catch {
                let failure: OpFailure = (error as? OpFailure)
                    ?? (Self.isUnreachable(error)
                        ? OpFailure.unreachable(error.localizedDescription)
                        : OpFailure.transient(error.localizedDescription))
                switch failure {
                case .permanent(let why):
                    // The server understood the request and refused it — a PUT
                    // to an issue someone deleted on the web, say. Replaying it
                    // will never work, so drop it and keep draining rather than
                    // let one dead op hold the whole queue hostage.
                    drop(op, reason: why)
                    problem = "Discarded \(op.method) \(op.path) — \(why)"
                case .unreachable(let why):
                    // The server was never reached, so this says nothing about
                    // the op and must not be counted against it. Stop the flush
                    // — if one request cannot get out, nor can the next — and
                    // leave the queue exactly as it is for whenever the network
                    // comes back.
                    lastFlushError = problem.map { "\($0); \(why)" } ?? why
                    saveOps()
                    return
                case .transient(let why):
                    let tries = recordAttempt(on: op.id)
                    if tries >= Self.maxAttempts {
                        drop(op, reason: "\(why) — gave up after \(tries) attempts")
                        problem = "Discarded \(op.method) \(op.path) after \(tries) attempts — \(why)"
                    } else {
                        // Worth another go later. Stop here so ops queued behind
                        // this one can't reach the server ahead of it.
                        lastFlushError = problem.map { "\($0); \(why)" } ?? why
                        saveOps()
                        return
                    }
                }
            }
        }

        lastFlushError = problem
        saveOps()
    }

    /// Notes a retryable failure against the op still sitting in the queue and
    /// returns its new attempt count. Looked up by id because the queue may have
    /// been rewritten while the request was in flight; a missing op simply has
    /// nothing left to count.
    private func recordAttempt(on id: String) -> Int {
        guard let idx = pendingOps.firstIndex(where: { $0.id == id }) else { return 0 }
        pendingOps[idx].attempts += 1
        return pendingOps[idx].attempts
    }

    private func drop(_ op: PendingOperation, reason: String) {
        pendingOps.removeAll { $0.id == op.id }
        droppedOps.append(DroppedOperation(
            id: op.id,
            method: op.method,
            path: op.path,
            reason: reason,
            droppedAt: Date()
        ))
        if droppedOps.count > Self.maxDroppedKept {
            droppedOps.removeFirst(droppedOps.count - Self.maxDroppedKept)
        }
        saveOps()
        saveDropped()
    }

    /// Clears the record of what was thrown away, once the user has seen it.
    func clearDropped() {
        droppedOps = []
        saveDropped()
    }

    /// Forgets what was dropped against one path, for a screen that is about to
    /// retry that exact write. Narrow on purpose: clearing the whole record to
    /// retry one issue would hide failures the user has not been told about.
    func clearDropped(forPath path: String) {
        droppedOps.removeAll { $0.path == path }
        saveDropped()
    }

    // MARK: - Execute single op

    /// Why one op failed, and therefore what the queue should do about it.
    private enum OpFailure: Error {
        /// The server understood and refused. Sending it again changes nothing.
        case permanent(String)
        /// The server answered, and badly — a 500, a 429, a reply that was not
        /// HTTP at all. Worth retrying, and worth counting: something about this
        /// request may be what the server keeps choking on.
        case transient(String)
        /// Nothing answered. No signal, no route to the Pi, the connection died
        /// mid-flight. This says nothing whatever about the op, so counting it
        /// would be counting the user's commute, which is how a queue quietly
        /// eats a day's edits.
        case unreachable(String)
    }

    /// True for the URLSession errors that mean "the server was never reached".
    ///
    /// Listed rather than "any URLError", because plenty of URLErrors *are*
    /// about the request — `.badURL`, `.dataLengthExceedsMaximum` — and those
    /// should still burn an attempt rather than retry forever.
    private static func isUnreachable(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .timedOut,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Returns the response body on success, for `onResponse`. Nothing here
    /// parses it — the queue has no idea what any given path answers with.
    @discardableResult
    private func execute(_ op: PendingOperation, baseURL: String) async throws -> Data? {
        let urlString = baseURL + op.path
        guard let url = URL(string: urlString) else {
            throw OpFailure.permanent("not a valid URL: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = op.method
        req.timeoutInterval = 10
        // The op's own id, which is stable from the moment it was queued and
        // survives relaunches, names this request for the server. A toggle
        // cannot be retried safely otherwise: a client that never saw the reply
        // cannot tell "the request was lost" from "the answer was lost", and the
        // two want opposite things. The server records applied ids and answers a
        // repeat without flipping again. Sent on every op, not just the toggles
        // — it is ignored where it is not needed, and a retry after a timeout is
        // exactly the case nobody remembers to special-case.
        req.setValue(op.id, forHTTPHeaderField: "X-Graft-Op-Id")
        if let body = op.body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        let response: URLResponse
        let payload: Data
        do {
            let (data, resp) = try await session.data(for: req)
            payload = data
            response = resp
        } catch {
            // Nothing came back. Whether that is worth counting against the op
            // depends entirely on *why*, which is the one thing the old code
            // threw away by calling every URLSession error transient.
            if Self.isUnreachable(error) {
                throw OpFailure.unreachable(error.localizedDescription)
            }
            throw OpFailure.transient(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpFailure.transient("unexpected response")
        }
        switch http.statusCode {
        case 200..<300:
            return payload
        case 408, 429:
            // The two 4xx codes that mean "later", not "never".
            throw OpFailure.transient("HTTP \(http.statusCode)")
        case 400..<500:
            throw OpFailure.permanent("HTTP \(http.statusCode)")
        default:
            throw OpFailure.transient("HTTP \(http.statusCode)")
        }
    }

    // MARK: - Persistence

    private func saveOps() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(pendingOps) {
            try? data.write(to: opsFileURL, options: .atomic)
        }
    }

    private func saveDropped() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(droppedOps) {
            try? data.write(to: droppedFileURL, options: .atomic)
        }
    }

    private func loadOps() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: opsFileURL),
           let ops = try? decoder.decode([PendingOperation].self, from: data) {
            pendingOps = ops
        }
        if let data = try? Data(contentsOf: droppedFileURL),
           let dropped = try? decoder.decode([DroppedOperation].self, from: data) {
            droppedOps = dropped
        }
    }

    var pendingCount: Int { pendingOps.count }
}
