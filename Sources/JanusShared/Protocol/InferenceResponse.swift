import Foundation

/// Provider → Client: inference result with a signed receipt.
public struct InferenceResponse: Codable, Sendable {
    public let requestID: String
    public let outputText: String
    public let creditsCharged: Int
    public let cumulativeSpend: Int
    public let receipt: Receipt

    public init(
        requestID: String,
        outputText: String,
        creditsCharged: Int,
        cumulativeSpend: Int,
        receipt: Receipt
    ) {
        self.requestID = requestID
        self.outputText = outputText
        self.creditsCharged = creditsCharged
        self.cumulativeSpend = cumulativeSpend
        self.receipt = receipt
    }
}
