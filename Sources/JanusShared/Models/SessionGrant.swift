import Foundation

/// A session grant issued by the backend, authorizing a client to spend
/// up to `maxCredits` at a specific provider.
///
/// The backend signs: session_id, user_pubkey, provider_id, max_credits, expires_at.
/// The provider verifies this signature using the hardcoded backend public key.
public struct SessionGrant: Codable, Sendable {
    public let sessionID: String
    public let userPubkey: String       // base64 Ed25519 public key
    public let providerID: String
    public let maxCredits: Int
    public let expiresAt: Date
    public let backendSignature: String // base64 Ed25519 signature

    public init(
        sessionID: String,
        userPubkey: String,
        providerID: String,
        maxCredits: Int,
        expiresAt: Date,
        backendSignature: String
    ) {
        self.sessionID = sessionID
        self.userPubkey = userPubkey
        self.providerID = providerID
        self.maxCredits = maxCredits
        self.expiresAt = expiresAt
        self.backendSignature = backendSignature
    }

    /// The fields that the backend signs, in canonical order.
    public var signableFields: [String] {
        [
            sessionID,
            userPubkey,
            providerID,
            String(maxCredits),
            ISO8601DateFormatter().string(from: expiresAt)
        ]
    }
}
