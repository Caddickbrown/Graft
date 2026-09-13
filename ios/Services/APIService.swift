import Foundation

// MARK: - Certificate handling
//
// There is deliberately no `URLSessionDelegate` here any more.
//
// This file used to carry an `InsecureSessionDelegate` that answered every
// server-trust challenge with `.useCredential` and the server's own trust
// object — that is, it accepted *any* certificate from *any* host, which is
// the whole of TLS turned off. It made the app's HTTPS decorative, and it made
// the Settings screen's certificate instructions a lie: nothing the user did
// with the mkcert root could have changed the outcome, because the app was
// never going to check.
//
// The Pi's certificate comes from the user's own mkcert development CA, and the
// supported way to trust it is the supported way: install the root on the
// device and enable it under Certificate Trust Settings. Settings spells out
// both steps. Until that is done, syncing fails — visibly, through the sync
// strip — which is the correct outcome rather than a silent downgrade.

// MARK: - APIService

struct APIService: Sendable {
    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    // MARK: - GET

    func get<T: Decodable>(_ urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - POST

    func post<Body: Encodable, Response: Decodable>(_ urlString: String, body: Body) async throws -> Response {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: - PUT

    func put<Body: Encodable, Response: Decodable>(_ urlString: String, body: Body) async throws -> Response {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: - DELETE

    func delete(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Scheduling endpoints
    //
    // Named methods rather than call sites assembling URLs, because these are
    // the four places a query string has to be got exactly right and getting it
    // wrong fails silently — a mis-spelled parameter is simply ignored by
    // Flask, and the caller gets a plausible-looking answer to a question it
    // did not ask.

    /// `GET /api/notifications`. `undelivered` is the scheduler's usual call:
    /// it excludes rows already delivered *or* dismissed, because dismissed
    /// means the user said no and asking again is how a notification system
    /// teaches people to ignore it.
    func notifications(
        base: String,
        undelivered: Bool = false,
        since: String? = nil,
        before: String? = nil,
        kinds: [String] = []
    ) async throws -> [GraftNotification] {
        var items: [URLQueryItem] = []
        if undelivered { items.append(URLQueryItem(name: "undelivered", value: "true")) }
        if let since, !since.isEmpty { items.append(URLQueryItem(name: "since", value: since)) }
        if let before, !before.isEmpty { items.append(URLQueryItem(name: "before", value: before)) }
        // `kind` IS multi-value — it goes through the server's `_multi`, unlike
        // the date bounds above and beside it.
        if !kinds.isEmpty {
            items.append(URLQueryItem(name: "kind", value: kinds.joined(separator: ",")))
        }
        return try await get(base + "/api/notifications" + Self.query(items))
    }

    /// `POST /api/notifications/:id/ack`. Idempotent server-side: a replayed
    /// ack keeps the first `delivered_at`, so a lost response costs nothing.
    @discardableResult
    func ackNotification(base: String, id: String, dismissed: Bool = false) async throws -> GraftNotification {
        let path = base + "/api/notifications/" + (Self.escape(id) ?? id) + "/ack"
        return try await post(path, body: ["dismissed": dismissed])
    }

    /// `GET /api/digest`. `assignee` scopes "waiting on you" to one person —
    /// `"none"` for the unassigned pile, as everywhere else. Without it that
    /// bucket comes back empty rather than guessed at.
    func digest(base: String, date: String? = nil, assignee: String? = nil) async throws -> GraftDigest {
        var items: [URLQueryItem] = []
        if let date, !date.isEmpty { items.append(URLQueryItem(name: "date", value: date)) }
        if let assignee, !assignee.isEmpty { items.append(URLQueryItem(name: "assignee", value: assignee)) }
        return try await get(base + "/api/digest" + Self.query(items))
    }

    /// `GET /api/issues/:id/series` — every occurrence of the series this issue
    /// belongs to, archived rows included and not optional.
    func series(base: String, issueId: String) async throws -> GraftIssueSeries {
        try await get(base + "/api/issues/" + (Self.escape(issueId) ?? issueId) + "/series")
    }

    /// `GET /api/issues?…` for a saved query. The one builder, so the
    /// single-value date bounds cannot drift back into the comma-joined form.
    func issues(base: String, matching query: IssueQuery) async throws -> [GraftIssue] {
        try await get(base + "/api/issues?" + query.serverQueryString())
    }

    // MARK: - Private

    /// `?a=b&c=d`, or `""`. Uses the same `+`-escaping fix as
    /// `IssueQuery.serverQueryString` — `URLComponents` leaves `+` alone in a
    /// query, where Flask decodes it as a space.
    private static func query(_ items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return "" }
        var components = URLComponents()
        components.queryItems = items
        let encoded = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        return encoded.isEmpty ? "" : "?" + encoded
    }

    private static func escape(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.init(rawValue: code))
        }
    }
}
