import Foundation
import Combine
import JanusShared

/// Orchestrates the client's request flow over MPC.
///
/// State machine: idle → waitingForResponse → complete/error
/// Tab model: idle → awaitingSettlement (auto-signs voucher) → idle → waitingForResponse
/// Owns the transport and SessionManager, and drives the UI.
///
/// Forwards transport's published properties so SwiftUI views can observe
/// connection state changes through this single object.
@MainActor
class ClientEngine: ObservableObject {

    // Forwarded transport state (so SwiftUI can observe)
    @Published var isSearching = false
    @Published var connectionStatus = "Disconnected"
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectedProvider: ServiceAnnounce?
    @Published var connectionMode: ConnectionMode = .disconnected
    @Published var sessionReady = false
    /// On-chain channel opening progress (e.g. "Funding wallet...", "Approving token...").
    @Published var channelStatus: String = ""
    /// All providers available via relay (empty when direct-connected or only one provider).
    @Published var availableProviders: [ServiceAnnounce] = []

    // Request flow state
    @Published var requestState: RequestState = .idle
    @Published var pendingSettlement: TabSettlementRequest?
    @Published var lastResult: InferenceResponse?
    @Published var errorMessage: String?

    // Response history (newest first) — backed by SessionManager persistence
    @Published var responseHistory: [HistoryEntry] = []

    // Settlement verification
    @Published var settlementStatus: SettlementStatus = .unverified

    // Disconnect detection
    @Published var disconnectedDuringRequest = false
    /// Set when provider pushes a ServiceUpdate mid-session. Cleared on disconnect or user dismiss.
    @Published var rateChangeNotice: String? = nil

    enum RequestState: String {
        case idle = "Ready"
        case waitingForResponse = "Processing..."
        case awaitingSettlement = "Settling tab..."
        case complete = "Done"
        case error = "Error"
    }

    let transport: any ProviderTransport
    /// Typed reference for composite transport features (Bonjour + MPC).
    /// Nil when transport is RelayLocalTransport (dual mode).
    let compositeRef: CompositeTransport?
    private(set) var sessionManager: SessionManager?
    private var cancellables = Set<AnyCancellable>()

    /// Monitors network interfaces and vends the URLSession for blockchain RPC calls.
    /// Inference traffic is unaffected — it stays on the transport (WiFi/mesh/BT).
    let connectivityManager = PaymentConnectivityManager()
    var pendingRequestID: String?
    var pendingTaskType: TaskType?
    var pendingPromptText: String?
    private var requestTimeoutTask: Task<Void, Never>?
    private var sessionCreationGeneration = 0
    /// Tracks the providerID of the last session we created, so we don't re-create on pricing re-announces.
    private var currentConnectedProviderID: String?

    convenience init() {
        self.init(transport: CompositeTransport())
    }

    init(transport: any ProviderTransport) {
        self.transport = transport
        self.compositeRef = transport as? CompositeTransport

        // Forward transport published properties to trigger SwiftUI updates
        transport.isSearchingPublisher
            .assign(to: &$isSearching)
        transport.connectionStatePublisher
            .assign(to: &$connectionState)
        transport.connectionStatePublisher
            .map { $0.rawValue.capitalized }
            .assign(to: &$connectionStatus)
        transport.connectedProviderPublisher
            .sink { [weak self] provider in
                self?.connectedProvider = provider
                self?.connectionMode = self?.transport.connectionMode ?? .disconnected
                if let provider {
                    // Only create/restore a session when the provider actually changes.
                    // Pricing re-announcements from the same provider update connectedProvider
                    // (so DiscoveryView refreshes) but must NOT disrupt an active session.
                    if self?.currentConnectedProviderID != provider.providerID {
                        self?.currentConnectedProviderID = provider.providerID
                        self?.createSession(providerID: provider.providerID)
                    }
                } else {
                    self?.currentConnectedProviderID = nil
                    // Detect disconnect during active request
                    if let self, self.requestState == .waitingForResponse || self.requestState == .awaitingSettlement {
                        self.cancelRequestTimeout()
                        self.disconnectedDuringRequest = true
                        self.errorMessage = "Provider disconnected during request"
                        self.requestState = .error
                        self.pendingRequestID = nil
                    }
                    // Don't nil sessionManager — it's persisted and can be reused on reconnect
                    self?.sessionReady = false
                    self?.channelStatus = ""
                    self?.connectionMode = .disconnected
                    self?.rateChangeNotice = nil
                }
            }
            .store(in: &cancellables)

        // Forward available providers from transport
        if let composite = compositeRef {
            // Merge relay providers (MPC path) + direct providers (Bonjour path)
            composite.mpcBrowser.$relayProviders
                .combineLatest(composite.bonjourBrowser.$directProviders)
                .map { relayProviders, bonjourProviders in
                    // Merge both, dedup by providerID (Bonjour wins)
                    var merged = relayProviders
                    for (id, announce) in bonjourProviders {
                        merged[id] = announce
                    }
                    return Array(merged.values)
                }
                .assign(to: &$availableProviders)
        } else if let browser = transport as? MPCBrowser {
            // Standalone MPCBrowser (tests or legacy usage)
            browser.$relayProviders
                .map { Array($0.values) }
                .assign(to: &$availableProviders)
        } else if let localTransport = transport as? RelayLocalTransport {
            localTransport.$relayProviders
                .map { Array($0.values) }
                .assign(to: &$availableProviders)
        }

        transport.onMessageReceived = { [weak self] envelope in
            Task { @MainActor in
                self?.handleMessage(envelope)
            }
        }

        connectivityManager.startMonitoring()
    }

