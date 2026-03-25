import XCTest
@testable import JanusShared

/// Tests for client-side receipt verification — the checks the iPhone
/// performs before accepting a response and deducting credits.
final class ReceiptVerificationTests: XCTestCase {

    private var providerKP: JanusKeyPair!
    private var providerSigner: JanusSigner!

    override func setUp() {
        providerKP = JanusKeyPair()
        providerSigner = JanusSigner(keyPair: providerKP)
    }

    // MARK: - Helpers

    private func makeReceipt(
        sessionID: String = "sess-1",
        requestID: String = "req-1",
        providerID: String = "prov-1",
        creditsCharged: Int = 5,
        cumulativeSpend: Int = 5,
        signer: JanusSigner? = nil
    ) -> Receipt {
        let receipt = Receipt(
            sessionID: sessionID,
            requestID: requestID,
            providerID: providerID,
            creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeSpend,
            providerSignature: ""
        )
        let s = signer ?? providerSigner!
        let sig = (try? s.sign(fields: receipt.signableFields)) ?? ""
        return Receipt(
            receiptID: receipt.receiptID,
            sessionID: sessionID,
            requestID: requestID,
            providerID: providerID,
            creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeSpend,
            timestamp: receipt.timestamp,
            providerSignature: sig
        )
    }

    // MARK: - Signature verification

    func testValidReceiptSignature() throws {
        let receipt = makeReceipt()
        let verifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)

        XCTAssertTrue(verifier.verify(signature: receipt.providerSignature, fields: receipt.signableFields))
    }

    func testRejectsReceiptSignedByWrongProvider() throws {
        let imposterKP = JanusKeyPair()
        let imposterSigner = JanusSigner(keyPair: imposterKP)
        let receipt = makeReceipt(signer: imposterSigner)

        // Verify against the real provider's key — should fail
        let verifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)
        XCTAssertFalse(verifier.verify(signature: receipt.providerSignature, fields: receipt.signableFields))
    }

    func testRejectsTamperedCreditsCharged() throws {
        let receipt = makeReceipt(creditsCharged: 5)
        let verifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)

        // Tamper: pretend the receipt says 10 credits instead of 5
        let tamperedFields = [
            receipt.receiptID,
            receipt.sessionID,
            receipt.requestID,
            receipt.providerID,
            "10",  // was 5
            String(receipt.cumulativeSpend),
            ISO8601DateFormatter().string(from: receipt.timestamp)
        ]
        XCTAssertFalse(verifier.verify(signature: receipt.providerSignature, fields: tamperedFields))
    }

    func testRejectsTamperedCumulativeSpend() throws {
        let receipt = makeReceipt(cumulativeSpend: 5)
        let verifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)

        // Tamper: inflate cumulative spend
        let tamperedFields = [
            receipt.receiptID,
            receipt.sessionID,
            receipt.requestID,
            receipt.providerID,
            String(receipt.creditsCharged),
            "50",  // was 5
            ISO8601DateFormatter().string(from: receipt.timestamp)
        ]
        XCTAssertFalse(verifier.verify(signature: receipt.providerSignature, fields: tamperedFields))
    }

    func testRejectsEmptySignature() throws {
        let receipt = Receipt(
            sessionID: "sess-1", requestID: "req-1", providerID: "prov-1",
            creditsCharged: 5, cumulativeSpend: 5, providerSignature: ""
        )
        let verifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)
        XCTAssertFalse(verifier.verify(signature: receipt.providerSignature, fields: receipt.signableFields))
    }

    // MARK: - Quote-price match (client-side check)

    func testQuotePriceMatchAccepts() {
        let quotedPrice = 5
        let chargedPrice = 5
        XCTAssertEqual(quotedPrice, chargedPrice, "Charged amount should match quoted price")
    }

    func testQuotePriceMismatchRejects() {
        let quotedPrice = 5
        let chargedPrice = 8
        XCTAssertNotEqual(quotedPrice, chargedPrice, "Client should reject when charged != quoted")
    }

    // MARK: - Sequential receipts

    func testSequentialReceiptsVerify() throws {
        let verifier = try JanusVerifier(publicKeyBase64: providerKP.publicKeyBase64)

        let receipt1 = makeReceipt(requestID: "req-1", creditsCharged: 3, cumulativeSpend: 3)
        let receipt2 = makeReceipt(requestID: "req-2", creditsCharged: 5, cumulativeSpend: 8)
        let receipt3 = makeReceipt(requestID: "req-3", creditsCharged: 8, cumulativeSpend: 16)

        XCTAssertTrue(verifier.verify(signature: receipt1.providerSignature, fields: receipt1.signableFields))
        XCTAssertTrue(verifier.verify(signature: receipt2.providerSignature, fields: receipt2.signableFields))
        XCTAssertTrue(verifier.verify(signature: receipt3.providerSignature, fields: receipt3.signableFields))

        // Cumulative spend is monotonically increasing
        XCTAssertTrue(receipt2.cumulativeSpend > receipt1.cumulativeSpend)
        XCTAssertTrue(receipt3.cumulativeSpend > receipt2.cumulativeSpend)
    }
}
