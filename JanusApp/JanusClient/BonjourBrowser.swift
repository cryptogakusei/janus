import Foundation
import Combine
import Network
import JanusShared

/// Discovers Janus providers over Bonjour+TCP using Network.framework.
///
/// Uses `NWBrowser` to find `_janus-tcp._tcp` services on the local network,
/// then establishes an `NWConnection` to each discovered provider. The first
/// message from each provider is a `ServiceAnnounce` that populates the
/// `directProviders` dictionary.
///
/// Supports multi-provider: maintains one `NWConnection` per discovered provider.
/// `selectProvider(_:)` switches which provider `send()` targets.
@MainActor
class BonjourBrowser: NSObject, ObservableObject, ProviderTransport {

    @Published var connectedProvider: ServiceAnnounce?
    @Published var isSearching = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectionMode: ConnectionMode = .disconnected

    var connectedProviderPublisher: Published<ServiceAnnounce?>.Publisher { $connectedProvider }
    var isSearchingPublisher: Published<Bool>.Publisher { $isSearching }
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    /// All discovered providers: providerID → ServiceAnnounce.
    @Published var directProviders: [String: ServiceAnnounce] = [:]

    var onMessageReceived: ((MessageEnvelope) -> Void)?

    private let serviceType = "_janus-tcp._tcp"
    private var browser: NWBrowser?

    /// Currently selected provider ID for send() routing.
    private var activeProviderID: String?

    /// NWBrowser result endpoint hash → NWConnection (before providerID is known).
    private var endpointConnections: [NWEndpoint: NWConnection] = [:]
    /// providerID → NWConnection (after ServiceAnnounce maps the identity).
    private var providerConnections: [String: NWConnection] = [:]
    /// Deframers keyed by endpoint.
    private var endpointDeframers: [NWEndpoint: TCPFramer.Deframer] = [:]
    /// endpoint → providerID mapping.
    private var endpointToProvider: [NWEndpoint: String] = [:]
    /// providerID → endpoint (reverse).
    private var providerToEndpoint: [String: NWEndpoint] = [:]

    /// Reconnect backoff tracking.
    private var reconnectTasks: [NWEndpoint: Task<Void, Never>] = [:]

    override init() {
        super.init()
    }

