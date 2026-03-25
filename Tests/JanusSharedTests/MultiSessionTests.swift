import XCTest
@testable import JanusShared

/// Tests for multi-client session isolation — verifying that multiple
/// simultaneous sessions maintain independent spend state, verification,
/// and settlement without cross-contamination.
final class MultiSessionTests: XCTestCase {

    private var backendKP: JanusKeyPair!
    private var backendSigner: JanusSigner!
    private var providerKP: JanusKeyPair!

    override func setUp() {
        backendKP = JanusKeyPair()
        backendSigner = JanusSigner(keyPair: backendKP)
        providerKP = JanusKeyPair()
    }

    // MARK: - Helpers

    private func makeGrant(sessionID: String, userPubkey: String, providerID: String, maxCredits: Int = 100) -> SessionGrant {
        let grant = SessionGrant(
            sessionID: sessionID, userPubkey: userPubkey, providerID: providerID,
            maxCredits: maxCredits, expiresAt: Date().addingTimeInterval(3600),
            backendSignature: ""
        )
        let sig = (try? backendSigner.sign(fields: grant.signableFields)) ?? ""
        return SessionGrant(
            sessionID: sessionID, userPubkey: userPubkey, providerID: providerID,
            maxCredits: maxCredits, expiresAt: grant.expiresAt, backendSignature: sig
        )
    }

    private func makeAuth(sessionID: String, requestID: String, quoteID: String,
                          cumulativeSpend: Int, sequenceNumber: Int, clientKP: JanusKeyPair) -> SpendAuthorization {
        let auth = SpendAuthorization(
            sessionID: sessionID, requestID: requestID, quoteID: quoteID,
            cumulativeSpend: cumulativeSpend, sequenceNumber: sequenceNumber, clientSignature: ""
        )
        let signer = JanusSigner(keyPair: clientKP)
        let sig = (try? signer.sign(fields: auth.signableFields)) ?? ""
        return SpendAuthorization(
            sessionID: sessionID, requestID: requestID, quoteID: quoteID,
            cumulativeSpend: cumulativeSpend, sequenceNumber: sequenceNumber, clientSignature: sig
        )
    }

    private func makeQuote(requestID: String, price: Int) -> QuoteResponse {
        QuoteResponse(requestID: requestID, priceCredits: price, priceTier: "medium",
                      expiresAt: Date().addingTimeInterval(60))
    }

    // MARK: - Independent spend states

    func testTwoSessionsTrackSpendIndependently() {
        var ledger: [String: SpendState] = [:]
        ledger["sess-A"] = SpendState(sessionID: "sess-A")
        ledger["sess-B"] = SpendState(sessionID: "sess-B")

        ledger["sess-A"]?.advance(creditsCharged: 5)
        ledger["sess-A"]?.advance(creditsCharged: 3)
        ledger["sess-B"]?.advance(creditsCharged: 10)

        XCTAssertEqual(ledger["sess-A"]?.cumulativeSpend, 8)
        XCTAssertEqual(ledger["sess-A"]?.sequenceNumber, 2)
        XCTAssertEqual(ledger["sess-B"]?.cumulativeSpend, 10)
        XCTAssertEqual(ledger["sess-B"]?.sequenceNumber, 1)
    }

    func testSpendInOneSessionDoesNotAffectAnother() {
        var ledger: [String: SpendState] = [:]
        ledger["sess-A"] = SpendState(sessionID: "sess-A")
        ledger["sess-B"] = SpendState(sessionID: "sess-B")

        // Exhaust sess-A's budget tracking
        for _ in 0..<20 {
            ledger["sess-A"]?.advance(creditsCharged: 5)
        }

        // sess-B should still be at zero
        XCTAssertEqual(ledger["sess-A"]?.cumulativeSpend, 100)
        XCTAssertEqual(ledger["sess-B"]?.cumulativeSpend, 0)
        XCTAssertEqual(ledger["sess-B"]?.sequenceNumber, 0)
    }

    // MARK: - Independent verification

