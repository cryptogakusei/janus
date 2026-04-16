import Foundation

/// Abstraction over HTTP transport for RPC calls.
///
/// Decouples `EthRPC` from `URLSession` so iOS clients can force payment traffic
/// over cellular using `NWConnection` when the active WiFi has no WAN uplink.
///
/// The default implementation (`URLSessionTransport`) wraps a `URLSession`.
/// iOS clients inject `CellularTransport` (in the app target) via `TempoConfig.transport`.
public protocol HTTPTransport: Sendable {
    /// Perform an HTTP POST and return (responseBody, httpStatusCode).
    func post(url: URL, headers: [String: String], body: Data) async throws -> (Data, Int)
}

/// Default `HTTPTransport` backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(url: URL, headers: [String: String], body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }
}
