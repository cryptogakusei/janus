import AppKit
import Foundation
import JanusShared
import MLXLMCommon
import MLXLLM
import Network
import os.log

private let smokeLog = OSLog(subsystem: "com.janus.provider", category: "SmokeTest")

/// Orchestrates the provider's full request pipeline.
///
/// Handles: PromptRequest → inference → InferenceResponse + TabUpdate → (when threshold crossed) TabSettlementRequest → VoucherAuthorization → reset tab.
/// Owns the MLX model, voucher verifier, channel state, and provider keypair.
@MainActor
class ProviderEngine: ObservableObject {

    @Published var modelStatus: ModelStatus = .notLoaded
    @Published var lastRequest: String?
    @Published var lastResponse: String?
    @Published var totalRequestsServed: Int = 0

    // Request log (newest first, capped at 50)
    struct LogEntry: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let taskType: String
        let promptPreview: String
        let responsePreview: String?
        let credits: Int?
        let isError: Bool
        let sessionID: String?

        init(timestamp: Date, taskType: String, promptPreview: String, responsePreview: String?, credits: Int?, isError: Bool, sessionID: String? = nil) {
            self.id = UUID()
            self.timestamp = timestamp
            self.taskType = taskType
            self.promptPreview = promptPreview
            self.responsePreview = responsePreview
            self.credits = credits
            self.isError = isError
            self.sessionID = sessionID
        }
    }
    @Published var requestLog: [LogEntry] = []

    // Session info
    /// Number of sessions with active clients or unsettled credits.
    var activeSessionCount: Int {
        channels.filter { sessionToSender[$0.key] != nil || $0.value.unsettledAmount > 0 }.count
    }
    @Published var totalCreditsEarned: Int = 0

    enum ModelStatus: String {
        case notLoaded = "Not Loaded"
        case loading = "Loading..."
        case ready = "Ready"
        case error = "Error"
    }

    /// Per-client summary for the provider dashboard UI.
    struct ClientSummary: Identifiable {
        let id: String          // stable identity (pubkey) or fallback senderID
        var senderIDs: [String] // all transport-level senderIDs for this identity
        var sessionIDs: [String]
        var totalCreditsUsed: Int
        var maxCredits: Int
        var requestCount: Int
        var errorCount: Int
        var lastActive: Date?
        var logs: [LogEntry]
    }

    /// Computes per-client summaries by grouping sessions by stable device identity.
    /// Falls back to senderID for clients that don't send `clientIdentity`.
    var clientSummaries: [ClientSummary] {
        var summaries: [String: ClientSummary] = [:]
        var senderIDSets: [String: Set<String>] = [:]

        // Iterate channels (source of truth for existing sessions), not sessionToSender (routing table)
        for sessionID in channels.keys {
            let senderID = sessionToSender[sessionID]
            // Use stable identity if available, fall back to senderID, then sessionID
            let identity = sessionToIdentity[sessionID] ?? senderID ?? sessionID
            let channel = channels[sessionID]

            var summary = summaries[identity] ?? ClientSummary(
                id: identity,
                senderIDs: [],
                sessionIDs: [],
                totalCreditsUsed: 0,
                maxCredits: 0,
                requestCount: 0,
                errorCount: 0,
                lastActive: nil,
                logs: []
            )
            if let senderID {
                senderIDSets[identity, default: []].insert(senderID)
            }
            summary.sessionIDs.append(sessionID)
            summary.totalCreditsUsed += Int(channel?.authorizedAmount ?? 0)
            summary.maxCredits += Int(channel?.deposit ?? 0)

            let sessionLogs = requestLog.filter { $0.sessionID == sessionID }
            summary.requestCount += sessionLogs.filter { !$0.isError && $0.taskType != "on-chain-settlement" }.count
            summary.errorCount += sessionLogs.filter { $0.isError }.count
            summary.logs.append(contentsOf: sessionLogs)
            if let latest = sessionLogs.first?.timestamp {
                if summary.lastActive == nil || latest > summary.lastActive! {
                    summary.lastActive = latest
                }
            }
            summaries[identity] = summary
        }

        // Convert senderID sets to arrays
        for (identity, senderSet) in senderIDSets {
            summaries[identity]?.senderIDs = Array(senderSet)
        }

        // Sort logs within each summary (newest first) and return sorted by last active
        return summaries.values
            .map { var s = $0; s.logs.sort { $0.timestamp > $1.timestamp }; return s }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// Total credits pending on-chain settlement (unsettled vouchers across all channels).
    var pendingSettlementCredits: Int {
        channels.values.reduce(0) { $0 + Int($1.unsettledAmount) }
    }

    let providerID: String
    let providerKeyPair: JanusKeyPair
    private let mlxRunner: MLXRunner
    private let store: JanusStore

    // Last response per session — for SessionSync recovery if client missed it
    private var lastResponses: [String: InferenceResponse] = [:]

    // Tab payment state
    /// Running token tab per client channel ID (hex). Derived from tabByChannelId[hex] >= tabThresholdTokens for blocking.
    private var tabByChannelId: [String: UInt64] = [:]
    /// channelId hex → requestID of outstanding TabSettlementRequest. Persisted for crash recovery + replay prevention.
    private var pendingTabSettlementByChannelId: [String: String] = [:]
    @Published var tokenRate: UInt64 = 10          // credits per 1000 tokens
    @Published var tabThresholdTokens: UInt64 = 5000 // tokens before settlement required

    // Tempo voucher path
    private var channels: [String: Channel] = [:] {         // sessionID → Channel
        didSet { objectWillChange.send() }
    }
    /// channelId (hex) → last known settledAmount. Persisted for RPC-unavailable reconnect recovery.
    private var settledChannelAmounts: [String: UInt64] = [:]
    private var voucherVerifier: VoucherVerifier?
    private let tempoConfig = TempoConfig.testnet
    /// Provider's Ethereum keypair (for Tempo address identity).
    private(set) var providerEthKeyPair: EthKeyPair?
    @Published private(set) var isSettling = false
    /// When settlement is requested while another is in progress, queue the parameters for re-run.
    private var pendingSettlementRequest: (isRetry: Bool, removeAfterSettlement: Bool)?
    @Published var settlementIntervalSeconds: Int = 300  // 5 minutes default
    @Published var settlementThreshold: Int = 50          // 50 credits default
    private var settlementTimerTask: Task<Void, Never>?
    private var networkMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status = .satisfied

    /// Callback to send messages back to a specific client via MPC.
    /// The String parameter is the sender/session ID for routing.
    var sendMessage: ((MessageEnvelope, String) -> Void)?

    // Maps sessionID → senderID for routing replies to the correct client
    private var sessionToSender: [String: String] = [:]
    /// Maps sessionID → stable client identity (device pubkey base64) for UI grouping.
    private var sessionToIdentity: [String: String] = [:]

    private static let filename = "provider_state.json"

    init(providerID: String, store: JanusStore = .appDefault) {
        self.store = store
        self.mlxRunner = MLXRunner()

        // Try to restore persisted state (preserves provider identity across restarts)
        if let persisted = store.load(PersistedProviderState.self, from: Self.filename),
           persisted.providerID == providerID,
           let keyData = Data(base64Encoded: persisted.privateKeyBase64),
           let kp = try? JanusKeyPair(privateKeyRaw: keyData) {
            self.providerID = persisted.providerID
            self.providerKeyPair = kp
            self.totalRequestsServed = persisted.totalRequestsServed
            self.totalCreditsEarned = persisted.totalCreditsEarned
            self.requestLog = persisted.requestLog.map { entry in
                LogEntry(timestamp: entry.timestamp, taskType: entry.taskType,
                         promptPreview: entry.promptPreview, responsePreview: entry.responsePreview,
                         credits: entry.credits, isError: entry.isError, sessionID: entry.sessionID)
            }
            // Restore unsettled channels (survive restart for offline settlement)
            if let unsettled = persisted.unsettledChannels, !unsettled.isEmpty {
                self.channels = unsettled
                // Restore identity mappings so clientSummaries groups correctly
                if let identities = persisted.sessionToIdentity {
                    self.sessionToIdentity = identities
                }
                let totalUnsettled = unsettled.values.reduce(0) { $0 + Int($1.unsettledAmount) }
                let details = unsettled.map { "\($0.key.prefix(8))...=\($0.value.unsettledAmount)" }.joined(separator: ", ")
                print("Restored \(unsettled.count) unsettled channel(s) from previous session: \(totalUnsettled) total credits [\(details)]")
            }
            // Restore settled channel baselines for RPC-unavailable reconnect recovery
            if let amounts = persisted.settledChannelAmounts {
                self.settledChannelAmounts = amounts
            }
            // Restore settlement settings
            if let interval = persisted.settlementIntervalSeconds {
                self.settlementIntervalSeconds = interval
            }
            if let threshold = persisted.settlementThreshold {
                self.settlementThreshold = threshold
            }
            // Restore tab payment state — prevents clients escaping debt via reconnect
            if let tabs = persisted.tabByChannelId {
                self.tabByChannelId = tabs
            }
            if let pending = persisted.pendingTabSettlementByChannelId {
                self.pendingTabSettlementByChannelId = pending
            }
            // Restore operator-configured pricing (clamp to safe minimums)
            if let rate = persisted.tokenRate { self.tokenRate = max(1, rate) }
            if let threshold = persisted.tabThresholdTokens { self.tabThresholdTokens = max(100, threshold) }
            print("Restored provider state: \(persisted.totalRequestsServed) served")
        } else {
            self.providerID = providerID
            self.providerKeyPair = JanusKeyPair()
        }

        // Initialize Tempo/Ethereum identity — restore persisted key or generate new one
        let ethKP: EthKeyPair?
        if let persisted = store.load(PersistedProviderState.self, from: Self.filename),
           let hex = persisted.ethPrivateKeyHex,
           let restored = try? EthKeyPair(hexPrivateKey: hex) {
            ethKP = restored
            print("Restored provider ETH keypair: \(restored.address)")
        } else {
            ethKP = try? EthKeyPair()
        }
        if let ethKP {
            self.providerEthKeyPair = ethKP
            self.voucherVerifier = VoucherVerifier(
                providerAddress: ethKP.address,
                config: tempoConfig
            )
            print("Provider Ethereum address: \(ethKP.address)")
            os_log("PROVIDER_ETH_ADDRESS=%{public}@", log: smokeLog, type: .default, ethKP.address.checksumAddress)
            // Write ETH address to sidecar file for CLI tooling
            let ethInfo: [String: String] = [
                "address": ethKP.address.checksumAddress,
                "privateKey": ethKP.privateKeyData.ethHexPrefixed,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: ethInfo, options: .prettyPrinted) {
                try? data.write(to: store.sidecarURL(for: "provider_eth.json"))
            }
            persistState()
        }

        // Persist unsettled channels on app termination (safety net — primary persistence is per-voucher)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistState() }
        }
    }

    /// Provider's public key base64 for ServiceAnnounce.
    var providerPubkeyBase64: String {
        providerKeyPair.publicKeyBase64
    }

    /// Fund the provider's ETH address via testnet faucet (for gas fees).
    /// Tempo uses pathUSD for gas, so a fresh key needs faucet funding before it can settle.
    func fundProviderIfNeeded() async {
        guard let ethKP = providerEthKeyPair, let rpcURL = tempoConfig.rpcURL else { return }
        let rpc = EthRPC(rpcURL: rpcURL)
        do {
            try await rpc.fundAddress(ethKP.address)
            print("Provider funded via testnet faucet: \(ethKP.address.checksumAddress)")
            os_log("PROVIDER_FUNDED=%{public}@", log: smokeLog, type: .default, ethKP.address.checksumAddress)
        } catch {
            print("Faucet funding failed (may already be funded): \(error.localizedDescription)")
        }
    }

    /// Settle all channels on-chain when a client disconnects.
    func settleAllSessions() async {
        await settleAllChannelsOnChain()
    }

    /// Maximum age for restored channels before they're discarded as stale (24 hours).
    private static let channelTTL: TimeInterval = 24 * 60 * 60

    /// Retry settlement for any persisted unsettled channels (called on startup and network restore).
    func retryPendingSettlements() async {
        // Discard channels older than TTL — on-chain channel may be closed, funds unrecoverable
        let now = Date()
        let staleIDs = channels.filter { sessionID, channel in
            guard channel.unsettledAmount > 0 else { return false }
            guard let lastVoucher = channel.lastVoucherAt else { return false }
            return now.timeIntervalSince(lastVoucher) > Self.channelTTL
        }.map(\.key)
        for sessionID in staleIDs {
            print("WARNING: Discarding stale channel \(sessionID.prefix(8))... (older than \(Int(Self.channelTTL / 3600))h) — \(channels[sessionID]?.unsettledAmount ?? 0) credits lost")
            if let channel = channels[sessionID] { recordSettledBaseline(for: channel) }
            channels.removeValue(forKey: sessionID)
            sessionToIdentity.removeValue(forKey: sessionID)
        }
        if !staleIDs.isEmpty { persistState() }

        let unsettledCount = channels.filter { $0.value.unsettledAmount > 0 }.count
        guard unsettledCount > 0 else { return }
        print("Retrying settlement for \(unsettledCount) persisted channel(s)...")
        await settleAllChannelsOnChain(isRetry: true)
    }

    /// Start monitoring network connectivity. Retries pending settlements when internet returns.
    func startNetworkMonitor() {
        guard networkMonitor == nil else { return }  // prevent double-init
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasUnsatisfied = self.lastPathStatus != .satisfied
                self.lastPathStatus = path.status
                if wasUnsatisfied && path.status == .satisfied {
                    print("Network restored — retrying pending settlements...")
                    await self.retryPendingSettlements()
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        self.networkMonitor = monitor
    }

    deinit {
        networkMonitor?.cancel()
        settlementTimerTask?.cancel()
    }

    /// Start periodic settlement timer. Settles all channels at the configured interval.
    /// Idempotent — cancels any existing timer before starting a new one.
    func startPeriodicSettlement() {
        settlementTimerTask?.cancel()
        let interval = settlementIntervalSeconds
        guard interval > 0 else {
            print("Periodic settlement disabled")
            return
        }
        print("Periodic settlement timer started: every \(interval)s (first fire in \(interval)s)")
        settlementTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                } catch {
                    break  // CancellationError — exit cleanly
                }
                guard let self else { return }
                let pending = self.pendingSettlementCredits
                guard pending > 0 else { continue }
                print("Periodic settlement triggered: \(pending) credits pending")
                await self.settleAllChannelsOnChain(isRetry: true, removeAfterSettlement: false)
            }
        }
    }

    /// Settle all Tempo channels on-chain that have unsettled vouchers.
    /// - Parameter isRetry: true when retrying persisted channels or periodic/threshold triggers (skips faucet/wait).
    /// - Parameter removeAfterSettlement: true to remove settled channels (disconnect path), false to keep them alive (periodic/threshold).
    private func settleAllChannelsOnChain(isRetry: Bool = false, removeAfterSettlement: Bool = true) async {
        // Concurrent settlement guard — isSettling is safe as plain Bool because @MainActor serializes access
        guard !isSettling else {
            // Queue this request — will re-run after current settlement completes.
            // Prefer removeAfterSettlement: true (disconnect) over false (periodic) when merging.
            let mergedRemove = (pendingSettlementRequest?.removeAfterSettlement ?? false) || removeAfterSettlement
            let mergedRetry = isRetry && (pendingSettlementRequest?.isRetry ?? true)
            pendingSettlementRequest = (isRetry: mergedRetry, removeAfterSettlement: mergedRemove)
            print("Settlement already in progress, queued (remove=\(mergedRemove), retry=\(mergedRetry))")
            return
        }
        isSettling = true
        defer {
            isSettling = false
            // If settlement was requested while we were busy, run it now
            if let queued = pendingSettlementRequest {
                pendingSettlementRequest = nil
                Task { await settleAllChannelsOnChain(isRetry: queued.isRetry, removeAfterSettlement: queued.removeAfterSettlement) }
            }
        }

        guard let ethKP = providerEthKeyPair, let rpcURL = tempoConfig.rpcURL else { return }

        let rpc = EthRPC(rpcURL: rpcURL)
        if !isRetry {
            // Ensure provider has gas funds before attempting settlement (skip on retry — already funded on startup)
            try? await rpc.fundAddress(ethKP.address)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        let settler = ChannelSettler(config: tempoConfig)
        var pendingChannels: [(String, Channel)] = []

        for (sessionID, channel) in channels {
            guard channel.latestVoucher != nil else { continue }

            let result = await settler.settle(providerKeyPair: ethKP, channel: channel)
            switch result {
            case .settled(let txHash, let amount):
                channels[sessionID]?.recordSettlement(amount: amount)
                if removeAfterSettlement {
                    removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId, onlyIfSettled: true)
                }
                print("On-chain settlement: session \(sessionID.prefix(8))... amount=\(amount) tx=\(txHash.prefix(18))...")
                os_log("SETTLEMENT_TX=%{public}@", log: smokeLog, type: .default, txHash)
                os_log("SETTLEMENT_AMOUNT=%{public}d", log: smokeLog, type: .default, amount)
                appendLog(LogEntry(
                    timestamp: Date(), taskType: "on-chain-settlement",
                    promptPreview: "Settled \(amount) credits on-chain",
                    responsePreview: txHash,
                    credits: Int(amount), isError: false, sessionID: sessionID
                ))
            case .noVoucher:
                break
            case .alreadySettled:
                if removeAfterSettlement {
                    removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId)
                }
                print("Channel \(sessionID.prefix(8))... already settled on-chain")
            case .failed(let reason):
                if case .channelNotOnChain = reason {
                    if isRetry {
                        // Persisted channel from previous session — client is gone
                        removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId)
                        print("Channel \(sessionID.prefix(8))... not on-chain (stale) — removed")
                    } else {
                        // Client may still be opening — queue for 20s retry
                        pendingChannels.append((sessionID, channel))
                        print("Channel \(sessionID.prefix(8))... not yet on-chain, will retry...")
                    }
                } else if reason.isPermanent {
                    removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId)
                    print("Channel \(sessionID.prefix(8))... \(reason) — removed")
                } else {
                    // Transient failure (network error, etc.) — keep for future retry via NWPathMonitor
                    print("On-chain settlement failed for \(sessionID.prefix(8))...: \(reason)")
                    os_log("SETTLEMENT_FAILED=%{public}@", log: smokeLog, type: .default, reason.description)
                    appendLog(LogEntry(
                        timestamp: Date(), taskType: "on-chain-settlement",
                        promptPreview: "On-chain settlement failed: \(reason)",
                        responsePreview: nil, credits: nil, isError: true, sessionID: sessionID
                    ))
                }
            }
        }

        // Retry pending channels after waiting for on-chain opening (disconnect path only)
        // Client needs ~15s total: 3s faucet wait + approve tx + open tx
        if !pendingChannels.isEmpty {
            print("Waiting 20s for \(pendingChannels.count) channel(s) to appear on-chain...")
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            for (sessionID, channel) in pendingChannels {
                let result = await settler.settle(providerKeyPair: ethKP, channel: channel)
                switch result {
                case .settled(let txHash, let amount):
                    channels[sessionID]?.recordSettlement(amount: amount)
                    if removeAfterSettlement {
                        removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId, onlyIfSettled: true)
                    }
                    print("On-chain settlement (retry): session \(sessionID.prefix(8))... amount=\(amount)")
                    os_log("SETTLEMENT_TX=%{public}@", log: smokeLog, type: .default, txHash)
                    os_log("SETTLEMENT_AMOUNT=%{public}d", log: smokeLog, type: .default, amount)
                    appendLog(LogEntry(
                        timestamp: Date(), taskType: "on-chain-settlement",
                        promptPreview: "Settled \(amount) credits on-chain",
                        responsePreview: txHash,
                        credits: Int(amount), isError: false, sessionID: sessionID
                    ))
                case .noVoucher, .alreadySettled:
                    if case .alreadySettled = result, removeAfterSettlement {
                        removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId)
                    }
                case .failed(let reason):
                    // After 20s grace period, channelNotOnChain is effectively permanent
                    var shouldRemove = reason.isPermanent
                    if case .channelNotOnChain = reason { shouldRemove = true }

                    if shouldRemove {
                        removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId)
                        print("On-chain settlement permanently failed (retry) for \(sessionID.prefix(8))...: \(reason)")
                    } else {
                        print("On-chain settlement failed (retry) for \(sessionID.prefix(8))...: \(reason)")
                    }
                    os_log("SETTLEMENT_FAILED=%{public}@", log: smokeLog, type: .default, reason.description)
                    appendLog(LogEntry(
                        timestamp: Date(), taskType: "on-chain-settlement",
                        promptPreview: "On-chain settlement failed: \(reason)",
                        responsePreview: nil, credits: nil, isError: true, sessionID: sessionID
                    ))
                }
            }
        }
    }

    /// Record the settled amount for a channel before it leaves in-memory state.
    /// Guards against the settled baseline being lost when the channel is removed
    /// and RPC is unavailable on the next reconnect.
    private func recordSettledBaseline(for channel: Channel) {
        guard channel.settledAmount > 0 else { return }
        let key = channel.channelId.ethHexPrefixed
        settledChannelAmounts[key] = max(settledChannelAmounts[key] ?? 0, channel.settledAmount)
    }

    /// Remove a channel only if its channelId still matches (guards against a reconnected client replacing the channel).
    /// Prunes all session-related state: identity mapping, sender routing, and cached responses.
    private func removeChannelIfMatch(sessionID: String, expectedChannelId: Data, onlyIfSettled: Bool = false) {
        guard channels[sessionID]?.channelId == expectedChannelId else { return }
        if onlyIfSettled {
            guard channels[sessionID]?.unsettledAmount == 0 else { return }
        }
        if let channel = channels[sessionID] { recordSettledBaseline(for: channel) }
        channels.removeValue(forKey: sessionID)
        sessionToIdentity.removeValue(forKey: sessionID)
        sessionToSender.removeValue(forKey: sessionID)
        lastResponses.removeValue(forKey: sessionID)
        persistState()
    }

    // MARK: - Model loading

    func loadModel() async {
        modelStatus = .loading
        do {
            try await mlxRunner.loadModel { [weak self] progress in
                Task { @MainActor in
                    if progress.fractionCompleted >= 1.0 {
                        self?.modelStatus = .ready
                    }
                }
            }
            modelStatus = .ready
        } catch {
            modelStatus = .error
            print("Model load failed: \(error)")
        }
    }

    // MARK: - Message handling

    func handleMessage(_ envelope: MessageEnvelope) {
        switch envelope.type {
        case .promptRequest:
            guard let request = try? envelope.unwrap(as: PromptRequest.self) else { return }
            Task { await handlePromptRequest(request, senderID: envelope.senderID) }
        case .voucherAuthorization:
            guard let auth = try? envelope.unwrap(as: VoucherAuthorization.self) else { return }
            if auth.quoteID == nil {
                Task { await handleTabSettlementVoucher(auth) }  // tab settlement
            }
            // Prepaid vouchers (quoteID non-nil) silently dropped — provider is tab-only
        case .tabSettlementRequest:
            break  // Provider sends, never receives
        default:
            break
        }
    }

    // MARK: - Request pipeline

    private func handlePromptRequest(_ request: PromptRequest, senderID: String) async {
        lastRequest = "[\(request.taskType.rawValue)] \(request.promptText.prefix(60))..."

        // Track sender for routing replies back to the correct client
        sessionToSender[request.sessionID] = senderID

        // Track stable device identity for UI grouping (falls back to senderID if absent)
        if let identity = request.clientIdentity {
            sessionToIdentity[request.sessionID] = identity
        }

        // If channel info included, verify and cache
        if let info = request.channelInfo, let vv = voucherVerifier {
            let existingChannel = channels[request.sessionID]
            let depositChanged = existingChannel.map { $0.deposit != info.deposit } ?? false
            let channelChanged = existingChannel?.channelId != info.channelId || depositChanged

            // Only hit the RPC for new or changed channels — known channels skip the network call
            // to avoid the 15-second RPC timeout blocking inference on every offline request.
            let result: ChannelVerificationResult
            if channelChanged {
                result = await vv.verifyChannelInfoOnChain(info)
            } else {
                result = .rpcUnavailable  // channel already known; treat as offline-accepted
            }

            switch result {
            case .acceptedOnChain, .rpcUnavailable:
                break  // proceed; rpcUnavailable is safe — supports offline inference after initial handshake
            case .channelNotFoundOnChain:
                sendError(requestID: request.requestID, sessionID: request.sessionID,
                          code: .channelNotReady, message: "Channel not yet opened on-chain.")
                return
            case .rejected(let reason):
                sendError(requestID: request.requestID, sessionID: request.sessionID,
                          code: .invalidSession, message: "Channel rejected: \(reason)")
                return
            }

            // Detect missed response: compare client's reported spend with our last
            // response. If the client's spend is behind, they missed the response and
            // need SessionSync to recover. If equal, they got it (idle reconnect).
            if existingChannel != nil, let missed = lastResponses[request.sessionID],
               info.clientCumulativeSpend < missed.cumulativeSpend {
                let sync = SessionSync(sessionID: request.sessionID, missedResponse: missed)
                send(type: .sessionSync, payload: sync, toSession: request.sessionID)
                print("SessionSync: client spend=\(info.clientCumulativeSpend) < provider=\(missed.cumulativeSpend), recovering session \(request.sessionID.prefix(8))...")
            }

            // Only replace channel if it's new, has different params, or deposit increased (top-up).
            if channelChanged {
                // Record the old channel's settled baseline before overwriting (channel replacement path).
                if let old = existingChannel { recordSettledBaseline(for: old) }

                var channel = Channel(
                    payer: info.payerAddress, payee: info.payeeAddress,
                    token: info.tokenAddress, salt: info.salt,
                    authorizedSigner: info.authorizedSigner,
                    deposit: info.deposit, config: tempoConfig
                )
                // Initialize settledAmount from on-chain state — critical for reconnecting clients
                // whose cumulative voucher amounts include previously-settled spend.
                if case .acceptedOnChain(_, let onChainSettled) = result, onChainSettled > 0 {
                    channel.recordSettlement(amount: onChainSettled)
                    settledChannelAmounts[info.channelId.ethHexPrefixed] = onChainSettled
                    print("Initialized settledAmount=\(onChainSettled) from on-chain for session \(request.sessionID.prefix(8))...")
                } else if case .rpcUnavailable = result {
                    let key = info.channelId.ethHexPrefixed
                    if let cached = settledChannelAmounts[key], cached > 0 {
                        channel.recordSettlement(amount: cached)
                        print("Initialized settledAmount=\(cached) from local cache (RPC unavailable) for session \(request.sessionID.prefix(8))...")
                    }
                }
                let isUpdate = existingChannel != nil
                channels[request.sessionID] = channel
                let verifyStatus: String
                switch result {
                case .acceptedOnChain(let deposit, let settled): verifyStatus = "on-chain verified (deposit=\(deposit), settled=\(settled))"
                case .channelNotFoundOnChain: verifyStatus = "not found on-chain"
                case .rpcUnavailable: verifyStatus = "RPC unavailable (offline)"
                case .rejected: verifyStatus = "rejected"
                }
                print("Tempo channel \(isUpdate ? "updated" : "cached") for session \(request.sessionID.prefix(8))...: \(verifyStatus)")
                os_log("CLIENT_CHANNEL_PAYER=%{public}@", log: smokeLog, type: .default, info.payerAddress.checksumAddress)
                os_log("CLIENT_CHANNEL_ID=%{public}@", log: smokeLog, type: .default, info.channelId.ethHexPrefixed)
                os_log("CLIENT_CHANNEL_DEPOSIT=%{public}d", log: smokeLog, type: .default, info.deposit)
            } else {
                print("Tempo channel unchanged for session \(request.sessionID.prefix(8))... (skipping RPC)")
            }
        }

        // Check session has an active payment channel
        guard channels[request.sessionID] != nil else {
            sendError(requestID: request.requestID, sessionID: request.sessionID,
                      code: .invalidSession, message: "Unknown session. Include channelInfo on first request.")
            return
        }

        // Check model is ready
        guard modelStatus == .ready else {
            sendError(requestID: request.requestID, sessionID: request.sessionID,
                      code: .providerBusy, message: "Model not ready: \(modelStatus.rawValue)")
            return
        }

        guard let channel = channels[request.sessionID] else { return }
        let channelIdHex = channel.channelId.map { String(format: "%02x", $0) }.joined()

        // Snapshot pricing at method entry. tokenRate and tabThresholdTokens are @Published vars
        // that the operator can change via the UI. Capturing locals here prevents a SwiftUI
        // .onChange event from mutating them mid-inference (during the await mlxRunner.generate yield).
        // tabThresholdTokens takes effect from the next request cycle, not retroactively.
        let tokenRate = self.tokenRate
        let tabThresholdTokens = self.tabThresholdTokens

        // 1. Check deposit sufficiency (must cover at least one full tab cycle above current authorized amount).
        // Use deposit - authorizedAmount, not remainingDeposit (deposit - settled), because
        // unsettled-but-authorized credits are already committed — vouchers can't exceed deposit.
        let maxSettlementCredits = (tabThresholdTokens * tokenRate + 999) / 1000
        guard channel.deposit - channel.authorizedAmount >= maxSettlementCredits else {
            sendError(requestID: request.requestID, sessionID: request.sessionID,
                      code: .insufficientCredits, message: "Channel deposit too small. Top up required.")
            return
        }

        // 2. Block + re-send settlement request if tab still at threshold
        //    (handles lost settlement message + post-restart recovery)
        let currentTab = tabByChannelId[channelIdHex] ?? 0
        if currentTab >= tabThresholdTokens {
            let tabCredits = max(1, (currentTab * tokenRate + 999) / 1000)
            let settleRequestID = pendingTabSettlementByChannelId[channelIdHex] ?? UUID().uuidString
            pendingTabSettlementByChannelId[channelIdHex] = settleRequestID
            sendSettlementRequest(tabCredits: tabCredits, requestID: settleRequestID,
                                  channel: channel, sessionID: request.sessionID)
            sendError(requestID: request.requestID, sessionID: request.sessionID,
                      code: .tabSettlementRequired, message: "Tab threshold reached. Settle balance to continue.")
            persistState()
            return
        }

        // 3. Run inference
        let inferenceResult: InferenceResult
        do {
            inferenceResult = try await mlxRunner.generate(
                prompt: request.promptText,
                taskType: request.taskType,
                maxOutputTokens: request.maxOutputTokens ?? 1024
            )
        } catch {
            sendError(requestID: request.requestID, sessionID: request.sessionID,
                      code: .inferenceFailed, message: "Inference failed: \(error)")
            return
        }

        // 4. Update tab (min 1 to prevent 0-credit monotonicity violation)
        // inferenceResult.outputTokenCount includes both input and output tokens.
        // Re-read tabByChannelId post-await to pick up any concurrent Task's write
        // (concurrent handlePromptRequest calls both yield at the mlxRunner.generate await).
        let tokensUsed = UInt64(max(1, inferenceResult.outputTokenCount))
        let newTab = (tabByChannelId[channelIdHex] ?? 0) + tokensUsed
        tabByChannelId[channelIdHex] = newTab

        // 5. Compute credits (ceiling division, min 1)
        let creditsCharged = Int(max(1, (tokensUsed * tokenRate + 999) / 1000))
        let cumulativeForReceipt = Int(channel.authorizedAmount) + creditsCharged

        // 6. Sign receipt + send response with embedded TabUpdate
        let receipt = signReceipt(
            sessionID: request.sessionID,
            requestID: request.requestID,
            creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeForReceipt
        )
        receiptsIssued.append(receipt)

        let response = InferenceResponse(
            requestID: request.requestID,
            outputText: inferenceResult.outputText,
            creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeForReceipt,
            receipt: receipt,
            tabUpdate: TabUpdate(
                tokensUsed: tokensUsed,
                cumulativeTabTokens: newTab,
                tabThreshold: tabThresholdTokens,
                tokenRate: tokenRate
            )
        )
        lastResponses[request.sessionID] = response
        send(type: .inferenceResponse, payload: response, toSession: request.sessionID)

        lastResponse = inferenceResult.outputText.prefix(100) + (inferenceResult.outputText.count > 100 ? "..." : "")
        totalRequestsServed += 1
        totalCreditsEarned += creditsCharged

        appendLog(LogEntry(
            timestamp: Date(),
            taskType: request.taskType.rawValue,
            promptPreview: String(request.promptText.prefix(60)),
            responsePreview: String(inferenceResult.outputText.prefix(80)),
            credits: creditsCharged,
            isError: false,
            sessionID: request.sessionID
        ))

        // 7. Check threshold — send settlement request if crossed
        if newTab >= tabThresholdTokens {
            let tabCredits = max(1, (newTab * tokenRate + 999) / 1000)
            let settleRequestID = UUID().uuidString
            pendingTabSettlementByChannelId[channelIdHex] = settleRequestID
            sendSettlementRequest(tabCredits: tabCredits, requestID: settleRequestID,
                                  channel: channel, sessionID: request.sessionID)
        }

        persistState()
    }

    private func sendSettlementRequest(tabCredits: UInt64, requestID: String, channel: Channel, sessionID: String) {
        let req = TabSettlementRequest(
            requestID: requestID,
            tabCredits: tabCredits,
            channelId: channel.channelId
        )
        send(type: .tabSettlementRequest, payload: req, toSession: sessionID)
        print("Tab settlement requested: \(tabCredits) credits, requestID=\(requestID.prefix(8))..., session=\(sessionID.prefix(8))...")
    }

    // MARK: - Tab settlement voucher

    private func handleTabSettlementVoucher(_ auth: VoucherAuthorization) async {
        guard let (sessionID, channelSnapshot) = channels.first(where: { $0.value.channelId == auth.channelId }) else {
            print("TabSettlementVoucher rejected: unknown channel \(auth.channelId.ethHexPrefixed.prefix(18))...")
            return
        }
        var channel = channelSnapshot
        let channelIdHex = channel.channelId.map { String(format: "%02x", $0) }.joined()

        // Replay prevention: requestID must match the outstanding settlement request
        guard let expectedRequestID = pendingTabSettlementByChannelId[channelIdHex],
              auth.requestID == expectedRequestID else {
            print("TabSettlementVoucher rejected: requestID mismatch for channel \(channelIdHex.prefix(18))...")
            return
        }

        guard let vv = voucherVerifier else { return }
        // Snapshot rate at method entry — must match the rate used when settlement was requested.
        let tokenRate = self.tokenRate
        let tabTokens = tabByChannelId[channelIdHex] ?? 0
        let tabCredits = max(1, (tabTokens * tokenRate + 999) / 1000)

        do {
            _ = try vv.verifyTabSettlement(authorization: auth, channel: channel, tabCredits: tabCredits)
            try channel.acceptVoucher(auth.signedVoucher)
            channels[sessionID] = channel
        } catch {
            print("Tab settlement rejected: \(error)")
            return
        }

        // Log settlement data
        print("TAB SETTLEMENT ACCEPTED — settlement data:")
        print("  channelId: \(auth.channelId.ethHexPrefixed)")
        print("  tabCredits: \(tabCredits), cumulativeAmount: \(auth.cumulativeAmount)")
        print("  signature: \(auth.signedVoucher.signatureBytes.ethHexPrefixed)")

        // Reset tab and clear pending settlement
        tabByChannelId[channelIdHex] = 0
        pendingTabSettlementByChannelId.removeValue(forKey: channelIdHex)
        persistState()

        // Check aggregate threshold for on-chain settlement
        let pending = pendingSettlementCredits
        if settlementThreshold > 0 && pending >= settlementThreshold {
            let breakdown = channels.filter { $0.value.unsettledAmount > 0 }
                .map { "\($0.key.prefix(8))...=\($0.value.unsettledAmount)" }
                .joined(separator: ", ")
            print("Threshold settlement triggered: \(pending) >= \(settlementThreshold) [\(breakdown)]")
            Task { await settleAllChannelsOnChain(isRetry: true, removeAfterSettlement: false) }
        }
    }

    // MARK: - Helpers

    private func signReceipt(
        sessionID: String, requestID: String,
        creditsCharged: Int, cumulativeSpend: Int
    ) -> Receipt {
        let receipt = Receipt(
            sessionID: sessionID,
            requestID: requestID,
            providerID: providerID,
            creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeSpend,
            providerSignature: "" // placeholder
        )
        let signer = JanusSigner(keyPair: providerKeyPair)
        let sig = (try? signer.sign(fields: receipt.signableFields)) ?? ""
        return Receipt(
            receiptID: receipt.receiptID,
            sessionID: sessionID,
            requestID: requestID,
            providerID: providerID,
            creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeSpend,
            timestamp: receipt.timestamp,
            providerSignature: sig
        )
    }

    private func send<T: Encodable>(type: MessageType, payload: T, toSession sessionID: String) {
        guard let envelope = try? MessageEnvelope.wrap(
            type: type, senderID: providerID, payload: payload
        ) else { return }
        let targetSender = sessionToSender[sessionID] ?? sessionID
        sendMessage?(envelope, targetSender)
    }

    private func sendError(requestID: String, sessionID: String, code: ErrorResponse.ErrorCode, message: String) {
        let error = ErrorResponse(requestID: requestID, errorCode: code, errorMessage: message)
        send(type: .errorResponse, payload: error, toSession: sessionID)
        appendLog(LogEntry(
            timestamp: Date(),
            taskType: "error",
            promptPreview: "[\(code.rawValue)] \(message)",
            responsePreview: nil,
            credits: nil,
            isError: true,
            sessionID: sessionID
        ))
    }

    private func appendLog(_ entry: LogEntry) {
        requestLog.insert(entry, at: 0)
        if requestLog.count > 50 {
            requestLog.removeLast()
        }
        persistState()
    }

    // MARK: - Service update broadcast

    /// Push updated pricing to all currently-connected clients.
    /// Called by ProviderStatusView.persistAndBroadcast() when the operator changes a picker.
    /// Only reaches sessions that have sent at least one request (sessionToSender populated).
    /// Clients that reconnect later pick up the new rate from ServiceAnnounce.
    func broadcastServiceUpdate() {
        let update = ServiceUpdate(tokenRate: tokenRate, tabThresholdTokens: tabThresholdTokens)
        for sessionID in sessionToSender.keys {
            send(type: .serviceUpdate, payload: update, toSession: sessionID)
        }
    }

    // MARK: - Persistence

    // Receipts issued (for future settlement)
    private var receiptsIssued: [Receipt] = []

    func persistState() {
        let logEntries = requestLog.map { entry in
            PersistedLogEntry(id: entry.id, timestamp: entry.timestamp, taskType: entry.taskType,
                              promptPreview: entry.promptPreview, responsePreview: entry.responsePreview,
                              credits: entry.credits, isError: entry.isError, sessionID: entry.sessionID)
        }
        let unsettled = channels.filter { $0.value.latestVoucher != nil && $0.value.unsettledAmount > 0 }

        // Upsert settledAmount for all in-memory channels. Covers the periodic/threshold settlement
        // path where removeAfterSettlement=false — channels stay in memory after settlement with
        // unsettledAmount=0, are excluded from unsettled filter above, but their settled baseline
        // must survive a restart for RPC-unavailable reconnects.
        for (_, channel) in channels where channel.settledAmount > 0 {
            let key = channel.channelId.ethHexPrefixed
            settledChannelAmounts[key] = max(settledChannelAmounts[key] ?? 0, channel.settledAmount)
        }
        // Cap at 500 entries — far more than needed in practice. Random eviction if exceeded.
        while settledChannelAmounts.count > 500 {
            if let randomKey = settledChannelAmounts.keys.randomElement() {
                settledChannelAmounts.removeValue(forKey: randomKey)
            }
        }
        // Only persist identity mappings for unsettled sessions — those are the only channels restored on restart.
        // Non-unsettled identity mappings are re-established when clients reconnect and send a PromptRequest.
        let unsettledIdentities = sessionToIdentity.filter { unsettled[$0.key] != nil }
        let state = PersistedProviderState(
            providerID: providerID,
            privateKeyBase64: providerKeyPair.privateKeyBase64,
            receiptsIssued: receiptsIssued,
            totalRequestsServed: totalRequestsServed,
            totalCreditsEarned: totalCreditsEarned,
            requestLog: logEntries,
            ethPrivateKeyHex: providerEthKeyPair?.privateKeyData.ethHexPrefixed,
            unsettledChannels: unsettled.isEmpty ? nil : unsettled,
            sessionToIdentity: unsettledIdentities.isEmpty ? nil : unsettledIdentities,
            settlementIntervalSeconds: settlementIntervalSeconds,
            settlementThreshold: settlementThreshold,
            settledChannelAmounts: settledChannelAmounts.isEmpty ? nil : settledChannelAmounts,
            tabByChannelId: tabByChannelId.isEmpty ? nil : tabByChannelId,
            pendingTabSettlementByChannelId: pendingTabSettlementByChannelId.isEmpty ? nil : pendingTabSettlementByChannelId,
            tokenRate: tokenRate,
            tabThresholdTokens: tabThresholdTokens
        )
        do {
            try store.save(state, as: Self.filename)
            print("Provider state persisted: \(channels.count) channels (\(unsettled.count) unsettled), \(totalRequestsServed) served")
        } catch {
            print("Failed to persist provider state: \(error)")
        }
    }
}
