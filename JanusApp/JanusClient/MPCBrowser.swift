import Foundation
import MultipeerConnectivity
import JanusShared
import UIKit

/// Discovers nearby Janus providers via Multipeer Connectivity.
///
/// Publishes discovered providers and handles bidirectional JSON messaging.
/// Supports two connection modes:
/// - **Direct**: client ↔ provider via MPC (browses `janus-ai`)
/// - **Relayed**: client ↔ relay ↔ provider (browses `janus-relay`)
@MainActor
class MPCBrowser: NSObject, ObservableObject, ProviderTransport {

    // Typealiases for backward compatibility (enums moved to ProviderTransport.swift)
    typealias ConnectionState = JanusClient.ConnectionState
    typealias ConnectionMode = JanusClient.ConnectionMode

    /// Currently discovered provider info (nil if no provider connected).
    @Published var connectedProvider: ServiceAnnounce?
    @Published var isSearching = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectionMode: ConnectionMode = .disconnected

    /// All providers available through the relay (providerID → ServiceAnnounce).
    /// Only populated when connected via relay with multiple providers.
    @Published var relayProviders: [String: ServiceAnnounce] = [:]

    /// Developer toggle: when true, ignores direct providers and only connects via relays.
    @Published var forceRelayMode = false

    // MARK: - ProviderTransport publisher accessors

    var connectedProviderPublisher: Published<ServiceAnnounce?>.Publisher { $connectedProvider }
    var isSearchingPublisher: Published<Bool>.Publisher { $isSearching }
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    private let providerServiceType = "janus-ai"
    private let relayServiceType = "janus-relay"
    nonisolated(unsafe) private let peerID: MCPeerID

    // Direct provider connection
    nonisolated(unsafe) private let providerBrowser: MCNearbyServiceBrowser
    nonisolated(unsafe) private var providerSession: MCSession
    private var providerPeerID: MCPeerID?

    // Relay connection
    nonisolated(unsafe) private let relayBrowser: MCNearbyServiceBrowser
    nonisolated(unsafe) private var relaySession: MCSession
    private var relayPeerID: MCPeerID?
    private var relayProviderID: String?  // which provider we're targeting through the relay
    private var relayRouteID: String?     // route ID for relay communication

    /// Callback for received messages.
    var onMessageReceived: ((MessageEnvelope) -> Void)?

    /// Track whether each browser is actively browsing to prevent double-stop crashes.
    /// iOS 26's CFNetServiceBrowser asserts on stop if the run loop source was already invalidated.
    private var providerBrowserActive = false
    private var relayBrowserActive = false

    /// Whether auto-reconnect is active (disabled on manual disconnect).
    private var autoReconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var relayInfoTimeoutTask: Task<Void, Never>?
    /// Consecutive connection timeouts — if >= 2, provider is likely discoverable
    /// via Bluetooth but unreachable via WiFi/AWDL (WiFi off on provider side).
    private var consecutiveTimeouts = 0
    private let maxTimeoutsBeforeWarning = 2

