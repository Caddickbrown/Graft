import Foundation

// MARK: - SyncEngine
//
// Owns the pending-operations queue. All mutations are written here first
// (locally, immediately), then flushed to the Pi server when reachable.
// Works without a server configured — ops just stay queued until one appears.

@MainActor
final class SyncEngine {

    // MARK: - State

    private(set) var pendingOps: [PendingOperation] = []
    private(set) var isFlushing = false
    var lastFlushError: String?

    // MARK: - Init

    private let session: URLSession
    private let opsFileURL: URL

    init(session: URLSession) {
        self.session = session
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        opsFileURL = docs.appendingPathComponent("graft_pending_ops.json")
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
        // For PUT/PATCH on the same path, replace any earlier op so we don't
        // accumulate redundant updates. For DELETE, wipe all ops on that path.
        if method == "DELETE" {
            pendingOps.removeAll { $0.path == path }
        } else if method == "PUT" || method == "PATCH" {
            pendingOps.removeAll { ($0.method == "PUT" || $0.method == "PATCH") && $0.path == path }
        }
        pendingOps.append(op)
        saveOps()
    }

    // MARK: - Flush

    /// Try to drain the queue to `baseURL`. Silently does nothing if no URL or no ops.
    func flush(to baseURL: String) async {
        guard !baseURL.isEmpty, !pendingOps.isEmpty, !isFlushing else { return }
        isFlushing = true
        lastFlushError = nil
        defer { isFlushing = false }

        var toRetry: [PendingOperation] = []

        for op in pendingOps {
            do {
                try await execute(op, baseURL: baseURL)
            } catch {
                // Stop flushing on first error — preserve order
                toRetry = pendingOps.drop(while: { $0.id != op.id }).map { $0 }
                lastFlushError = error.localizedDescription
                break
            }
        }

        pendingOps = toRetry
        saveOps()
    }

    // MARK: - Execute single op

    private func execute(_ op: PendingOperation, baseURL: String) async throws {
        let urlString = baseURL + op.path
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = op.method
        req.timeoutInterval = 10
        if let body = op.body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
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

    private func loadOps() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: opsFileURL),
              let ops = try? decoder.decode([PendingOperation].self, from: data) else { return }
        pendingOps = ops
    }

    var pendingCount: Int { pendingOps.count }
}
