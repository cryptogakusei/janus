import Foundation
import CryptoKit

/// Signs messages using an Ed25519 private key.
///
/// Signature format: `sign(field1 \n field2 \n ... \n fieldN)`
/// Fields are UTF-8 encoded and joined with newline delimiters.
public struct JanusSigner: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public init(keyPair: JanusKeyPair) {
        self.privateKey = keyPair.privateKey
    }

    /// Sign an array of string fields, returning a base64-encoded signature.
    public func sign(fields: [String]) throws -> String {
        let message = fields.joined(separator: "\n")
        let messageData = Data(message.utf8)
        let signature = try privateKey.signature(for: messageData)
        return signature.base64EncodedString()
    }
}
