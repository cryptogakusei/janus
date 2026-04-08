import XCTest
@testable import JanusClient
import JanusShared

/// Tests for ClientEngine's message handling state machine.
///
/// These tests inject MessageEnvelopes directly into handleMessage()
/// and verify state transitions without requiring MPC transport.
/// The real MPCBrowser is created but never started (MPC stays dormant).
@MainActor
final class ClientEngineTests: XCTestCase {

    private var engine: ClientEngine!
    private var providerJanusKP: JanusKeyPair!

    override func setUp() {
        super.setUp()
        engine = ClientEngine()
        providerJanusKP = JanusKeyPair()
    }

    override func tearDown() {
        engine = nil
        providerJanusKP = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeQuote(requestID: String, priceCredits: Int = 5) -> QuoteResponse {
        QuoteResponse(requestID: requestID, priceCredits: priceCredits,
                      priceTier: "medium", expiresAt: Date().addingTimeInterval(60))
    }

    private func makeReceipt(sessionID: String, requestID: String, providerID: String,
                             creditsCharged: Int, cumulativeSpend: Int) -> Receipt {
        let signer = JanusSigner(keyPair: providerJanusKP)
        let receiptID = UUID().uuidString
        let timestamp = Date()
        let fields = [
            receiptID, sessionID, requestID, providerID,
            String(creditsCharged), String(cumulativeSpend),
            ISO8601DateFormatter().string(from: timestamp)
        ]
        let sig = try! signer.sign(fields: fields)
        return Receipt(
            receiptID: receiptID,
            sessionID: sessionID,
            requestID: requestID,
            providerID: providerID,
            creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeSpend,
            timestamp: timestamp,
            providerSignature: sig
        )
    }

    private func makeInferenceResponse(requestID: String, creditsCharged: Int, cumulativeSpend: Int,
                                        sessionID: String = "sess-1", providerID: String = "prov-1") -> InferenceResponse {
        let receipt = makeReceipt(
            sessionID: sessionID, requestID: requestID,
            providerID: providerID, creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeSpend
        )
        return InferenceResponse(
            requestID: requestID,
            outputText: "Test output",
            creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeSpend,
            receipt: receipt
        )
    }

    // MARK: - QuoteResponse handling

    func testHandleQuoteResponse_setsCurrentQuote() throws {
        let requestID = "req-1"
        engine.pendingRequestID = requestID
        engine.requestState = .waitingForQuote

        let quote = makeQuote(requestID: requestID, priceCredits: 3)
        let envelope = try MessageEnvelope.wrap(type: .quoteResponse, senderID: "prov-1", payload: quote)
        engine.handleMessage(envelope)

        // Quote should be set even though sessionManager is nil (voucher auth will fail gracefully)
        XCTAssertNotNil(engine.currentQuote)
        XCTAssertEqual(engine.currentQuote?.requestID, requestID)
        XCTAssertEqual(engine.currentQuote?.priceCredits, 3)
    }

    func testHandleQuoteResponse_ignoresWrongRequestID() throws {
        engine.pendingRequestID = "req-1"
        engine.requestState = .waitingForQuote

        let quote = makeQuote(requestID: "wrong-id", priceCredits: 5)
        let envelope = try MessageEnvelope.wrap(type: .quoteResponse, senderID: "prov-1", payload: quote)
        engine.handleMessage(envelope)

        XCTAssertNil(engine.currentQuote, "Quote with non-matching requestID should be ignored")
        XCTAssertEqual(engine.requestState, .waitingForQuote, "State should remain unchanged")
    }

    // MARK: - InferenceResponse handling

    func testHandleInferenceResponse_rejectsMismatchedCharge() throws {
        let requestID = "req-1"
        engine.pendingRequestID = requestID
        engine.requestState = .waitingForResponse
        engine.currentQuote = makeQuote(requestID: requestID, priceCredits: 5)

        // Response charges 8 but quote said 5
        let response = makeInferenceResponse(requestID: requestID, creditsCharged: 8, cumulativeSpend: 8)
        let envelope = try MessageEnvelope.wrap(type: .inferenceResponse, senderID: "prov-1", payload: response)
        engine.handleMessage(envelope)

        XCTAssertEqual(engine.requestState, .error)
        XCTAssertTrue(engine.errorMessage?.contains("charged") == true,
                      "Error should mention charge mismatch: \(engine.errorMessage ?? "nil")")
        XCTAssertNil(engine.pendingRequestID, "Pending request should be cleared on error")
    }

    func testHandleInferenceResponse_rejectsInvalidReceiptSignature() throws {
        let requestID = "req-1"
        engine.pendingRequestID = requestID
        engine.requestState = .waitingForResponse
        engine.currentQuote = makeQuote(requestID: requestID, priceCredits: 3)

        // Set a provider pubkey so signature verification is triggered
        let realProvider = JanusKeyPair()
        engine.connectedProvider = ServiceAnnounce(
            providerID: "prov-1",
            providerName: "Test Provider",
            providerPubkey: realProvider.publicKeyBase64,
            providerEthAddress: ""
        )

        // Create response with receipt signed by a DIFFERENT key (providerJanusKP != realProvider)
        let response = makeInferenceResponse(requestID: requestID, creditsCharged: 3, cumulativeSpend: 3)
        let envelope = try MessageEnvelope.wrap(type: .inferenceResponse, senderID: "prov-1", payload: response)
        engine.handleMessage(envelope)

        XCTAssertEqual(engine.requestState, .error)
        XCTAssertTrue(engine.errorMessage?.contains("signature") == true || engine.errorMessage?.contains("dishonest") == true,
                      "Error should mention invalid signature: \(engine.errorMessage ?? "nil")")
    }

    func testHandleInferenceResponse_ignoresWrongRequestID() throws {
        engine.pendingRequestID = "req-1"
        engine.requestState = .waitingForResponse

        let response = makeInferenceResponse(requestID: "wrong-id", creditsCharged: 3, cumulativeSpend: 3)
        let envelope = try MessageEnvelope.wrap(type: .inferenceResponse, senderID: "prov-1", payload: response)
        engine.handleMessage(envelope)

        XCTAssertEqual(engine.requestState, .waitingForResponse, "State should remain unchanged for wrong requestID")
        XCTAssertNil(engine.lastResult)
    }

    // MARK: - ErrorResponse handling

    func testHandleError_setsErrorState() throws {
        engine.pendingRequestID = "req-1"
        engine.requestState = .waitingForQuote

        let error = ErrorResponse(requestID: "req-1", errorCode: .providerBusy, errorMessage: "Model not ready")
        let envelope = try MessageEnvelope.wrap(type: .errorResponse, senderID: "prov-1", payload: error)
        engine.handleMessage(envelope)

        XCTAssertEqual(engine.requestState, .error)
        XCTAssertEqual(engine.errorMessage, "[PROVIDER_BUSY] Model not ready")
        XCTAssertNil(engine.pendingRequestID, "Pending request should be cleared")
    }

    func testHandleError_allCodes() throws {
        let codes: [ErrorResponse.ErrorCode] = [
            .invalidSession, .expiredQuote, .insufficientCredits,
            .invalidSignature, .sessionExpired, .providerBusy,
            .sequenceMismatch, .inferenceFailed, .providerUnreachable
        ]

        for code in codes {
            engine.pendingRequestID = "req-\(code.rawValue)"
            engine.requestState = .waitingForQuote

            let error = ErrorResponse(requestID: "req-\(code.rawValue)", errorCode: code, errorMessage: "Test")
            let envelope = try MessageEnvelope.wrap(type: .errorResponse, senderID: "prov-1", payload: error)
            engine.handleMessage(envelope)

            XCTAssertEqual(engine.requestState, .error, "Error state not set for code: \(code.rawValue)")
            XCTAssertTrue(engine.errorMessage?.contains(code.rawValue) == true,
                          "Error message should contain code \(code.rawValue)")
        }
    }

    // MARK: - Relay disconnect (providerUnreachable)

    func testHandleError_providerUnreachable_setsErrorState() throws {
        engine.pendingRequestID = "req-1"
        engine.requestState = .waitingForQuote

        // Relay sends error with requestID: nil (can't peek into opaque envelope)
        let error = ErrorResponse(
            requestID: nil,
            errorCode: .providerUnreachable,
            errorMessage: "Provider is no longer reachable through this relay"
        )
        let envelope = try MessageEnvelope.wrap(type: .errorResponse, senderID: "relay", payload: error)
        engine.handleMessage(envelope)

        XCTAssertEqual(engine.requestState, .error)
        XCTAssertTrue(engine.errorMessage?.contains("PROVIDER_UNREACHABLE") == true)
        XCTAssertNil(engine.pendingRequestID)
    }

    // MARK: - Message routing

    func testHandleMessage_ignoresUnknownTypes() throws {
        engine.requestState = .idle

        // ServiceAnnounce is handled by MPCBrowser, not ClientEngine — should be ignored
        let announce = ServiceAnnounce(
            providerID: "prov-1", providerName: "Test",
            providerPubkey: "", providerEthAddress: ""
        )
        let envelope = try MessageEnvelope.wrap(type: .serviceAnnounce, senderID: "prov-1", payload: announce)
        engine.handleMessage(envelope)

        XCTAssertEqual(engine.requestState, .idle, "Unhandled message types should not change state")
    }
}
