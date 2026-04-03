import Foundation

/// Sent by a relay to connected clients listing which providers it can reach.
///
/// The client uses this to decide whether to connect through the relay.
/// Sent immediately when a client connects to the relay, and re-sent
/// whenever the relay's reachable provider list changes.
public struct RelayAnnounce: Codable, Sendable {
    /// The relay's display name.
    public let relayName: String
    /// Providers the relay can currently reach, keyed by provider ID.
    public let reachableProviders: [RelayProviderInfo]

    public init(relayName: String, reachableProviders: [RelayProviderInfo]) {
        self.relayName = relayName
        self.reachableProviders = reachableProviders
    }
}

/// Summary of a provider reachable through a relay.
/// Carries enough info for the client to decide which provider to use.
public struct RelayProviderInfo: Codable, Sendable, Identifiable {
    public var id: String { providerID }
    public let providerID: String
    public let providerName: String
    public let providerPubkey: String
    public let providerEthAddress: String?

    public init(providerID: String, providerName: String, providerPubkey: String = "", providerEthAddress: String? = nil) {
        self.providerID = providerID
        self.providerName = providerName
        self.providerPubkey = providerPubkey
        self.providerEthAddress = providerEthAddress
    }

    /// Create from a full ServiceAnnounce.
    public init(from announce: ServiceAnnounce) {
        self.providerID = announce.providerID
        self.providerName = announce.providerName
        self.providerPubkey = announce.providerPubkey
        self.providerEthAddress = announce.providerEthAddress
    }
}
