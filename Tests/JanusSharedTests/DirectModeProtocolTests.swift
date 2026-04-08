import XCTest
@testable import JanusShared

/// Regression tests for the direct-connection protocol flow.
///
/// Simulates the full message sequence without MPC transport to verify
/// that relay protocol additions haven't broken the direct path.
final class DirectModeProtocolTests: XCTestCase {

    private var clientKP: EthKeyPair!
    private var providerKP: EthKeyPair!
    private var providerJanusKP: JanusKeyPair!
    private var config: TempoConfig!
    private var channel: Channel!
    private var verifier: VoucherVerifier!

    override func setUp() {
        super.setUp()
        clientKP = try! EthKeyPair()
        providerKP = try! EthKeyPair()
        providerJanusKP = JanusKeyPair()
        config = TempoConfig.testnet

        let salt = Keccak256.hash(Data("direct-regression".utf8))
        channel = Channel(
            payer: clientKP.address,
            payee: providerKP.address,
            token: EthAddress(Data(repeating: 0, count: 20)),
            salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 100,
            config: config
        )
        verifier = VoucherVerifier(providerAddress: providerKP.address, config: config)
    }

    // MARK: - Helpers

    private func makeQuote(requestID: String, priceCredits: Int = 5) -> QuoteResponse {
        QuoteResponse(requestID: requestID, priceCredits: priceCredits,
                      priceTier: "medium", expiresAt: Date().addingTimeInterval(60))
    }

