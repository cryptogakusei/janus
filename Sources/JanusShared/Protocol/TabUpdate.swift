import Foundation

/// Provider → Client: token usage update appended to every InferenceResponse.
///
/// Lets the client track their running tab in real time.
public struct TabUpdate: Codable, Sendable {
    /// Tokens consumed by this specific request (input + output).
    public let tokensUsed: UInt64
    /// Running total tokens accumulated since last settlement for this client.
    public let cumulativeTabTokens: UInt64
    /// Tokens at which the provider will require settlement.
    public let tabThreshold: UInt64
    /// Rate used to compute creditsCharged for this response (credits per 1000 tokens).
    /// Embedded so the client verifies against the actual rate applied, not its current
    /// local state — prevents a ServiceUpdate arrival ordering race from triggering false
    /// fraud detection. Zero means legacy response; client falls back to connectedProvider.tokenRate.
    public let tokenRate: UInt64

    public init(tokensUsed: UInt64, cumulativeTabTokens: UInt64,
                tabThreshold: UInt64, tokenRate: UInt64) {
        self.tokensUsed = tokensUsed
        self.cumulativeTabTokens = cumulativeTabTokens
        self.tabThreshold = tabThreshold
        self.tokenRate = tokenRate
    }

    /// Custom decoder: old responses without tokenRate decode as 0 (client falls back to connectedProvider.tokenRate).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokensUsed = try c.decode(UInt64.self, forKey: .tokensUsed)
        cumulativeTabTokens = try c.decode(UInt64.self, forKey: .cumulativeTabTokens)
        tabThreshold = try c.decode(UInt64.self, forKey: .tabThreshold)
        tokenRate = (try? c.decodeIfPresent(UInt64.self, forKey: .tokenRate)) ?? 0
    }
}
