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
/// Handles: PromptRequest → QuoteResponse → VoucherAuthorization → inference → InferenceResponse.
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
    @Published var activeSessionCount: Int = 0
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

        for (sessionID, senderID) in sessionToSender {
            // Use stable identity if available, fall back to senderID
            let identity = sessionToIdentity[sessionID] ?? senderID
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
            senderIDSets[identity, default: []].insert(senderID)
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

    // Pending quotes: quoteID → QuoteResponse (transient — not persisted)
    private var pendingQuotes: [String: QuoteResponse] = [:]
    // Last response per session — for SessionSync recovery if client missed it
    private var lastResponses: [String: InferenceResponse] = [:]

    // Tempo voucher path
    private var channels: [String: Channel] = [:] {         // sessionID → Channel
        didSet { objectWillChange.send() }
    }
    private var voucherVerifier: VoucherVerifier?
    private let tempoConfig = TempoConfig.testnet
    /// Provider's Ethereum keypair (for Tempo address identity).
    private(set) var providerEthKeyPair: EthKeyPair?
    @Published private(set) var isSettling = false
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
                self.activeSessionCount = unsettled.count
                print("Restored \(unsettled.count) unsettled channel(s) from previous session")
            }
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

    /// Retry settlement for any persisted unsettled channels (called on startup and network restore).
    func retryPendingSettlements() async {
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
    }

    /// Settle all Tempo channels on-chain that have unsettled vouchers.
    /// - Parameter isRetry: true when retrying persisted channels from a previous session (skips faucet/wait).
    private func settleAllChannelsOnChain(isRetry: Bool = false) async {
        // Concurrent settlement guard — isSettling is safe as plain Bool because @MainActor serializes access
        guard !isSettling else { print("Settlement already in progress, skipping"); return }
        isSettling = true
        defer { isSettling = false }

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
                removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId, onlyIfSettled: true)
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
                removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId)
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
                    removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId, onlyIfSettled: true)
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
                    if case .alreadySettled = result {
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

    /// Remove a channel only if its channelId still matches (guards against a reconnected client replacing the channel).
    /// Also prunes sessionToIdentity (UI grouping). Does NOT prune sessionToSender — it's needed for send() routing.
    private func removeChannelIfMatch(sessionID: String, expectedChannelId: Data, onlyIfSettled: Bool = false) {
        guard channels[sessionID]?.channelId == expectedChannelId else { return }
        if onlyIfSettled {
            guard channels[sessionID]?.unsettledAmount == 0 else { return }
        }
        channels.removeValue(forKey: sessionID)
        sessionToIdentity.removeValue(forKey: sessionID)
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
            Task { await handleVoucherAuthorization(auth) }
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

        // Cache the request for later lookup during VoucherAuthorization
        cacheRequest(request)

        // If channel info included, verify and cache
        if let info = request.channelInfo, let vv = voucherVerifier {
            let result = await vv.verifyChannelInfoOnChain(info)
            guard result.isAccepted else {
                if case .rejected(let reason) = result {
                    sendError(requestID: request.requestID, sessionID: request.sessionID,
                              code: .invalidSession, message: "Channel rejected: \(reason)")
                }
                return
            }

            // Detect missed response: compare client's reported spend with our last
            // response. If the client's spend is behind, they missed the response and
            // need SessionSync to recover. If equal, they got it (idle reconnect).
            let existingChannel = channels[request.sessionID]
            if existingChannel != nil, let missed = lastResponses[request.sessionID],
               info.clientCumulativeSpend < missed.cumulativeSpend {
                let sync = SessionSync(sessionID: request.sessionID, missedResponse: missed)
                send(type: .sessionSync, payload: sync, toSession: request.sessionID)
                print("SessionSync: client spend=\(info.clientCumulativeSpend) < provider=\(missed.cumulativeSpend), recovering session \(request.sessionID.prefix(8))...")
            }

            // Only replace channel if it's new or has different params (e.g., new keypair).
            // Preserving the existing channel keeps voucher history (authorizedAmount).
            if existingChannel?.channelId != info.channelId {
                let channel = Channel(
                    payer: info.payerAddress, payee: info.payeeAddress,
                    token: info.tokenAddress, salt: info.salt,
                    authorizedSigner: info.authorizedSigner,
                    deposit: info.deposit, config: tempoConfig
                )
                let isUpdate = existingChannel != nil
                channels[request.sessionID] = channel
                activeSessionCount = channels.count
                let verifyStatus: String
                switch result {
                case .acceptedOnChain(let deposit): verifyStatus = "on-chain verified (deposit=\(deposit))"
                case .acceptedOffChainOnly: verifyStatus = "off-chain only"
                case .rejected: verifyStatus = "rejected"
                }
                print("Tempo channel \(isUpdate ? "updated" : "cached") for session \(request.sessionID.prefix(8))...: \(verifyStatus)")
                os_log("CLIENT_CHANNEL_PAYER=%{public}@", log: smokeLog, type: .default, info.payerAddress.checksumAddress)
                os_log("CLIENT_CHANNEL_ID=%{public}@", log: smokeLog, type: .default, info.channelId.ethHexPrefixed)
                os_log("CLIENT_CHANNEL_DEPOSIT=%{public}d", log: smokeLog, type: .default, info.deposit)
            } else if existingChannel != nil {
                print("Tempo channel unchanged for session \(request.sessionID.prefix(8))... (same channelId)")
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

        // Classify pricing tier and generate quote
        let tier = PricingTier.classify(promptLength: request.promptText.count)
        let quote = QuoteResponse(
            requestID: request.requestID,
            priceCredits: tier.credits,
            priceTier: tier.rawValue,
            expiresAt: Date().addingTimeInterval(60)
        )

        // Cache the quote and clean up expired ones
        pendingQuotes[quote.quoteID] = quote
        cleanupExpiredQuotes()

        // Send quote to client
        send(type: .quoteResponse, payload: quote, toSession: request.sessionID)
    }

    // MARK: - Voucher authorization

    private func handleVoucherAuthorization(_ auth: VoucherAuthorization) async {
        // Find the channel by matching the voucher's channelId to a known session
        guard let (sessionID, channel) = channels.first(where: { $0.value.channelId == auth.channelId }) else {
            // Try to find a session to route the error back
            // The requestID from a pending quote can help us find the session
            if let quote = pendingQuotes[auth.quoteID],
               let cachedRequest = requestCache[quote.requestID] {
                sendError(requestID: auth.requestID, sessionID: cachedRequest.sessionID,
                          code: .invalidSession, message: "Unknown payment channel — reconnect and retry")
            }
            print("VoucherAuth rejected: unknown channel \(auth.channelId.ethHexPrefixed.prefix(18))...")
            return
        }
        guard let vv = voucherVerifier else {
            sendError(requestID: auth.requestID, sessionID: sessionID,
                      code: .invalidSession, message: "Voucher verification not available")
            return
        }
        guard let quote = pendingQuotes[auth.quoteID] else {
            sendError(requestID: auth.requestID, sessionID: sessionID,
                      code: .expiredQuote, message: "Quote not found or expired")
            return
        }

        // Verify the voucher
        let accepted: VoucherVerifier.Accepted
        do {
            accepted = try vv.verify(authorization: auth, channel: channel, quote: quote)
        } catch let error as VoucherVerificationError {
            sendError(requestID: auth.requestID, sessionID: sessionID,
                      code: error.errorCode, message: "\(error)")
            return
        } catch {
            sendError(requestID: auth.requestID, sessionID: sessionID,
                      code: .invalidSignature, message: "Voucher verification failed: \(error)")
            return
        }

        // Accept voucher into channel state
        do {
            try channels[sessionID]?.acceptVoucher(auth.signedVoucher)
            persistState()  // Critical: persist immediately — this voucher is real money owed
        } catch {
            sendError(requestID: auth.requestID, sessionID: sessionID,
                      code: .invalidSignature, message: "Channel rejected voucher: \(error)")
            return
        }

        // Log settlement data (needed for manual on-chain settlement via cast)
        print("VOUCHER ACCEPTED — settlement data:")
        print("  channelId: \(auth.channelId.ethHexPrefixed)")
        print("  cumulativeAmount: \(auth.cumulativeAmount)")
        print("  signature: \(auth.signedVoucher.signatureBytes.ethHexPrefixed)")

        // Remove used quote
        pendingQuotes.removeValue(forKey: auth.quoteID)

        // Run inference
        let outputText: String
        do {
            let tier = PricingTier(rawValue: quote.priceTier) ?? .medium
            let taskType = cachedTaskType(for: auth.requestID) ?? .summarize
            outputText = try await mlxRunner.generate(
                prompt: cachedPrompt(for: auth.requestID) ?? "",
                taskType: taskType,
                maxOutputTokens: tier.maxOutputTokens
            )
        } catch {
            sendError(requestID: auth.requestID, sessionID: sessionID,
                      code: .inferenceFailed, message: "Inference failed: \(error)")
            return
        }

        // Create signed receipt (Ed25519 provider signature for non-repudiation)
        let receipt = signReceipt(
            sessionID: sessionID,
            requestID: auth.requestID,
            creditsCharged: accepted.creditsCharged,
            cumulativeSpend: Int(accepted.newCumulativeAmount)
        )
        receiptsIssued.append(receipt)

        // Send response
        let response = InferenceResponse(
            requestID: auth.requestID,
            outputText: outputText,
            creditsCharged: accepted.creditsCharged,
            cumulativeSpend: Int(accepted.newCumulativeAmount),
            receipt: receipt
        )
        lastResponses[sessionID] = response
        send(type: .inferenceResponse, payload: response, toSession: sessionID)

        lastResponse = outputText.prefix(100) + (outputText.count > 100 ? "..." : "")
        totalRequestsServed += 1
        totalCreditsEarned += accepted.creditsCharged

        let taskType = cachedTaskType(for: auth.requestID) ?? .summarize
        appendLog(LogEntry(
            timestamp: Date(),
            taskType: taskType.rawValue,
            promptPreview: String((cachedPrompt(for: auth.requestID) ?? "").prefix(60)),
            responsePreview: String(outputText.prefix(80)),
            credits: accepted.creditsCharged,
            isError: false,
            sessionID: sessionID
        ))

        requestCache.removeValue(forKey: auth.requestID)
    }

    // MARK: - Request context cache

    // Cache prompt requests so we can look up task type and prompt text
    // when the VoucherAuthorization arrives
    private var requestCache: [String: PromptRequest] = [:]

    func cacheRequest(_ request: PromptRequest) {
        requestCache[request.requestID] = request
    }

    private func cachedTaskType(for requestID: String) -> TaskType? {
        requestCache[requestID]?.taskType
    }

    private func cachedPrompt(for requestID: String) -> String? {
        requestCache[requestID]?.promptText
    }

    // MARK: - Cleanup

    private func cleanupExpiredQuotes() {
        let now = Date()
        pendingQuotes = pendingQuotes.filter { $0.value.expiresAt > now }
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

    // MARK: - Persistence

    // Receipts issued (for future settlement)
    private var receiptsIssued: [Receipt] = []

    private func persistState() {
        let logEntries = requestLog.map { entry in
            PersistedLogEntry(id: entry.id, timestamp: entry.timestamp, taskType: entry.taskType,
                              promptPreview: entry.promptPreview, responsePreview: entry.responsePreview,
                              credits: entry.credits, isError: entry.isError, sessionID: entry.sessionID)
        }
        let unsettled = channels.filter { $0.value.latestVoucher != nil && $0.value.unsettledAmount > 0 }
        let state = PersistedProviderState(
            providerID: providerID,
            privateKeyBase64: providerKeyPair.privateKeyBase64,
            receiptsIssued: receiptsIssued,
            totalRequestsServed: totalRequestsServed,
            totalCreditsEarned: totalCreditsEarned,
            requestLog: logEntries,
            ethPrivateKeyHex: providerEthKeyPair?.privateKeyData.ethHexPrefixed,
            unsettledChannels: unsettled.isEmpty ? nil : unsettled
        )
        do {
            try store.save(state, as: Self.filename)
            print("Provider state persisted: \(channels.count) channels (\(unsettled.count) unsettled), \(totalRequestsServed) served")
        } catch {
            print("Failed to persist provider state: \(error)")
        }
    }
}
