import XCTest
@testable import JanusShared

final class ProtocolTests: XCTestCase {

    // MARK: - MessageEnvelope

    func testEnvelopeWrapUnwrap() throws {
        let announce = ServiceAnnounce(providerID: "p1", providerName: "TestMac")
        let envelope = try MessageEnvelope.wrap(
            type: .serviceAnnounce, senderID: "p1", payload: announce
        )

        XCTAssertEqual(envelope.type, .serviceAnnounce)
        XCTAssertEqual(envelope.senderID, "p1")

        let decoded = try envelope.unwrap(as: ServiceAnnounce.self)
        XCTAssertEqual(decoded.providerID, "p1")
        XCTAssertEqual(decoded.providerName, "TestMac")
    }

    func testEnvelopeSerializeDeserialize() throws {
        let announce = ServiceAnnounce(providerID: "p1", providerName: "TestMac")
        let envelope = try MessageEnvelope.wrap(
            type: .serviceAnnounce, senderID: "p1", payload: announce
        )

        let data = try envelope.serialized()
        let restored = try MessageEnvelope.deserialize(from: data)

        XCTAssertEqual(restored.type, .serviceAnnounce)
        XCTAssertEqual(restored.messageID, envelope.messageID)
        XCTAssertEqual(restored.senderID, "p1")
    }

    // MARK: - ServiceAnnounce

    func testServiceAnnounceRoundTrip() throws {
        let original = ServiceAnnounce(
            providerID: "p1",
            providerName: "TestMac",
            modelTier: "small-text-v1",
            supportedTasks: [.translate, .summarize],
            pricing: Pricing(small: 3, medium: 5, large: 8),
            available: true,
            queueDepth: 2,
            providerPubkey: "abc123base64"
        )

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(ServiceAnnounce.self, from: data)

        XCTAssertEqual(decoded.providerID, "p1")
        XCTAssertEqual(decoded.providerName, "TestMac")
        XCTAssertEqual(decoded.supportedTasks, [.translate, .summarize])
        XCTAssertEqual(decoded.pricing.small, 3)
        XCTAssertEqual(decoded.pricing.large, 8)
        XCTAssertEqual(decoded.queueDepth, 2)
        XCTAssertEqual(decoded.providerPubkey, "abc123base64")
    }

    // MARK: - PromptRequest

    func testPromptRequestRoundTrip() throws {
        let grant = SessionGrant(
            sessionID: "s1", userPubkey: "pk1", providerID: "p1",
            maxCredits: 50, expiresAt: Date(timeIntervalSince1970: 1800000000),
            backendSignature: "sig1"
        )
        let original = PromptRequest(
            requestID: "r1",
            sessionID: "s1",
            taskType: .translate,
            promptText: "Hello world",
            parameters: PromptRequest.Parameters(targetLanguage: "es"),
            maxOutputTokens: 256,
            sessionGrant: grant
        )

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(PromptRequest.self, from: data)

        XCTAssertEqual(decoded.requestID, "r1")
        XCTAssertEqual(decoded.sessionID, "s1")
        XCTAssertEqual(decoded.taskType, .translate)
        XCTAssertEqual(decoded.promptText, "Hello world")
        XCTAssertEqual(decoded.parameters.targetLanguage, "es")
        XCTAssertNil(decoded.parameters.style)
        XCTAssertEqual(decoded.maxOutputTokens, 256)
        XCTAssertEqual(decoded.sessionGrant?.sessionID, "s1")
        XCTAssertEqual(decoded.sessionGrant?.maxCredits, 50)
    }

    func testPromptRequestWithoutGrant() throws {
        let original = PromptRequest(
            sessionID: "s1", taskType: .rewrite, promptText: "Fix this",
            parameters: PromptRequest.Parameters(style: "formal")
        )

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(PromptRequest.self, from: data)

        XCTAssertNil(decoded.sessionGrant)
        XCTAssertEqual(decoded.parameters.style, "formal")
    }

    // MARK: - QuoteResponse

    func testQuoteResponseRoundTrip() throws {
        let expiry = Date(timeIntervalSince1970: 1800000000)
        let original = QuoteResponse(
            requestID: "r1", quoteID: "q1",
            priceCredits: 5, priceTier: "medium", expiresAt: expiry
        )

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(QuoteResponse.self, from: data)

        XCTAssertEqual(decoded.requestID, "r1")
        XCTAssertEqual(decoded.quoteID, "q1")
        XCTAssertEqual(decoded.priceCredits, 5)
        XCTAssertEqual(decoded.priceTier, "medium")
        XCTAssertEqual(decoded.expiresAt, expiry)
    }

    // MARK: - InferenceResponse