    func testVerifierAcceptsTwoClientsOnSameProvider() throws {
        let providerID = "prov-1"
        let verifier = try SpendVerifier(providerID: providerID, backendPublicKeyBase64: backendKP.publicKeyBase64)

        let clientA = JanusKeyPair()
        let clientB = JanusKeyPair()

        let grantA = makeGrant(sessionID: "sess-A", userPubkey: clientA.publicKeyBase64, providerID: providerID)
        let grantB = makeGrant(sessionID: "sess-B", userPubkey: clientB.publicKeyBase64, providerID: providerID)

        // Both grants should verify
        XCTAssertTrue(verifier.verifyGrant(grantA))
        XCTAssertTrue(verifier.verifyGrant(grantB))

        // Client A spends
        let quoteA = makeQuote(requestID: "req-A1", price: 5)
        let authA = makeAuth(sessionID: "sess-A", requestID: "req-A1", quoteID: quoteA.quoteID,
                             cumulativeSpend: 5, sequenceNumber: 1, clientKP: clientA)
        let stateA = SpendState(sessionID: "sess-A")

        let resultA = try verifier.verify(authorization: authA, grant: grantA, spendState: stateA, quote: quoteA)
        XCTAssertEqual(resultA.creditsCharged, 5)

        // Client B spends (independently)
        let quoteB = makeQuote(requestID: "req-B1", price: 8)
        let authB = makeAuth(sessionID: "sess-B", requestID: "req-B1", quoteID: quoteB.quoteID,
                             cumulativeSpend: 8, sequenceNumber: 1, clientKP: clientB)
        let stateB = SpendState(sessionID: "sess-B")

        let resultB = try verifier.verify(authorization: authB, grant: grantB, spendState: stateB, quote: quoteB)
        XCTAssertEqual(resultB.creditsCharged, 8)
    }

    func testClientACantSpendOnClientBSession() throws {
        let providerID = "prov-1"
        let verifier = try SpendVerifier(providerID: providerID, backendPublicKeyBase64: backendKP.publicKeyBase64)

        let clientA = JanusKeyPair()
        let clientB = JanusKeyPair()

        // Grant B is for client B's pubkey
        let grantB = makeGrant(sessionID: "sess-B", userPubkey: clientB.publicKeyBase64, providerID: providerID)

        // Client A tries to spend on session B
        let quote = makeQuote(requestID: "req-evil", price: 5)
        let authEvil = makeAuth(sessionID: "sess-B", requestID: "req-evil", quoteID: quote.quoteID,
                                cumulativeSpend: 5, sequenceNumber: 1, clientKP: clientA)
        let stateB = SpendState(sessionID: "sess-B")

        // Should fail — client A's signature won't verify against client B's pubkey in the grant
        XCTAssertThrowsError(try verifier.verify(authorization: authEvil, grant: grantB, spendState: stateB, quote: quote)) { error in
            XCTAssertTrue(error is VerificationError)
        }
    }

    // MARK: - Independent settlement

    func testSettlementTracksPerSession() {
        var settledSpends: [String: Int] = [:]
        let ledger: [String: SpendState] = [
            "sess-A": { var s = SpendState(sessionID: "sess-A"); s.advance(creditsCharged: 15); return s }(),
            "sess-B": { var s = SpendState(sessionID: "sess-B"); s.advance(creditsCharged: 30); return s }(),
        ]

        // Settle session A
        settledSpends["sess-A"] = ledger["sess-A"]!.cumulativeSpend

        // Session A is settled, session B is not
        XCTAssertEqual(settledSpends["sess-A"], 15)
        XCTAssertNil(settledSpends["sess-B"])

        // Check which sessions need settlement
        let needsSettlement = ledger.filter { sessionID, spend in
            spend.cumulativeSpend > (settledSpends[sessionID] ?? 0)
        }
        XCTAssertEqual(needsSettlement.count, 1)
        XCTAssertNotNil(needsSettlement["sess-B"])
    }

