import Foundation
import Combine
import JanusShared

/// Orchestrates the client's request flow over MPC.
///
/// State machine: idle → waitingForQuote → waitingForResponse → complete/error
/// Owns the MPCBrowser and SessionManager, and drives the UI.
///
/// Forwards browser's published properties so SwiftUI views can observe
/// connection state changes through this single object.
@MainActor
class ClientEngine: ObservableObject {

    // Forwarded browser state (so SwiftUI can observe)
    @Published var isSearching = false
    @Published var connectionStatus = "Disconnected"
    @Published var connectedProvider: ServiceAnnounce?
    @Published var sessionReady = false

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

    let browser: MPCBrowser
    private(set) var sessionManager: SessionManager?
    private var cancellables = Set<AnyCancellable>()
    private var pendingRequestID: String?
    private var pendingTaskType: TaskType?
    private var pendingPromptText: String?
    private var requestTimeoutTask: Task<Void, Never>?

    init() {
        self.browser = MPCBrowser()

        // Forward browser published properties to trigger SwiftUI updates
        browser.$isSearching
            .assign(to: &$isSearching)
        browser.$connectionState
            .map { $0.rawValue.capitalized }
            .assign(to: &$connectionStatus)
        browser.$connectedProvider
            .sink { [weak self] provider in
                self?.connectedProvider = provider
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
                }
            }
            .store(in: &cancellables)

        browser.onMessageReceived = { [weak self] envelope in
            Task { @MainActor in
                self?.handleMessage(envelope)
            }
        }
    }

    func startSearching() {
        browser.startSearching()
    }

    func stopSearching() {
        browser.stopSearching()
    }

    /// Create or restore a session for the connected provider.
    /// Tries to restore a persisted session first; creates a new one via backend API if none found.
    func createSession(providerID: String) {
        if let restored = SessionManager.restore(providerID: providerID) {
            sessionManager = restored
            responseHistory = restored.history
            // Set up Tempo channel if provider supports it and not already set up
            if !restored.usesVouchers, let ethAddr = connectedProvider?.providerEthAddress, !ethAddr.isEmpty {
                restored.setupTempoChannel(providerEthAddress: ethAddr)
            }
            sessionReady = true
            print("Restored session: \(restored.sessionGrant.sessionID.prefix(8))... (\(restored.remainingCredits) credits left, \(restored.history.count) history, vouchers=\(restored.usesVouchers))")
        } else {
            // Request grant from backend (async)
            Task {
                let manager = await SessionManager.create(providerID: providerID)
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

        // Include session identity on first request:
        // - Tempo path: channelInfo (replaces sessionGrant)
        // - Ed25519 path: sessionGrant
        let grant: SessionGrant?
        let channelInfo: ChannelInfo?
        if session.usesVouchers {
            grant = nil
            channelInfo = session.channelInfoDelivered ? nil : session.channelInfo
        } else {
            grant = session.grantDelivered ? nil : session.sessionGrant
            channelInfo = nil
        }

        let request = PromptRequest(
            requestID: requestID,
            sessionID: session.sessionGrant.sessionID,
            taskType: taskType,
            promptText: promptText,
            parameters: parameters,
            sessionGrant: grant,
            channelInfo: channelInfo
        )

        do {
            let envelope = try MessageEnvelope.wrap(
                type: .promptRequest,
                senderID: session.sessionGrant.sessionID,
                payload: request
            )
            try browser.send(envelope)
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

    private func handleMessage(_ envelope: MessageEnvelope) {
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

        // Auto-accept: create and send authorization (Tempo voucher or Ed25519)
        guard let session = sessionManager else { return }

        do {
            let envelope: MessageEnvelope
            if session.usesVouchers {
                let auth = try session.createVoucherAuthorization(
                    requestID: quote.requestID,
                    quoteID: quote.quoteID,
                    priceCredits: quote.priceCredits
                )
                envelope = try MessageEnvelope.wrap(
                    type: .voucherAuthorization,
                    senderID: session.sessionGrant.sessionID,
                    payload: auth
                )
                session.channelInfoDelivered = true
            } else {
                let auth = try session.createAuthorization(
                    requestID: quote.requestID,
                    quoteID: quote.quoteID,
                    priceCredits: quote.priceCredits
                )
                envelope = try MessageEnvelope.wrap(
                    type: .spendAuthorization,
                    senderID: session.sessionGrant.sessionID,
                    payload: auth
                )
                session.grantDelivered = true
            }
            try browser.send(envelope)
            requestState = .waitingForResponse
        } catch {
            errorMessage = "Failed to authorize: \(error.localizedDescription)"
            requestState = .error
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
        browser.checkConnectionHealth()
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
