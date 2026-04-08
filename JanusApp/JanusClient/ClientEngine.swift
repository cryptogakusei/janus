import Foundation
import Combine
import JanusShared

/// Orchestrates the client's request flow over MPC.
///
/// State machine: idle → waitingForQuote → waitingForResponse → complete/error
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
    /// All providers available via relay (empty when direct-connected or only one provider).
    @Published var availableProviders: [ServiceAnnounce] = []

    // Request flow state
    @Published var requestState: RequestState = .idle
    @Published var currentQuote: QuoteResponse?
    @Published var lastResult: InferenceResponse?
    @Published var errorMessage: String?

    // Response history (newest first) — backed by SessionManager persistence
    @Published var responseHistory: [HistoryEntry] = []

    // Disconnect detection
    @Published var disconnectedDuringRequest = false

    enum RequestState: String {
        case idle = "Ready"
        case waitingForQuote = "Getting quote..."
        case waitingForResponse = "Processing..."
        case complete = "Done"
        case error = "Error"
    }

    let transport: any ProviderTransport
    /// Typed reference for browser-specific features (force relay toggle).
    /// Nil when transport is RelayLocalTransport (dual mode).
    let browserRef: MPCBrowser?
    private(set) var sessionManager: SessionManager?
    private var cancellables = Set<AnyCancellable>()
    var pendingRequestID: String?
    var pendingTaskType: TaskType?
    var pendingPromptText: String?
    private var requestTimeoutTask: Task<Void, Never>?

    /// Optional wallet provider injected from Privy auth.
    /// When set, SessionManager uses it for voucher signing and on-chain ops.
    var walletProvider: (any WalletProvider)?

    convenience init() {
        self.init(transport: MPCBrowser())
    }

    init(transport: any ProviderTransport) {
        self.transport = transport
        self.browserRef = transport as? MPCBrowser

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
                    self?.createSession(providerID: provider.providerID)
                } else {
                    // Detect disconnect during active request
                    if let self, self.requestState == .waitingForQuote || self.requestState == .waitingForResponse {
                        self.cancelRequestTimeout()
                        self.disconnectedDuringRequest = true
                        self.errorMessage = "Provider disconnected during request"
                        self.requestState = .error
                        self.pendingRequestID = nil
                    }
                    // Don't nil sessionManager — it's persisted and can be reused on reconnect
                    self?.sessionReady = false
                    self?.connectionMode = .disconnected
                }
            }
            .store(in: &cancellables)

        // Forward relay providers list from transport (browser or local transport)
        if let browser = browserRef {
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
    }

    /// Switch to a different provider available through the relay.
    func selectProvider(_ providerID: String) {
        if let browser = browserRef {
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
    }

    /// Create or restore a session for the connected provider.
    /// Tries to restore a persisted session first; creates a new one via backend API if none found.
    func createSession(providerID: String) {
        if let restored = SessionManager.restore(providerID: providerID, walletProvider: walletProvider) {
            sessionManager = restored
            responseHistory = restored.history
            // Set up Tempo channel if not already set up
            if restored.channel == nil, let ethAddr = connectedProvider?.providerEthAddress, !ethAddr.isEmpty {
                restored.setupTempoChannel(providerEthAddress: ethAddr)
            } else {
                // Retry opening on-chain if previous attempt was interrupted
                restored.retryChannelOpenIfNeeded()
            }
            sessionReady = true
            print("Restored session: \(restored.sessionGrant.sessionID.prefix(8))... (\(restored.remainingCredits) credits left, \(restored.history.count) history)")
        } else {
            // Request grant from backend (async)
            Task {
                let manager = await SessionManager.create(providerID: providerID, walletProvider: walletProvider)
                // Set up Tempo channel if provider supports it
                if let ethAddr = connectedProvider?.providerEthAddress, !ethAddr.isEmpty {
                    manager.setupTempoChannel(providerEthAddress: ethAddr)
                }
                sessionManager = manager
                responseHistory = []
                sessionReady = true
            }
        }
    }

    /// Submit a prompt request to the connected provider.
    func submitRequest(taskType: TaskType, promptText: String, parameters: PromptRequest.Parameters) {
        guard let session = sessionManager else {
            errorMessage = "No active session"
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
            channelInfo: channelInfo
        )

        do {
            let envelope = try MessageEnvelope.wrap(
                type: .promptRequest,
                senderID: session.sessionGrant.sessionID,
                payload: request
            )
            try transport.send(envelope)
            requestState = .waitingForQuote
            errorMessage = nil
            currentQuote = nil
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
        case .quoteResponse:
            guard let quote = try? envelope.unwrap(as: QuoteResponse.self) else { return }
            handleQuote(quote)
        case .inferenceResponse:
            guard let response = try? envelope.unwrap(as: InferenceResponse.self) else { return }
            handleInferenceResponse(response)
        case .sessionSync:
            guard let sync = try? envelope.unwrap(as: SessionSync.self) else { return }
            handleSessionSync(sync)
        case .errorResponse:
            guard let error = try? envelope.unwrap(as: ErrorResponse.self) else { return }
            handleError(error)
        default:
            break
        }
    }

    private func handleQuote(_ quote: QuoteResponse) {
        guard quote.requestID == pendingRequestID else { return }
        currentQuote = quote

        // Auto-accept: sign a Tempo voucher and send authorization
        guard let session = sessionManager else { return }

        Task {
            do {
                let auth = try await session.createVoucherAuthorization(
                    requestID: quote.requestID,
                    quoteID: quote.quoteID,
                    priceCredits: quote.priceCredits
                )
                let envelope = try MessageEnvelope.wrap(
                    type: .voucherAuthorization,
                    senderID: session.sessionGrant.sessionID,
                    payload: auth
                )
                try transport.send(envelope)
                requestState = .waitingForResponse
            } catch {
                errorMessage = "Failed to authorize: \(error.localizedDescription)"
                requestState = .error
            }
        }
    }

    private func handleInferenceResponse(_ response: InferenceResponse) {
        guard response.requestID == pendingRequestID else { return }

        // Verify the charged amount matches the quoted price
        if let quote = currentQuote, response.creditsCharged != quote.priceCredits {
            errorMessage = "Provider charged \(response.creditsCharged) but quoted \(quote.priceCredits)"
            requestState = .error
            pendingRequestID = nil
            pendingTaskType = nil
            pendingPromptText = nil
            return
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
        sessionManager?.recordSpend(
            creditsCharged: response.creditsCharged,
            receipt: response.receipt
        )
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
            try? await Task.sleep(nanoseconds: 20_000_000_000) // 20 seconds
            guard !Task.isCancelled,
                  pendingRequestID == requestID,
                  requestState == .waitingForQuote || requestState == .waitingForResponse else { return }
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

    /// Minimum credits needed (smallest pricing tier).
    var canAffordRequest: Bool {
        (sessionManager?.remainingCredits ?? 0) >= PricingTier.small.credits
    }
}
