import Foundation
import CryptoKit
import JanusShared
import os.log

private let smokeLog = OSLog(subsystem: "com.janus.client", category: "SmokeTest")

/// Manages the client's session state: keypair, session grant, and spend tracking.
///
/// On init, generates a client keypair and creates a demo session grant
/// signed by the hardcoded backend key. In production, the grant would
/// come from the backend API after payment.
///
/// Persists state to disk so sessions survive app restarts.
@MainActor
class SessionManager: ObservableObject {

    @Published var remainingCredits: Int
    @Published var receipts: [Receipt] = []
    @Published var history: [HistoryEntry] = []

    let clientKeyPair: JanusKeyPair
    let sessionGrant: SessionGrant
    private(set) var spendState: SpendState
    private let clientSigner: JanusSigner
    private let store: JanusStore

    /// Whether the grant has been sent to the provider already.
    var grantDelivered = false

    // Tempo voucher support
    private(set) var ethKeyPair: EthKeyPair?
    private(set) var walletProvider: (any WalletProvider)?
    private(set) var channel: Channel?
    private(set) var channelInfo: ChannelInfo?
    private let tempoConfig = TempoConfig.testnet
    /// Whether the channel info has been sent to the provider.
    var channelInfoDelivered = false
    /// Whether this session uses Tempo vouchers (vs Ed25519 SpendAuthorization).
    var usesVouchers: Bool { channel != nil }
    /// On-chain channel status.
    @Published var channelOnChainStatus: String = ""

    private static let filename = "client_session.json"

    /// Try to restore a persisted session for this provider. Returns nil if none exists or expired.
    static func restore(providerID: String, walletProvider: (any WalletProvider)? = nil, store: JanusStore = .appDefault) -> SessionManager? {
        guard let persisted = store.load(PersistedClientSession.self, from: filename),
              persisted.isValid,
              persisted.sessionGrant.providerID == providerID else {
            return nil
        }
        return try? SessionManager(persisted: persisted, walletProvider: walletProvider, store: store)
    }

    /// Restore from persisted state.
    private init(persisted: PersistedClientSession, walletProvider: (any WalletProvider)?, store: JanusStore) throws {
        guard let keyData = Data(base64Encoded: persisted.privateKeyBase64) else {
            throw CryptoError.invalidBase64
        }
        let kp = try JanusKeyPair(privateKeyRaw: keyData)
        self.clientKeyPair = kp
        self.clientSigner = JanusSigner(keyPair: kp)
        self.sessionGrant = persisted.sessionGrant
        self.spendState = persisted.spendState
        self.remainingCredits = persisted.remainingCredits
        self.receipts = persisted.receipts
        self.history = persisted.history
        self.grantDelivered = persisted.grantDelivered
        self.store = store

        // Use injected wallet provider (Privy) or restore local ETH keypair
        if let wp = walletProvider {
            self.walletProvider = wp
            print("Using injected wallet provider: \(wp.address)")
        } else if let ethHex = persisted.ethPrivateKeyHex, let ethKP = try? EthKeyPair(hexPrivateKey: ethHex) {
            self.ethKeyPair = ethKP
            self.walletProvider = LocalWalletProvider(keyPair: ethKP, rpcURL: tempoConfig.rpcURL)
            print("Restored ETH keypair: \(ethKP.address)")
        }
    }

    /// Create a new session by requesting a grant from the backend API.
    /// Falls back to local self-signing if the backend is unreachable.
    static func create(providerID: String, walletProvider: (any WalletProvider)? = nil, store: JanusStore = .appDefault) async -> SessionManager {
        let kp = JanusKeyPair()

        // Try to get a real grant from the backend
        do {
            let backend: SessionBackend = HTTPSessionBackend()
            let grant = try await backend.fundSession(
                providerID: providerID,
                clientPubkey: kp.publicKeyBase64,
                maxCredits: nil
            )
            let manager = SessionManager(keyPair: kp, grant: grant, walletProvider: walletProvider, store: store)
            print("Session created via backend: \(grant.sessionID.prefix(8))...")
            return manager
        } catch {
            print("Backend unreachable, falling back to local grant: \(error.localizedDescription)")
        }

        // Fallback: self-sign with DemoConfig (offline mode)
        let sessionID = UUID().uuidString
        let maxCredits = DemoConfig.defaultMaxCredits
        let expiresAt = Date().addingTimeInterval(DemoConfig.defaultSessionDuration)

        let unsignedGrant = SessionGrant(
            sessionID: sessionID,
            userPubkey: kp.publicKeyBase64,
            providerID: providerID,
            maxCredits: maxCredits,
            expiresAt: expiresAt,
            backendSignature: ""
        )
        let backendSigner = JanusSigner(privateKey: DemoConfig.backendPrivateKey)
        let sig = (try? backendSigner.sign(fields: unsignedGrant.signableFields)) ?? ""
        let grant = SessionGrant(
            sessionID: sessionID,
            userPubkey: kp.publicKeyBase64,
            providerID: providerID,
            maxCredits: maxCredits,
            expiresAt: expiresAt,
            backendSignature: sig
        )

        let manager = SessionManager(keyPair: kp, grant: grant, walletProvider: walletProvider, store: store)
        print("Session created locally (offline): \(sessionID.prefix(8))...")
        return manager
    }

