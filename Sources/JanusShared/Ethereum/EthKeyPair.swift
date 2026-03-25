import Foundation
import P256K

/// A secp256k1 key pair with Ethereum address derivation.
///
/// Wraps `swift-secp256k1`'s `P256K.Signing` and `P256K.Recovery` key types
/// to provide Ethereum-compatible operations: address derivation, recoverable
/// ECDSA signing (needed for EIP-712 vouchers), and hex encoding.
public struct EthKeyPair: Sendable {

    /// The 32-byte raw private key.
    public let privateKeyData: Data

    /// The 65-byte uncompressed public key (0x04 || x || y).
    public let uncompressedPublicKey: Data

    /// The 20-byte Ethereum address (last 20 bytes of keccak256 of pubkey x||y).
    public let address: EthAddress

    /// Generate a new random key pair.
    public init() throws {
        let signingKey = try P256K.Signing.PrivateKey(format: .uncompressed)
        self.privateKeyData = signingKey.dataRepresentation
        self.uncompressedPublicKey = signingKey.publicKey.uncompressedRepresentation
        self.address = Self.deriveAddress(from: self.uncompressedPublicKey)
    }

    /// Reconstruct from a 32-byte raw private key.
    public init(privateKey: Data) throws {
        let signingKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
        self.privateKeyData = signingKey.dataRepresentation
        self.uncompressedPublicKey = signingKey.publicKey.uncompressedRepresentation
        self.address = Self.deriveAddress(from: self.uncompressedPublicKey)
    }

    /// Reconstruct from a hex-encoded private key (with or without "0x" prefix).
    public init(hexPrivateKey: String) throws {
        let data = try Data(ethHex: hexPrivateKey)
        try self.init(privateKey: data)
    }

    /// Sign a 32-byte message hash with recoverable ECDSA, returning (r, s, v).
    ///
    /// The `v` value is the recovery ID (0 or 1), which Ethereum encodes as 27 or 28
    /// (or chainId*2 + 35/36 for EIP-155).
    public func signRecoverable(messageHash: Data) throws -> EthSignature {
        let recoveryKey = try P256K.Recovery.PrivateKey(dataRepresentation: privateKeyData)
        let digest = SHA256Digest(messageHash)
        let signature = try recoveryKey.signature(for: digest)
        let compact = try signature.compactRepresentation
        return EthSignature(
            r: compact.signature.prefix(32),
            s: compact.signature.suffix(32),
            v: UInt8(compact.recoveryId)
        )
    }

    /// Derive an Ethereum address from a 65-byte uncompressed public key.
    private static func deriveAddress(from uncompressedKey: Data) -> EthAddress {
        // Skip the 0x04 prefix byte, hash the 64-byte x||y coordinates
        let pubkeyBody = uncompressedKey.dropFirst()
        let hash = Keccak256.hash(Data(pubkeyBody))
        // Address = last 20 bytes of the hash
        return EthAddress(hash.suffix(20))
    }
}

/// A 20-byte Ethereum address.
public struct EthAddress: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let data: Data

    public init(_ data: Data) {
        precondition(data.count == 20, "Ethereum address must be 20 bytes")
        self.data = data
    }

    public init(hex: String) throws {
        let raw = try Data(ethHex: hex)
        guard raw.count == 20 else {
            throw EthError.invalidAddress
        }
        self.data = raw
    }

    /// EIP-55 mixed-case checksum address.
    public var checksumAddress: String {
        let hexAddr = data.map { String(format: "%02x", $0) }.joined()
        let hash = Keccak256.hash(Data(hexAddr.utf8))
        var result = "0x"
        for (i, char) in hexAddr.enumerated() {
            let hashByte = hash[i / 2]
            let nibble = (i % 2 == 0) ? (hashByte >> 4) : (hashByte & 0x0f)
            result.append(nibble >= 8 ? char.uppercased() : String(char))
        }
        return result
    }

    public var description: String { checksumAddress }

    // Codable: encode/decode as hex string
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        try self.init(hex: hex)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(checksumAddress)
    }
}

/// A recoverable ECDSA signature (r, s, v).
public struct EthSignature: Codable, Sendable, Equatable {
    public let r: Data  // 32 bytes
    public let s: Data  // 32 bytes
    public let v: UInt8 // recovery ID (0 or 1)

    public init(r: Data, s: Data, v: UInt8) {
        self.r = r
        self.s = s
        self.v = v
    }

    /// The 65-byte compact representation: r || s || v
    public var compactRepresentation: Data {
        r + s + Data([v])
    }

    /// The Ethereum-style v value (27 or 28).
    public var ethV: UInt8 { v + 27 }
}

/// Errors from the Ethereum crypto layer.
public enum EthError: Error, LocalizedError {
    case invalidHex
    case invalidAddress
    case invalidPrivateKey
    case signingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidHex: return "Invalid hex string"
        case .invalidAddress: return "Invalid Ethereum address (must be 20 bytes)"
        case .invalidPrivateKey: return "Invalid secp256k1 private key"
        case .signingFailed: return "ECDSA signing failed"
        }
    }
}

// MARK: - Hex utilities

public extension Data {
    /// Decode hex string to Data. Accepts optional "0x" prefix.
    init(ethHex hex: String) throws {
        let clean = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        guard clean.count % 2 == 0 else { throw EthError.invalidHex }

        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let nextIndex = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<nextIndex], radix: 16) else {
                throw EthError.invalidHex
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    /// Hex string without "0x" prefix.
    var ethHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Hex string with "0x" prefix.
    var ethHexPrefixed: String {
        "0x" + ethHex
    }
}

// MARK: - SHA256Digest wrapper

/// Wraps a pre-computed 32-byte hash so it conforms to `Digest`,
/// letting us pass raw message hashes to the secp256k1 signer.
struct SHA256Digest: Digest {
    static var byteCount: Int { 32 }

    private let bytes: [UInt8]

    init(_ data: Data) {
        precondition(data.count == 32, "SHA256Digest must be 32 bytes")
        self.bytes = Array(data)
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { ptr in
            try body(UnsafeRawBufferPointer(ptr))
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
    }

    static func == (lhs: SHA256Digest, rhs: SHA256Digest) -> Bool {
        lhs.bytes == rhs.bytes
    }

    var description: String {
        Data(bytes).ethHex
    }

    func makeIterator() -> Array<UInt8>.Iterator {
        bytes.makeIterator()
    }
}
