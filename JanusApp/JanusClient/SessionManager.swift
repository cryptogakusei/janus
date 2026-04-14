import Foundation
import CryptoKit
import JanusShared
import os.log

private let smokeLog = OSLog(subsystem: "com.janus.client", category: "SmokeTest")

/// Manages the client's session state: keypair, session grant, spend tracking, and Tempo channel.
///
/// Creates a local session grant for identity tracking, then sets up a Tempo
/// payment channel with the provider. Vouchers are always signed via a local
/// `EthKeyPair` wrapped in `LocalWalletProvider` — works offline.
/// Privy (if present) is used for identity/funding only, not signing.
/// Persists state to disk so sessions survive app restarts.
@MainActor
class SessionManager: ObservableObject {

    @Published var remainingCredits: Int
    @Published var receipts: [Receipt] = []
    @Published var history: [HistoryEntry] = []
    @Published var lastChannelId: Data?
    @Published var lastVerifiedSettlement: UInt64?

    let clientKeyPair: JanusKeyPair
    let sessionGrant: SessionGrant
    private(set) var spendState: SpendState
    private let clientSigner: JanusSigner
    private let store: JanusStore

    // Tempo payment channel
    private(set) var ethKeyPair: EthKeyPair?
    private(set) var walletProvider: (any WalletProvider)?
    /// Privy wallet address for identity/display only (not used for signing).
    private(set) var privyIdentityAddress: EthAddress?
    private(set) var channel: Channel?
    /// Computed: includes current cumulativeSpend so the provider can detect missed responses.
    var channelInfo: ChannelInfo? {
        guard let ch = channel else { return nil }
        return ChannelInfo(channel: ch, config: tempoConfig, clientCumulativeSpend: spendState.cumulativeSpend)
    }
    private let tempoConfig = TempoConfig.testnet
    /// Whether the channel has been successfully opened on-chain.
    @Published var channelOpenedOnChain = false
    /// On-chain channel status.
    @Published var channelOnChainStatus: String = ""

    // MARK: - Stable device identity

    private static var _cachedIdentity: JanusKeyPair?

    /// Stable device identity — persisted independently of session state.
    /// Cached in memory after first load to avoid disk I/O on every request.
    static func deviceIdentityKey(store: JanusStore = .appDefault) -> JanusKeyPair {
        if let cached = _cachedIdentity { return cached }
        let filename = "client_device_identity.json"
        if let data = store.load(DeviceIdentity.self, from: filename),
           let rawData = Data(base64Encoded: data.privateKeyBase64),
           let kp = try? JanusKeyPair(privateKeyRaw: rawData) {
            _cachedIdentity = kp
            return kp
        }
        // Create new identity (first launch or corrupted file)
        let kp = JanusKeyPair()
        try? store.save(DeviceIdentity(privateKeyBase64: kp.privateKeyBase64), as: filename)
        _cachedIdentity = kp
        return kp
    }

    /// Clear the persisted device identity (e.g., for device transfer or privacy reset).
    static func clearDeviceIdentity(store: JanusStore = .appDefault) {
        store.delete("client_device_identity.json")
        _cachedIdentity = nil
    }

    private struct DeviceIdentity: Codable {
        let privateKeyBase64: String
    }

    /// Per-provider session filename so switching providers doesn't overwrite sessions.
    private static func filename(for providerID: String) -> String {
        "client_session_\(providerID).json"
    }

    /// Stored providerID for determining which file to persist to.
    private let providerID: String

