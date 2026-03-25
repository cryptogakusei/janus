import Foundation

// MARK: - SessionBackend protocol

/// Abstraction over the session funding/settlement backend.
///
/// Today: HTTP calls to a local Vapor server.
/// Tomorrow: MPP/Tempo payment channel operations.
///
/// The three operations map to MPP concepts:
///   - `fundSession`   → open + fund a payment channel
///   - `registerProvider` → announce provider identity to the network
///   - `settleSession` → close + settle a payment channel
public protocol SessionBackend: Sendable {
    func fundSession(providerID: String, clientPubkey: String, maxCredits: Int?) async throws -> SessionGrant
    func registerProvider(providerID: String, publicKeyBase64: String) async throws -> ProviderRegistration
    func settleSession(sessionID: String, providerID: String, cumulativeSpend: Int, receipts: [Receipt]) async throws -> Settlement
}

/// Result of provider registration.
public struct ProviderRegistration: Codable, Sendable {
    public let providerID: String
    public let registered: Bool

    public init(providerID: String, registered: Bool) {
        self.providerID = providerID
        self.registered = registered
    }
}

/// Result of session settlement.
public struct Settlement: Codable, Sendable {
    public let sessionID: String
    public let settled: Bool
    public let settledSpend: Int

    public init(sessionID: String, settled: Bool, settledSpend: Int) {
        self.sessionID = sessionID
        self.settled = settled
        self.settledSpend = settledSpend
    }
}

// MARK: - HTTP implementation (v1 Vapor backend)

/// HTTP-based implementation of SessionBackend, talking to the local Vapor server.
/// Will be replaced by an MPP/Tempo implementation in a future milestone.
public struct HTTPSessionBackend: SessionBackend {

    public let baseURL: String

    public init(baseURL: String = DemoConfig.backendBaseURL) {
        self.baseURL = baseURL
    }

    public func fundSession(providerID: String, clientPubkey: String, maxCredits: Int? = nil) async throws -> SessionGrant {
        struct Request: Codable { let providerID: String; let clientPubkey: String; let maxCredits: Int? }
        struct Response: Codable { let sessionGrant: SessionGrant }
        let response: Response = try await post("/sessions", body: Request(providerID: providerID, clientPubkey: clientPubkey, maxCredits: maxCredits))
        return response.sessionGrant
    }

    public func registerProvider(providerID: String, publicKeyBase64: String) async throws -> ProviderRegistration {
        struct Request: Codable { let providerID: String; let publicKeyBase64: String }
        let body = Request(providerID: providerID, publicKeyBase64: publicKeyBase64)
        return try await post("/providers/register", body: body)
    }

    public func settleSession(sessionID: String, providerID: String, cumulativeSpend: Int, receipts: [Receipt]) async throws -> Settlement {
        struct Request: Codable { let sessionID: String; let providerID: String; let cumulativeSpend: Int; let receipts: [Receipt] }
        let body = Request(sessionID: sessionID, providerID: providerID, cumulativeSpend: cumulativeSpend, receipts: receipts)
        return try await post("/sessions/settle", body: body)
    }

    // MARK: - HTTP transport

    private func post<T: Codable, R: Codable>(_ path: String, body: T) async throws -> R {
        guard let url = URL(string: baseURL + path) else {
            throw SessionBackendError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.janus.encode(body)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SessionBackendError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SessionBackendError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        return try JSONDecoder.janus.decode(R.self, from: data)
    }
}

public enum SessionBackendError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid backend URL"
        case .invalidResponse: return "Invalid server response"
        case .serverError(let code, let message): return "Server error \(code): \(message)"
        }
    }
}
