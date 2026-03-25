import Foundation

/// A signed receipt from the provider, proving work was done and credits charged.
///
/// The provider signs: receipt_id, session_id, request_id, provider_id,
/// credits_charged, cumulative_spend, timestamp.
public struct Receipt: Codable, Sendable {
    public let receiptID: String
    public let sessionID: String
    public let requestID: String
    public let providerID: String
    public let creditsCharged: Int
    public let cumulativeSpend: Int
    public let timestamp: Date
    public let providerSignature: String // base64 Ed25519 signature

    public init(
        receiptID: String = UUID().uuidString,
        sessionID: String,
        requestID: String,
        providerID: String,
        creditsCharged: Int,
        cumulativeSpend: Int,
        timestamp: Date = Date(),
        providerSignature: String
    ) {
        self.receiptID = receiptID
        self.sessionID = sessionID
        self.requestID = requestID
        self.providerID = providerID
        self.creditsCharged = creditsCharged
        self.cumulativeSpend = cumulativeSpend
        self.timestamp = timestamp
        self.providerSignature = providerSignature
    }

    /// The fields that the provider signs, in canonical order.
    public var signableFields: [String] {
        [
            receiptID,
            sessionID,
            requestID,
            providerID,
            String(creditsCharged),
            String(cumulativeSpend),
            ISO8601DateFormatter().string(from: timestamp)
        ]
    }
}