    /// Internal init with a pre-created keypair and grant.
    private init(keyPair: JanusKeyPair, grant: SessionGrant, walletProvider: (any WalletProvider)?, store: JanusStore) {
        self.clientKeyPair = keyPair
        self.clientSigner = JanusSigner(keyPair: keyPair)
        self.sessionGrant = grant
        self.spendState = SpendState(sessionID: grant.sessionID)
        self.remainingCredits = grant.maxCredits
        self.walletProvider = walletProvider
        self.store = store
        persist()
    }

    /// Set up a Tempo payment channel for this session.
    /// Called after receiving ServiceAnnounce with a provider Ethereum address.
    ///
    /// When a Privy wallet is injected, it becomes the `authorizedSigner` (signs vouchers)
    /// while a local `EthKeyPair` serves as the `payer` (funds and opens the channel on-chain).
    /// Privy's embedded wallet can't send raw transactions to custom chains like Tempo,
    /// but it can sign EIP-712 typed data for vouchers.
    func setupTempoChannel(providerEthAddress: String) {
        let payerAddress: EthAddress
        let signerAddress: EthAddress

        // Always create/restore a local ETH keypair for on-chain transactions (payer)
        let ethKP: EthKeyPair
        if let existing = self.ethKeyPair {
            ethKP = existing
        } else if let newKP = try? EthKeyPair() {
            ethKP = newKP
        } else {
            print("Failed to create Ethereum keypair")
            return
        }
        self.ethKeyPair = ethKP
        payerAddress = ethKP.address

        let addr = ethKP.address.checksumAddress
        os_log("CLIENT_ETH_ADDRESS=%{public}@ (payer)", log: smokeLog, type: .default, addr)
        print("CLIENT ETH ADDRESS (payer): \(addr)")

        if let wp = walletProvider {
            // Privy wallet signs vouchers; local key pays on-chain
            signerAddress = wp.address
            let sigAddr = wp.address.checksumAddress
            os_log("CLIENT_SIGNER_ADDRESS=%{public}@ (Privy wallet)", log: smokeLog, type: .default, sigAddr)
            print("CLIENT SIGNER ADDRESS (Privy): \(sigAddr)")
        } else {
            // No Privy — local key does both
            signerAddress = ethKP.address
            self.walletProvider = LocalWalletProvider(keyPair: ethKP, rpcURL: tempoConfig.rpcURL)
        }

        guard let providerAddr = try? EthAddress(hex: providerEthAddress) else {
            print("Invalid provider Ethereum address: \(providerEthAddress)")
            return
        }

        let salt = Keccak256.hash(Data(sessionGrant.sessionID.utf8))
        let saltHex = salt.ethHexPrefixed
        os_log("CLIENT_CHANNEL_SALT=%{public}@", log: smokeLog, type: .default, saltHex)
        print("CLIENT CHANNEL SALT: \(saltHex)")

        let ch = Channel(
            payer: payerAddress,
            payee: providerAddr,
            token: tempoConfig.paymentToken,
            salt: salt,
            authorizedSigner: signerAddress,
            deposit: UInt64(sessionGrant.maxCredits),
            config: tempoConfig
        )
        self.channel = ch
        self.channelInfo = ChannelInfo(channel: ch, config: tempoConfig)
        let chIdHex = ch.channelId.ethHexPrefixed
        os_log("CLIENT_CHANNEL_ID=%{public}@", log: smokeLog, type: .default, chIdHex)
        print("Tempo channel created: \(chIdHex.prefix(18))... deposit=\(ch.deposit)")
        persist()

        // Open channel on-chain using local key (async, non-blocking)
        // Always use LocalWalletProvider for on-chain ops — Privy can't send to custom chains
        let onChainWallet = LocalWalletProvider(keyPair: ethKP, rpcURL: tempoConfig.rpcURL)
        Task { await openChannelOnChain(wallet: onChainWallet, channel: ch) }
    }