    /// Switch to a different provider.
    func selectProvider(_ providerID: String) {
        if let composite = compositeRef {
            // Try Bonjour direct first, then relay
            if composite.bonjourBrowser.directProviders[providerID] != nil {
                composite.bonjourBrowser.selectProvider(providerID)
            } else {
                composite.mpcBrowser.selectRelayProvider(providerID)
            }
        } else if let browser = transport as? MPCBrowser {
            browser.selectRelayProvider(providerID)
        } else if let localTransport = transport as? RelayLocalTransport {
            localTransport.selectProvider(providerID)
        }
    }

    func startSearching() {
        transport.startSearching()
    }

    func stopSearching() {
        transport.stopSearching()
        connectivityManager.stopMonitoring()
    }

    /// Create or restore a session for the connected provider.
    /// Tries to restore a persisted session first; creates a new one locally via Tempo if none found.
    /// `sessionReady` is gated on on-chain channel confirmation when Tempo is in use.
    func createSession(providerID: String) {
        sessionReady = false
        channelStatus = ""
        sessionCreationGeneration += 1
        let expectedGeneration = sessionCreationGeneration

        if let restored = SessionManager.restore(providerID: providerID) {
            sessionManager = restored
            restored.attachConnectivityManager(connectivityManager)
            responseHistory = restored.history
            if restored.channelOpenedOnChain {
                // Channel already verified on a previous session.
                // Still call setupTempoChannel() to reconstruct the in-memory Channel object —
                // it is not persisted, only the ETH keypair is. Without it channelInfo is nil
                // and every request fails with INVALID_SESSION.
                // openChannelOnChain() will find .alreadyOpen quickly and be a no-op.
                bindChannelStatus(to: restored)
                if restored.channel == nil, let ethAddr = connectedProvider?.providerEthAddress, !ethAddr.isEmpty {
                    restored.setupTempoChannel(providerEthAddress: ethAddr)
                }
                sessionReady = true
            } else {
                // Channel not yet open — observe until it confirms, then unblock
                observeChannelOpening(on: restored)
                if restored.channel == nil, let ethAddr = connectedProvider?.providerEthAddress, !ethAddr.isEmpty {
                    restored.setupTempoChannel(providerEthAddress: ethAddr)
                } else {
                    restored.retryChannelOpenIfNeeded()
                }
            }
            restoreSettlementStatus()
            print("Restored session: \(restored.sessionGrant.sessionID.prefix(8))... (\(restored.remainingCredits) credits left, \(restored.history.count) history)")
        } else {
            // Create session locally with Tempo channel (async)
            Task {
                let manager = await SessionManager.create(providerID: providerID)
                // Discard if a newer createSession() has been called (rapid provider switching)
                guard sessionCreationGeneration == expectedGeneration else {
                    print("Discarding stale session creation for \(providerID.prefix(8))...")
                    return
                }
                sessionManager = manager
                manager.attachConnectivityManager(connectivityManager)
                bindChannelStatus(to: manager)
                if let ethAddr = connectedProvider?.providerEthAddress, !ethAddr.isEmpty {
                    // Gate sessionReady on channel confirmation
                    observeChannelOpening(on: manager)
                    manager.setupTempoChannel(providerEthAddress: ethAddr)
                } else {
                    // No Tempo channel — unblock immediately
                    sessionReady = true
                }
                responseHistory = manager.history  // history file loaded in SessionManager.init
                settlementStatus = .unverified
            }
        }
    }

