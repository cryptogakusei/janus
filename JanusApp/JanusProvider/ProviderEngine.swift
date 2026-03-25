import Foundation
import JanusShared
import MLXLMCommon
import MLXLLM
import os.log

private let smokeLog = OSLog(subsystem: "com.janus.provider", category: "SmokeTest")

/// Orchestrates the provider's full request pipeline.
///
/// Handles: PromptRequest → QuoteResponse → SpendAuthorization → inference → InferenceResponse.
/// Owns the MLX model, spend verifier, session cache, and provider keypair.
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
        let id: String  // senderID
        var sessionIDs: [String]
        var totalCreditsUsed: Int
        var maxCredits: Int
        var requestCount: Int
        var errorCount: Int
        var lastActive: Date?
        var logs: [LogEntry]
    }

    /// Computes per-client summaries by grouping sessions by senderID.
    var clientSummaries: [ClientSummary] {
        var summaries: [String: ClientSummary] = [:]

        for (sessionID, senderID) in sessionToSender {
            let grant = knownSessions[sessionID]
            let spend = spendLedger[sessionID]

            var summary = summaries[senderID] ?? ClientSummary(
                id: senderID,
                sessionIDs: [],
                totalCreditsUsed: 0,
                maxCredits: 0,
                requestCount: 0,
                errorCount: 0,
                lastActive: nil,
                logs: []
            )
            summary.sessionIDs.append(sessionID)
            summary.totalCreditsUsed += spend?.cumulativeSpend ?? 0
            summary.maxCredits += grant?.maxCredits ?? 0

            let sessionLogs = requestLog.filter { $0.sessionID == sessionID }
            summary.requestCount += sessionLogs.filter { !$0.isError && $0.taskType != "settlement" }.count
            summary.errorCount += sessionLogs.filter { $0.isError }.count
            summary.logs.append(contentsOf: sessionLogs)
            if let latest = sessionLogs.first?.timestamp {
                if summary.lastActive == nil || latest > summary.lastActive! {
                    summary.lastActive = latest
                }
            }
            summaries[senderID] = summary
        }

        // Sort logs within each summary (newest first) and return sorted by last active
        return summaries.values
            .map { var s = $0; s.logs.sort { $0.timestamp > $1.timestamp }; return s }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    let providerID: String
    let providerKeyPair: JanusKeyPair
    private let mlxRunner: MLXRunner
    private let spendVerifier: SpendVerifier
    private let store: JanusStore

    // Session cache: sessionID → SessionGrant
    private var knownSessions: [String: SessionGrant] = [:]
    // Spend ledger: sessionID → SpendState
    private var spendLedger: [String: SpendState] = [:]
    // Pending quotes: quoteID → QuoteResponse (transient — not persisted)
    private var pendingQuotes: [String: QuoteResponse] = [:]
    // Last response per session — for SessionSync recovery if client missed it
    private var lastResponses: [String: InferenceResponse] = [:]

    // Tempo voucher path
    private var channels: [String: Channel] = [:]           // sessionID → Channel
    private var voucherVerifier: VoucherVerifier?
    private let tempoConfig = TempoConfig.testnet
    /// Provider's Ethereum keypair (for Tempo address identity).
    private(set) var providerEthKeyPair: EthKeyPair?

    /// Callback to send messages back to a specific client via MPC.
    /// The String parameter is the sender/session ID for routing.
    var sendMessage: ((MessageEnvelope, String) -> Void)?

    // Maps sessionID → senderID for routing replies to the correct client
    private var sessionToSender: [String: String] = [:]

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
            self.knownSessions = persisted.knownSessions
            self.spendLedger = persisted.spendLedger
            self.totalRequestsServed = persisted.totalRequestsServed
            self.totalCreditsEarned = persisted.totalCreditsEarned
            self.activeSessionCount = persisted.knownSessions.count
            self.requestLog = persisted.requestLog.map { entry in
                LogEntry(timestamp: entry.timestamp, taskType: entry.taskType,
                         promptPreview: entry.promptPreview, responsePreview: entry.responsePreview,
                         credits: entry.credits, isError: entry.isError, sessionID: entry.sessionID)
            }
            self.settledSpends = persisted.settledSpends
            print("Restored provider state: \(persisted.knownSessions.count) sessions, \(persisted.totalRequestsServed) served, \(persisted.settledSpends.count) settled")
        } else {
            self.providerID = providerID
            self.providerKeyPair = JanusKeyPair()
        }

        self.spendVerifier = try! SpendVerifier(
            providerID: providerID,
            backendPublicKeyBase64: DemoConfig.backendPublicKeyBase64
        )

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
    }

    /// Provider's public key base64 for ServiceAnnounce.
    var providerPubkeyBase64: String {
        providerKeyPair.publicKeyBase64
    }

    @Published var backendRegistered = false

    /// Register this provider's identity with the backend.
    func registerWithBackend() async {
        let backend: SessionBackend = HTTPSessionBackend()
        do {
            let response = try await backend.registerProvider(
                providerID: providerID,
                publicKeyBase64: providerKeyPair.publicKeyBase64
            )
            backendRegistered = response.registered
            print("Registered with backend: \(providerID)")
        } catch {
            print("Backend registration failed (will retry on next launch): \(error.localizedDescription)")
        }
    }

    /// Settle a session with the backend, submitting all receipts.
    /// Returns true if the backend confirmed settlement.
    @discardableResult
    func settleSession(_ sessionID: String) async -> Bool {
        guard let _ = knownSessions[sessionID],
              let spend = spendLedger[sessionID] else { return false }

        let sessionReceipts = receiptsIssued.filter { $0.sessionID == sessionID }
        let backend: SessionBackend = HTTPSessionBackend()
        do {
            let response = try await backend.settleSession(
                sessionID: sessionID,
                providerID: providerID,
                cumulativeSpend: spend.cumulativeSpend,
                receipts: sessionReceipts
            )
            if response.settled {
                print("Session \(sessionID.prefix(8))... settled with backend: \(response.settledSpend) credits")
                appendLog(LogEntry(
                    timestamp: Date(), taskType: "settlement",
                    promptPreview: "Settled \(response.settledSpend) credits",
                    responsePreview: nil, credits: response.settledSpend, isError: false,
                    sessionID: sessionID
                ))
                return true
            }
            return false
        } catch {
            print("Settlement failed for \(sessionID.prefix(8))...: \(error.localizedDescription)")
            appendLog(LogEntry(
                timestamp: Date(), taskType: "settlement",
                promptPreview: "Settlement failed: \(error.localizedDescription)",
                responsePreview: nil, credits: nil, isError: true,
                sessionID: sessionID
            ))
            return false
        }
    }

    /// Settle all sessions that have unsettled spend.
    /// Called when a client disconnects. Handles both paths:
    /// - Ed25519 sessions → settle with Janus backend
    /// - Tempo channels → settle on-chain via escrow contract
    func settleAllSessions() async {
        // Ed25519 path: settle with backend
        for (sessionID, spend) in spendLedger where spend.cumulativeSpend > 0 {
            let lastSettled = settledSpends[sessionID] ?? 0
            if spend.cumulativeSpend <= lastSettled { continue }
            let success = await settleSession(sessionID)
            if success {
                settledSpends[sessionID] = spend.cumulativeSpend
                persistState()
            }
        }

        // Tempo path: settle on-chain
        await settleAllChannelsOnChain()
    }

    /// Settle all Tempo channels on-chain that have unsettled vouchers.
    private func settleAllChannelsOnChain() async {
        guard let ethKP = providerEthKeyPair, tempoConfig.rpcURL != nil else { return }
        let settler = ChannelSettler(config: tempoConfig)

        for (sessionID, channel) in channels {
            guard channel.latestVoucher != nil else { continue }

            let result = await settler.settle(providerKeyPair: ethKP, channel: channel)
            switch result {
            case .settled(let txHash, let amount):
                channels[sessionID]?.recordSettlement(amount: amount)
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
                break // nothing to settle
            case .alreadySettled:
                print("Channel \(sessionID.prefix(8))... already settled on-chain")
            case .failed(let reason):
                print("On-chain settlement failed for \(sessionID.prefix(8))...: \(reason)")
                os_log("SETTLEMENT_FAILED=%{public}@", log: smokeLog, type: .default, reason)
                appendLog(LogEntry(
                    timestamp: Date(), taskType: "on-chain-settlement",
                    promptPreview: "On-chain settlement failed: \(reason)",
                    responsePreview: nil, credits: nil, isError: true, sessionID: sessionID
                ))
            }
        }
    }

    // Maps sessionID → last settled cumulative spend
    private var settledSpends: [String: Int] = [:]

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
        case .spendAuthorization:
            guard let auth = try? envelope.unwrap(as: SpendAuthorization.self) else { return }
            Task { await handleSpendAuthorization(auth) }
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

        // Cache the request for later lookup during SpendAuthorization
        cacheRequest(request)

        // If session grant included (Ed25519 path), verify and cache
        if let grant = request.sessionGrant {
            guard spendVerifier.verifyGrant(grant) else {
                sendError(requestID: request.requestID, sessionID: request.sessionID,
                          code: .invalidSession, message: "Invalid session grant signature")
                return
            }
            knownSessions[grant.sessionID] = grant
            if spendLedger[grant.sessionID] == nil {
                spendLedger[grant.sessionID] = SpendState(sessionID: grant.sessionID)
                activeSessionCount = knownSessions.count
                persistState()
            }
        }

        // If channel info included (Tempo voucher path), verify and cache
        if let info = request.channelInfo, let vv = voucherVerifier {
            let result = await vv.verifyChannelInfoOnChain(info)
            guard result.isAccepted else {
                if case .rejected(let reason) = result {
                    sendError(requestID: request.requestID, sessionID: request.sessionID,
                              code: .invalidSession, message: "Channel rejected: \(reason)")
                }
                return
            }
            // Always update channel — client may reconnect with a new keypair
            let channel = Channel(
                payer: info.payerAddress, payee: info.payeeAddress,
                token: info.tokenAddress, salt: info.salt,
                authorizedSigner: info.authorizedSigner,
                deposit: info.deposit, config: tempoConfig
            )
            let isUpdate = channels[request.sessionID] != nil
            channels[request.sessionID] = channel
            activeSessionCount = knownSessions.count + channels.count
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
        }

        // Check session exists (either Ed25519 grant or Tempo channel)
        guard knownSessions[request.sessionID] != nil || channels[request.sessionID] != nil else {
            sendError(requestID: request.requestID, sessionID: request.sessionID,
                      code: .invalidSession, message: "Unknown session. Include sessionGrant or channelInfo on first request.")
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

    private func handleSpendAuthorization(_ auth: SpendAuthorization) async {
        // Look up grant and spend state
        guard let grant = knownSessions[auth.sessionID] else {
            sendError(requestID: auth.requestID, sessionID: auth.sessionID,
                      code: .invalidSession, message: "Unknown session")
            return
        }
        guard let spendState = spendLedger[auth.sessionID] else {
            sendError(requestID: auth.requestID, sessionID: auth.sessionID,
                      code: .invalidSession, message: "No spend state for session")
            return
        }
        guard let quote = pendingQuotes[auth.quoteID] else {
            sendError(requestID: auth.requestID, sessionID: auth.sessionID,
                      code: .expiredQuote, message: "Quote not found or expired")
            return
        }

        // Run 9-step verification
        let accepted: SpendVerifier.Accepted
        do {
            accepted = try spendVerifier.verify(
                authorization: auth, grant: grant,
                spendState: spendState, quote: quote
            )
        } catch VerificationError.sequenceMismatch {
            // Client is behind — they missed our last response.
            // Send SessionSync with the missed response so they can recover.
            if let missed = lastResponses[auth.sessionID] {
                let sync = SessionSync(sessionID: auth.sessionID, missedResponse: missed)
                send(type: .sessionSync, payload: sync, toSession: auth.sessionID)
                print("Sent SessionSync for \(auth.sessionID.prefix(8))... (client behind)")
            } else {
                sendError(requestID: auth.requestID, sessionID: auth.sessionID,
                          code: .sequenceMismatch, message: "Sequence mismatch and no recovery data available")
            }
            return
        } catch let error as VerificationError {
            sendError(requestID: auth.requestID, sessionID: auth.sessionID,
                      code: error.errorCode, message: "\(error)")
            return
        } catch {
            sendError(requestID: auth.requestID, sessionID: auth.sessionID,
                      code: .invalidSignature, message: "Verification failed: \(error)")
            return
        }

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
            sendError(requestID: auth.requestID, sessionID: auth.sessionID,
                      code: .inferenceFailed, message: "Inference failed: \(error)")
            return
        }

        // Update spend state
        spendLedger[auth.sessionID]?.advance(creditsCharged: accepted.creditsCharged)
        persistState()

        // Create signed receipt
        let receipt = signReceipt(
            sessionID: auth.sessionID,
            requestID: auth.requestID,
            creditsCharged: accepted.creditsCharged,
            cumulativeSpend: accepted.newCumulativeSpend
        )

        // Store receipt for future settlement
        receiptsIssued.append(receipt)

        // Send response
        let response = InferenceResponse(
            requestID: auth.requestID,
            outputText: outputText,
            creditsCharged: accepted.creditsCharged,
            cumulativeSpend: accepted.newCumulativeSpend,
            receipt: receipt
        )
        // Store for SessionSync recovery, then send
        lastResponses[auth.sessionID] = response
        send(type: .inferenceResponse, payload: response, toSession: auth.sessionID)

        lastResponse = outputText.prefix(100) + (outputText.count > 100 ? "..." : "")
        totalRequestsServed += 1
        totalCreditsEarned += accepted.creditsCharged

        // Log entry
        let taskType = cachedTaskType(for: auth.requestID) ?? .summarize
        appendLog(LogEntry(
            timestamp: Date(),
            taskType: taskType.rawValue,
            promptPreview: String((cachedPrompt(for: auth.requestID) ?? "").prefix(60)),
            responsePreview: String(outputText.prefix(80)),
            credits: accepted.creditsCharged,
            isError: false,
            sessionID: auth.sessionID
        ))

        // Clean up request cache
        requestCache.removeValue(forKey: auth.requestID)
    }

    // MARK: - Tempo voucher authorization

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

        // Create signed receipt (still using Ed25519 provider signature for receipts)
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
    // when the SpendAuthorization arrives
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
        let state = PersistedProviderState(
            providerID: providerID,
            privateKeyBase64: providerKeyPair.privateKeyBase64,
            knownSessions: knownSessions,
            spendLedger: spendLedger,
            receiptsIssued: receiptsIssued,
            totalRequestsServed: totalRequestsServed,
            totalCreditsEarned: totalCreditsEarned,
            requestLog: logEntries,
            settledSpends: settledSpends,
            ethPrivateKeyHex: providerEthKeyPair?.privateKeyData.ethHexPrefixed
        )
        do {
            try store.save(state, as: Self.filename)
            print("Provider state persisted: \(knownSessions.count) sessions, \(totalRequestsServed) served")
        } catch {
            print("Failed to persist provider state: \(error)")
        }
    }
}
