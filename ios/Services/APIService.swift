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

    // MARK: - Private

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.init(rawValue: code))
        }
    }
}