    /// Try to restore a persisted session for this provider. Returns nil if none exists or expired.
    static func restore(providerID: String, walletProvider: (any WalletProvider)? = nil, store: JanusStore = .appDefault) -> SessionManager? {
        // Try per-provider file first, fall back to legacy single file for migration
        let perProviderFile = filename(for: providerID)
        let legacyFile = "client_session.json"
        let file = store.load(PersistedClientSession.self, from: perProviderFile) != nil ? perProviderFile : legacyFile
        guard let persisted = store.load(PersistedClientSession.self, from: file),
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
        self.providerID = persisted.sessionGrant.providerID
        self.spendState = persisted.spendState
        self.remainingCredits = persisted.remainingCredits
        self.receipts = persisted.receipts
        self.history = persisted.history
        self.lastChannelId = persisted.lastChannelId
        self.lastVerifiedSettlement = persisted.lastVerifiedSettlement
        self.channelOpenedOnChain = persisted.channelOpenedOnChain
        self.store = store

        // Always restore local ETH keypair if persisted (used for on-chain ops AND voucher signing)
        if let ethHex = persisted.ethPrivateKeyHex {
            do {
                let ethKP = try EthKeyPair(hexPrivateKey: ethHex)
                self.ethKeyPair = ethKP
                print("Restored ETH keypair: \(ethKP.address)")
                // Promote to Keychain on first launch after Keychain feature ships.
                // Guard prevents redundant writes on every subsequent restore.
                if JanusWalletKeychain.load() == nil {
                    JanusWalletKeychain.save(ethKP)
                    print("Migrated ETH keypair to Keychain: \(ethKP.address)")
                }
            } catch {
                print("WARNING: Failed to restore ETH keypair: \(error). A new key will be generated, which may orphan an existing on-chain channel.")
            }
        }

        // Capture Privy identity for display (not used for signing)
        if let wp = walletProvider {
            self.privyIdentityAddress = wp.address
            print("Privy identity present: \(wp.address) (identity only, not used for signing)")
        }
        // walletProvider is set in setupTempoChannel() — always LocalWalletProvider
    }

    /// Create a new session with a locally-generated identity.
    /// Trust is established via Tempo on-chain payment channel verification.
    static func create(providerID: String, walletProvider: (any WalletProvider)? = nil, store: JanusStore = .appDefault) async -> SessionManager {
        let kp = JanusKeyPair()
        let sessionID = UUID().uuidString
        let maxCredits = 100
        let expiresAt = Date().addingTimeInterval(3600)

        let grant = SessionGrant(
            sessionID: sessionID,
            userPubkey: kp.publicKeyBase64,
            providerID: providerID,
            maxCredits: maxCredits,
            expiresAt: expiresAt
        )

        let manager = SessionManager(keyPair: kp, grant: grant, walletProvider: walletProvider, store: store)
        print("Session created: \(sessionID.prefix(8))...")
        return manager
    }

    /// Internal init with a pre-created keypair and grant.
    private init(keyPair: JanusKeyPair, grant: SessionGrant, walletProvider: (any WalletProvider)?, store: JanusStore) {
        self.clientKeyPair = keyPair
        self.clientSigner = JanusSigner(keyPair: keyPair)
        self.sessionGrant = grant
        self.providerID = grant.providerID
        self.spendState = SpendState(sessionID: grant.sessionID)
        self.remainingCredits = grant.maxCredits
        // Don't store Privy as walletProvider — setupTempoChannel() always sets LocalWalletProvider.
        // Capture Privy address for identity/display only.
        if let wp = walletProvider {
            self.privyIdentityAddress = wp.address
        }
        self.store = store
        persist()
    }

