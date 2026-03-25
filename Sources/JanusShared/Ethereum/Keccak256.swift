import Foundation
import CryptoSwift

/// Keccak-256 hash function used by Ethereum.
///
/// Thin wrapper around CryptoSwift's battle-tested implementation.
/// Ethereum uses Keccak-256 (NOT SHA3-256 — they differ in the padding byte).
public enum Keccak256 {

    /// Compute the Keccak-256 hash of the given data.
    public static func hash(_ data: Data) -> Data {
        Data(SHA3(variant: .keccak256).calculate(for: Array(data)))
    }

    /// Compute the Keccak-256 hash of a byte array.
    public static func hash(_ bytes: [UInt8]) -> Data {
        Data(SHA3(variant: .keccak256).calculate(for: bytes))
    }
}
