import Foundation

/// Provider → Client: live pricing update pushed to connected clients when the operator changes settings.
///
/// Inform-only — no accept/reject handshake (see roadmap #13e+1 for that).
/// The client updates its local connectedProvider state and shows a dismissible banner.
public struct ServiceUpdate: Codable, Sendable {
    /// Credits charged per 1000 output tokens (tab model).
    public let tokenRate: UInt64
    /// Tokens before settlement is required.
    public let tabThresholdTokens: UInt64

    public init(tokenRate: UInt64, tabThresholdTokens: UInt64) {
        self.tokenRate = tokenRate
        self.tabThresholdTokens = tabThresholdTokens
    }
}