    /// Open the payment channel on-chain using the wallet provider.
    private func openChannelOnChain(wallet: any WalletProvider, channel: Channel) async {
        guard tempoConfig.rpcURL != nil else { return }
        channelOnChainStatus = "Opening channel on-chain..."
        os_log("CHANNEL_ONCHAIN_START", log: smokeLog, type: .default)

        let opener = ChannelOpener(config: tempoConfig)
        let result = await opener.openChannel(wallet: wallet, channel: channel)

        switch result {
        case .opened(let channelId, let approveTx, let openTx):
            channelOnChainStatus = "Channel open on-chain"
            os_log("CHANNEL_ONCHAIN_OPENED=%{public}@", log: smokeLog, type: .default, channelId.ethHexPrefixed)
            os_log("CHANNEL_APPROVE_TX=%{public}@", log: smokeLog, type: .default, approveTx)
            os_log("CHANNEL_OPEN_TX=%{public}@", log: smokeLog, type: .default, openTx)
            print("Channel opened on-chain: approve=\(approveTx.prefix(18))... open=\(openTx.prefix(18))...")
        case .alreadyOpen(let channelId):
            channelOnChainStatus = "Channel already open"
            os_log("CHANNEL_ALREADY_OPEN=%{public}@", log: smokeLog, type: .default, channelId.ethHexPrefixed)
            print("Channel already exists on-chain")
        case .failed(let reason):
            channelOnChainStatus = "On-chain failed: \(reason)"
            os_log("CHANNEL_ONCHAIN_FAILED=%{public}@", log: smokeLog, type: .default, reason)
            print("On-chain channel opening failed: \(reason)")
        }
    }

    /// Create a signed VoucherAuthorization for the given quote (Tempo path).
    /// Async because WalletProvider signing may be a network call (e.g. Privy MPC).
    func createVoucherAuthorization(requestID: String, quoteID: String, priceCredits: Int) async throws -> VoucherAuthorization {
        guard let wp = walletProvider, let ch = channel else {
            throw CryptoError.verificationFailed
        }
        let newCumulative = UInt64(spendState.cumulativeSpend + priceCredits)
        let voucher = Voucher(channelId: ch.channelId, cumulativeAmount: newCumulative)
        let signed = try await wp.signVoucher(voucher, config: tempoConfig)
        return VoucherAuthorization(requestID: requestID, quoteID: quoteID, signedVoucher: signed)
    }

    /// Create a signed SpendAuthorization for the given quote (Ed25519 path).
    func createAuthorization(requestID: String, quoteID: String, priceCredits: Int) throws -> SpendAuthorization {
        let newCumulative = spendState.cumulativeSpend + priceCredits
        let newSequence = spendState.sequenceNumber + 1

        let auth = SpendAuthorization(
            sessionID: sessionGrant.sessionID,
            requestID: requestID,
            quoteID: quoteID,
            cumulativeSpend: newCumulative,
            sequenceNumber: newSequence,
            clientSignature: ""
        )
        let sig = try clientSigner.sign(fields: auth.signableFields)
        return SpendAuthorization(
            sessionID: auth.sessionID,
            requestID: requestID,
            quoteID: quoteID,
            cumulativeSpend: newCumulative,
            sequenceNumber: newSequence,
            clientSignature: sig
        )
    }

    /// Update local state after receiving an InferenceResponse.
    func recordSpend(creditsCharged: Int, receipt: Receipt) {
        spendState.advance(creditsCharged: creditsCharged)
        remainingCredits = sessionGrant.maxCredits - spendState.cumulativeSpend
        receipts.insert(receipt, at: 0)
        persist()
    }

    /// Force-update spend state from a verified SessionSync.
    /// Called when we missed a response and the provider sends us the receipt.
    func syncSpendState(to response: InferenceResponse) {
        spendState = SpendState(
            sessionID: sessionGrant.sessionID,
            cumulativeSpend: response.cumulativeSpend,
            sequenceNumber: spendState.sequenceNumber + 1
        )
        remainingCredits = sessionGrant.maxCredits - spendState.cumulativeSpend
        receipts.insert(response.receipt, at: 0)
        persist()
    }

    /// Record a completed request in history.
    func recordHistory(task: TaskType, prompt: String, response: InferenceResponse) {
        history.insert(HistoryEntry(task: task, prompt: prompt, response: response), at: 0)
        persist()
    }

    /// Clear persisted session (e.g. on session expiry or manual reset).
    func clearPersistedSession() {
        store.delete(Self.filename)
    }

    // MARK: - Persistence

    private func persist() {
        let state = PersistedClientSession(
            privateKeyBase64: clientKeyPair.privateKeyBase64,
            sessionGrant: sessionGrant,
            spendState: spendState,
            receipts: receipts,
            grantDelivered: grantDelivered,
            history: history,
            ethPrivateKeyHex: ethKeyPair?.privateKeyData.ethHexPrefixed
        )
        do {
            try store.save(state, as: Self.filename)
            print("Client session persisted: \(remainingCredits) credits, \(history.count) history, grantDelivered=\(grantDelivered)")
        } catch {
            print("Failed to persist client session: \(error)")
        }
    }
}
