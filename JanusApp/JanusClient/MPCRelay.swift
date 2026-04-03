import Foundation
import MultipeerConnectivity
import JanusShared
import UIKit

/// Relay node that bridges clients to providers over MPC.
///
/// Browses for providers (`janus-ai`), advertises as a relay (`janus-relay`),
/// and forwards messages bidirectionally. The provider never sees the relay —
/// it receives standard MessageEnvelopes as if the client were directly connected.
@MainActor
class MPCRelay: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var isRunning = false
    /// Providers the relay has connected to.
    @Published var reachableProviders: [String: ServiceAnnounce] = [:]  // providerID → announce
    /// Connected clients (downstream).
    @Published var connectedClients: [MCPeerID: String] = [:]  // peerID → display name
    /// Number of messages forwarded.
    @Published var forwardedCount = 0

    // MARK: - MPC infrastructure

    private let providerServiceType = "janus-ai"
    private let relayServiceType = "janus-relay"

    nonisolated(unsafe) private let peerID: MCPeerID
    /// Browses for providers upstream.
    nonisolated(unsafe) private let providerBrowser: MCNearbyServiceBrowser
    /// Advertises relay service to clients downstream.
    nonisolated(unsafe) private let clientAdvertiser: MCNearbyServiceAdvertiser

    /// Per-provider MPC sessions (upstream).
    nonisolated(unsafe) private var providerSessions: [MCPeerID: MCSession] = [:]
    /// Per-client MPC sessions (downstream).
    nonisolated(unsafe) private var clientSessions: [MCPeerID: MCSession] = [:]

    // MARK: - Routing tables

    /// Maps provider ID → provider MPC peer (for forwarding client→provider).
    private var providerRoutes: [String: MCPeerID] = [:]
    /// Maps senderID (from MessageEnvelope) → client MPC peer (for routing responses back).
    private var clientRoutes: [String: MCPeerID] = [:]
    /// Maps provider MPC peer → provider ID (for routing provider responses to clients).
    private var peerToProviderID: [MCPeerID: String] = [:]

    // MARK: - Init

    override init() {
        let name = UIDevice.current.name
        self.peerID = MCPeerID(displayName: name)
        self.providerBrowser = MCNearbyServiceBrowser(peer: peerID, serviceType: providerServiceType)
        self.clientAdvertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["type": "relay"], serviceType: relayServiceType)
        super.init()
        self.providerBrowser.delegate = self
        self.clientAdvertiser.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        isRunning = true
        forwardedCount = 0
        reachableProviders.removeAll()
        connectedClients.removeAll()
        providerRoutes.removeAll()
        clientRoutes.removeAll()
        peerToProviderID.removeAll()

        // Keep screen awake so MPC sessions survive
        UIApplication.shared.isIdleTimerDisabled = true

        // Browse for providers first
        providerBrowser.startBrowsingForPeers()
        print("[Relay] Started browsing for providers")
    }

    func stop() {
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        providerBrowser.stopBrowsingForPeers()
        clientAdvertiser.stopAdvertisingPeer()
        // Disconnect all sessions
        for session in providerSessions.values { session.disconnect() }
        for session in clientSessions.values { session.disconnect() }
        providerSessions.removeAll()
        clientSessions.removeAll()
        reachableProviders.removeAll()
        connectedClients.removeAll()
        providerRoutes.removeAll()
        clientRoutes.removeAll()
        peerToProviderID.removeAll()
        print("[Relay] Stopped")
    }

    // MARK: - Advertising control

    /// Start advertising as relay once we have at least one provider.
    private func startAdvertisingIfNeeded() {
        guard isRunning, !reachableProviders.isEmpty else { return }
        clientAdvertiser.startAdvertisingPeer()
        print("[Relay] Advertising as relay with \(reachableProviders.count) provider(s)")
    }

    /// Stop advertising if no providers are reachable.
    private func stopAdvertisingIfNeeded() {
        if reachableProviders.isEmpty {
            clientAdvertiser.stopAdvertisingPeer()
            print("[Relay] No providers reachable — stopped advertising")
        }
    }

    // MARK: - Send RelayAnnounce to a client

    private func sendRelayAnnounce(to clientPeer: MCPeerID) {
        guard let session = clientSessions[clientPeer] else { return }
        let announce = RelayAnnounce(
            relayName: peerID.displayName,
            reachableProviders: reachableProviders.values.map { RelayProviderInfo(from: $0) }
        )
        do {
            let envelope = try MessageEnvelope.wrap(
                type: .relayAnnounce,
                senderID: "relay",
                payload: announce
            )
            let data = try envelope.serialized()
            try session.send(data, toPeers: [clientPeer], with: .reliable)
            print("[Relay] Sent RelayAnnounce to \(clientPeer.displayName)")
        } catch {
            print("[Relay] Failed to send RelayAnnounce: \(error)")
        }
    }

    // MARK: - Forward ServiceAnnounce to a client

    /// Forward the full ServiceAnnounce from a provider to a client,
    /// wrapped in a RelayEnvelope so the client knows it's relayed.
    private func forwardServiceAnnounce(_ announce: ServiceAnnounce, to clientPeer: MCPeerID) {
        guard let session = clientSessions[clientPeer] else { return }
        do {
            let innerEnvelope = try MessageEnvelope.wrap(
                type: .serviceAnnounce,
                senderID: announce.providerID,
                payload: announce
            )
            let relayEnvelope = try RelayEnvelope.wrap(
                envelope: innerEnvelope,
                destinationID: "client",
                originID: announce.providerID
            )
            let data = try relayEnvelope.serialized()
            // Send as raw data — client will detect RelayEnvelope format
            try session.send(data, toPeers: [clientPeer], with: .reliable)
            print("[Relay] Forwarded ServiceAnnounce from \(announce.providerName) to \(clientPeer.displayName)")
        } catch {
            print("[Relay] Failed to forward ServiceAnnounce: \(error)")
        }
    }

    // MARK: - Message forwarding

    /// Forward a message from client to provider.
    /// Client sends RelayEnvelope; relay unwraps and sends bare MessageEnvelope to provider.
    private func forwardToProvider(_ relayEnvelope: RelayEnvelope, from clientPeer: MCPeerID) {
        guard relayEnvelope.hopCount < relayEnvelope.maxHops else {
            print("[Relay] Dropping message — hop count exceeded")
            return
        }

        let providerID = relayEnvelope.destinationID
        guard let providerPeer = providerRoutes[providerID],
              let session = providerSessions[providerPeer],
              session.connectedPeers.contains(providerPeer) else {
            print("[Relay] Cannot forward to provider \(providerID) — not connected")
            return
        }

        // Register the sender for response routing
        clientRoutes[relayEnvelope.originID] = clientPeer

        // Unwrap and send bare MessageEnvelope to provider (provider transparency)
        do {
            try session.send(relayEnvelope.innerEnvelope, toPeers: [providerPeer], with: .reliable)
            forwardedCount += 1
            print("[Relay] Forwarded client→provider (\(providerID.prefix(8))...) count=\(forwardedCount)")
        } catch {
            print("[Relay] Failed to forward to provider: \(error)")
        }
    }

    /// Forward a message from provider to the originating client.
    /// Provider sends bare MessageEnvelope; relay wraps in RelayEnvelope for client.
    private func forwardToClient(_ envelope: MessageEnvelope, from providerPeer: MCPeerID) {
        // Look up which client this response is for
        let senderID = envelope.senderID
        guard let providerID = peerToProviderID[providerPeer] else {
            print("[Relay] Unknown provider peer — cannot route response")
            return
        }

        // The response's destination is the client. Find the client peer.
        // For provider→client messages, the envelope's implicit destination is
        // whoever sent the original request. We look up by checking clientRoutes
        // for any client that has an active route to this provider.
        guard let clientPeer = findClientForProvider(providerID),
              let session = clientSessions[clientPeer],
              session.connectedPeers.contains(clientPeer) else {
            print("[Relay] Cannot route response — no client found for provider \(providerID.prefix(8))...")
            return
        }

        do {
            let relayEnvelope = try RelayEnvelope.wrap(
                envelope: envelope,
                destinationID: "client",
                originID: providerID
            )
            let data = try relayEnvelope.serialized()
            try session.send(data, toPeers: [clientPeer], with: .reliable)
            forwardedCount += 1
            print("[Relay] Forwarded provider→client count=\(forwardedCount)")
        } catch {
            print("[Relay] Failed to forward to client: \(error)")
        }
    }

    /// Find the client peer that is communicating with a given provider.
    private func findClientForProvider(_ providerID: String) -> MCPeerID? {
        // In Phase 1 (single-hop), there's typically one client per provider route.
        // Look through clientRoutes for any senderID that has been routing to this provider.
        // For simplicity, if there's only one connected client, return it.
        if connectedClients.count == 1, let peer = connectedClients.keys.first {
            return peer
        }
        // Multi-client: look up from clientRoutes
        // The clientRoutes maps senderID → clientPeer. We need to find which senderID
        // was targeting this provider. For now, return the most recently registered client.
        return clientRoutes.values.first
    }

    // MARK: - Session creation

    private func createProviderSession(for peer: MCPeerID) -> MCSession {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        providerSessions[peer] = session
        return session
    }

    private func createClientSession(for peer: MCPeerID) -> MCSession {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        clientSessions[peer] = session
        return session
    }

    /// Determine if a peer is a provider (upstream) or client (downstream).
    private func isProviderPeer(_ peer: MCPeerID) -> Bool {
        providerSessions[peer] != nil
    }
}

