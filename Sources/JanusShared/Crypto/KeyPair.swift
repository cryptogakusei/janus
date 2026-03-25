import Foundation
import CryptoKit

/// Ed25519 key pair for signing and verification.
///
/// Used by all three actors:
/// - Backend: signs session grants
/// - Client: signs spend authorizations
/// - Provider: signs receipts
public struct JanusKeyPair: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Curve25519.Signing.PublicKey

    /// Generate a new random key pair.
    public init() {
        self.privateKey = Curve25519.Signing.PrivateKey()
        self.publicKey = privateKey.publicKey
    }

    /// Reconstruct from a raw private key (32 bytes).
    public init(privateKeyRaw: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        self.publicKey = privateKey.publicKey
    }

    /// Base64-encoded public key for wire transport.
    public var publicKeyBase64: String {
        publicKey.rawRepresentation.base64EncodedString()
    }

    /// Base64-encoded private key for storage.
    public var privateKeyBase64: String {
        privateKey.rawRepresentation.base64EncodedString()
    }

    /// Reconstruct a public key from base64.
    public static func publicKey(fromBase64 string: String) throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: string) else {
            throw CryptoError.invalidBase64
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}

/// Errors from the Janus crypto layer.
public enum CryptoError: Error, LocalizedError {
    case invalidBase64
    case invalidSignature
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidBase64: return "Invalid base64-encoded key or signature."
        case .invalidSignature: return "Signature data is malformed."
        case .verificationFailed: return "Signature verification failed."
        }
    }
}