    func testInferenceResponseRoundTrip() throws {
        let receipt = Receipt(
            receiptID: "rec1", sessionID: "s1", requestID: "r1",
            providerID: "p1", creditsCharged: 5, cumulativeSpend: 15,
            timestamp: Date(timeIntervalSince1970: 1800000000),
            providerSignature: "recsig"
        )
        let original = InferenceResponse(
            requestID: "r1", outputText: "Hola mundo",
            creditsCharged: 5, cumulativeSpend: 15, receipt: receipt
        )

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(InferenceResponse.self, from: data)

        XCTAssertEqual(decoded.requestID, "r1")
        XCTAssertEqual(decoded.outputText, "Hola mundo")
        XCTAssertEqual(decoded.creditsCharged, 5)
        XCTAssertEqual(decoded.receipt.receiptID, "rec1")
        XCTAssertEqual(decoded.receipt.providerSignature, "recsig")
    }

    // MARK: - ErrorResponse

    func testErrorResponseRoundTrip() throws {
        let original = ErrorResponse(
            requestID: "r1",
            errorCode: .insufficientCredits,
            errorMessage: "Not enough credits"
        )

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(ErrorResponse.self, from: data)

        XCTAssertEqual(decoded.requestID, "r1")
        XCTAssertEqual(decoded.errorCode, .insufficientCredits)
        XCTAssertEqual(decoded.errorMessage, "Not enough credits")
    }

    func testErrorResponseNilRequestID() throws {
        let original = ErrorResponse(
            requestID: nil,
            errorCode: .providerBusy,
            errorMessage: "Try again later"
        )

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(ErrorResponse.self, from: data)

        XCTAssertNil(decoded.requestID)
        XCTAssertEqual(decoded.errorCode, .providerBusy)
    }

    // MARK: - SessionGrant

    func testSessionGrantRoundTrip() throws {
        let expiry = Date(timeIntervalSince1970: 1800000000)
        let original = SessionGrant(
            sessionID: "s1", userPubkey: "pk1", providerID: "p1",
            maxCredits: 100, expiresAt: expiry, backendSignature: "bsig"
        )

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(SessionGrant.self, from: data)

        XCTAssertEqual(decoded.sessionID, "s1")
        XCTAssertEqual(decoded.userPubkey, "pk1")
        XCTAssertEqual(decoded.maxCredits, 100)
        XCTAssertEqual(decoded.expiresAt, expiry)
    }

    func testSessionGrantSignableFields() {
        let expiry = Date(timeIntervalSince1970: 1800000000)
        let grant = SessionGrant(
            sessionID: "s1", userPubkey: "pk1", providerID: "p1",
            maxCredits: 100, expiresAt: expiry, backendSignature: "bsig"
        )

        let fields = grant.signableFields
        XCTAssertEqual(fields[0], "s1")
        XCTAssertEqual(fields[1], "pk1")
        XCTAssertEqual(fields[2], "p1")
        XCTAssertEqual(fields[3], "100")
        XCTAssertEqual(fields[4], ISO8601DateFormatter().string(from: expiry))
    }

    // MARK: - Receipt

    func testReceiptSignableFields() {
        let ts = Date(timeIntervalSince1970: 1800000000)
        let receipt = Receipt(
            receiptID: "rec1", sessionID: "s1", requestID: "r1",
            providerID: "p1", creditsCharged: 5, cumulativeSpend: 15,
            timestamp: ts, providerSignature: "sig"
        )

        let fields = receipt.signableFields
        XCTAssertEqual(fields, [
            "rec1", "s1", "r1", "p1", "5", "15",
            ISO8601DateFormatter().string(from: ts)
        ])
    }

    // MARK: - SpendState

    func testSpendStateAdvance() {
        var state = SpendState(sessionID: "s1")
        XCTAssertEqual(state.cumulativeSpend, 0)
        XCTAssertEqual(state.sequenceNumber, 0)

        state.advance(creditsCharged: 5)
        XCTAssertEqual(state.cumulativeSpend, 5)
        XCTAssertEqual(state.sequenceNumber, 1)

        state.advance(creditsCharged: 3)
        XCTAssertEqual(state.cumulativeSpend, 8)
        XCTAssertEqual(state.sequenceNumber, 2)
    }

    // MARK: - MessageEnvelope with all types

    func testEnvelopeWithPromptRequest() throws {
        let req = PromptRequest(sessionID: "s1", taskType: .summarize, promptText: "Long text here")
        let envelope = try MessageEnvelope.wrap(type: .promptRequest, senderID: "client-1", payload: req)

        let data = try envelope.serialized()
        let restored = try MessageEnvelope.deserialize(from: data)

        XCTAssertEqual(restored.type, .promptRequest)
        let decoded = try restored.unwrap(as: PromptRequest.self)
        XCTAssertEqual(decoded.taskType, .summarize)
    }

    func testEnvelopeWithErrorResponse() throws {
        let err = ErrorResponse(requestID: "r1", errorCode: .sessionExpired, errorMessage: "Expired")
        let envelope = try MessageEnvelope.wrap(type: .errorResponse, senderID: "p1", payload: err)

        let data = try envelope.serialized()
        let restored = try MessageEnvelope.deserialize(from: data)
        let decoded = try restored.unwrap(as: ErrorResponse.self)

        XCTAssertEqual(decoded.errorCode, .sessionExpired)
    }
}
