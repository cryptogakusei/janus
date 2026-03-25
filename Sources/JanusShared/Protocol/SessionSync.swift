import Foundation

/// Provider → Client: state reconciliation after a missed response.
///
/// Sent when the provider detects a sequence mismatch — meaning the client
/// missed the last InferenceResponse (MPC dropped it mid-flight). Contains
/// the missed response so the client can verify the receipt, update its
/// spend state, and recover without reinstalling.
public struct SessionSync: Codable, Sendable {
    public let sessionID: String
    public let missedResponse: InferenceResponse

    public init(sessionID: String, missedResponse: InferenceResponse) {
        self.sessionID = sessionID
        self.missedResponse = missedResponse
    }
}
