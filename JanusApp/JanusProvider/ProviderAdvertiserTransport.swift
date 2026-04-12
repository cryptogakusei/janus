import Foundation
import JanusShared

/// Abstraction over the provider's transport layer.
///
/// `MPCAdvertiser` implements this for MPC/AWDL connections.
/// `BonjourAdvertiser` implements this for Bonjour+TCP connections.
/// `CompositeAdvertiser` wraps both for simultaneous advertising.
@MainActor
protocol ProviderAdvertiserTransport: AnyObject {
    var isAdvertising: Bool { get }

    /// Connected clients: senderID → display name.
    var connectedClients: [String: String] { get }

    /// Callback when a message arrives from a client. String is the senderID.
    var onMessageReceived: ((MessageEnvelope, String) -> Void)? { get set }

    /// Callback when a client disconnects. String is the senderID or display name.
    var onClientDisconnected: ((String) -> Void)? { get set }

    func startAdvertising()
    func stopAdvertising()
    func send(_ envelope: MessageEnvelope, to senderID: String) throws
    func updateServiceAnnounce(providerPubkey: String, providerEthAddress: String?)

    /// Look up the display name for a senderID.
    func displayName(forSender senderID: String) -> String?

    /// Check whether a senderID is currently connected.
    func isConnected(senderID: String) -> Bool

    /// Get display name for any of the given senderIDs (identity-based grouping).
    func displayName(forSenderIDs senderIDs: [String]) -> String?

    /// Check if ANY of the given senderIDs is currently connected.
    func isConnected(senderIDs: [String]) -> Bool
}

// Default implementations derived from connectedClients.
extension ProviderAdvertiserTransport {
    func displayName(forSender senderID: String) -> String? {
        connectedClients[senderID]
    }

    func isConnected(senderID: String) -> Bool {
        connectedClients[senderID] != nil
    }

    func displayName(forSenderIDs senderIDs: [String]) -> String? {
        for id in senderIDs {
            if let name = connectedClients[id] { return name }
        }
        return nil
    }

    func isConnected(senderIDs: [String]) -> Bool {
        senderIDs.contains { connectedClients[$0] != nil }
    }
}
