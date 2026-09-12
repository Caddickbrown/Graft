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
    private static let maxAttempts = 8

    /// Only the most recent drops are worth keeping around for the UI.
    private static let maxDroppedKept = 20

    /// The op whose request is on the wire right now. It stays in `pendingOps`
    /// until it succeeds, so without this `enqueue` could "cancel" a toggle the
    /// server is already applying.
    private var inFlightOpID: String?

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
        } else if isToggle(method: method, path: path) {
            // Archive is a server-side *toggle*, not a value being set, so the
            // "newest write supersedes the earlier ones" rule below is exactly
            // wrong for it: archive-then-undo would collapse to a single net
            // flip, leaving the server archived while the phone shows the issue
            // live, and the next pull would re-archive it.
            //
            // Two toggles on the same path are a no-op, so they cancel out.
            // That keeps the queue short and matches local state, which also
            // flipped twice and is back where it started.
            //
            // Unless the earlier one is already being sent: the server is going
            // to apply it either way, so the second toggle has to be sent too
            // for the two ends to agree.
            if let idx = pendingOps.lastIndex(where: {
                $0.method == method && $0.path == path && $0.id != inFlightOpID
            }) {
                pendingOps.remove(at: idx)
                saveOps()
                return
            }
        } else if method == "PUT" || method == "PATCH" {
            // Genuinely idempotent whole-record writes: the newest one carries
            // everything the earlier ones said.
            pendingOps.removeAll { ($0.method == "PUT" || $0.method == "PATCH") && $0.path == path }
        }

        pendingOps.append(op)
        saveOps()
    }

    /// `PATCH .../archive` flips a flag rather than setting one, so it is not
    /// safe to treat as idempotent.
    private func isToggle(method: String, path: String) -> Bool {
        method == "PATCH" && path.hasSuffix("/archive")
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
                try await execute(op, baseURL: baseURL)
                pendingOps.removeAll { $0.id == op.id }
                saveOps()
            } catch {
                let failure: OpFailure = (error as? OpFailure)
                    ?? OpFailure.transient(error.localizedDescription)
                switch failure {
                case .permanent(let why):
                    // The server understood the request and refused it — a PUT
                    // to an issue someone deleted on the web, say. Replaying it
                    // will never work, so drop it and keep draining rather than
                    // let one dead op hold the whole queue hostage.
                    drop(op, reason: why)
                    problem = "Discarded \(op.method) \(op.path) — \(why)"
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
        /// Server trouble or no network. The same request may well work later.
        case transient(String)
    }

    private func execute(_ op: PendingOperation, baseURL: String) async throws {
        let urlString = baseURL + op.path
        guard let url = URL(string: urlString) else {
            throw OpFailure.permanent("not a valid URL: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = op.method
        req.timeoutInterval = 10
        if let body = op.body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        let response: URLResponse
        do {
            let (_, resp) = try await session.data(for: req)
            response = resp
        } catch {
            // Anything URLSession itself raises is a reachability problem.
            throw OpFailure.transient(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpFailure.transient("unexpected response")
        }
        switch http.statusCode {
        case 200..<300:
            return
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
