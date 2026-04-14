import Foundation

/// A session grant created locally by the client, authorizing spend
/// up to `maxCredits` at a specific provider.
///
/// Sessions are created locally — trust comes from on-chain Tempo payment
/// channel verification, not backend signing.
public struct SessionGrant: Codable, Sendable {
    public let sessionID: String
    public let userPubkey: String       // base64 Ed25519 public key
    public let providerID: String
    public let maxCredits: Int
    public let expiresAt: Date

    public init(
        sessionID: String,
        userPubkey: String,
        providerID: String,
        maxCredits: Int,
        expiresAt: Date
    ) {
        self.sessionID = sessionID
        self.userPubkey = userPubkey
        self.providerID = providerID
        self.maxCredits = maxCredits
        self.expiresAt = expiresAt
    }
}