    /// Set up a Tempo payment channel for this session.
    /// Called after receiving ServiceAnnounce with a provider Ethereum address.
    ///
    /// Always uses the local `EthKeyPair` as both payer and authorizedSigner.
    /// This ensures voucher signing works offline (pure local secp256k1 crypto).
    /// Privy (if present) is identity/funding only — not involved in the payment channel.
    func setupTempoChannel(providerEthAddress: String) {
        let payerAddress: EthAddress
        let signerAddress: EthAddress

        // Always create/restore a local ETH keypair for on-chain transactions (payer).
        // Migration from JSON → Keychain happens in init(persisted:), not here.
        let ethKP: EthKeyPair
        if let existing = self.ethKeyPair {
            ethKP = existing
        } else if let keychainKP = JanusWalletKeychain.loadOrCreate() {
            ethKP = keychainKP
        } else {
            print("SessionManager: ETH key unavailable — cannot set up Tempo channel")
            return
        }
        self.ethKeyPair = ethKP
        payerAddress = ethKP.address

        let addr = ethKP.address.checksumAddress
        os_log("CLIENT_ETH_ADDRESS=%{public}@ (payer)", log: smokeLog, type: .default, addr)
        print("CLIENT ETH ADDRESS (payer): \(addr)")

        // Always use local key as authorizedSigner — works offline.
        // Privy wallet (if present) is identity/funding only.
        signerAddress = ethKP.address
        self.walletProvider = LocalWalletProvider(keyPair: ethKP, rpcURL: tempoConfig.rpcURL)

        let sigAddr = ethKP.address.checksumAddress
        os_log("CLIENT_SIGNER_ADDRESS=%{public}@ (local key, offline-capable)", log: smokeLog, type: .default, sigAddr)
        print("CLIENT SIGNER ADDRESS (local, offline-capable): \(sigAddr)")

        if let privyAddr = privyIdentityAddress {
            os_log("CLIENT_PRIVY_IDENTITY=%{public}@", log: smokeLog, type: .default, privyAddr.checksumAddress)
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
        self.lastChannelId = ch.channelId
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
        let result = await opener.openChannel(wallet: wallet, channel: channel) { [weak self] status in
            Task { @MainActor [weak self] in self?.channelOnChainStatus = status }
        }

        switch result {
        case .opened(let channelId, let approveTx, let openTx):
            channelOpenedOnChain = true
            channelOnChainStatus = "Channel open on-chain"
            persist()
            os_log("CHANNEL_ONCHAIN_OPENED=%{public}@", log: smokeLog, type: .default, channelId.ethHexPrefixed)
            os_log("CHANNEL_APPROVE_TX=%{public}@", log: smokeLog, type: .default, approveTx)
            os_log("CHANNEL_OPEN_TX=%{public}@", log: smokeLog, type: .default, openTx)
            print("Channel opened on-chain: approve=\(approveTx.prefix(18))... open=\(openTx.prefix(18))...")
        case .alreadyOpen(let channelId):
            channelOpenedOnChain = true
            channelOnChainStatus = "Channel already open"
            persist()
            os_log("CHANNEL_ALREADY_OPEN=%{public}@", log: smokeLog, type: .default, channelId.ethHexPrefixed)
            print("Channel already exists on-chain")
        case .failed(let reason):
            channelOnChainStatus = "On-chain failed: \(reason)"
            os_log("CHANNEL_ONCHAIN_FAILED=%{public}@", log: smokeLog, type: .default, reason)
            print("On-chain channel opening failed: \(reason)")
        }
    }

    /// Retry opening the channel on-chain if a previous attempt failed or was interrupted.
    func retryChannelOpenIfNeeded() {
        guard let ethKP = ethKeyPair, channel != nil, !channelOpenedOnChain else { return }
        let onChainWallet = LocalWalletProvider(keyPair: ethKP, rpcURL: tempoConfig.rpcURL)
        guard let ch = channel else { return }
        print("Retrying channel open on-chain...")
        Task { await openChannelOnChain(wallet: onChainWallet, channel: ch) }
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

    /// Verify settlement on-chain by reading the escrow contract directly.
    /// Compares on-chain settled amount against client's cumulative spend.
    func verifySettlementOnChain() async -> SettlementStatus? {
        guard let channelId = lastChannelId else { return nil }
        let escrow = EscrowClient(config: tempoConfig)
        do {
            let onChain = try await escrow.getChannel(channelId: channelId)
            guard let settled = onChain.settled.toUInt64 else {
                print("WARNING: settled amount exceeds UInt64 range: \(onChain.settled)")
                return nil
            }
            lastVerifiedSettlement = settled
            persist()

            let expected = UInt64(spendState.cumulativeSpend)
            if settled == expected {
                return .match(settled: settled)
            } else if settled > expected {
                return .overpayment(settled: settled, expected: expected)
            } else {
                return .underpayment(settled: settled, expected: expected)
            }
        } catch {
            print("On-chain verification failed: \(error)")
            return nil
        }
    }

    /// Clear persisted session (e.g. on session expiry or manual reset).
    func clearPersistedSession() {
        store.delete(Self.filename(for: providerID))
    }

    // MARK: - Persistence

    private func persist() {
        let state = PersistedClientSession(
            privateKeyBase64: clientKeyPair.privateKeyBase64,
            sessionGrant: sessionGrant,
            spendState: spendState,
            receipts: receipts,
            history: history,
            ethPrivateKeyHex: ethKeyPair?.privateKeyData.ethHexPrefixed,
            lastChannelId: lastChannelId,
            lastVerifiedSettlement: lastVerifiedSettlement,
            channelOpenedOnChain: channelOpenedOnChain
        )
        do {
            try store.save(state, as: Self.filename(for: providerID))
            print("Client session persisted: \(remainingCredits) credits, \(history.count) history")
        } catch {
            print("Failed to persist client session: \(error)")
        }
    }
}
