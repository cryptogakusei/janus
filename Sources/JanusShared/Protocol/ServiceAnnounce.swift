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
    public let pricing: Pricing
    public let available: Bool
    public let queueDepth: Int
    /// Base64-encoded Ed25519 public key for receipt verification.
    public let providerPubkey: String
    /// Ethereum address (hex, EIP-55 checksummed) for Tempo voucher sessions.
    public let providerEthAddress: String?

    public init(
        providerID: String,
        providerName: String,
        modelTier: String = "small-text-v1",
        supportedTasks: [TaskType] = TaskType.allCases,
        pricing: Pricing = .default,
        available: Bool = true,
        queueDepth: Int = 0,
        providerPubkey: String = "",
        providerEthAddress: String? = nil
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
    }
}

/// Credit costs per pricing tier.
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
