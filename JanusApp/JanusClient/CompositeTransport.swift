import Foundation
import Combine
import JanusShared

/// Wraps `BonjourBrowser` + `MPCBrowser`, running both simultaneously.
///
/// Bonjour is preferred for sending (faster connection: ~100-200ms vs AWDL's ~2-5s).
/// MPC stays warm as instant fallback — no cold-restart delay if Bonjour disconnects.
///
/// Exposes child transports for transport-specific features:
/// - `mpcBrowser` for relay mode (`relayProviders`, `forceRelayMode`)
/// - `bonjourBrowser` for direct multi-provider (`directProviders`)
@MainActor
class CompositeTransport: NSObject, ObservableObject, ProviderTransport {

    @Published var connectedProvider: ServiceAnnounce?
    @Published var isSearching = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectionMode: ConnectionMode = .disconnected

    var connectedProviderPublisher: Published<ServiceAnnounce?>.Publisher { $connectedProvider }
    var isSearchingPublisher: Published<Bool>.Publisher { $isSearching }
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var onMessageReceived: ((MessageEnvelope) -> Void)?

    /// Child transports — exposed for transport-specific features.
    let bonjourBrowser = BonjourBrowser()
    let mpcBrowser = MPCBrowser()

    /// Which transport is currently active for sending.
    private enum ActiveTransport {
        case bonjour
        case mpc
        case none
    }
    private var activeTransport: ActiveTransport = .none

    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        wireUpSubscriptions()
    }

    func startSearching() {
        isSearching = true
        bonjourBrowser.startSearching()
        mpcBrowser.startSearching()
    }

    func stopSearching() {
        bonjourBrowser.stopSearching()
        mpcBrowser.stopSearching()
        isSearching = false
        activeTransport = .none
        connectionState = .disconnected
        connectionMode = .disconnected
        connectedProvider = nil
    }

    func send(_ envelope: MessageEnvelope) throws {
        switch activeTransport {
        case .bonjour:
            try bonjourBrowser.send(envelope)
        case .mpc:
            try mpcBrowser.send(envelope)
        case .none:
            throw MPCError.notConnected
        }
    }

    func checkConnectionHealth() {
        switch activeTransport {
        case .bonjour:
            bonjourBrowser.checkConnectionHealth()
        case .mpc:
            mpcBrowser.checkConnectionHealth()
        case .none:
            break
        }
    }

    // MARK: - Combine Wiring

    private func wireUpSubscriptions() {
        // Forward messages from both transports
        bonjourBrowser.onMessageReceived = { [weak self] envelope in
            self?.onMessageReceived?(envelope)
        }
        mpcBrowser.onMessageReceived = { [weak self] envelope in
            self?.onMessageReceived?(envelope)
        }

        // Subscribe to both transports' connection states.
        // Bonjour is preferred — if Bonjour connects, use it.
        // If only MPC connects, use MPC.
        // If Bonjour disconnects, fall back to MPC if it's connected.

        bonjourBrowser.$connectionState
            .combineLatest(mpcBrowser.$connectionState)
            .sink { [weak self] bonjourState, mpcState in
                self?.resolveActiveTransport(bonjourState: bonjourState, mpcState: mpcState)
            }
            .store(in: &cancellables)
    }

    private func resolveActiveTransport(bonjourState: ConnectionState, mpcState: ConnectionState) {
        // Prefer Bonjour when connected
        if bonjourState == .connected {
            activeTransport = .bonjour
            connectionState = .connected
            connectionMode = .direct
            connectedProvider = bonjourBrowser.connectedProvider
        } else if mpcState == .connected {
            activeTransport = .mpc
            connectionState = .connected
            connectionMode = mpcBrowser.connectionMode
            connectedProvider = mpcBrowser.connectedProvider
        } else if bonjourState == .connecting || mpcState == .connecting {
            activeTransport = .none
            connectionState = .connecting
            connectionMode = .disconnected
            connectedProvider = nil
        } else if bonjourState == .connectionFailed || mpcState == .connectionFailed {
            activeTransport = .none
            connectionState = .connectionFailed
            connectionMode = .disconnected
            connectedProvider = nil
        } else {
            activeTransport = .none
            connectionState = .disconnected
            connectionMode = .disconnected
            connectedProvider = nil
        }
    }
}
