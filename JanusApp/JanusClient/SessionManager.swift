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
/// Persists state to disk so sessions survive app restarts.
@MainActor
class SessionManager: ObservableObject {

    @Published var remainingCredits: Int
    @Published var receipts: [Receipt] = []
    @Published var history: [HistoryEntry] = []
    @Published var lastChannelId: Data?
    @Published var lastVerifiedSettlement: UInt64?

    // Tab payment state — updated by provider via TabUpdate embedded in InferenceResponse
    @Published var currentTabTokens: UInt64 = 0
    @Published var tabThreshold: UInt64 = 500
    @Published var tokenRate: UInt64 = 10

    let clientKeyPair: JanusKeyPair
    let sessionGrant: SessionGrant
    private(set) var spendState: SpendState
    private let clientSigner: JanusSigner
    private let store: JanusStore

    // Tempo payment channel
    private(set) var ethKeyPair: EthKeyPair?
    private(set) var walletProvider: (any WalletProvider)?
    /// Persisted deposit after top-ups — nil means no top-up has occurred.
    private var lastChannelDeposit: UInt64?
    private(set) var channel: Channel?
    /// Computed: includes current cumulativeSpend so the provider can detect missed responses.
    var channelInfo: ChannelInfo? {
        guard let ch = channel else { return nil }
        return ChannelInfo(channel: ch, config: tempoConfig, clientCumulativeSpend: spendState.cumulativeSpend)
    }

    /// Connectivity manager — vends the URLSession to use for blockchain RPC calls.
    /// Weak to avoid a reference cycle (ClientEngine owns both SessionManager and the manager).
    private weak var connectivityManager: PaymentConnectivityManager?

    /// Builds a TempoConfig that routes blockchain calls over whichever interface currently
    /// has confirmed internet access (WiFi-with-WAN first, cellular fallback).
    ///
    /// When WiFi has no WAN uplink (e.g. offline mesh), `internetTransport` returns a
    /// `CellularTransport` backed by `NWConnection.requiredInterfaceType = .cellular` —
    /// the only public iOS API that deterministically forces traffic onto the cellular modem.
    /// Called fresh at each on-chain operation so it always reflects the current interface.
    private var tempoConfig: TempoConfig {
        let base = TempoConfig.testnet
        let transport: any HTTPTransport = connectivityManager?.internetTransport
            ?? URLSessionTransport(session: .shared)
        return TempoConfig(
            escrowContract: base.escrowContract,
            paymentToken: base.paymentToken,
            chainId: base.chainId,
            rpcURL: base.rpcURL,
            transport: transport
        )
    }

    /// Wire a connectivity manager so on-chain operations use the correct network interface.
    /// Must be called before the first `setupTempoChannel` / `retryChannelOpenIfNeeded`.
    func attachConnectivityManager(_ manager: PaymentConnectivityManager) {
        connectivityManager = manager
    }

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
    static func restore(providerID: String, store: JanusStore = .appDefault) -> SessionManager? {
        // Try per-provider file first, fall back to legacy single file for migration
        let perProviderFile = filename(for: providerID)
        let legacyFile = "client_session.json"
        let file = store.load(PersistedClientSession.self, from: perProviderFile) != nil ? perProviderFile : legacyFile
        guard let persisted = store.load(PersistedClientSession.self, from: file),
              persisted.isValid,
              persisted.sessionGrant.providerID == providerID else {
            return nil
        }
        return try? SessionManager(persisted: persisted, store: store)
    }

    /// Restore from persisted state.
    private init(persisted: PersistedClientSession, store: JanusStore) throws {
        guard let keyData = Data(base64Encoded: persisted.privateKeyBase64) else {
            throw CryptoError.invalidBase64
        }
        let kp = try JanusKeyPair(privateKeyRaw: keyData)
        self.clientKeyPair = kp
        self.clientSigner = JanusSigner(keyPair: kp)
        self.sessionGrant = persisted.sessionGrant
        self.providerID = persisted.sessionGrant.providerID
        self.spendState = persisted.spendState
        self.lastChannelDeposit = persisted.lastChannelDeposit
        self.remainingCredits = persisted.remainingCredits
        self.receipts = persisted.receipts
        self.history = persisted.history
        self.lastChannelId = persisted.lastChannelId
        self.lastVerifiedSettlement = persisted.lastVerifiedSettlement
        // Reset channelOpenedOnChain if the escrow contract address changed since last persist
        // (e.g. testnet redeployment). Without this, the guard in openChannelOnChain() would
        // skip the opener for a channel that no longer exists on the new contract.
        let currentEscrow = TempoConfig.testnet.escrowContract.description
        if let storedEscrow = persisted.lastEscrowContract, storedEscrow != currentEscrow {
            self.channelOpenedOnChain = false
            print("Escrow contract changed (\(storedEscrow) → \(currentEscrow)), resetting channelOpenedOnChain")
        } else {
            self.channelOpenedOnChain = persisted.channelOpenedOnChain
        }
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

        // walletProvider is set in setupTempoChannel() — always LocalWalletProvider
    }

