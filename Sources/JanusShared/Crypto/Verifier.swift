import Foundation
import CryptoKit

/// Verifies Ed25519 signatures against a public key.
public struct JanusVerifier: Sendable {
    private let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    /// Create a verifier from a base64-encoded public key.
    public init(publicKeyBase64: String) throws {
        self.publicKey = try JanusKeyPair.publicKey(fromBase64: publicKeyBase64)
    }

    /// Verify a base64-encoded signature against the given fields.
    /// Returns true if valid, false otherwise.
    public func verify(signature signatureBase64: String, fields: [String]) -> Bool {
        guard let signatureData = Data(base64Encoded: signatureBase64) else {
            return false
        }
        let message = fields.joined(separator: "\n")
        let messageData = Data(message.utf8)
        return publicKey.isValidSignature(signatureData, for: messageData)
    }
}
