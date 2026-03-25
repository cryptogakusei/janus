import XCTest
@testable import JanusShared

final class SessionSyncTests: XCTestCase {

    // Shared fixtures
    private var backendKP: JanusKeyPair!
    private var clientKP: JanusKeyPair!
    private var providerKP: JanusKeyPair!
    private var verifier: SpendVerifier!
    private let providerID = "provider-001"
    private let sessionID = "session-001"

    override func setUp() {
        super.setUp()
        backendKP = JanusKeyPair()
        clientKP = JanusKeyPair()
        providerKP = JanusKeyPair()
        verifier = try! SpendVerifier(
            providerID: providerID,
            backendPublicKeyBase64: backendKP.publicKeyBase64
        )
    }

    // MARK: - Helpers

    private func makeGrant(maxCredits: Int = 100) throws -> SessionGrant {
        let grant = SessionGrant(
            sessionID: sessionID, userPubkey: clientKP.publicKeyBase64,
            providerID: providerID, maxCredits: maxCredits,
            expiresAt: Date().addingTimeInterval(3600), backendSignature: ""
        )
        let sig = try JanusSigner(keyPair: backendKP).sign(fields: grant.signableFields)
        return SessionGrant(
            sessionID: grant.sessionID, userPubkey: grant.userPubkey,
            providerID: grant.providerID, maxCredits: grant.maxCredits,
            expiresAt: grant.expiresAt, backendSignature: sig
        )
    }

    private func makeQuote(requestID: String, priceCredits: Int = 5) -> QuoteResponse {
        QuoteResponse(requestID: requestID, priceCredits: priceCredits,
                      priceTier: "medium", expiresAt: Date().addingTimeInterval(60))
    }

    private func makeAuth(requestID: String, quoteID: String,
                          cumulativeSpend: Int, sequenceNumber: Int) throws -> SpendAuthorization {
        let auth = SpendAuthorization(
            sessionID: sessionID, requestID: requestID, quoteID: quoteID,
            cumulativeSpend: cumulativeSpend, sequenceNumber: sequenceNumber, clientSignature: ""
        )
        let sig = try JanusSigner(keyPair: clientKP).sign(fields: auth.signableFields)
        return SpendAuthorization(
            sessionID: auth.sessionID, requestID: auth.requestID, quoteID: auth.quoteID,
            cumulativeSpend: auth.cumulativeSpend, sequenceNumber: auth.sequenceNumber, clientSignature: sig
        )
    }

    private func makeReceipt(requestID: String, creditsCharged: Int,
                             cumulativeSpend: Int, keyPair: JanusKeyPair? = nil) -> Receipt {
        let kp = keyPair ?? providerKP!
        let receipt = Receipt(
            sessionID: sessionID, requestID: requestID, providerID: providerID,
            creditsCharged: creditsCharged, cumulativeSpend: cumulativeSpend, providerSignature: ""
        )
        let sig = (try? JanusSigner(keyPair: kp).sign(fields: receipt.signableFields)) ?? ""
        return Receipt(
            receiptID: receipt.receiptID, sessionID: sessionID, requestID: requestID,
            providerID: providerID, creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeSpend, timestamp: receipt.timestamp, providerSignature: sig
        )
    }

    private func makeInferenceResponse(requestID: String, creditsCharged: Int,
                                       cumulativeSpend: Int, keyPair: JanusKeyPair? = nil) -> InferenceResponse {
        let receipt = makeReceipt(requestID: requestID, creditsCharged: creditsCharged,
                                  cumulativeSpend: cumulativeSpend, keyPair: keyPair)
        return InferenceResponse(
            requestID: requestID, outputText: "test output",
            creditsCharged: creditsCharged, cumulativeSpend: cumulativeSpend, receipt: receipt
        )
    }

    // MARK: - SessionSync encode/decode

