import Foundation
import MultipeerConnectivity
import JanusShared

/// Advertises the Janus provider over Multipeer Connectivity.
///
/// Supports multiple simultaneous clients. Each client gets its own independent
/// MCSession so that one client disconnecting cannot affect another.
@MainActor
class MPCAdvertiser: NSObject, ObservableObject, ProviderAdvertiserTransport {

    @Published var isAdvertising = false
    @Published var connectedPeers: [MCPeerID: String] = [:]  // peerID → display name

    /// Protocol-conforming view of connected clients: senderID → display name.
    var connectedClients: [String: String] {
        var result: [String: String] = [:]
        for (senderID, peer) in senderToPeer {
            if let name = connectedPeers[peer] {
                result[senderID] = name
            }
        }
        return result
    }

    private let serviceType = "janus-ai"
    nonisolated(unsafe) private let peerID: MCPeerID
    nonisolated(unsafe) private let advertiser: MCNearbyServiceAdvertiser

    /// One MCSession per client — isolates peers so one bad connection can't poison another.
    nonisolated(unsafe) private var clientSessions: [MCPeerID: MCSession] = [:]

    private var serviceAnnounce: ServiceAnnounce

    // Maps senderID (from MessageEnvelope) → MCPeerID for routing replies
    private var senderToPeer: [String: MCPeerID] = [:]

    /// Callback for received messages from clients. String is the senderID from the envelope.
    var onMessageReceived: ((MessageEnvelope, String) -> Void)?

    /// Callback when a specific client disconnects. Passes the peer's display name.
    var onClientDisconnected: ((String) -> Void)?

    init(providerName: String, providerID: String, providerPubkey: String = "") {
        self.peerID = MCPeerID(displayName: providerName)
        self.advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        self.serviceAnnounce = ServiceAnnounce(
            providerID: providerID,
            providerName: providerName,
            providerPubkey: providerPubkey
        )
        super.init()
        self.advertiser.delegate = self
    }

    func startAdvertising() {
        isAdvertising = true
        advertiser.startAdvertisingPeer()
    }

    func stopAdvertising() {
        isAdvertising = false
        advertiser.stopAdvertisingPeer()
    }

    /// Update the ServiceAnnounce with provider identity (pubkey + Ethereum address).
    /// Called after ProviderEngine has initialized its keypairs.
    func updateServiceAnnounce(providerPubkey: String, providerEthAddress: String?) {
        serviceAnnounce = ServiceAnnounce(
            providerID: serviceAnnounce.providerID,
            providerName: serviceAnnounce.providerName,
            providerPubkey: providerPubkey,
            providerEthAddress: providerEthAddress
        )
    }

    /// Send a message envelope to a specific peer by sender ID.
    func send(_ envelope: MessageEnvelope, to senderID: String) throws {
        guard let peer = senderToPeer[senderID],
              let session = clientSessions[peer],
              session.connectedPeers.contains(peer) else {
            throw MPCError.notConnected
        }
        let data = try envelope.serialized()
        try session.send(data, toPeers: [peer], with: .reliable)
    }

    /// Send a message envelope to a specific MPC peer directly.
    func send(_ envelope: MessageEnvelope, toPeer peer: MCPeerID) throws {
        guard let session = clientSessions[peer],
              session.connectedPeers.contains(peer) else {
            throw MPCError.notConnected
        }
        let data = try envelope.serialized()
        try session.send(data, toPeers: [peer], with: .reliable)
    }

    var connectedClientName: String? {
        connectedPeers.values.first
    }

    /// Look up the display name for a given senderID (from MessageEnvelope).
    func displayName(forSender senderID: String) -> String? {
        guard let peer = senderToPeer[senderID] else { return nil }
        return connectedPeers[peer]
    }

    /// Check whether a senderID is currently connected.
    func isConnected(senderID: String) -> Bool {
        guard let peer = senderToPeer[senderID],
              let session = clientSessions[peer] else { return false }
        return session.connectedPeers.contains(peer)
    }

    /// Get display name for any of the given senderIDs (identity-based grouping).
    func displayName(forSenderIDs senderIDs: [String]) -> String? {
        for id in senderIDs {
            if let peer = senderToPeer[id] { return connectedPeers[peer] }
        }
        return nil
    }

    /// Check if ANY of the given senderIDs is currently connected.
    func isConnected(senderIDs: [String]) -> Bool {
        senderIDs.contains { id in
            guard let peer = senderToPeer[id],
                  let session = clientSessions[peer] else { return false }
            return session.connectedPeers.contains(peer)
        }
    }

    /// Send ServiceAnnounce to a connected client via their dedicated session.
    private func sendServiceAnnounce(to peer: MCPeerID) {
        guard let session = clientSessions[peer] else { return }
        do {
            let envelope = try MessageEnvelope.wrap(
                type: .serviceAnnounce,
                senderID: serviceAnnounce.providerID,
                payload: serviceAnnounce
            )
            let data = try envelope.serialized()
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            print("Failed to send ServiceAnnounce: \(error)")
        }
    }

    /// Create a fresh MCSession for an incoming client.
    private func createSession(for clientPeer: MCPeerID) -> MCSession {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        clientSessions[clientPeer] = session
        return session
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MPCAdvertiser: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Each client gets its own MCSession — fully isolated
        Task { @MainActor in
            let session = createSession(for: peerID)
            invitationHandler(true, session)
        }
    }
}

// MARK: - MCSessionDelegate

extension MPCAdvertiser: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                connectedPeers[peerID] = peerID.displayName
                sendServiceAnnounce(to: peerID)
                print("Client connected: \(peerID.displayName) (total: \(connectedPeers.count))")
            case .notConnected:
                if let name = connectedPeers.removeValue(forKey: peerID) {
                    senderToPeer = senderToPeer.filter { $0.value != peerID }
                    clientSessions.removeValue(forKey: peerID)
                    onClientDisconnected?(name)
                    print("Client disconnected: \(name) (total: \(connectedPeers.count))")
                }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let envelope = try? MessageEnvelope.deserialize(from: data) else { return }
            // Register the sender→peer mapping so we can route replies
            senderToPeer[envelope.senderID] = peerID

            // Ignore ping/pong
            guard envelope.type != .ping && envelope.type != .pong else { return }

            onMessageReceived?(envelope, envelope.senderID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
