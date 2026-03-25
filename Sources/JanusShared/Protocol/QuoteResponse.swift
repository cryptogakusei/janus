import Foundation

/// Provider → Client: price quote for the requested inference.
public struct QuoteResponse: Codable, Sendable {
    public let requestID: String
    public let quoteID: String
    public let priceCredits: Int
    public let priceTier: String
    public let expiresAt: Date

    public init(
        requestID: String,
        quoteID: String = UUID().uuidString,
        priceCredits: Int,
        priceTier: String,
        expiresAt: Date
    ) {
        self.requestID = requestID
        self.quoteID = quoteID
        self.priceCredits = priceCredits
        self.priceTier = priceTier
        self.expiresAt = expiresAt
    }
}
