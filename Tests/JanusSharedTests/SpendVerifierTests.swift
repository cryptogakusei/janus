import XCTest
@testable import JanusShared

final class SpendVerifierTests: XCTestCase {

    // Shared test fixtures
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

    private func makeGrant(
        maxCredits: Int = 100,
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws -> SessionGrant {
        let grant = SessionGrant(
            sessionID: sessionID,
            userPubkey: clientKP.publicKeyBase64,
            providerID: providerID,
            maxCredits: maxCredits,
            expiresAt: expiresAt,
            backendSignature: "" // placeholder, set below
        )
        let signer = JanusSigner(keyPair: backendKP)
        let sig = try signer.sign(fields: grant.signableFields)
        return SessionGrant(
            sessionID: grant.sessionID,
            userPubkey: grant.userPubkey,
            providerID: grant.providerID,
            maxCredits: grant.maxCredits,
            expiresAt: grant.expiresAt,
            backendSignature: sig
        )
    }

    private func makeQuote(
        requestID: String = "request-001",
        priceCredits: Int = 5,
        expiresAt: Date = Date().addingTimeInterval(60)
    ) -> QuoteResponse {
        QuoteResponse(
            requestID: requestID,
            priceCredits: priceCredits,
            priceTier: "medium",
            expiresAt: expiresAt
        )
    }

    private func makeAuthorization(
        requestID: String = "request-001",
        quoteID: String,
        cumulativeSpend: Int,
        sequenceNumber: Int
    ) throws -> SpendAuthorization {
        let auth = SpendAuthorization(
            sessionID: sessionID,
            requestID: requestID,
            quoteID: quoteID,
            cumulativeSpend: cumulativeSpend,
            sequenceNumber: sequenceNumber,
            clientSignature: "" // placeholder
        )
        let signer = JanusSigner(keyPair: clientKP)
        let sig = try signer.sign(fields: auth.signableFields)
        return SpendAuthorization(
            sessionID: auth.sessionID,
            requestID: auth.requestID,
            quoteID: auth.quoteID,
            cumulativeSpend: auth.cumulativeSpend,
            sequenceNumber: auth.sequenceNumber,
            clientSignature: sig
        )
    }

    // MARK: - Happy path

    func testValidSpendAuthorization() throws {
        let grant = try makeGrant()
        let quote = makeQuote()
        let spendState = SpendState(sessionID: sessionID)
        let auth = try makeAuthorization(
            quoteID: quote.quoteID,
            cumulativeSpend: 5,
            sequenceNumber: 1
        )

        let result = try verifier.verify(
            authorization: auth,
            grant: grant,
            spendState: spendState,
            quote: quote
        )

        XCTAssertEqual(result.creditsCharged, 5)
        XCTAssertEqual(result.newCumulativeSpend, 5)
        XCTAssertEqual(result.newSequenceNumber, 1)
    }

    func testMultipleSequentialSpends() throws {
        let grant = try makeGrant(maxCredits: 100)
        var spendState = SpendState(sessionID: sessionID)

        // First spend
        let quote1 = makeQuote(requestID: "req-1", priceCredits: 3)
        let auth1 = try makeAuthorization(
            requestID: "req-1",
            quoteID: quote1.quoteID,
            cumulativeSpend: 3,
            sequenceNumber: 1
        )
        let result1 = try verifier.verify(
            authorization: auth1, grant: grant, spendState: spendState, quote: quote1
        )
        spendState.advance(creditsCharged: result1.creditsCharged)

        // Second spend
        let quote2 = makeQuote(requestID: "req-2", priceCredits: 8)
        let auth2 = try makeAuthorization(
            requestID: "req-2",
            quoteID: quote2.quoteID,
            cumulativeSpend: 11,
            sequenceNumber: 2
        )
        let result2 = try verifier.verify(
            authorization: auth2, grant: grant, spendState: spendState, quote: quote2
        )

        XCTAssertEqual(result2.newCumulativeSpend, 11)
        XCTAssertEqual(result2.newSequenceNumber, 2)
    }

    // MARK: - Check 1: Session exists (ID mismatch)

    func testRejectsWrongSessionID() throws {
        let grant = try makeGrant()
        let quote = makeQuote()
        let spendState = SpendState(sessionID: sessionID)

        // Authorization with wrong session ID
        let wrongAuth = SpendAuthorization(
            sessionID: "wrong-session",
            requestID: "request-001",
            quoteID: quote.quoteID,
            cumulativeSpend: 5,
            sequenceNumber: 1,
            clientSignature: "irrelevant"
        )

        XCTAssertThrowsError(try verifier.verify(
            authorization: wrongAuth, grant: grant, spendState: spendState, quote: quote
        )) { error in
            XCTAssertEqual(error as? VerificationError, .invalidSession)
        }
    }

    // MARK: - Check 2: Session not expired

    func testRejectsExpiredSession() throws {
        let grant = try makeGrant(expiresAt: Date().addingTimeInterval(-1))
        let quote = makeQuote()
        let spendState = SpendState(sessionID: sessionID)
        let auth = try makeAuthorization(
            quoteID: quote.quoteID, cumulativeSpend: 5, sequenceNumber: 1
        )

        XCTAssertThrowsError(try verifier.verify(
            authorization: auth, grant: grant, spendState: spendState, quote: quote
        )) { error in
            XCTAssertEqual(error as? VerificationError, .sessionExpired)
        }
    }

    // MARK: - Check 3: Provider match

    func testRejectsWrongProvider() throws {
        // Grant bound to a different provider
        let grant = SessionGrant(
            sessionID: sessionID,
            userPubkey: clientKP.publicKeyBase64,
            providerID: "other-provider",
            maxCredits: 100,
            expiresAt: Date().addingTimeInterval(3600),
            backendSignature: ""
        )
        let signer = JanusSigner(keyPair: backendKP)
        let sig = try signer.sign(fields: grant.signableFields)
        let signedGrant = SessionGrant(
            sessionID: grant.sessionID, userPubkey: grant.userPubkey,
            providerID: grant.providerID, maxCredits: grant.maxCredits,
            expiresAt: grant.expiresAt, backendSignature: sig
        )

        let quote = makeQuote()
        let spendState = SpendState(sessionID: sessionID)
        let auth = try makeAuthorization(
            quoteID: quote.quoteID, cumulativeSpend: 5, sequenceNumber: 1
        )

        XCTAssertThrowsError(try verifier.verify(
            authorization: auth, grant: signedGrant, spendState: spendState, quote: quote
        )) { error in
            XCTAssertEqual(error as? VerificationError, .invalidSession)
        }
    }

    // MARK: - Check 4: Quote expired

    func testRejectsExpiredQuote() throws {
        let grant = try makeGrant()
        let quote = makeQuote(expiresAt: Date().addingTimeInterval(-1))
        let spendState = SpendState(sessionID: sessionID)
        let auth = try makeAuthorization(
            quoteID: quote.quoteID, cumulativeSpend: 5, sequenceNumber: 1
        )

        XCTAssertThrowsError(try verifier.verify(
            authorization: auth, grant: grant, spendState: spendState, quote: quote
        )) { error in
            XCTAssertEqual(error as? VerificationError, .expiredQuote)
        }
    }

    // MARK: - Check 5: Sequence monotonic

    func testRejectsNonMonotonicSequence() throws {
        let grant = try makeGrant()
        let quote = makeQuote()
        var spendState = SpendState(sessionID: sessionID)
        spendState.advance(creditsCharged: 5) // sequence is now 1

        let auth = try makeAuthorization(
            quoteID: quote.quoteID, cumulativeSpend: 10, sequenceNumber: 1 // same as current
        )

        XCTAssertThrowsError(try verifier.verify(
            authorization: auth, grant: grant, spendState: spendState, quote: quote
        )) { error in
            XCTAssertEqual(error as? VerificationError, .sequenceMismatch)
        }
    }

    // MARK: - Check 6: Spend monotonic

    func testRejectsNonMonotonicSpend() throws {
        let grant = try makeGrant()
        let quote = makeQuote(priceCredits: 5)
        var spendState = SpendState(sessionID: sessionID)
        spendState.advance(creditsCharged: 10) // cumulative is now 10

        let auth = try makeAuthorization(
            quoteID: quote.quoteID, cumulativeSpend: 8, sequenceNumber: 2 // less than 10
        )

        XCTAssertThrowsError(try verifier.verify(
            authorization: auth, grant: grant, spendState: spendState, quote: quote
        )) { error in
            XCTAssertEqual(error as? VerificationError, .sequenceMismatch)
        }
    }

    // MARK: - Check 7: Spend increment matches quote

    func testRejectsInsufficientIncrement() throws {
        let grant = try makeGrant()
        let quote = makeQuote(priceCredits: 5)
        let spendState = SpendState(sessionID: sessionID)

        let auth = try makeAuthorization(
            quoteID: quote.quoteID, cumulativeSpend: 3, sequenceNumber: 1 // increment 3 < price 5
        )

        XCTAssertThrowsError(try verifier.verify(
            authorization: auth, grant: grant, spendState: spendState, quote: quote
        )) { error in
            XCTAssertEqual(error as? VerificationError, .insufficientCredits)
        }
    }

    // MARK: - Check 8: Budget sufficient

    func testRejectsOverBudget() throws {
        let grant = try makeGrant(maxCredits: 10)
        let quote = makeQuote(priceCredits: 5)
        var spendState = SpendState(sessionID: sessionID)
        spendState.advance(creditsCharged: 8) // cumulative 8, max 10

        let auth = try makeAuthorization(
            quoteID: quote.quoteID, cumulativeSpend: 13, sequenceNumber: 2 // 13 > max 10
        )

        XCTAssertThrowsError(try verifier.verify(
            authorization: auth, grant: grant, spendState: spendState, quote: quote
        )) { error in
            XCTAssertEqual(error as? VerificationError, .insufficientCredits)
        }
    }

    // MARK: - Check 9: Signature invalid

    func testRejectsInvalidSignature() throws {
        let grant = try makeGrant()
        let quote = makeQuote()
        let spendState = SpendState(sessionID: sessionID)

        // Sign with wrong key
        let wrongKP = JanusKeyPair()
        let wrongSigner = JanusSigner(keyPair: wrongKP)
        let auth = SpendAuthorization(
            sessionID: sessionID,
            requestID: "request-001",
            quoteID: quote.quoteID,
            cumulativeSpend: 5,
            sequenceNumber: 1,
            clientSignature: try wrongSigner.sign(fields: [
                sessionID, "request-001", quote.quoteID, "5", "1"
            ])
        )

        XCTAssertThrowsError(try verifier.verify(
            authorization: auth, grant: grant, spendState: spendState, quote: quote
        )) { error in
            XCTAssertEqual(error as? VerificationError, .invalidSignature)
        }
    }

    // MARK: - Grant verification

    func testVerifyValidGrant() throws {
        let grant = try makeGrant()
        XCTAssertTrue(verifier.verifyGrant(grant))
    }

    func testRejectsTamperedGrant() throws {
        let grant = try makeGrant(maxCredits: 100)
        // Tamper: change maxCredits but keep old signature
        let tampered = SessionGrant(
            sessionID: grant.sessionID,
            userPubkey: grant.userPubkey,
            providerID: grant.providerID,
            maxCredits: 9999,
            expiresAt: grant.expiresAt,
            backendSignature: grant.backendSignature
        )
        XCTAssertFalse(verifier.verifyGrant(tampered))
    }

    func testRejectsGrantForWrongProvider() throws {
        // Grant signed for this provider but verifier checks providerID match
        let grant = SessionGrant(
            sessionID: sessionID,
            userPubkey: clientKP.publicKeyBase64,
            providerID: "wrong-provider",
            maxCredits: 100,
            expiresAt: Date().addingTimeInterval(3600),
            backendSignature: try JanusSigner(keyPair: backendKP).sign(fields: [
                sessionID, clientKP.publicKeyBase64, "wrong-provider", "100",
                ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            ])
        )
        XCTAssertFalse(verifier.verifyGrant(grant))
    }
}

// Equatable for test assertions
extension VerificationError: Equatable {
    public static func == (lhs: VerificationError, rhs: VerificationError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidSession, .invalidSession),
             (.sessionExpired, .sessionExpired),
             (.expiredQuote, .expiredQuote),
             (.sequenceMismatch, .sequenceMismatch),
             (.insufficientCredits, .insufficientCredits),
             (.invalidSignature, .invalidSignature):
            return true
        default:
            return false
        }
    }
}