    /// Bind a SessionManager's channelOnChainStatus to channelStatus for all sessions,
    /// including already-open ones (needed so top-up progress is visible).
    private func bindChannelStatus(to manager: SessionManager) {
        manager.$channelOnChainStatus
            .receive(on: RunLoop.main)
            .assign(to: &$channelStatus)
    }

    /// Subscribe to a SessionManager's channel state and forward to published properties.
    /// Sets `sessionReady = true` once the channel opens on-chain.
    private func observeChannelOpening(on manager: SessionManager) {
        bindChannelStatus(to: manager)

        manager.$channelOpenedOnChain
            .filter { $0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sessionReady = true }
            .store(in: &cancellables)
    }

    /// Submit a prompt request to the connected provider.
    func submitRequest(taskType: TaskType, promptText: String, parameters: PromptRequest.Parameters) {
        guard let session = sessionManager else {
            errorMessage = "No active session"
            requestState = .error
            return
        }

        guard sessionReady else {
            errorMessage = "Session is being set up. Please wait."
            requestState = .error
            return
        }

        let requestID = UUID().uuidString
        pendingRequestID = requestID
        pendingTaskType = taskType
        pendingPromptText = promptText
        disconnectedDuringRequest = false

        // Always include channel info so the provider can set up or verify the channel.
        // ChannelInfo includes clientCumulativeSpend so the provider can tell if the
        // client actually missed a response (vs. idle reconnect).
        let channelInfo = session.channelInfo

        let request = PromptRequest(
            requestID: requestID,
            sessionID: session.sessionGrant.sessionID,
            taskType: taskType,
            promptText: promptText,
            parameters: parameters,
            sessionGrant: nil,
            channelInfo: channelInfo,
            clientIdentity: SessionManager.deviceIdentityKey().publicKeyBase64
        )

        do {
            let envelope = try MessageEnvelope.wrap(
                type: .promptRequest,
                senderID: session.sessionGrant.sessionID,
                payload: request
            )
            try transport.send(envelope)
            requestState = .waitingForResponse
            errorMessage = nil
            pendingSettlement = nil
            lastResult = nil
            startRequestTimeout(requestID: requestID)
        } catch {
            errorMessage = "Failed to send: \(error.localizedDescription)"
            requestState = .error
        }
    }

    // MARK: - Message handling

    func handleMessage(_ envelope: MessageEnvelope) {
        switch envelope.type {
        case .inferenceResponse:
            guard let response = try? envelope.unwrap(as: InferenceResponse.self) else { return }
            handleInferenceResponse(response)
        case .tabSettlementRequest:
            guard let req = try? envelope.unwrap(as: TabSettlementRequest.self) else { return }
            handleTabSettlementRequest(req)
        case .sessionSync:
            guard let sync = try? envelope.unwrap(as: SessionSync.self) else { return }
            handleSessionSync(sync)
        case .errorResponse:
            guard let error = try? envelope.unwrap(as: ErrorResponse.self) else { return }
            handleError(error)
        case .serviceUpdate:
            guard let update = try? envelope.unwrap(as: ServiceUpdate.self) else { return }
            handleServiceUpdate(update)
        default:
            break
        }
    }

    private func handleServiceUpdate(_ update: ServiceUpdate) {
        // Clamp incoming values — provider may be buggy or send 0
        let safeRate = max(1, update.tokenRate)
        let safeThreshold = max(100, update.tabThresholdTokens)

        // Update connectedProvider in place (tokenRate/tabThreshold are var after §0C)
        connectedProvider?.tokenRate = safeRate
        connectedProvider?.tabThreshold = safeThreshold  // note: field is tabThreshold on ServiceAnnounce

        // Keep SessionManager in sync — it stores these independently
        sessionManager?.tokenRate = safeRate
        sessionManager?.tabThreshold = safeThreshold

        rateChangeNotice = "Provider updated pricing: \(safeRate) credits / 1K tokens · settle every \(safeThreshold) tokens"
    }

