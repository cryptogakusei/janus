import XCTest
@testable import JanusShared

final class CryptoTests: XCTestCase {

    // MARK: - Key generation

    func testKeyPairGeneration() {
        let kp = JanusKeyPair()
        XCTAssertFalse(kp.publicKeyBase64.isEmpty)
        XCTAssertFalse(kp.privateKeyBase64.isEmpty)
        XCTAssertNotEqual(kp.publicKeyBase64, kp.privateKeyBase64)
    }

    func testKeyPairFromPrivateKey() throws {
        let original = JanusKeyPair()
        let restored = try JanusKeyPair(privateKeyRaw: original.privateKey.rawRepresentation)
        XCTAssertEqual(original.publicKeyBase64, restored.publicKeyBase64)
    }

    func testPublicKeyFromBase64() throws {
        let kp = JanusKeyPair()
        let pubKey = try JanusKeyPair.publicKey(fromBase64: kp.publicKeyBase64)
        XCTAssertEqual(pubKey.rawRepresentation, kp.publicKey.rawRepresentation)
    }

    func testInvalidBase64Throws() {
        XCTAssertThrowsError(try JanusKeyPair.publicKey(fromBase64: "not-valid-base64!!!"))
    }

    // MARK: - Sign / Verify round-trip

    func testSignAndVerify() throws {
        let kp = JanusKeyPair()
        let signer = JanusSigner(keyPair: kp)
        let verifier = JanusVerifier(publicKey: kp.publicKey)

        let fields = ["session-123", "request-456", "quote-789", "15", "3"]
        let signature = try signer.sign(fields: fields)

        XCTAssertTrue(verifier.verify(signature: signature, fields: fields))
    }

    func testVerifyFailsWithWrongKey() throws {
        let signerKP = JanusKeyPair()
        let wrongKP = JanusKeyPair()

        let signer = JanusSigner(keyPair: signerKP)
        let wrongVerifier = JanusVerifier(publicKey: wrongKP.publicKey)

        let fields = ["hello", "world"]
        let signature = try signer.sign(fields: fields)

        XCTAssertFalse(wrongVerifier.verify(signature: signature, fields: fields))
    }

    func testVerifyFailsWithTamperedFields() throws {
        let kp = JanusKeyPair()
        let signer = JanusSigner(keyPair: kp)
        let verifier = JanusVerifier(publicKey: kp.publicKey)

        let fields = ["session-123", "5"]
        let signature = try signer.sign(fields: fields)

        let tampered = ["session-123", "50"]
        XCTAssertFalse(verifier.verify(signature: signature, fields: tampered))
    }

    func testVerifyFailsWithBadSignatureData() {
        let kp = JanusKeyPair()
        let verifier = JanusVerifier(publicKey: kp.publicKey)

        XCTAssertFalse(verifier.verify(signature: "not-a-signature", fields: ["test"]))
    }

    // MARK: - Verifier from base64

    func testVerifierFromBase64() throws {
        let kp = JanusKeyPair()
        let signer = JanusSigner(keyPair: kp)
        let verifier = try JanusVerifier(publicKeyBase64: kp.publicKeyBase64)

        let fields = ["test-field"]
        let signature = try signer.sign(fields: fields)

        XCTAssertTrue(verifier.verify(signature: signature, fields: fields))
    }
}