    override init() {
        self.peerID = MCPeerID(displayName: UIDevice.current.name)
        self.providerSession = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.providerBrowser = MCNearbyServiceBrowser(peer: peerID, serviceType: providerServiceType)
        self.relaySession = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.relayBrowser = MCNearbyServiceBrowser(peer: peerID, serviceType: relayServiceType)
        super.init()
        self.providerSession.delegate = self
        self.providerBrowser.delegate = self
        self.relaySession.delegate = self
        self.relayBrowser.delegate = self

        // Check connection health when app returns to foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkConnectionHealth()
            }
        }
    }

    func startSearching() {
        autoReconnect = true
        isSearching = true
        connectionState = .disconnected
        connectionMode = .disconnected
        connectedProvider = nil
        relayProviders = [:]
        consecutiveTimeouts = 0
        // Clear all peer state from previous connections
        providerPeerID = nil
        relayPeerID = nil
        relayProviderID = nil
        relayRouteID = nil
        relayInfoTimeoutTask?.cancel()
        // Stop and fully tear down before restarting
        stopProviderBrowser()
        stopRelayBrowser()
        resetProviderSession()
        resetRelaySession()

        // Brief delay lets MPC fully clean up cached peer state before re-browsing.
        // Without this, reconnecting to the same relay/provider can get stuck at .connecting.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard isSearching else { return }
            if forceRelayMode {
                startRelayBrowser()
                print("Searching for relays only (force relay mode)...")
            } else {
                startProviderBrowser()
                startRelayBrowser()
                print("Searching for providers and relays...")
            }
        }
    }

    func stopSearching() {
        autoReconnect = false
        isSearching = false
        reconnectTask?.cancel()
        reconnectTask = nil
        relayInfoTimeoutTask?.cancel()
        relayInfoTimeoutTask = nil
        stopProviderBrowser()
        stopRelayBrowser()
    }

    /// Send a message envelope to the connected provider (direct or via relay).
    func send(_ envelope: MessageEnvelope) throws {
        switch connectionMode {
        case .direct:
            guard let providerPeerID, providerSession.connectedPeers.contains(providerPeerID) else {
                throw MPCError.notConnected
            }
            let data = try envelope.serialized()
            try providerSession.send(data, toPeers: [providerPeerID], with: .reliable)

        case .relayed:
            guard let relayPeerID, relaySession.connectedPeers.contains(relayPeerID),
                  let providerID = relayProviderID else {
                throw MPCError.notConnected
            }
            // Wrap in RelayEnvelope for the relay to forward
            let relayEnvelope = try RelayEnvelope.wrap(
                envelope: envelope,
                destinationID: providerID,
                originID: envelope.senderID,
                routeID: relayRouteID ?? UUID().uuidString
            )
            let data = try relayEnvelope.serialized()
            try relaySession.send(data, toPeers: [relayPeerID], with: .reliable)

        case .disconnected:
            throw MPCError.notConnected
        }
    }

    func disconnect() {
        autoReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        relayInfoTimeoutTask?.cancel()
        relayInfoTimeoutTask = nil
        providerSession.disconnect()
        relaySession.disconnect()
        connectedProvider = nil
        relayProviders = [:]
        providerPeerID = nil
        relayPeerID = nil
        relayProviderID = nil
        relayRouteID = nil
        connectionState = .disconnected
        connectionMode = .disconnected
    }

    // MARK: - Connection health

    /// Called on foreground re-entry. Detects stale connections MPC didn't notify about.
    func checkConnectionHealth() {
        guard autoReconnect else { return }

        if connectionState == .connected {
            switch connectionMode {
            case .direct:
                if let provider = providerPeerID, providerSession.connectedPeers.contains(provider) {
                    return // genuinely connected
                }
            case .relayed:
                if let relay = relayPeerID, relaySession.connectedPeers.contains(relay) {
                    return // genuinely connected via relay
                }
            case .disconnected:
                break
            }
            print("Stale connection detected — reconnecting...")
            connectedProvider = nil
            providerPeerID = nil
            relayPeerID = nil
            relayProviderID = nil
            connectionState = .disconnected
            connectionMode = .disconnected
        }

        print("Foreground re-entry — restarting MPC browsing...")
        stopProviderBrowser()
        stopRelayBrowser()
        resetProviderSession()
        resetRelaySession()
        if forceRelayMode {
            startRelayBrowser()
        } else {
            startProviderBrowser()
            startRelayBrowser()
        }
    }

    // MARK: - Provider lost via relay

    /// Handle the case where the relay reports our provider is no longer reachable.
    private func handleProviderLostViaRelay() {
        // Remove the lost provider from relayProviders; auto-select next if available
        if let lostID = relayProviderID {
            relayProviders.removeValue(forKey: lostID)
        }
        connectedProvider = nil
        relayProviderID = nil
        relayRouteID = nil

        // If other providers are still available via relay, auto-select the next one
        if let (nextID, nextAnnounce) = relayProviders.first {
            connectedProvider = nextAnnounce
            relayProviderID = nextID
            relayRouteID = UUID().uuidString
            print("Auto-switched to next relay provider: \(nextAnnounce.providerName)")
            return
        }

        connectionState = .disconnected
        connectionMode = .disconnected

        if !forceRelayMode {
            print("Attempting direct connection as fallback...")
            startProviderBrowser()
        }
        scheduleReconnect()
    }

    // MARK: - Auto-reconnect

    private func scheduleReconnect() {
        guard autoReconnect else { return }
        reconnectTask?.cancel()
        connectionTimeoutTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            guard !Task.isCancelled, autoReconnect else { return }
            print("Auto-reconnecting...")
            resetProviderSession()
            resetRelaySession()
            if forceRelayMode {
                startRelayBrowser()
            } else {
                startProviderBrowser()
                startRelayBrowser()
            }
        }
    }

    /// If stuck in .connecting for 10 seconds, force reset and retry.
    private func startConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            guard !Task.isCancelled, autoReconnect, connectionState == .connecting else { return }
            consecutiveTimeouts += 1
            if consecutiveTimeouts >= maxTimeoutsBeforeWarning {
                print("Direct connection failed after \(consecutiveTimeouts) attempts — falling back to relay search")
                connectionState = .connectionFailed
                // Don't stop — start relay browser as fallback, keep direct running for race
                stopProviderBrowser()
                stopRelayBrowser()
                resetProviderSession()
                resetRelaySession()
                if forceRelayMode {
                    startRelayBrowser()
                } else {
                    startProviderBrowser()
                    startRelayBrowser()
                }
            } else {
                print("Connection timeout (\(consecutiveTimeouts)/\(maxTimeoutsBeforeWarning)) — retrying...")
                connectionState = .disconnected
                connectionMode = .disconnected
                providerPeerID = nil
                stopProviderBrowser()
                stopRelayBrowser()
                resetProviderSession()
                resetRelaySession()
                if forceRelayMode {
                    startRelayBrowser()
                } else {
                    startProviderBrowser()
                    startRelayBrowser()
                }
            }
        }
    }

    /// If the relay connects but doesn't send provider info within 15s, reset and retry.
    private func startRelayInfoTimeout() {
        relayInfoTimeoutTask?.cancel()
        relayInfoTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15 seconds
            guard !Task.isCancelled, autoReconnect, connectionState != .connected else { return }
            print("Relay connected but no provider info received — resetting...")
            relaySession.disconnect()
            relayPeerID = nil
            relayProviderID = nil
            relayRouteID = nil
            connectionState = .disconnected
            connectionMode = .disconnected
            resetRelaySession()
            if forceRelayMode {
                startRelayBrowser()
            } else {
                startProviderBrowser()
                startRelayBrowser()
            }
        }
    }

    // MARK: - Safe browser start/stop

    private func stopProviderBrowser() {
        guard providerBrowserActive else { return }
        providerBrowserActive = false
        providerBrowser.stopBrowsingForPeers()
    }

    private func stopRelayBrowser() {
        guard relayBrowserActive else { return }
        relayBrowserActive = false
        relayBrowser.stopBrowsingForPeers()
    }

    private func startProviderBrowser() {
        guard !providerBrowserActive else { return }
        providerBrowserActive = true
        providerBrowser.startBrowsingForPeers()
    }

    private func startRelayBrowser() {
        guard !relayBrowserActive else { return }
        relayBrowserActive = true
        relayBrowser.startBrowsingForPeers()
    }

    private func resetProviderSession() {
        providerSession.disconnect()
        let newSession = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        newSession.delegate = self
        providerSession = newSession
    }

    private func resetRelaySession() {
        relaySession.disconnect()
        let newSession = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        newSession.delegate = self
        relaySession = newSession
    }

    /// Whether a peer belongs to the relay session (vs provider session).
    private func isRelayPeer(_ peer: MCPeerID) -> Bool {
        peer == relayPeerID || relaySession.connectedPeers.contains(peer)
    }

    /// Switch to a different provider available through the relay.
    func selectRelayProvider(_ providerID: String) {
        guard let announce = relayProviders[providerID] else { return }
        connectedProvider = announce
        relayProviderID = providerID
        relayRouteID = UUID().uuidString
        print("Switched to relay provider: \(announce.providerName)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MPCBrowser: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard connectionState == .disconnected || connectionState == .connectionFailed else { return }

            let isRelay = info?["type"] == "relay"

            if isRelay {
                // Found a relay
                connectionState = .connecting
                startConnectionTimeout()
                browser.invitePeer(peerID, to: relaySession, withContext: nil, timeout: 15)
                print("Found relay: \(peerID.displayName), inviting...")
            } else {
                // Found a direct provider
                if forceRelayMode {
                    return  // Skip direct providers in force relay mode
                }
                connectionState = .connecting
                startConnectionTimeout()
                browser.invitePeer(peerID, to: providerSession, withContext: nil, timeout: 15)
                print("Found provider: \(peerID.displayName), inviting...")
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            if peerID == providerPeerID {
                // Ignore if MCSession is still connected — AWDL visibility flicker
                guard !providerSession.connectedPeers.contains(peerID) else {
                    print("lostPeer for provider but session still active — ignoring AWDL flicker")
                    return
                }
                connectedProvider = nil
                providerPeerID = nil
                connectionState = .disconnected
                connectionMode = .disconnected
                scheduleReconnect()
            } else if peerID == relayPeerID {
                // Ignore if MCSession is still connected — AWDL visibility flicker
                guard !relaySession.connectedPeers.contains(peerID) else {
                    print("lostPeer for relay but session still active — ignoring AWDL flicker")
                    return
                }
                connectedProvider = nil
                relayPeerID = nil
                relayProviderID = nil
                relayRouteID = nil
                connectionState = .disconnected
                connectionMode = .disconnected
                scheduleReconnect()
            }
        }
    }
}