    func testSessionSyncRoundTrip() throws {
        let response = makeInferenceResponse(requestID: "req-1", creditsCharged: 5, cumulativeSpend: 5)
        let sync = SessionSync(sessionID: sessionID, missedResponse: response)

        let envelope = try MessageEnvelope.wrap(type: .sessionSync, senderID: providerID, payload: sync)
        let data = try envelope.serialized()
        let restored = try MessageEnvelope.deserialize(from: data)

        XCTAssertEqual(restored.type, .sessionSync)
        let decoded = try restored.unwrap(as: SessionSync.self)
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.missedResponse.requestID, "req-1")
        XCTAssertEqual(decoded.missedResponse.creditsCharged, 5)
        XCTAssertEqual(decoded.missedResponse.cumulativeSpend, 5)
        XCTAssertEqual(decoded.missedResponse.outputText, "test output")
    }

    // MARK: - Full divergence → sync → recovery scenario

    func testDivergenceAndRecovery() throws {
        let grant = try makeGrant()
        var providerSpend = SpendState(sessionID: sessionID)
        var clientSpend = SpendState(sessionID: sessionID)

        // Request 1: both sides complete successfully
        let quote1 = makeQuote(requestID: "req-1", priceCredits: 5)
        let auth1 = try makeAuth(requestID: "req-1", quoteID: quote1.quoteID,
                                 cumulativeSpend: 5, sequenceNumber: 1)
        let result1 = try verifier.verify(authorization: auth1, grant: grant,
                                          spendState: providerSpend, quote: quote1)
        providerSpend.advance(creditsCharged: result1.creditsCharged)
        clientSpend.advance(creditsCharged: result1.creditsCharged)
        // Both at seq 1, spend 5

        // Request 2: provider completes, but client never gets the response
        let quote2 = makeQuote(requestID: "req-2", priceCredits: 3)
        let auth2 = try makeAuth(requestID: "req-2", quoteID: quote2.quoteID,
                                 cumulativeSpend: 8, sequenceNumber: 2)
        let result2 = try verifier.verify(authorization: auth2, grant: grant,
                                          spendState: providerSpend, quote: quote2)
        providerSpend.advance(creditsCharged: result2.creditsCharged)
        // Provider at seq 2, spend 8
        // Client still at seq 1, spend 5 (never got response)

        XCTAssertEqual(providerSpend.sequenceNumber, 2)
        XCTAssertEqual(providerSpend.cumulativeSpend, 8)
        XCTAssertEqual(clientSpend.sequenceNumber, 1)
        XCTAssertEqual(clientSpend.cumulativeSpend, 5)

        // Client tries request 3 with stale state — should fail with sequenceMismatch
        let quote3 = makeQuote(requestID: "req-3", priceCredits: 5)
        let staleAuth = try makeAuth(requestID: "req-3", quoteID: quote3.quoteID,
                                     cumulativeSpend: 10, sequenceNumber: 2)
        XCTAssertThrowsError(try verifier.verify(
            authorization: staleAuth, grant: grant, spendState: providerSpend, quote: quote3
        )) { error in
            XCTAssertEqual(error as? VerificationError, .sequenceMismatch)
        }

        // Client syncs state from the missed response
        let missedResponse = makeInferenceResponse(requestID: "req-2", creditsCharged: 3, cumulativeSpend: 8)
        clientSpend = SpendState(sessionID: sessionID,
                                 cumulativeSpend: missedResponse.cumulativeSpend,
                                 sequenceNumber: clientSpend.sequenceNumber + 1)
        // Client now at seq 2, spend 8 — matches provider

        XCTAssertEqual(clientSpend.sequenceNumber, providerSpend.sequenceNumber)
        XCTAssertEqual(clientSpend.cumulativeSpend, providerSpend.cumulativeSpend)

        // Client retries request 3 with correct state — should succeed
        let retryAuth = try makeAuth(requestID: "req-3", quoteID: quote3.quoteID,
                                     cumulativeSpend: 13, sequenceNumber: 3)
        let result3 = try verifier.verify(authorization: retryAuth, grant: grant,
                                          spendState: providerSpend, quote: quote3)
        XCTAssertEqual(result3.creditsCharged, 5)
        XCTAssertEqual(result3.newCumulativeSpend, 13)
        XCTAssertEqual(result3.newSequenceNumber, 3)
    }

    // MARK: - Receipt verification in sync

    func testSyncReceiptSignatureValid() throws {
        let receipt = makeReceipt(requestID: "req-1", creditsCharged: 5, cumulativeSpend: 5)
        let providerVerifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)
        XCTAssertTrue(providerVerifier.verify(signature: receipt.providerSignature,
                                              fields: receipt.signableFields))
    }

    func testSyncReceiptRejectsWrongSigner() throws {
        let wrongKP = JanusKeyPair()
        let receipt = makeReceipt(requestID: "req-1", creditsCharged: 5,
                                  cumulativeSpend: 5, keyPair: wrongKP)
        let providerVerifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)
        XCTAssertFalse(providerVerifier.verify(signature: receipt.providerSignature,
                                               fields: receipt.signableFields))
    }

    func testSyncReceiptRejectsTamperedAmount() throws {
        let receipt = makeReceipt(requestID: "req-1", creditsCharged: 5, cumulativeSpend: 5)
        // Tamper: change creditsCharged but keep original signature
        let tampered = Receipt(
            receiptID: receipt.receiptID, sessionID: sessionID, requestID: "req-1",
            providerID: providerID, creditsCharged: 50, cumulativeSpend: 50,
            timestamp: receipt.timestamp, providerSignature: receipt.providerSignature
        )
        let providerVerifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)
        XCTAssertFalse(providerVerifier.verify(signature: tampered.providerSignature,
                                               fields: tampered.signableFields))
    }

    // MARK: - Edge cases

    func testSyncDoesNotAllowSpendBeyondBudget() throws {
        let grant = try makeGrant(maxCredits: 10)
        var providerSpend = SpendState(sessionID: sessionID)

        // Request 1 succeeds (5 credits)
        let quote1 = makeQuote(requestID: "req-1", priceCredits: 5)
        let auth1 = try makeAuth(requestID: "req-1", quoteID: quote1.quoteID,
                                 cumulativeSpend: 5, sequenceNumber: 1)
        let result1 = try verifier.verify(authorization: auth1, grant: grant,
                                          spendState: providerSpend, quote: quote1)
        providerSpend.advance(creditsCharged: result1.creditsCharged)

        // Request 2 succeeds (5 more = 10 total, at budget limit)
        let quote2 = makeQuote(requestID: "req-2", priceCredits: 5)
        let auth2 = try makeAuth(requestID: "req-2", quoteID: quote2.quoteID,
                                 cumulativeSpend: 10, sequenceNumber: 2)
        let result2 = try verifier.verify(authorization: auth2, grant: grant,
                                          spendState: providerSpend, quote: quote2)
        providerSpend.advance(creditsCharged: result2.creditsCharged)

        // After sync, client tries to spend more but budget is exhausted
        let quote3 = makeQuote(requestID: "req-3", priceCredits: 3)
        let auth3 = try makeAuth(requestID: "req-3", quoteID: quote3.quoteID,
                                 cumulativeSpend: 13, sequenceNumber: 3)
        XCTAssertThrowsError(try verifier.verify(
            authorization: auth3, grant: grant, spendState: providerSpend, quote: quote3
        )) { error in
            XCTAssertEqual(error as? VerificationError, .insufficientCredits)
        }
    }
}
