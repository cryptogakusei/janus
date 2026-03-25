import Foundation
import MultipeerConnectivity
import JanusShared
import UIKit

/// Discovers nearby Janus providers via Multipeer Connectivity.
///
/// Publishes discovered providers and handles bidirectional JSON messaging.
/// The browser advertises as a client and looks for provider peers.
@MainActor
class MPCBrowser: NSObject, ObservableObject {

    /// Currently discovered provider info (nil if no provider connected).
    @Published var connectedProvider: ServiceAnnounce?
    @Published var isSearching = false
    @Published var connectionState: ConnectionState = .disconnected

    enum ConnectionState: String {
        case disconnected
        case connecting
        case connected
        /// Provider found via Bluetooth but session can't be established (WiFi likely off on provider).
        case connectionFailed = "Connection Failed"
    }

    private let serviceType = "janus-ai"
    nonisolated(unsafe) private let peerID: MCPeerID
    nonisolated(unsafe) private let browser: MCNearbyServiceBrowser
    nonisolated(unsafe) private var session: MCSession
    private var providerPeerID: MCPeerID?

    /// Callback for received messages.
    var onMessageReceived: ((MessageEnvelope) -> Void)?

    /// Whether auto-reconnect is active (disabled on manual disconnect).
    private var autoReconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    /// Consecutive connection timeouts — if ≥ 2, provider is likely discoverable
    /// via Bluetooth but unreachable via WiFi/AWDL (WiFi off on provider side).
    private var consecutiveTimeouts = 0
    private let maxTimeoutsBeforeWarning = 2

    override init() {
        self.peerID = MCPeerID(displayName: UIDevice.current.name)
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        super.init()
        self.session.delegate = self
        self.browser.delegate = self

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
        connectedProvider = nil
        consecutiveTimeouts = 0
        // Stop then start to force MPC to re-evaluate network interfaces.
        // After screen lock/unlock or cellular toggle, the browser's Bonjour
        // discovery can be bound to stale interfaces — a stop/start cycle fixes this.
        browser.stopBrowsingForPeers()
        resetSession()
        browser.startBrowsingForPeers()
    }

    func stopSearching() {
        autoReconnect = false
        isSearching = false
        reconnectTask?.cancel()
        reconnectTask = nil
        browser.stopBrowsingForPeers()
    }

    /// Send a message envelope to the connected provider.
    func send(_ envelope: MessageEnvelope) throws {
        guard let providerPeerID, session.connectedPeers.contains(providerPeerID) else {
            throw MPCError.notConnected
        }
        let data = try envelope.serialized()
        try session.send(data, toPeers: [providerPeerID], with: .reliable)
    }

    func disconnect() {
        autoReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        session.disconnect()
        connectedProvider = nil
        providerPeerID = nil
        connectionState = .disconnected
    }

    // MARK: - Connection health

    /// Called on foreground re-entry. Detects stale connections MPC didn't notify about.
    /// Also restarts browsing to pick up network interface changes (e.g. cellular toggle).
    func checkConnectionHealth() {
        guard autoReconnect else { return }

        if connectionState == .connected {
            if let provider = providerPeerID, session.connectedPeers.contains(provider) {
                return // genuinely connected
            }
            print("Stale connection detected — reconnecting...")
            connectedProvider = nil
            providerPeerID = nil
            connectionState = .disconnected
        }

        // Always restart browsing on foreground re-entry — network interfaces
        // may have changed (WiFi/cellular toggle) while the app was suspended.
        print("Foreground re-entry — restarting MPC browsing...")
        browser.stopBrowsingForPeers()
        resetSession()
        browser.startBrowsingForPeers()
    }

    // MARK: - Auto-reconnect

    private func scheduleReconnect() {
        guard autoReconnect else { return }
        reconnectTask?.cancel()
        connectionTimeoutTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            guard !Task.isCancelled, autoReconnect else { return }
            print("Auto-reconnecting to provider...")
            resetSession()
            browser.startBrowsingForPeers()
        }
    }

    /// If stuck in .connecting for 10 seconds, force reset and retry.
    /// After repeated timeouts, surface a warning — likely WiFi is off on one or both devices.
    private func startConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            guard !Task.isCancelled, autoReconnect, connectionState == .connecting else { return }
            consecutiveTimeouts += 1
            if consecutiveTimeouts >= maxTimeoutsBeforeWarning {
                print("Connection failed after \(consecutiveTimeouts) attempts — WiFi likely off")
                connectionState = .connectionFailed
                browser.stopBrowsingForPeers()
                // Don't auto-retry — wait for user to tap Scan again after enabling WiFi
            } else {
                print("Connection timeout (\(consecutiveTimeouts)/\(maxTimeoutsBeforeWarning)) — retrying...")
                browser.stopBrowsingForPeers()
                resetSession()
                browser.startBrowsingForPeers()
            }
        }
    }

    private func resetSession() {
        session.disconnect()
        let newSession = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        newSession.delegate = self
        session = newSession
        connectionState = .disconnected
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MPCBrowser: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard connectionState == .disconnected else { return }
            connectionState = .connecting
            startConnectionTimeout()
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            if peerID == providerPeerID {
                connectedProvider = nil
                providerPeerID = nil
                connectionState = .disconnected
                scheduleReconnect()
            }
        }
    }
}

// MARK: - MCSessionDelegate

extension MPCBrowser: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                reconnectTask?.cancel()
                connectionTimeoutTask?.cancel()
                consecutiveTimeouts = 0
                providerPeerID = peerID
                connectionState = .connected
                browser.stopBrowsingForPeers()
            case .notConnected:
                connectedProvider = nil
                providerPeerID = nil
                if connectionState != .disconnected {
                    connectionState = .disconnected
                    scheduleReconnect()
                }
            case .connecting:
                connectionState = .connecting
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let envelope = try? MessageEnvelope.deserialize(from: data) else { return }

            switch envelope.type {
            case .serviceAnnounce:
                if let announce = try? envelope.unwrap(as: ServiceAnnounce.self) {
                    connectedProvider = announce
                }
            case .ping, .pong:
                break // ignore — no heartbeat active
            default:
                onMessageReceived?(envelope)
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