// MARK: - MCSessionDelegate

extension MPCBrowser: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            // Determine if this is a provider session or relay session event
            if session === providerSession {
                handleProviderSessionChange(peer: peerID, state: state)
            } else if session === relaySession {
                handleRelaySessionChange(peer: peerID, state: state)
            }
        }
    }

    private func handleProviderSessionChange(peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            reconnectTask?.cancel()
            connectionTimeoutTask?.cancel()
            consecutiveTimeouts = 0
            providerPeerID = peer
            connectionState = .connected
            connectionMode = .direct
            stopProviderBrowser()
            stopRelayBrowser()  // stop relay search — direct is preferred
            // Disconnect relay if we had one
            if relayPeerID != nil {
                relaySession.disconnect()
                relayPeerID = nil
                relayProviderID = nil
                relayRouteID = nil
            }
            print("Direct connection to provider: \(peer.displayName)")
        case .notConnected:
            if connectionMode == .direct {
                connectedProvider = nil
                providerPeerID = nil
                connectionState = .disconnected
                connectionMode = .disconnected
                scheduleReconnect()
            }
        case .connecting:
            connectionState = .connecting
        @unknown default:
            break
        }
    }

    private func handleRelaySessionChange(peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            reconnectTask?.cancel()
            connectionTimeoutTask?.cancel()
            consecutiveTimeouts = 0
            relayPeerID = peer
            // Don't set connectionState to .connected yet — wait for RelayAnnounce/ServiceAnnounce
            // But start a timeout: if the relay doesn't send provider info within 15s, reset
            startRelayInfoTimeout()
            print("Connected to relay: \(peer.displayName), waiting for provider info...")
        case .notConnected:
            if connectionMode != .direct {
                // Only handle relay disconnect if we're not already on direct
                connectedProvider = nil
                relayProviders = [:]
                relayPeerID = nil
                relayProviderID = nil
                relayRouteID = nil
                if connectionState != .disconnected {
                    connectionState = .disconnected
                    connectionMode = .disconnected
                    scheduleReconnect()
                }
            }
        case .connecting:
            if connectionMode != .direct {
                connectionState = .connecting
            }
        @unknown default:
            break
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            if session === providerSession {
                handleDirectData(data, from: peerID)
            } else if session === relaySession {
                handleRelayData(data, from: peerID)
            }
        }
    }

    /// Handle data received directly from a provider.
    private func handleDirectData(_ data: Data, from peerID: MCPeerID) {
        guard let envelope = try? MessageEnvelope.deserialize(from: data) else { return }

        switch envelope.type {
        case .serviceAnnounce:
            if let announce = try? envelope.unwrap(as: ServiceAnnounce.self) {
                connectedProvider = announce
            }
        case .ping, .pong:
            break
        default:
            onMessageReceived?(envelope)
        }
    }

    /// Handle data received from a relay (RelayEnvelopes).
    private func handleRelayData(_ data: Data, from peerID: MCPeerID) {
        // First try to parse as a regular MessageEnvelope (for RelayAnnounce)
        if let envelope = try? MessageEnvelope.deserialize(from: data) {
            if envelope.type == .relayAnnounce {
                if let announce = try? envelope.unwrap(as: RelayAnnounce.self) {
                    print("Received RelayAnnounce: \(announce.relayName) with \(announce.reachableProviders.count) provider(s)")
                    // Prune providers no longer in the relay's reachable list
                    let reachableIDs = Set(announce.reachableProviders.map(\.providerID))
                    for id in relayProviders.keys where !reachableIDs.contains(id) {
                        relayProviders.removeValue(forKey: id)
                        print("Provider \(id.prefix(8))... removed from relay providers")
                    }
                    // Check if our current provider is still reachable
                    if let currentProviderID = relayProviderID, !reachableIDs.contains(currentProviderID) {
                        print("Provider \(currentProviderID.prefix(8))... no longer reachable via relay")
                        handleProviderLostViaRelay()
                        return
                    }
                    // If we don't have a provider yet, pick the first one
                    if relayProviderID == nil, let first = announce.reachableProviders.first {
                        relayProviderID = first.providerID
                        relayRouteID = UUID().uuidString
                        print("Targeting provider via relay: \(first.providerName)")
                    }
                }
                return
            }
        }

        // Try to parse as RelayEnvelope (forwarded provider messages)
        guard let relayEnvelope = try? RelayEnvelope.deserialize(from: data) else {
            print("Received unrecognized data from relay")
            return
        }

        // Unwrap the inner MessageEnvelope
        guard let innerEnvelope = try? relayEnvelope.unwrapInner() else {
            print("Failed to unwrap inner envelope from relay")
            return
        }

        switch innerEnvelope.type {
        case .serviceAnnounce:
            if let announce = try? innerEnvelope.unwrap(as: ServiceAnnounce.self) {
                relayInfoTimeoutTask?.cancel()
                // Store in relay providers dict
                relayProviders[announce.providerID] = announce
                // Set as connected provider if it's the one we're targeting, or auto-select first
                if relayProviderID == nil || relayProviderID == announce.providerID {
                    connectedProvider = announce
                    relayProviderID = announce.providerID
                    connectionState = .connected
                    connectionMode = .relayed(relayName: relayPeerID?.displayName ?? "Relay")
                    // Stop browsing — we're connected
                    if forceRelayMode {
                        stopRelayBrowser()
                    } else {
                        stopProviderBrowser()
                        stopRelayBrowser()
                    }
                }
                print("Relay provider available: \(announce.providerName) (\(relayProviders.count) total)")
            }
        case .ping, .pong:
            break
        default:
            onMessageReceived?(innerEnvelope)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
