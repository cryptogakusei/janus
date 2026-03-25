import Foundation

/// Tracks the cumulative spend state for a session.
///
/// Both client and provider maintain a SpendState:
/// - Client uses it to construct the next VoucherAuthorization
/// - Provider uses it to check voucher monotonicity
public struct SpendState: Codable, Sendable {
    public let sessionID: String
    public private(set) var cumulativeSpend: Int
    public private(set) var sequenceNumber: Int
    public private(set) var updatedAt: Date

    public init(sessionID: String, cumulativeSpend: Int = 0, sequenceNumber: Int = 0) {
        self.sessionID = sessionID
        self.cumulativeSpend = cumulativeSpend
        self.sequenceNumber = sequenceNumber
        self.updatedAt = Date()
    }

    /// Advance the spend state after a successful request.
    public mutating func advance(creditsCharged: Int) {
        self.cumulativeSpend += creditsCharged
        self.sequenceNumber += 1
        self.updatedAt = Date()
    }
}
