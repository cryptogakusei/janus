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

    // MARK: - In-flight request tracking

    /// Tracks forwarded requests awaiting a response from the provider.
    /// Key is originID (client session ID), value is the in-flight request info.
    private var inFlightRequests: [String: InFlightRequest] = [:]

    /// How long the relay waits for a provider response before sending a timeout error.
    /// Must be shorter than the client's 20s timeout so the relay error arrives first.
    private let relayTimeoutInterval: TimeInterval = 15

    private struct InFlightRequest {
        let clientPeer: MCPeerID
        let providerID: String
        let messageType: MessageType
        let forwardedAt: Date
        let timeoutTask: Task<Void, Never>
    }

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
        cancelAllInFlightTimeouts()

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
        cancelAllInFlightTimeouts()
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
            sendProviderUnreachableError(to: clientPeer)
            return
        }

        // Register the sender for response routing
        clientRoutes[relayEnvelope.originID] = clientPeer

        // Peek at inner envelope to track request types that expect a response
        if let innerEnvelope = try? relayEnvelope.unwrapInner(),
           innerEnvelope.type == .promptRequest || innerEnvelope.type == .voucherAuthorization {
            trackInFlightRequest(
                originID: relayEnvelope.originID,
                clientPeer: clientPeer,
                providerID: providerID,
                messageType: innerEnvelope.type
            )
        }

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
        // Clear in-flight tracking for response types
        if envelope.type == .quoteResponse || envelope.type == .inferenceResponse || envelope.type == .errorResponse || envelope.type == .sessionSync {
            // Find which client's in-flight request this response satisfies.
            // The provider doesn't know the originID, so we match by providerID.
            if let providerID = peerToProviderID[providerPeer] {
                let matching = inFlightRequests.filter { $0.value.providerID == providerID }
                for (key, _) in matching {
                    clearInFlightRequest(originID: key)
                }
            }
        }

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

    /// Send a providerUnreachable error back to a client whose message could not be forwarded.
    private func sendProviderUnreachableError(to clientPeer: MCPeerID) {
        guard let session = clientSessions[clientPeer] else { return }
        let error = ErrorResponse(
            requestID: nil,
            errorCode: .providerUnreachable,
            errorMessage: "Provider is no longer reachable through this relay"
        )
        do {
            let innerEnvelope = try MessageEnvelope.wrap(
                type: .errorResponse,
                senderID: "relay",
                payload: error
            )
            let relayEnvelope = try RelayEnvelope.wrap(
                envelope: innerEnvelope,
                destinationID: "client",
                originID: "relay"
            )
            let data = try relayEnvelope.serialized()
            try session.send(data, toPeers: [clientPeer], with: .reliable)
            print("[Relay] Sent providerUnreachable error to \(clientPeer.displayName)")
        } catch {
            print("[Relay] Failed to send error to client: \(error)")
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

    // MARK: - In-flight request timeout

    /// Track a forwarded request that expects a response from the provider.
    private func trackInFlightRequest(originID: String, clientPeer: MCPeerID, providerID: String, messageType: MessageType) {
        // Cancel any existing timeout for this client (shouldn't happen, but be safe)
        inFlightRequests[originID]?.timeoutTask.cancel()

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(15_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleRelayTimeout(originID: originID)
        }

        inFlightRequests[originID] = InFlightRequest(
            clientPeer: clientPeer,
            providerID: providerID,
            messageType: messageType,
            forwardedAt: Date(),
            timeoutTask: timeoutTask
        )
        print("[Relay] Tracking in-flight \(messageType) for \(originID.prefix(8))... (timeout: \(Int(relayTimeoutInterval))s)")
    }

    /// Clear the in-flight tracker when a response arrives.
    private func clearInFlightRequest(originID: String) {
        if let request = inFlightRequests.removeValue(forKey: originID) {
            request.timeoutTask.cancel()
            let elapsed = Date().timeIntervalSince(request.forwardedAt)
            print("[Relay] Cleared in-flight \(request.messageType) for \(originID.prefix(8))... (responded in \(String(format: "%.1f", elapsed))s)")
        }
    }

    /// Handle a relay timeout — provider didn't respond in time.
    private func handleRelayTimeout(originID: String) {
        guard let request = inFlightRequests.removeValue(forKey: originID) else { return }
        print("[Relay] Timeout: provider \(request.providerID.prefix(8))... did not respond within \(Int(relayTimeoutInterval))s for \(originID.prefix(8))...")

        sendRelayTimeoutError(to: request.clientPeer, providerID: request.providerID)
    }

    /// Send a relayTimeout error back to the client.
    private func sendRelayTimeoutError(to clientPeer: MCPeerID, providerID: String) {
        guard let session = clientSessions[clientPeer] else { return }
        let error = ErrorResponse(
            requestID: nil,
            errorCode: .relayTimeout,
            errorMessage: "Provider did not respond within \(Int(relayTimeoutInterval))s"
        )
        do {
            let innerEnvelope = try MessageEnvelope.wrap(
                type: .errorResponse,
                senderID: "relay",
                payload: error
            )
            let relayEnvelope = try RelayEnvelope.wrap(
                envelope: innerEnvelope,
                destinationID: "client",
                originID: providerID
            )
            let data = try relayEnvelope.serialized()
            try session.send(data, toPeers: [clientPeer], with: .reliable)
            print("[Relay] Sent relayTimeout error to \(clientPeer.displayName)")
        } catch {
            print("[Relay] Failed to send timeout error: \(error)")
        }
    }

    /// Cancel all in-flight timeouts (used during cleanup).
    private func cancelAllInFlightTimeouts() {
        for request in inFlightRequests.values {
            request.timeoutTask.cancel()
        }
        inFlightRequests.removeAll()
    }

    /// Cancel in-flight requests for a specific client (used on client disconnect).
    private func cancelInFlightRequests(for clientPeer: MCPeerID) {
        let toRemove = inFlightRequests.filter { $0.value.clientPeer == clientPeer }
        for (key, request) in toRemove {
            request.timeoutTask.cancel()
            inFlightRequests.removeValue(forKey: key)
        }
    }

    /// Cancel in-flight requests targeting a specific provider (used on provider disconnect).
    private func cancelInFlightRequests(forProvider providerID: String) {
        let toRemove = inFlightRequests.filter { $0.value.providerID == providerID }
        for (key, request) in toRemove {
            request.timeoutTask.cancel()
            inFlightRequests.removeValue(forKey: key)
            // Also notify the client that their request won't be answered
            sendProviderUnreachableError(to: request.clientPeer)
        }
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
            // Notify all connected clients that provider list changed
            for clientPeer in connectedClients.keys {
                sendRelayAnnounce(to: clientPeer)
            }
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
                // Notify clients with in-flight requests that provider is gone
                cancelInFlightRequests(forProvider: providerID)
                reachableProviders.removeValue(forKey: providerID)
                providerRoutes.removeValue(forKey: providerID)
                peerToProviderID.removeValue(forKey: peer)
                print("[Relay] Provider disconnected: \(peer.displayName)")
            }
            providerSessions.removeValue(forKey: peer)
            // Notify all connected clients that provider list changed
            for clientPeer in connectedClients.keys {
                sendRelayAnnounce(to: clientPeer)
            }
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
                // Clean up routes and in-flight requests for this client
                clientRoutes = clientRoutes.filter { $0.value != peer }
                cancelInFlightRequests(for: peer)
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
