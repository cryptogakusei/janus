import Foundation
import Combine
import JanusShared

/// Abstraction over the transport layer between ClientEngine and a provider.
///
/// MPCBrowser implements this for direct/relay connections.
/// RelayLocalTransport implements this for dual-mode local queries through the relay.
@MainActor
protocol ProviderTransport: AnyObject {
    var connectedProvider: ServiceAnnounce? { get }
    var connectedProviderPublisher: Published<ServiceAnnounce?>.Publisher { get }
    var isSearching: Bool { get }
    var isSearchingPublisher: Published<Bool>.Publisher { get }
    var connectionState: ConnectionState { get }
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var connectionMode: ConnectionMode { get }

    /// Callback for messages received from the provider.
    var onMessageReceived: ((MessageEnvelope) -> Void)? { get set }

    func send(_ envelope: MessageEnvelope) throws
    func startSearching()
    func stopSearching()
    func checkConnectionHealth()
}

/// Connection state shared between transport implementations.
enum ConnectionState: String {
    case disconnected
    case connecting
    case connected
    /// Provider found via Bluetooth but session can't be established (WiFi likely off on provider).
    case connectionFailed = "Connection Failed"
}

/// Connection mode shared between transport implementations.
enum ConnectionMode: Equatable {
    case disconnected
    case direct
    case relayed(relayName: String)

    var displayLabel: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .direct: return "Direct"
        case .relayed(let name): return "via \(name)"
        }
    }
}