    private func handleTabSettlementRequest(_ req: TabSettlementRequest) {
        pendingSettlement = req
        requestState = .awaitingSettlement
        guard let session = sessionManager else { return }
        Task {
            do {
                let auth = try await session.createTabSettlementVoucher(
                    requestID: req.requestID,
                    tabCredits: req.tabCredits,
                    channelId: req.channelId
                )
                let envelope = try MessageEnvelope.wrap(
                    type: .voucherAuthorization,
                    senderID: session.sessionGrant.sessionID,
                    payload: auth
                )
                try transport.send(envelope)
                session.recordTabSettlement(tabCredits: req.tabCredits)
                pendingSettlement = nil
                requestState = .idle
            } catch {
                errorMessage = "Tab settlement failed: \(error.localizedDescription)"
                requestState = .error
            }
        }
    }

    private func handleInferenceResponse(_ response: InferenceResponse) {
        guard response.requestID == pendingRequestID else { return }

        // Tab model: verify creditsCharged matches tokenRate × tokensUsed.
        // Use tabUpdate.tokenRate (rate used at computation time) when present to avoid a
        // ServiceUpdate / InferenceResponse arrival-order race. Fall back to connectedProvider.tokenRate
        // for legacy responses (tabUpdate.tokenRate == 0).
        if let tabUpdate = response.tabUpdate, let provider = connectedProvider, provider.paymentModel == "tab" {
            let rateForCheck = tabUpdate.tokenRate > 0 ? tabUpdate.tokenRate : provider.tokenRate
            let expected = Int(max(1, (tabUpdate.tokensUsed * rateForCheck + 999) / 1000))
            guard response.creditsCharged == expected else {
                errorMessage = "Provider charged \(response.creditsCharged) but token count implies \(expected)"
                requestState = .error
                pendingRequestID = nil
                pendingTaskType = nil
                pendingPromptText = nil
                return
            }
            sessionManager?.applyTabUpdate(tabUpdate, tokenRate: rateForCheck)
        }

        // Verify the provider's receipt signature before accepting
        if let providerPubkey = connectedProvider?.providerPubkey, !providerPubkey.isEmpty {
            do {
                let verifier = try JanusVerifier(publicKeyBase64: providerPubkey)
                let valid = verifier.verify(
                    signature: response.receipt.providerSignature,
                    fields: response.receipt.signableFields
                )
                if !valid {
                    errorMessage = "Invalid receipt signature — provider may be dishonest"
                    requestState = .error
                    pendingRequestID = nil
                    pendingTaskType = nil
                    pendingPromptText = nil
                    return
                }
            } catch {
                errorMessage = "Cannot verify receipt: \(error.localizedDescription)"
                requestState = .error
                pendingRequestID = nil
                pendingTaskType = nil
                pendingPromptText = nil
                return
            }
        }

        cancelRequestTimeout()
        lastResult = response
        // Tab mode: do NOT advance spendState here — only advance at settlement time
        // (recordTabSettlement). Calling recordSpend() AND recordTabSettlement() for the
        // same credits would double-count, inflating spendState and causing voucher creation
        // to exceed the channel deposit on the next settlement cycle.
        if connectedProvider?.paymentModel == "tab" {
            sessionManager?.recordReceiptOnly(receipt: response.receipt)
        } else {
            sessionManager?.recordSpend(
                creditsCharged: response.creditsCharged,
                receipt: response.receipt
            )
        }
        // Store in history (persisted via SessionManager)
        if let task = pendingTaskType, let prompt = pendingPromptText {
            let entry = HistoryEntry(task: task, prompt: prompt, response: response)
            sessionManager?.recordHistory(task: task, prompt: prompt, response: response)
            responseHistory.insert(entry, at: 0)
        }
        requestState = .complete
        pendingRequestID = nil
        pendingTaskType = nil
        pendingPromptText = nil
    }

