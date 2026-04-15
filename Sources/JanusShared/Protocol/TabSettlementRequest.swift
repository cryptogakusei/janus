import Foundation

/// Provider → Client: payment demand when the client's tab has crossed the threshold.
///
/// The provider blocks further inference until the client sends a VoucherAuthorization
/// with a nil quoteID (the tab settlement discriminant) matching this requestID.
public struct TabSettlementRequest: Codable, Sendable {
    /// Fresh UUID per settlement cycle — used for replay prevention on the provider side.
    public let requestID: String
    /// Exact credits owed (ceiling division: (tabTokens * tokenRate + 999) / 1000, min 1).
    public let tabCredits: UInt64
    /// The payment channel ID to settle against (32 bytes).
    public let channelId: Data

    public init(requestID: String, tabCredits: UInt64, channelId: Data) {
        self.requestID = requestID
        self.tabCredits = tabCredits
        self.channelId = channelId
    }
}
