import Foundation
import Network
import JanusShared

/// Advertises the Janus provider over Bonjour+TCP using Network.framework.
///
/// Accepts TCP connections from clients on the local network. Each client gets
/// its own `NWConnection` with length-prefixed framing (`TCPFramer`). The provider
/// sends a `ServiceAnnounce` as the first message to each new client.
///
/// Client identity bootstrapping: when a new TCP connection arrives, a temporary
/// UUID is assigned. On the first `MessageEnvelope` received, the `senderID` is
/// extracted and used as the permanent key for routing replies.
@MainActor
class BonjourAdvertiser: NSObject, ObservableObject, ProviderAdvertiserTransport {

    @Published var isAdvertising = false

    /// senderID → display name (display name starts as "TCP Client" until we learn the real name).
    private var clients: [String: String] = [:]

    /// Protocol-conforming view: senderID → display name.
    var connectedClients: [String: String] { clients }

    var onMessageReceived: ((MessageEnvelope, String) -> Void)?
    var onClientDisconnected: ((String) -> Void)?

    private let serviceType = "_janus-tcp._tcp"
    /// Dedicated queue for NWListener and NWConnection events.
    /// Decouples Bonjour health from @MainActor scheduling — Bonjour keeps running
    /// even if @MainActor is busy with inference or settlement.
    private let networkQueue = DispatchQueue(label: "com.janus.bonjour.network", qos: .userInitiated)
    private var listener: NWListener?
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private let maxRetries = 5

    private var serviceAnnounce: ServiceAnnounce

    /// Temporary client ID → NWConnection (before senderID is known).
    private var tempConnections: [String: NWConnection] = [:]
    /// senderID → NWConnection (after first MessageEnvelope maps the identity).
    private var senderConnections: [String: NWConnection] = [:]
    /// Deframers keyed by temporary client ID.
    private var deframers: [String: TCPFramer.Deframer] = [:]
    /// Temporary client ID → senderID mapping (once known).
    private var tempToSender: [String: String] = [:]
    /// Reverse: senderID → temporary client ID.
    private var senderToTemp: [String: String] = [:]

    init(providerName: String, providerID: String, providerPubkey: String = "") {
        self.serviceAnnounce = ServiceAnnounce(
            providerID: providerID,
            providerName: providerName,
            providerPubkey: providerPubkey
        )
        super.init()
    }

