import Foundation

/// Broadcast by the provider when a client connects.
///
/// Contains everything the client needs to decide whether to use this provider:
/// identity, capabilities, pricing, and availability.
public struct ServiceAnnounce: Codable, Sendable {
    public let providerID: String
    public let providerName: String
    public let modelTier: String
    public let supportedTasks: [TaskType]
    /// Legacy fixed-tier pricing. Nil for tab-model providers; present for old prepaid providers.
    public let pricing: Pricing?
    public let available: Bool
    public let queueDepth: Int
    /// Base64-encoded Ed25519 public key for receipt verification.
    public let providerPubkey: String
    /// Ethereum address (hex, EIP-55 checksummed) for Tempo voucher sessions.
    public let providerEthAddress: String?
    /// Credits charged per 1000 tokens (tab model). Default 10.
    /// `var` so ClientEngine.handleServiceUpdate can update in place after a live pricing push.
    public var tokenRate: UInt64
    /// Tokens before settlement is required (tab model). Default 500.
    /// `var` so ClientEngine.handleServiceUpdate can update in place after a live pricing push.
    public var tabThreshold: UInt64
    /// Maximum output tokens per request. Default 1024.
    public let maxOutputTokens: Int
    /// Payment model: "tab" (postpaid, per-token) or "prepaid" (quote-driven). Default "prepaid".
    public let paymentModel: String

    public init(
        providerID: String,
        providerName: String,
        modelTier: String = "small-text-v1",
        supportedTasks: [TaskType] = TaskType.allCases,
        pricing: Pricing? = .default,
        available: Bool = true,
        queueDepth: Int = 0,
        providerPubkey: String = "",
        providerEthAddress: String? = nil,
        tokenRate: UInt64 = 10,
        tabThreshold: UInt64 = 500,
        maxOutputTokens: Int = 1024,
        paymentModel: String = "tab"
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelTier = modelTier
        self.supportedTasks = supportedTasks
        self.pricing = pricing
        self.available = available
        self.queueDepth = queueDepth
        self.providerPubkey = providerPubkey
        self.providerEthAddress = providerEthAddress
        self.tokenRate = tokenRate
        self.tabThreshold = tabThreshold
        self.maxOutputTokens = maxOutputTokens
        self.paymentModel = paymentModel
    }

    /// Custom decoder: handles both old (pricing non-optional, no tab fields) and new schemas.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try c.decode(String.self, forKey: .providerID)
        providerName = try c.decode(String.self, forKey: .providerName)
        modelTier = try c.decodeIfPresent(String.self, forKey: .modelTier) ?? "small-text-v1"
        supportedTasks = try c.decodeIfPresent([TaskType].self, forKey: .supportedTasks) ?? TaskType.allCases
        pricing = try c.decodeIfPresent(Pricing.self, forKey: .pricing)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? true
        queueDepth = try c.decodeIfPresent(Int.self, forKey: .queueDepth) ?? 0
        providerPubkey = try c.decodeIfPresent(String.self, forKey: .providerPubkey) ?? ""
        providerEthAddress = try c.decodeIfPresent(String.self, forKey: .providerEthAddress)
        tokenRate = try c.decodeIfPresent(UInt64.self, forKey: .tokenRate) ?? 10
        tabThreshold = try c.decodeIfPresent(UInt64.self, forKey: .tabThreshold) ?? 500
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 1024
        paymentModel = try c.decodeIfPresent(String.self, forKey: .paymentModel) ?? "prepaid"
    }
}

/// Credit costs per legacy fixed pricing tier.
/// Kept for backward compatibility with old prepaid providers.
public struct Pricing: Codable, Sendable {
    public let small: Int
    public let medium: Int
    public let large: Int

    public init(small: Int, medium: Int, large: Int) {
        self.small = small
        self.medium = medium
        self.large = large
    }

    public static let `default` = Pricing(small: 3, medium: 5, large: 8)
}