    func startSearching() {
        guard browser == nil else { return }
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    print("[BonjourBrowser] Browsing for \(self.serviceType)")
                case .failed(let error):
                    print("[BonjourBrowser] Browse failed: \(error)")
                    self.browser?.cancel()
                    self.browser = nil
                    // Restart
                    self.startSearching()
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleBrowseResults(results: results, changes: changes)
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stopSearching() {
        browser?.cancel()
        browser = nil
        isSearching = false

        // Cancel all reconnect tasks
        for (_, task) in reconnectTasks { task.cancel() }
        reconnectTasks.removeAll()

        // Tear down all connections
        for (_, connection) in endpointConnections {
            connection.cancel()
        }
        endpointConnections.removeAll()
        providerConnections.removeAll()
        endpointDeframers.removeAll()
        endpointToProvider.removeAll()
        providerToEndpoint.removeAll()
        directProviders.removeAll()
        activeProviderID = nil
        connectedProvider = nil
        connectionState = .disconnected
        connectionMode = .disconnected
    }

    func send(_ envelope: MessageEnvelope) throws {
        guard let providerID = activeProviderID,
              let connection = providerConnections[providerID] else {
            throw MPCError.notConnected
        }
        let data = try envelope.serialized()
        let framed = TCPFramer.frame(data)
        connection.send(content: framed, completion: .contentProcessed { error in
            if let error {
                print("[BonjourBrowser] Send error: \(error)")
            }
        })
    }

    func checkConnectionHealth() {
        guard let providerID = activeProviderID,
              let connection = providerConnections[providerID] else {
            if connectionState == .connected {
                connectionState = .disconnected
                connectionMode = .disconnected
                connectedProvider = nil
            }
            return
        }
        // NWConnection has explicit state — check it
        if connection.state == .failed(NWError.posix(.ECONNRESET)) ||
           connection.state == .cancelled {
            connectionState = .disconnected
            connectionMode = .disconnected
            connectedProvider = nil
        }
    }

    /// Switch which provider send() targets. Instant — no disconnect/reconnect.
    func selectProvider(_ providerID: String) {
        guard providerConnections[providerID] != nil,
              let announce = directProviders[providerID] else { return }
        activeProviderID = providerID
        connectedProvider = announce
        connectionState = .connected
        connectionMode = .direct
    }

    // MARK: - Browse Result Handling

    private func handleBrowseResults(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                connectToEndpoint(result.endpoint)
            case .removed(let result):
                // Only remove if the NWConnection is actually dead.
                // TCP connections survive browse changes.
                let endpoint = result.endpoint
                if let connection = endpointConnections[endpoint],
                   connection.state != .ready {
                    disconnectEndpoint(endpoint)
                }
            case .changed(old: _, new: let result, flags: _):
                // Endpoint metadata changed — reconnect if needed
                if endpointConnections[result.endpoint] == nil {
                    connectToEndpoint(result.endpoint)
                }
            @unknown default:
                break
            }
        }
    }

    private func connectToEndpoint(_ endpoint: NWEndpoint) {
        guard endpointConnections[endpoint] == nil else { return }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true

        let connection = NWConnection(to: endpoint, using: params)
        endpointConnections[endpoint] = connection

        let deframer = TCPFramer.Deframer()
        endpointDeframers[endpoint] = deframer

        deframer.onFrame = { [weak self] data in
            Task { @MainActor in
                self?.handleFrame(data, fromEndpoint: endpoint)
            }
        }

        deframer.onError = { [weak self] error in
            Task { @MainActor in
                print("[BonjourBrowser] Framing error: \(error)")
                self?.disconnectEndpoint(endpoint)
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    print("[BonjourBrowser] Connected to endpoint")
                    // Cancel any pending reconnect
                    self.reconnectTasks[endpoint]?.cancel()
                    self.reconnectTasks.removeValue(forKey: endpoint)
                case .failed(let error):
                    print("[BonjourBrowser] Connection failed: \(error)")
                    self.disconnectEndpoint(endpoint)
                    self.scheduleReconnect(endpoint)
                case .cancelled:
                    self.disconnectEndpoint(endpoint)
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
        receiveLoop(connection: connection, endpoint: endpoint)
    }

    /// Pull-based receive loop.
    private func receiveLoop(connection: NWConnection, endpoint: NWEndpoint) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    self.endpointDeframers[endpoint]?.append(data)
                }
                if isComplete {
                    self.disconnectEndpoint(endpoint)
                } else if let error {
                    print("[BonjourBrowser] Receive error: \(error)")
                    self.disconnectEndpoint(endpoint)
                    self.scheduleReconnect(endpoint)
                } else {
                    self.receiveLoop(connection: connection, endpoint: endpoint)
                }
            }
        }
    }

    /// Process a complete framed message.
    private func handleFrame(_ data: Data, fromEndpoint endpoint: NWEndpoint) {
        guard let envelope = try? MessageEnvelope.deserialize(from: data) else {
            print("[BonjourBrowser] Failed to deserialize envelope")
            return
        }

        // ServiceAnnounce is the first message — maps endpoint → providerID
        if envelope.type == .serviceAnnounce {
            guard let announce = try? envelope.unwrap(as: ServiceAnnounce.self) else { return }
            let providerID = announce.providerID

            endpointToProvider[endpoint] = providerID
            providerToEndpoint[providerID] = endpoint
            if let connection = endpointConnections[endpoint] {
                providerConnections[providerID] = connection
            }
            directProviders[providerID] = announce

            // Auto-select first provider
            if activeProviderID == nil {
                activeProviderID = providerID
                connectedProvider = announce
                connectionState = .connected
                connectionMode = .direct
            }

            print("[BonjourBrowser] Discovered provider: \(announce.providerName) (\(providerID))")
            return
        }

        // Ignore ping/pong
        guard envelope.type != .ping && envelope.type != .pong else { return }

        onMessageReceived?(envelope)
    }

    /// Clean up state for a disconnected endpoint.
    private func disconnectEndpoint(_ endpoint: NWEndpoint) {
        guard endpointConnections[endpoint] != nil else { return }

        endpointConnections[endpoint]?.cancel()
        endpointConnections.removeValue(forKey: endpoint)
        endpointDeframers[endpoint]?.reset()
        endpointDeframers.removeValue(forKey: endpoint)

        if let providerID = endpointToProvider.removeValue(forKey: endpoint) {
            providerToEndpoint.removeValue(forKey: providerID)
            providerConnections.removeValue(forKey: providerID)
            directProviders.removeValue(forKey: providerID)

            if activeProviderID == providerID {
                // Switch to another provider if available
                if let nextID = directProviders.keys.first,
                   let nextAnnounce = directProviders[nextID] {
                    activeProviderID = nextID
                    connectedProvider = nextAnnounce
                } else {
                    activeProviderID = nil
                    connectedProvider = nil
                    connectionState = .disconnected
                    connectionMode = .disconnected
                }
            }

            print("[BonjourBrowser] Provider disconnected: \(providerID)")
        }
    }

    /// Auto-reconnect with exponential backoff.
    private func scheduleReconnect(_ endpoint: NWEndpoint) {
        guard isSearching else { return }
        reconnectTasks[endpoint]?.cancel()

        reconnectTasks[endpoint] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard !Task.isCancelled, self.isSearching else { return }
            self.connectToEndpoint(endpoint)
        }
    }
}
