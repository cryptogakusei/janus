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

    // MARK: - InferenceResponse handling

    func testHandleInferenceResponse_rejectsMismatchedCharge() throws {
        let requestID = "req-1"
        engine.pendingRequestID = requestID
        engine.requestState = .waitingForResponse

        // Set provider as tab model: tokenRate=10 (10 credits per 1000 tokens)
        engine.connectedProvider = ServiceAnnounce(
            providerID: "prov-1", providerName: "Test",
            providerPubkey: "", providerEthAddress: "",
            tokenRate: 10, tabThreshold: 500, maxOutputTokens: 1024, paymentModel: "tab"
        )

        // 100 tokens → expected = max(1, (100*10+999)/1000) = 1 credit
        // Response charges 5 → mismatch
        let tabUpdate = TabUpdate(tokensUsed: 100, cumulativeTabTokens: 100, tabThreshold: 500)
        let receipt = makeReceipt(sessionID: "sess-1", requestID: requestID, providerID: "prov-1",
                                  creditsCharged: 5, cumulativeSpend: 5)
        let response = InferenceResponse(requestID: requestID, outputText: "Test",
                                         creditsCharged: 5, cumulativeSpend: 5,
                                         receipt: receipt, tabUpdate: tabUpdate)
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
        engine.requestState = .waitingForResponse

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
            engine.requestState = .waitingForResponse

            let error = ErrorResponse(requestID: "req-\(code.rawValue)", errorCode: code, errorMessage: "Test")
            let envelope = try MessageEnvelope.wrap(type: .errorResponse, senderID: "prov-1", payload: error)
            engine.handleMessage(envelope)

            XCTAssertEqual(engine.requestState, .error, "Error state not set for code: \(code.rawValue)")
            XCTAssertTrue(engine.errorMessage?.contains(code.rawValue) == true,
                          "Error message should contain code \(code.rawValue)")
        }
    }

    func testHandleError_tabSettlementRequired_isSilentlyDropped() throws {
        // When provider sends tabSettlementRequired, the paired TabSettlementRequest message
        // is what drives state. This error code must not override awaitingSettlement state.
        engine.pendingRequestID = "req-1"
        engine.requestState = .awaitingSettlement

        let error = ErrorResponse(requestID: "req-1", errorCode: .tabSettlementRequired, errorMessage: "Settle tab")
        let envelope = try MessageEnvelope.wrap(type: .errorResponse, senderID: "prov-1", payload: error)
        engine.handleMessage(envelope)

        XCTAssertEqual(engine.requestState, .awaitingSettlement, "tabSettlementRequired must not override awaitingSettlement")
        XCTAssertNil(engine.errorMessage, "tabSettlementRequired must not set errorMessage")
    }

    // MARK: - Tab settlement request handling

    func testHandleTabSettlementRequest_setsAwaitingSettlementState() throws {
        engine.requestState = .waitingForResponse
        engine.pendingRequestID = "req-1"

        let channelId = Data(repeating: 0xAB, count: 32)
        let req = TabSettlementRequest(requestID: "settle-1", tabCredits: 15, channelId: channelId)
        let envelope = try MessageEnvelope.wrap(type: .tabSettlementRequest, senderID: "prov-1", payload: req)
        engine.handleMessage(envelope)

        XCTAssertEqual(engine.requestState, .awaitingSettlement,
                       "TabSettlementRequest must set awaitingSettlement state")
        XCTAssertNotNil(engine.pendingSettlement, "pendingSettlement must be populated")
        XCTAssertEqual(engine.pendingSettlement?.tabCredits, 15)
        XCTAssertEqual(engine.pendingSettlement?.requestID, "settle-1")
        // No sessionManager → auto-sign task returns early; state stays awaitingSettlement
    }

    // MARK: - Relay disconnect (providerUnreachable)

    func testHandleError_providerUnreachable_setsErrorState() throws {
        engine.pendingRequestID = "req-1"
        engine.requestState = .waitingForResponse

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