    func testReSettlementAfterMoreSpend() {
        var settledSpends: [String: Int] = ["sess-A": 10]
        var stateA = SpendState(sessionID: "sess-A")
        // Simulate: already spent 10, now spend 5 more
        stateA.advance(creditsCharged: 10)
        stateA.advance(creditsCharged: 5)

        // Should need re-settlement: 15 > 10
        XCTAssertTrue(stateA.cumulativeSpend > (settledSpends["sess-A"] ?? 0))

        // After re-settlement
        settledSpends["sess-A"] = stateA.cumulativeSpend
        XCTAssertEqual(settledSpends["sess-A"], 15)

        // No more settlement needed
        XCTAssertFalse(stateA.cumulativeSpend > (settledSpends["sess-A"] ?? 0))
    }

    // MARK: - Independent receipts

    func testReceiptsFromDifferentSessionsVerifyIndependently() throws {
        let providerSigner = JanusSigner(keyPair: providerKP)
        let verifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)

        // Receipt for session A
        let receiptA = Receipt(sessionID: "sess-A", requestID: "req-A1", providerID: "prov-1",
                               creditsCharged: 5, cumulativeSpend: 5, providerSignature: "")
        let sigA = try providerSigner.sign(fields: receiptA.signableFields)
        let signedA = Receipt(receiptID: receiptA.receiptID, sessionID: "sess-A", requestID: "req-A1",
                              providerID: "prov-1", creditsCharged: 5, cumulativeSpend: 5,
                              timestamp: receiptA.timestamp, providerSignature: sigA)

        // Receipt for session B
        let receiptB = Receipt(sessionID: "sess-B", requestID: "req-B1", providerID: "prov-1",
                               creditsCharged: 8, cumulativeSpend: 8, providerSignature: "")
        let sigB = try providerSigner.sign(fields: receiptB.signableFields)
        let signedB = Receipt(receiptID: receiptB.receiptID, sessionID: "sess-B", requestID: "req-B1",
                              providerID: "prov-1", creditsCharged: 8, cumulativeSpend: 8,
                              timestamp: receiptB.timestamp, providerSignature: sigB)

        // Both verify
        XCTAssertTrue(verifier.verify(signature: signedA.providerSignature, fields: signedA.signableFields))
        XCTAssertTrue(verifier.verify(signature: signedB.providerSignature, fields: signedB.signableFields))

        // Cross-check: A's signature doesn't verify B's fields
        XCTAssertFalse(verifier.verify(signature: signedA.providerSignature, fields: signedB.signableFields))
    }

    // MARK: - Persistence with multiple sessions

    func testProviderStatePersistsMultipleSessions() throws {
        let store = JanusStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))

        let state = PersistedProviderState(
            providerID: "prov-1",
            privateKeyBase64: providerKP.privateKeyBase64,
            knownSessions: [
                "sess-A": makeGrant(sessionID: "sess-A", userPubkey: "pubA", providerID: "prov-1"),
                "sess-B": makeGrant(sessionID: "sess-B", userPubkey: "pubB", providerID: "prov-1"),
            ],
            spendLedger: [
                "sess-A": { var s = SpendState(sessionID: "sess-A"); s.advance(creditsCharged: 10); return s }(),
                "sess-B": { var s = SpendState(sessionID: "sess-B"); s.advance(creditsCharged: 25); return s }(),
            ],
            settledSpends: ["sess-A": 10]
        )

        try store.save(state, as: "test_multi.json")
        let loaded = store.load(PersistedProviderState.self, from: "test_multi.json")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.knownSessions.count, 2)
        XCTAssertEqual(loaded?.spendLedger["sess-A"]?.cumulativeSpend, 10)
        XCTAssertEqual(loaded?.spendLedger["sess-B"]?.cumulativeSpend, 25)
        XCTAssertEqual(loaded?.settledSpends["sess-A"], 10)
        XCTAssertNil(loaded?.settledSpends["sess-B"])

        store.delete("test_multi.json")
    }
}