    /// Create a new session with a locally-generated identity.
    /// Trust is established via Tempo on-chain payment channel verification.
    static func create(providerID: String, store: JanusStore = .appDefault) async -> SessionManager {
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

        let manager = SessionManager(keyPair: kp, grant: grant, store: store)
        print("Session created: \(sessionID.prefix(8))...")
        return manager
    }

    /// Internal init with a pre-created keypair and grant.
    private init(keyPair: JanusKeyPair, grant: SessionGrant, store: JanusStore) {
        self.clientKeyPair = keyPair
        self.clientSigner = JanusSigner(keyPair: keyPair)
        self.sessionGrant = grant
        self.providerID = grant.providerID
        self.spendState = SpendState(sessionID: grant.sessionID)
        self.remainingCredits = grant.maxCredits
        self.store = store
        persist()
    }

    /// Set up a Tempo payment channel for this session.
    /// Called after receiving ServiceAnnounce with a provider Ethereum address.
    ///
    /// Always uses the local `EthKeyPair` as both payer and authorizedSigner.
    /// This ensures voucher signing works offline (pure local secp256k1 crypto).
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
        signerAddress = ethKP.address
        // walletProvider is used for voucher signing (pure local secp256k1, no RPC needed).
        self.walletProvider = LocalWalletProvider(keyPair: ethKP)

