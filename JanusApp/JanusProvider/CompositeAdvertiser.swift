import Foundation
import JanusShared

/// Wraps `MPCAdvertiser` + `BonjourAdvertiser`, running both simultaneously.
///
/// Tracks which transport each client connected through (`senderTransport`)
/// and routes replies to the correct child. Merges `connectedClients` from both
/// children — if a client connects via both, Bonjour is preferred.
@MainActor
class CompositeAdvertiser: NSObject, ObservableObject, ProviderAdvertiserTransport {

    @Published var isAdvertising = false

    let mpcAdvertiser: MPCAdvertiser
    let bonjourAdvertiser: BonjourAdvertiser

    /// Which transport each senderID came from.
    private var senderTransport: [String: ProviderAdvertiserTransport] = [:]

    var connectedClients: [String: String] {
        // Merge both, dedup (Bonjour wins if both have the same senderID)
        var merged = mpcAdvertiser.connectedClients
        for (senderID, name) in bonjourAdvertiser.connectedClients {
            merged[senderID] = name
        }
        return merged
    }

    var onMessageReceived: ((MessageEnvelope, String) -> Void)? {
        didSet {
            mpcAdvertiser.onMessageReceived = { [weak self] envelope, senderID in
                self?.senderTransport[senderID] = self?.mpcAdvertiser
                self?.onMessageReceived?(envelope, senderID)
            }
            bonjourAdvertiser.onMessageReceived = { [weak self] envelope, senderID in
                self?.senderTransport[senderID] = self?.bonjourAdvertiser
                self?.onMessageReceived?(envelope, senderID)
            }
        }
    }

    var onClientDisconnected: ((String) -> Void)? {
        didSet {
            // Only fire when client is disconnected from ALL transports
            mpcAdvertiser.onClientDisconnected = { [weak self] name in
                guard let self else { return }
                // Check if still connected via Bonjour
                let stillConnectedViaTCP = self.bonjourAdvertiser.connectedClients.values.contains(name)
                if !stillConnectedViaTCP {
                    self.onClientDisconnected?(name)
                }
            }
            bonjourAdvertiser.onClientDisconnected = { [weak self] name in
                guard let self else { return }
                // Check if still connected via MPC
                let stillConnectedViaMPC = self.mpcAdvertiser.connectedClients.values.contains(name)
                if !stillConnectedViaMPC {
                    self.onClientDisconnected?(name)
                }
            }
        }
    }

    init(providerName: String, providerID: String, providerPubkey: String = "") {
        self.mpcAdvertiser = MPCAdvertiser(
            providerName: providerName,
            providerID: providerID,
            providerPubkey: providerPubkey
        )
        self.bonjourAdvertiser = BonjourAdvertiser(
            providerName: providerName,
            providerID: providerID,
            providerPubkey: providerPubkey
        )
        super.init()
    }

    func startAdvertising() {
        mpcAdvertiser.startAdvertising()
        bonjourAdvertiser.startAdvertising()
        isAdvertising = true
    }

    func stopAdvertising() {
        mpcAdvertiser.stopAdvertising()
        bonjourAdvertiser.stopAdvertising()
        isAdvertising = false
        senderTransport.removeAll()
    }

    func send(_ envelope: MessageEnvelope, to senderID: String) throws {
        // Route to the transport this sender connected through
        guard let transport = senderTransport[senderID] else {
            throw MPCError.notConnected
        }
        try transport.send(envelope, to: senderID)
    }

    func updateServiceAnnounce(providerPubkey: String, providerEthAddress: String?) {
        mpcAdvertiser.updateServiceAnnounce(providerPubkey: providerPubkey, providerEthAddress: providerEthAddress)
        bonjourAdvertiser.updateServiceAnnounce(providerPubkey: providerPubkey, providerEthAddress: providerEthAddress)
    }
}
