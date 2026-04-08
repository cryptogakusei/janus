import Foundation

/// Provider → Client: error response for failed requests.
public struct ErrorResponse: Codable, Sendable {
    public let requestID: String?
    public let errorCode: ErrorCode
    public let errorMessage: String

    public init(requestID: String?, errorCode: ErrorCode, errorMessage: String) {
        self.requestID = requestID
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    public enum ErrorCode: String, Codable, Sendable {
        case invalidSession = "INVALID_SESSION"
        case expiredQuote = "EXPIRED_QUOTE"
        case insufficientCredits = "INSUFFICIENT_CREDITS"
        case invalidSignature = "INVALID_SIGNATURE"
        case sessionExpired = "SESSION_EXPIRED"
        case providerBusy = "PROVIDER_BUSY"
        case sequenceMismatch = "SEQUENCE_MISMATCH"
        case inferenceFailed = "INFERENCE_FAILED"
        case providerUnreachable = "PROVIDER_UNREACHABLE"
        case relayTimeout = "RELAY_TIMEOUT"
    }
}