    private func handleSessionSync(_ sync: SessionSync) {
        guard let session = sessionManager,
              sync.sessionID == session.sessionGrant.sessionID else { return }

        let response = sync.missedResponse

        // Verify the receipt signature before trusting the provider's state
        if let providerPubkey = connectedProvider?.providerPubkey, !providerPubkey.isEmpty {
            do {
                let verifier = try JanusVerifier(publicKeyBase64: providerPubkey)
                let valid = verifier.verify(
                    signature: response.receipt.providerSignature,
                    fields: response.receipt.signableFields
                )
                if !valid {
                    print("SessionSync rejected: invalid receipt signature")
                    errorMessage = "State sync rejected — invalid receipt"
                    requestState = .error
                    return
                }
            } catch {
                print("SessionSync rejected: cannot verify receipt: \(error)")
                errorMessage = "State sync failed — cannot verify receipt"
                requestState = .error
                return
            }
        }

        cancelRequestTimeout()

        // Receipt verified — update spend state to match provider
        session.syncSpendState(to: response)

        // Add the missed response to history
        let entry = HistoryEntry(task: .summarize, prompt: "(recovered)", response: response)
        session.recordHistory(task: .summarize, prompt: "(recovered)", response: response)
        responseHistory.insert(entry, at: 0)

        print("SessionSync applied: spend now \(response.cumulativeSpend), seq \(session.spendState.sequenceNumber)")

        // Reset to idle — client can retry their request
        errorMessage = nil
        requestState = .idle
        pendingRequestID = nil
        pendingTaskType = nil
        pendingPromptText = nil
    }

    private func handleError(_ error: ErrorResponse) {
        cancelRequestTimeout()
        if error.errorCode == .channelNotReady {
            // Race window: channel opened between client check and provider check — silently retry
            requestState = .idle
            pendingRequestID = nil
            pendingTaskType = nil
            pendingPromptText = nil
            return
        }
        if error.errorCode == .tabSettlementRequired {
            // A TabSettlementRequest is incoming — pre-set the state so the UI shows
            // "Settling tab..." immediately rather than staying stuck at "Processing...".
            // handleTabSettlementRequest will set .awaitingSettlement again (idempotent).
            requestState = .awaitingSettlement
            return
        }
        errorMessage = "[\(error.errorCode.rawValue)] \(error.errorMessage)"
        requestState = .error
        pendingRequestID = nil
        pendingTaskType = nil
        pendingPromptText = nil
    }

    // MARK: - Request timeout

    /// Start a timeout that resets the request state if no response arrives.
    /// Also proactively checks connection health before the timer starts.
    private func startRequestTimeout(requestID: String) {
        requestTimeoutTask?.cancel()
        transport.checkConnectionHealth()
        requestTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
            guard !Task.isCancelled,
                  pendingRequestID == requestID,
                  requestState == .waitingForResponse else { return }
            errorMessage = "Request timed out — provider may be unreachable"
            requestState = .error
            pendingRequestID = nil
            pendingTaskType = nil
            pendingPromptText = nil
        }
    }

    private func cancelRequestTimeout() {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
    }

    var isWaitingForResponse: Bool {
        requestState == .waitingForResponse
    }

/// Top up the active channel. Disabled during in-flight inference to prevent race conditions.
    func topUpChannel(additionalDeposit: UInt64) {
        guard let manager = sessionManager, !isWaitingForResponse else { return }
        Task { await manager.topUpChannel(additionalDeposit: additionalDeposit) }
    }

    var canAffordRequest: Bool {
        guard requestState != .awaitingSettlement else { return false }
        return (sessionManager?.remainingCredits ?? 0) > 0
    }

    // MARK: - Settlement verification

    /// Trigger on-chain settlement verification.
    func verifySettlement() {
        Task {
            if let status = await sessionManager?.verifySettlementOnChain() {
                settlementStatus = status
            }
        }
    }

    /// Restore settlement status from persisted session state.
    private func restoreSettlementStatus() {
        guard let session = sessionManager,
              let verified = session.lastVerifiedSettlement else {
            settlementStatus = .unverified
            return
        }
        let expected = UInt64(session.spendState.cumulativeSpend)
        if verified == expected {
            settlementStatus = .match(settled: verified)
        } else if verified > expected {
            settlementStatus = .overpayment(settled: verified, expected: expected)
        } else {
            settlementStatus = .underpayment(settled: verified, expected: expected)
        }
    }
}
