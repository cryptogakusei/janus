import XCTest
@testable import JanusShared

/// Tests for multi-client session isolation — verifying that multiple
/// simultaneous sessions maintain independent spend state and receipts.
final class MultiSessionTests: XCTestCase {

    private var providerKP: JanusKeyPair!

    override func setUp() {
        providerKP = JanusKeyPair()
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

    // MARK: - Provider state persistence

    func testProviderStatePersistsCorrectly() throws {
        let store = JanusStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))

        let state = PersistedProviderState(
            providerID: "prov-1",
            privateKeyBase64: providerKP.privateKeyBase64,
            receiptsIssued: [],
            totalRequestsServed: 5,
            totalCreditsEarned: 35
        )

        try store.save(state, as: "test_multi.json")
        let loaded = store.load(PersistedProviderState.self, from: "test_multi.json")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.providerID, "prov-1")
        XCTAssertEqual(loaded?.totalRequestsServed, 5)
        XCTAssertEqual(loaded?.totalCreditsEarned, 35)

        store.delete("test_multi.json")
    }
}