    func startAdvertising() {
        guard listener == nil else { return }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true

        do {
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(type: serviceType)

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isAdvertising = true
                        self.retryCount = 0
                        if let port = self.listener?.port {
                            print("[BonjourAdvertiser] Listening on port \(port)")
                        }
                    case .failed(let error):
                        print("[BonjourAdvertiser] Listener failed: \(error)")
                        self.isAdvertising = false
                        self.listener?.cancel()
                        self.listener = nil
                        self.retryCount += 1
                        if self.retryCount <= self.maxRetries {
                            print("[BonjourAdvertiser] Retry \(self.retryCount)/\(self.maxRetries) in 5s...")
                            self.retryTask = Task { [weak self] in
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                await self?.startAdvertising()
                            }
                        } else {
                            print("[BonjourAdvertiser] Max retries reached. Check Local Network permission in System Settings.")
                        }
                    case .cancelled:
                        self.isAdvertising = false
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }

            self.listener = listener
            listener.start(queue: networkQueue)
        } catch {
            print("[BonjourAdvertiser] Failed to create listener: \(error)")
        }
    }

    func stopAdvertising() {
        retryTask?.cancel()
        retryTask = nil
        listener?.cancel()
        listener = nil
        isAdvertising = false

        // Tear down all client connections
        for (_, connection) in tempConnections {
            connection.cancel()
        }
        tempConnections.removeAll()
        senderConnections.removeAll()
        deframers.removeAll()
        tempToSender.removeAll()
        senderToTemp.removeAll()
        clients.removeAll()
    }

    // Note: NWConnection.send completion blocks fire on networkQueue, not @MainActor.
    // Current completions only call print() — safe. If you add state mutation here in
    // the future, dispatch back to @MainActor via Task { @MainActor in ... }.
    func send(_ envelope: MessageEnvelope, to senderID: String) throws {
        guard let connection = senderConnections[senderID] else {
            throw MPCError.notConnected
        }
        let data = try envelope.serialized()
        let framed = TCPFramer.frame(data)
        connection.send(content: framed, completion: .contentProcessed { error in
            if let error {
                print("[BonjourAdvertiser] Send error to \(senderID): \(error)")
            }
        })
    }

    func updateServiceAnnounce(providerPubkey: String, providerEthAddress: String?,
                               tokenRate: UInt64 = 10, tabThreshold: UInt64 = 500,
                               maxOutputTokens: Int = 1024, paymentModel: String = "tab") {
        serviceAnnounce = ServiceAnnounce(
            providerID: serviceAnnounce.providerID,
            providerName: serviceAnnounce.providerName,
            providerPubkey: providerPubkey,
            providerEthAddress: providerEthAddress,
            tokenRate: tokenRate,
            tabThreshold: tabThreshold,
            maxOutputTokens: maxOutputTokens,
            paymentModel: paymentModel
        )
        // Re-send updated ServiceAnnounce to all currently connected clients.
        // Uses tempConnections (populated on TCP connect) so it reaches clients
        // that haven't sent any messages yet — the window where broadcastServiceUpdate
        // (keyed on sessionToSender) would miss them.
        for clientID in tempConnections.keys {
            sendServiceAnnounce(toClient: clientID)
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let clientID = UUID().uuidString
        tempConnections[clientID] = connection

        let deframer = TCPFramer.Deframer()
        deframers[clientID] = deframer

        deframer.onFrame = { [weak self] frameData in
            Task { @MainActor in
                self?.handleFrame(frameData, fromClient: clientID)
            }
        }

        deframer.onError = { [weak self] error in
            Task { @MainActor in
                print("[BonjourAdvertiser] Framing error from \(clientID): \(error)")
                self?.disconnectClient(clientID)
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    print("[BonjourAdvertiser] Client connected: \(clientID)")
                    self.sendServiceAnnounce(toClient: clientID)
                case .failed(let error):
                    print("[BonjourAdvertiser] Connection failed for \(clientID): \(error)")
                    self.disconnectClient(clientID)
                case .cancelled:
                    self.disconnectClient(clientID)
                default:
                    break
                }
            }
        }

        connection.start(queue: networkQueue)
        receiveLoop(connection: connection, clientID: clientID)
    }

    /// Pull-based receive loop — NWConnection requires re-calling receive() after each completion.
    private func receiveLoop(connection: NWConnection, clientID: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    self.deframers[clientID]?.append(data)
                }
                if isComplete {
                    self.disconnectClient(clientID)
                } else if let error {
                    print("[BonjourAdvertiser] Receive error from \(clientID): \(error)")
                    self.disconnectClient(clientID)
                } else {
                    self.receiveLoop(connection: connection, clientID: clientID)
                }
            }
        }
    }

    /// Process a complete framed message from a client.
    private func handleFrame(_ data: Data, fromClient clientID: String) {
        guard let envelope = try? MessageEnvelope.deserialize(from: data) else {
            print("[BonjourAdvertiser] Failed to deserialize envelope from \(clientID)")
            return
        }

        let senderID = envelope.senderID

        // Register senderID mapping on first message
        if tempToSender[clientID] == nil {
            tempToSender[clientID] = senderID
            senderToTemp[senderID] = clientID
            if let connection = tempConnections[clientID] {
                senderConnections[senderID] = connection
            }
            clients[senderID] = "TCP Client"  // will be updated if we learn a better name
            print("[BonjourAdvertiser] Mapped client \(clientID) → senderID \(senderID)")
        }

        // Ignore ping/pong
        guard envelope.type != .ping && envelope.type != .pong else { return }

        onMessageReceived?(envelope, senderID)
    }

    /// Send ServiceAnnounce to a newly connected client.
    private func sendServiceAnnounce(toClient clientID: String) {
        guard let connection = tempConnections[clientID] else { return }
        do {
            let envelope = try MessageEnvelope.wrap(
                type: .serviceAnnounce,
                senderID: serviceAnnounce.providerID,
                payload: serviceAnnounce
            )
            let data = try envelope.serialized()
            let framed = TCPFramer.frame(data)
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    print("[BonjourAdvertiser] Failed to send ServiceAnnounce: \(error)")
                }
            })
        } catch {
            print("[BonjourAdvertiser] Failed to create ServiceAnnounce: \(error)")
        }
    }

    /// Clean up a disconnected client.
    private func disconnectClient(_ clientID: String) {
        // Prevent double-cleanup
        guard tempConnections[clientID] != nil else { return }

        tempConnections[clientID]?.cancel()
        tempConnections.removeValue(forKey: clientID)
        deframers[clientID]?.reset()
        deframers.removeValue(forKey: clientID)

        if let senderID = tempToSender.removeValue(forKey: clientID) {
            senderToTemp.removeValue(forKey: senderID)
            senderConnections.removeValue(forKey: senderID)
            let name = clients.removeValue(forKey: senderID) ?? "Unknown"
            onClientDisconnected?(name)
            print("[BonjourAdvertiser] Client disconnected: \(senderID) (\(name))")
        } else {
            print("[BonjourAdvertiser] Unnamed client disconnected: \(clientID)")
        }
    }
}