// MARK: - MCNearbyServiceBrowserDelegate (discovering providers)

extension MPCRelay: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard isRunning else { return }
            // Only connect to providers we haven't already connected to
            guard providerSessions[peerID] == nil else { return }
            let session = createProviderSession(for: peerID)
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
            print("[Relay] Found provider: \(peerID.displayName), inviting...")
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let providerID = peerToProviderID[peerID] else { return }
            reachableProviders.removeValue(forKey: providerID)
            providerRoutes.removeValue(forKey: providerID)
            peerToProviderID.removeValue(forKey: peerID)
            providerSessions.removeValue(forKey: peerID)
            stopAdvertisingIfNeeded()
            print("[Relay] Lost provider: \(peerID.displayName)")
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate (accepting clients)

extension MPCRelay: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            let session = createClientSession(for: peerID)
            invitationHandler(true, session)
            print("[Relay] Accepted client connection: \(peerID.displayName)")
        }
    }
}

// MARK: - MCSessionDelegate (handling both provider and client sessions)

extension MPCRelay: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            if isProviderPeer(peerID) {
                handleProviderStateChange(peer: peerID, state: state)
            } else if clientSessions[peerID] != nil {
                handleClientStateChange(peer: peerID, state: state)
            }
        }
    }

    private func handleProviderStateChange(peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            print("[Relay] Connected to provider: \(peer.displayName)")
            // ServiceAnnounce will arrive via didReceive data
        case .notConnected:
            if let providerID = peerToProviderID[peer] {
                reachableProviders.removeValue(forKey: providerID)
                providerRoutes.removeValue(forKey: providerID)
                peerToProviderID.removeValue(forKey: peer)
                print("[Relay] Provider disconnected: \(peer.displayName)")
            }
            providerSessions.removeValue(forKey: peer)
            stopAdvertisingIfNeeded()
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    private func handleClientStateChange(peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            connectedClients[peer] = peer.displayName
            // Send RelayAnnounce so client knows which providers are available
            sendRelayAnnounce(to: peer)
            // Forward ServiceAnnounce from each provider so client can set up sessions
            for announce in reachableProviders.values {
                forwardServiceAnnounce(announce, to: peer)
            }
            print("[Relay] Client connected: \(peer.displayName) (total: \(connectedClients.count))")
        case .notConnected:
            if let name = connectedClients.removeValue(forKey: peer) {
                // Clean up routes for this client
                clientRoutes = clientRoutes.filter { $0.value != peer }
                clientSessions.removeValue(forKey: peer)
                print("[Relay] Client disconnected: \(name) (total: \(connectedClients.count))")
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            if isProviderPeer(peerID) {
                handleProviderData(data, from: peerID)
            } else {
                handleClientData(data, from: peerID)
            }
        }
    }

    /// Handle data from a provider (upstream).
    private func handleProviderData(_ data: Data, from peerID: MCPeerID) {
        // Providers send bare MessageEnvelopes
        guard let envelope = try? MessageEnvelope.deserialize(from: data) else { return }

        switch envelope.type {
        case .serviceAnnounce:
            // Provider announcing itself — store and start advertising
            if let announce = try? envelope.unwrap(as: ServiceAnnounce.self) {
                reachableProviders[announce.providerID] = announce
                providerRoutes[announce.providerID] = peerID
                peerToProviderID[peerID] = announce.providerID
                startAdvertisingIfNeeded()
                print("[Relay] Registered provider: \(announce.providerName) (\(announce.providerID.prefix(8))...)")

                // Forward to already-connected clients
                for clientPeer in connectedClients.keys {
                    sendRelayAnnounce(to: clientPeer)
                    forwardServiceAnnounce(announce, to: clientPeer)
                }
            }
        case .ping, .pong:
            break
        default:
            // Response from provider — forward to the originating client
            forwardToClient(envelope, from: peerID)
        }
    }

    /// Handle data from a client (downstream).
    private func handleClientData(_ data: Data, from peerID: MCPeerID) {
        // Clients send RelayEnvelopes
        guard let relayEnvelope = try? RelayEnvelope.deserialize(from: data) else {
            print("[Relay] Received non-RelayEnvelope from client — ignoring")
            return
        }
        forwardToProvider(relayEnvelope, from: peerID)
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
