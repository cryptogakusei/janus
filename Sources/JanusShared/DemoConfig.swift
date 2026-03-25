import Foundation
import CryptoKit

/// Hardcoded keys for v1 development/demo.
///
/// In production, the backend key would live on the server only.
/// For v1, we hardcode a deterministic keypair so the client can
/// generate fake-but-structurally-correct session grants and both
/// client and provider can verify them.
public enum DemoConfig {

    /// Deterministic seed for the backend keypair.
    /// SHA256 of "janus-demo-backend-v1" gives us 32 bytes for Ed25519.
    private static let seed = SHA256.hash(data: Data("janus-demo-backend-v1".utf8))

    private static let _backendKeyPair: JanusKeyPair = {
        let seedBytes = Data(seed)
        return try! JanusKeyPair(privateKeyRaw: seedBytes)
    }()

    /// Backend public key — used by provider to verify session grants.
    public static var backendPublicKeyBase64: String {
        _backendKeyPair.publicKeyBase64
    }

    /// Backend private key — used by client to sign demo session grants.
    /// In production this would NEVER be on the client.
    public static var backendPrivateKey: Curve25519.Signing.PrivateKey {
        _backendKeyPair.privateKey
    }

    /// Default session budget for demo.
    public static let defaultMaxCredits = 100

    /// Default session duration for demo (1 hour).
    public static let defaultSessionDuration: TimeInterval = 3600

    /// Backend API base URL.
    /// The Mac provider runs on the same LAN as the iPhone client.
    /// Uses the Mac's local IP so the iPhone can reach it.
    public static let backendBaseURL = "http://10.0.0.119:8080"
}