    private func makeAuth(requestID: String, quoteID: String,
                          cumulativeAmount: UInt64) throws -> VoucherAuthorization {
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: cumulativeAmount)
        let signed = try voucher.sign(with: clientKP, config: config)
        return VoucherAuthorization(requestID: requestID, quoteID: quoteID, signedVoucher: signed)
    }

    private func makeReceipt(sessionID: String, requestID: String, providerID: String,
                             creditsCharged: Int, cumulativeSpend: Int) -> Receipt {
        let signer = JanusSigner(keyPair: providerJanusKP)
        let receiptID = UUID().uuidString
        let timestamp = Date()
        // Build signable fields manually to sign before creating the receipt
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

    // MARK: - Full direct flow

    func testFullDirectFlow_PromptToReceipt() throws {
        let sessionID = "sess-direct-1"
        let providerID = "prov-1"

        // 1. Client sends PromptRequest
        let prompt = PromptRequest(
            sessionID: sessionID,
            taskType: .translate,
            promptText: "Hello world",
            parameters: PromptRequest.Parameters(targetLanguage: "es")
        )
        let promptEnv = try MessageEnvelope.wrap(type: .promptRequest, senderID: sessionID, payload: prompt)
        let promptData = try promptEnv.serialized()
        let promptRestored = try MessageEnvelope.deserialize(from: promptData)
        let decodedPrompt = try promptRestored.unwrap(as: PromptRequest.self)
        XCTAssertEqual(decodedPrompt.taskType, TaskType.translate)
        XCTAssertEqual(decodedPrompt.promptText, "Hello world")

        // 2. Provider sends QuoteResponse
        let quote = makeQuote(requestID: prompt.requestID, priceCredits: 3)
        let quoteEnv = try MessageEnvelope.wrap(type: .quoteResponse, senderID: providerID, payload: quote)
        let quoteData = try quoteEnv.serialized()
        let quoteRestored = try MessageEnvelope.deserialize(from: quoteData)
        let decodedQuote = try quoteRestored.unwrap(as: QuoteResponse.self)
        XCTAssertEqual(decodedQuote.requestID, prompt.requestID)
        XCTAssertEqual(decodedQuote.priceCredits, 3)

        // 3. Client sends VoucherAuthorization
        let auth = try makeAuth(requestID: prompt.requestID, quoteID: quote.quoteID, cumulativeAmount: 3)
        let authEnv = try MessageEnvelope.wrap(type: .voucherAuthorization, senderID: sessionID, payload: auth)
        let authData = try authEnv.serialized()
        let authRestored = try MessageEnvelope.deserialize(from: authData)
        let decodedAuth = try authRestored.unwrap(as: VoucherAuthorization.self)
        XCTAssertEqual(decodedAuth.cumulativeAmount, 3)

        // 4. Provider verifies voucher
        let result = try verifier.verify(authorization: decodedAuth, channel: channel, quote: decodedQuote)
        XCTAssertEqual(result.creditsCharged, 3)
        try channel.acceptVoucher(decodedAuth.signedVoucher)

        // 5. Provider sends InferenceResponse with signed receipt
        let receipt = makeReceipt(
            sessionID: sessionID, requestID: prompt.requestID,
            providerID: providerID, creditsCharged: 3, cumulativeSpend: 3
        )
        let response = InferenceResponse(
            requestID: prompt.requestID,
            outputText: "Hola mundo",
            creditsCharged: 3,
            cumulativeSpend: 3,
            receipt: receipt
        )
        let respEnv = try MessageEnvelope.wrap(type: .inferenceResponse, senderID: providerID, payload: response)
        let respData = try respEnv.serialized()
        let respRestored = try MessageEnvelope.deserialize(from: respData)
        let decodedResp = try respRestored.unwrap(as: InferenceResponse.self)
        XCTAssertEqual(decodedResp.outputText, "Hola mundo")
        XCTAssertEqual(decodedResp.creditsCharged, 3)

        // 6. Client verifies receipt signature
        let receiptVerifier = try JanusVerifier(publicKeyBase64: providerJanusKP.publicKeyBase64)
        XCTAssertTrue(receiptVerifier.verify(
            signature: decodedResp.receipt.providerSignature,
            fields: decodedResp.receipt.signableFields
        ))
    }

    // MARK: - SessionSync recovery

    func testSessionSync_afterMissedResponse() throws {
        let sessionID = "sess-sync-1"
        let providerID = "prov-1"

        // Simulate a response the client missed (e.g., relay died mid-flight)
        let receipt = makeReceipt(
            sessionID: sessionID, requestID: "missed-req",
            providerID: providerID, creditsCharged: 5, cumulativeSpend: 5
        )
        let missedResponse = InferenceResponse(
            requestID: "missed-req",
            outputText: "You missed this",
            creditsCharged: 5,
            cumulativeSpend: 5,
            receipt: receipt
        )

        // Provider sends SessionSync on reconnect
        let sync = SessionSync(sessionID: sessionID, missedResponse: missedResponse)
        let env = try MessageEnvelope.wrap(type: .sessionSync, senderID: providerID, payload: sync)
        let data = try env.serialized()
        let restored = try MessageEnvelope.deserialize(from: data)

        XCTAssertEqual(restored.type, .sessionSync)
        let decodedSync = try restored.unwrap(as: SessionSync.self)
        XCTAssertEqual(decodedSync.sessionID, sessionID)
        XCTAssertEqual(decodedSync.missedResponse.creditsCharged, 5)

        // Client verifies the receipt in the sync message
        let receiptVerifier = try JanusVerifier(publicKeyBase64: providerJanusKP.publicKeyBase64)
        XCTAssertTrue(receiptVerifier.verify(
            signature: decodedSync.missedResponse.receipt.providerSignature,
            fields: decodedSync.missedResponse.receipt.signableFields
        ))

        // Client can reconstruct spend state from the sync
        var spendState = SpendState(sessionID: sessionID)
        spendState.advance(creditsCharged: decodedSync.missedResponse.creditsCharged)
        XCTAssertEqual(spendState.cumulativeSpend, 5)
        XCTAssertEqual(spendState.sequenceNumber, 1)
    }

    // MARK: - Multi-client independence

    func testTwoClientsSequentialRequests_independentReceipts() throws {
        let providerID = "prov-1"

        // Client A setup
        let clientAKP = try EthKeyPair()
        let saltA = Keccak256.hash(Data("client-a".utf8))
        var channelA = Channel(
            payer: clientAKP.address, payee: providerKP.address,
            token: EthAddress(Data(repeating: 0, count: 20)),
            salt: saltA, authorizedSigner: clientAKP.address,
            deposit: 100, config: config
        )

        // Client B setup
        let clientBKP = try EthKeyPair()
        let saltB = Keccak256.hash(Data("client-b".utf8))
        var channelB = Channel(
            payer: clientBKP.address, payee: providerKP.address,
            token: EthAddress(Data(repeating: 0, count: 20)),
            salt: saltB, authorizedSigner: clientBKP.address,
            deposit: 100, config: config
        )

        // Client A request
        let voucherA = Voucher(channelId: channelA.channelId, cumulativeAmount: 5)
        let signedA = try voucherA.sign(with: clientAKP, config: config)
        let quoteA = makeQuote(requestID: "req-a1", priceCredits: 5)
        let authA = VoucherAuthorization(requestID: "req-a1", quoteID: quoteA.quoteID, signedVoucher: signedA)
        _ = try verifier.verify(authorization: authA, channel: channelA, quote: quoteA)
        try channelA.acceptVoucher(signedA)

        // Client B request (interleaved)
        let voucherB = Voucher(channelId: channelB.channelId, cumulativeAmount: 8)
        let signedB = try voucherB.sign(with: clientBKP, config: config)
        let quoteB = makeQuote(requestID: "req-b1", priceCredits: 8)
        let authB = VoucherAuthorization(requestID: "req-b1", quoteID: quoteB.quoteID, signedVoucher: signedB)
        _ = try verifier.verify(authorization: authB, channel: channelB, quote: quoteB)
        try channelB.acceptVoucher(signedB)

        // Verify independence
        XCTAssertEqual(channelA.authorizedAmount, 5)
        XCTAssertEqual(channelB.authorizedAmount, 8)
        XCTAssertNotEqual(channelA.channelId, channelB.channelId)

        // Receipts are independent
        let receiptA = makeReceipt(sessionID: "sess-a", requestID: "req-a1",
                                   providerID: providerID, creditsCharged: 5, cumulativeSpend: 5)
        let receiptB = makeReceipt(sessionID: "sess-b", requestID: "req-b1",
                                   providerID: providerID, creditsCharged: 8, cumulativeSpend: 8)
        XCTAssertNotEqual(receiptA.sessionID, receiptB.sessionID)
        XCTAssertEqual(receiptA.creditsCharged, 5)
        XCTAssertEqual(receiptB.creditsCharged, 8)
    }

    // MARK: - ErrorResponse round-trips

    func testErrorResponse_allCodes_serializeCorrectly() throws {
        let allCodes: [ErrorResponse.ErrorCode] = [
            .invalidSession, .expiredQuote, .insufficientCredits,
            .invalidSignature, .sessionExpired, .providerBusy,
            .sequenceMismatch, .inferenceFailed, .providerUnreachable,
            .relayTimeout
        ]

        for code in allCodes {
            let error = ErrorResponse(requestID: "req-err", errorCode: code, errorMessage: "Test: \(code.rawValue)")
            let env = try MessageEnvelope.wrap(type: .errorResponse, senderID: "prov-1", payload: error)
            let data = try env.serialized()
            let restored = try MessageEnvelope.deserialize(from: data)

            XCTAssertEqual(restored.type, .errorResponse)
            let decoded = try restored.unwrap(as: ErrorResponse.self)
            XCTAssertEqual(decoded.errorCode, code, "Round-trip failed for \(code.rawValue)")
            XCTAssertEqual(decoded.requestID, "req-err")
        }
    }
}
