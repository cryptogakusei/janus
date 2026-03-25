import Foundation

/// Client → Provider: authorize spending credits for a quoted request.
///
/// The cumulative_spend is monotonically increasing — each authorization
/// represents the new total, not the increment.
public struct SpendAuthorization: Codable, Sendable {
    public let sessionID: String
    public let requestID: String
    public let quoteID: String
    public let cumulativeSpend: Int
    public let sequenceNumber: Int
    public let clientSignature: String  // base64 Ed25519 signature

    public init(
        sessionID: String,
        requestID: String,
        quoteID: String,
        cumulativeSpend: Int,
        sequenceNumber: Int,
        clientSignature: String
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.quoteID = quoteID
        self.cumulativeSpend = cumulativeSpend
        self.sequenceNumber = sequenceNumber
        self.clientSignature = clientSignature
    }

    /// The fields that the client signs, in canonical order.
    public var signableFields: [String] {
        [
            sessionID,
            requestID,
            quoteID,
            String(cumulativeSpend),
            String(sequenceNumber)
        ]
    }
}