        let sigAddr = ethKP.address.checksumAddress
        os_log("CLIENT_SIGNER_ADDRESS=%{public}@ (local key, offline-capable)", log: smokeLog, type: .default, sigAddr)
        print("CLIENT SIGNER ADDRESS (local, offline-capable): \(sigAddr)")

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
            deposit: lastChannelDeposit ?? UInt64(sessionGrant.maxCredits),
            config: tempoConfig
        )
        self.channel = ch
        self.lastChannelId = ch.channelId
        let chIdHex = ch.channelId.ethHexPrefixed
        os_log("CLIENT_CHANNEL_ID=%{public}@", log: smokeLog, type: .default, chIdHex)
        print("Tempo channel created: \(chIdHex.prefix(18))... deposit=\(ch.deposit)")
        persist()

        // Open channel on-chain — deferred via connectivity queue so it runs when internet is
        // available (handles the offline-mesh-only scenario: mesh for inference, cellular for txs).
        let ethKPCapture = ethKP
        let chCapture = ch
        if let cm = connectivityManager {
            cm.enqueuePaymentOperation(label: "Open channel on-chain") { [weak self] in
                await self?.openChannelOnChain(ethKP: ethKPCapture, channel: chCapture)
            }
        } else {
            Task { await openChannelOnChain(ethKP: ethKPCapture, channel: chCapture) }
        }
    }

    /// Open the payment channel on-chain.
    ///
    /// Constructs a `QueueingWalletProvider` using the *current* `tempoConfig.transport`
    /// at invocation time, so the RPC call routes over whichever interface has internet.
    /// When WiFi has no WAN uplink, `tempoConfig.transport` is a `CellularTransport` backed
    /// by `NWConnection.requiredInterfaceType = .cellular`.
    private func openChannelOnChain(ethKP: EthKeyPair, channel: Channel, attempt: Int = 0) async {
        let maxAttempts = 8
        guard let rpcURL = tempoConfig.rpcURL else { return }
        let config = tempoConfig  // snapshot once so both wallet and opener use the same transport
        let wallet = QueueingWalletProvider(keyPair: ethKP, rpc: EthRPC(rpcURL: rpcURL, transport: config.transport))
        // Bug #11b-1: Skip the opener entirely when channel is already confirmed open.
        // ChannelOpener uses try? on its pre-existence RPC check — if the RPC call fails,
        // it proceeds to send open() which reverts because the channel already exists.
        guard !channelOpenedOnChain else {
            os_log("CHANNEL_ONCHAIN_SKIP_ALREADY_OPEN", log: smokeLog, type: .default)
            return
        }
        channelOnChainStatus = "Opening channel on-chain..."
        os_log("CHANNEL_ONCHAIN_START", log: smokeLog, type: .default)

        let opener = ChannelOpener(config: config)
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
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.channelOnChainStatus = ""
            }
        case .alreadyOpen(let channelId):
            channelOpenedOnChain = true
            persist()
            os_log("CHANNEL_ALREADY_OPEN=%{public}@", log: smokeLog, type: .default, channelId.ethHexPrefixed)
            print("Channel already exists on-chain")
        case .failed(let reason):
            // "RPC unavailable" = transient network error (iOS hasn't routed to cellular yet).
            // Re-enqueue so it retries once the cellular path is confirmed stable.
            if reason.hasPrefix("RPC unavailable"), attempt < maxAttempts, let cm = connectivityManager {
                let nextAttempt = attempt + 1
                channelOnChainStatus = "Waiting for internet — retry \(nextAttempt)/\(maxAttempts)..."
                os_log("CHANNEL_ONCHAIN_RETRY=%{public}d", log: smokeLog, type: .default, nextAttempt)
                print("Channel open RPC unavailable (attempt \(nextAttempt)/\(maxAttempts)), re-queuing...")
                cm.enqueuePaymentOperation(label: "Retry channel open (attempt \(nextAttempt))") { [weak self] in
                    await self?.openChannelOnChain(ethKP: ethKP, channel: channel, attempt: nextAttempt)
                }
            } else {
                channelOnChainStatus = "On-chain failed: \(reason)"
                os_log("CHANNEL_ONCHAIN_FAILED=%{public}@", log: smokeLog, type: .default, reason)
                print("On-chain channel opening failed: \(reason)")
            }
        }
    }

    /// The total deposit ceiling for display purposes (reflects top-ups).
    var totalDeposit: Int {
        channel.map { Int($0.deposit) } ?? sessionGrant.maxCredits
    }

    /// Retry opening the channel on-chain if a previous attempt failed or was interrupted.
    func retryChannelOpenIfNeeded() {
        guard let ethKP = ethKeyPair, let ch = channel, !channelOpenedOnChain else { return }
        print("Retrying channel open on-chain...")
        if let cm = connectivityManager {
            cm.enqueuePaymentOperation(label: "Retry channel open on-chain") { [weak self] in
                await self?.openChannelOnChain(ethKP: ethKP, channel: ch)
            }
        } else {
            Task { await openChannelOnChain(ethKP: ethKP, channel: ch) }
        }
    }

    /// Create a signed VoucherAuthorization for the given quote (Tempo path).
    func createVoucherAuthorization(requestID: String, quoteID: String, priceCredits: Int) async throws -> VoucherAuthorization {
        guard let wp = walletProvider, let ch = channel else {
            throw CryptoError.verificationFailed
        }
        let newCumulative = UInt64(spendState.cumulativeSpend + priceCredits)
        let voucher = Voucher(channelId: ch.channelId, cumulativeAmount: newCumulative)
        let signed = try await wp.signVoucher(voucher, config: tempoConfig)
        return VoucherAuthorization(requestID: requestID, quoteID: quoteID, signedVoucher: signed)
    }

    /// Update local tab state from the TabUpdate embedded in each InferenceResponse.
    func applyTabUpdate(_ tabUpdate: TabUpdate, tokenRate: UInt64) {
        currentTabTokens = tabUpdate.cumulativeTabTokens
        tabThreshold = tabUpdate.tabThreshold
        self.tokenRate = tokenRate
    }

    /// Create a signed VoucherAuthorization for a tab settlement (quoteID is nil).
    /// Cumulative = existing authorized amount + tabCredits owed.
    func createTabSettlementVoucher(requestID: String, tabCredits: UInt64, channelId: Data) async throws -> VoucherAuthorization {
        guard let wp = walletProvider, let ch = channel else {
            throw CryptoError.verificationFailed
        }
        // Use max(authorizedAmount, spendState.cumulativeSpend) as baseline.
        // spendState.cumulativeSpend is persisted across restarts; ch.authorizedAmount is derived
        // from latestVoucher which is NOT persisted. After a restart, authorizedAmount resets to 0
        // but spendState still reflects total spend — without this, the first post-restart voucher
        // produces a cumulative below the provider's settledAmount, making unsettledAmount = 0.
        let base = max(ch.authorizedAmount, UInt64(max(0, spendState.cumulativeSpend)))
        let newCumulative = base + tabCredits
        guard newCumulative <= ch.deposit else {
            throw ChannelError.exceedsDeposit
        }
        let voucher = Voucher(channelId: ch.channelId, cumulativeAmount: newCumulative)
        let signed = try await wp.signVoucher(voucher, config: tempoConfig)
        // Update local channel so the next settlement computes a strictly higher cumulative amount.
        // authorizedAmount is derived from latestVoucher.cumulativeAmount — without this update
        // every settlement would produce the same (non-monotonic) amount and be rejected.
        channel?.latestVoucher = signed
        return VoucherAuthorization(requestID: requestID, quoteID: nil, signedVoucher: signed)
    }

    /// Record a tab settlement: advance spend state and reset tab counter.
    func recordTabSettlement(tabCredits: UInt64) {
        spendState.advance(creditsCharged: Int(min(tabCredits, UInt64(Int.max))))
        remainingCredits = max(0, creditCeiling - spendState.cumulativeSpend)
        currentTabTokens = 0
        persist()
    }

    /// The credit ceiling — uses channel deposit if available (reflects top-ups), otherwise sessionGrant.maxCredits.
    private var creditCeiling: Int {
        channel.map { Int($0.deposit) } ?? sessionGrant.maxCredits
    }

    /// Update local state after receiving an InferenceResponse (prepaid / non-tab mode).
    ///
    /// Advances the spend state so `remainingCredits` reflects credits paid.
    /// Do NOT call this in tab mode — use `recordReceiptOnly()` instead.
    /// In tab mode, `spendState` is advanced only at settlement time (via `recordTabSettlement`)
    /// to prevent double-counting: per-response accrual + settlement accrual = 2× actual spend.
    func recordSpend(creditsCharged: Int, receipt: Receipt) {
        spendState.advance(creditsCharged: creditsCharged)
        remainingCredits = creditCeiling - spendState.cumulativeSpend
        receipts.insert(receipt, at: 0)
        persist()
    }

    /// Store a receipt without advancing the spend state (tab mode only).
    ///
    /// In the tab model the channel is authorized at settlement time, not per-response.
    /// Calling `recordSpend()` on every response AND `recordTabSettlement()` at cycle end
    /// would double-count every credit, inflating `spendState.cumulativeSpend` and causing
    /// the next settlement voucher's `newCumulative` to exceed the deposit.
    func recordReceiptOnly(receipt: Receipt) {
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
        remainingCredits = creditCeiling - spendState.cumulativeSpend
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

    /// Top up the active payment channel by sending additional tokens to escrow.
    func topUpChannel(additionalDeposit: UInt64) async {
        guard let channel = self.channel,
              let ethKP = self.ethKeyPair,
              let rpcURL = tempoConfig.rpcURL else {
            channelOnChainStatus = "Top-up failed: no active channel"
            return
        }
        channelOnChainStatus = "Topping up..."
        // Snapshot tempoConfig once so wallet and topUpService share the same transport.
        let config = tempoConfig
        let wallet = QueueingWalletProvider(keyPair: ethKP, rpc: EthRPC(rpcURL: rpcURL, transport: config.transport))
        let topUpService = ChannelTopUp(config: config)
        let result = await topUpService.topUp(
            wallet: wallet,
            channel: channel,
            additionalDeposit: additionalDeposit
        ) { [weak self] status in
            Task { @MainActor [weak self] in self?.channelOnChainStatus = status }
        }

        switch result {
        case .topped(_, _, let newDeposit):
            self.channel?.recordTopUp(newDeposit: newDeposit)
            lastChannelDeposit = newDeposit
            remainingCredits = Int(newDeposit) - spendState.cumulativeSpend
            channelOnChainStatus = "Top-up complete — \(remainingCredits) credits available"
            persist()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.channelOnChainStatus = ""
            }
        case .failed(let reason):
            channelOnChainStatus = "Top-up failed: \(reason)"
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
            channelOpenedOnChain: channelOpenedOnChain,
            lastChannelDeposit: lastChannelDeposit,
            lastEscrowContract: tempoConfig.escrowContract.description
        )
        do {
            try store.save(state, as: Self.filename(for: providerID))
            print("Client session persisted: \(remainingCredits) credits, \(history.count) history")
        } catch {
            print("Failed to persist client session: \(error)")
        }
    }
}
