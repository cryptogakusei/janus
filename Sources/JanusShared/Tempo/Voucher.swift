import Foundation
import P256K

/// A Tempo payment voucher — a signed, cumulative payment authorization.
///
/// Vouchers are the off-chain payment primitive in Tempo. The client signs a voucher
/// for each request, authorizing the provider to claim up to `cumulativeAmount` from
/// the on-chain escrow. The amount is cumulative and monotonically increasing —
/// each new voucher supersedes the previous one.
///
/// EIP-712 type: `Voucher(bytes32 channelId, uint128 cumulativeAmount)`
/// Domain: "Tempo Stream Channel", version "1", chainId, escrow contract address
public struct Voucher: Codable, Sendable, Equatable {

    /// The channel this voucher belongs to.
    public let channelId: Data // 32 bytes

    /// The cumulative amount authorized (monotonically increasing).
    public let cumulativeAmount: UInt64

    public init(channelId: Data, cumulativeAmount: UInt64) {
        precondition(channelId.count == 32, "channelId must be 32 bytes")
        self.channelId = channelId
        self.cumulativeAmount = cumulativeAmount
    }
}

/// A voucher with its EIP-712 signature.
public struct SignedVoucher: Codable, Sendable, Equatable {

    public let voucher: Voucher
    public let signature: EthSignature

    public init(voucher: Voucher, signature: EthSignature) {
        self.voucher = voucher
        self.signature = signature
    }

    /// The 65-byte signature for on-chain verification (r || s || v).
    public var signatureBytes: Data {
        signature.compactRepresentation
    }
}

// MARK: - EIP-712 hashing and signing

/// The EIP-712 type definition for Voucher.
public let voucherEIP712Type = EIP712.TypeDefinition(
    name: "Voucher",
    fields: [
        EIP712.Field(name: "channelId", type: "bytes32"),
        EIP712.Field(name: "cumulativeAmount", type: "uint128"),
    ]
)

public extension Voucher {

    /// Compute the EIP-712 struct hash for this voucher.
    var structHash: Data {
        EIP712.hashStruct(
            type: voucherEIP712Type,
            encodedValues: [
                channelId,                                  // bytes32, already 32 bytes
                ABI.Value.uint256(cumulativeAmount).encoded  // uint128 encoded as uint256
            ]
        )
    }

    /// Compute the full EIP-712 signable digest for this voucher.
    func signableHash(config: TempoConfig) -> Data {
        EIP712.signableHash(domain: config.voucherDomain, structHash: structHash)
    }

    /// Sign this voucher with a secp256k1 private key, producing a SignedVoucher.
    func sign(with keyPair: EthKeyPair, config: TempoConfig) throws -> SignedVoucher {
        let hash = signableHash(config: config)
        let sig = try keyPair.signRecoverable(messageHash: hash)
        return SignedVoucher(voucher: self, signature: sig)
    }
}

// MARK: - Verification

public extension Voucher {

    /// Verify that a signed voucher was signed by the expected address.
    ///
    /// This mirrors the on-chain `ecrecover` check: recover the signer from the
    /// EIP-712 digest + signature, and compare against the expected address.
    static func verify(
        signedVoucher: SignedVoucher,
        expectedSigner: EthAddress,
        config: TempoConfig
    ) -> Bool {
        let hash = signedVoucher.voucher.signableHash(config: config)
        guard let recovered = try? recoverAddress(messageHash: hash, signature: signedVoucher.signature) else {
            return false
        }
        return recovered == expectedSigner
    }
}

// MARK: - Address recovery from signature

/// Recover an Ethereum address from a message hash and recoverable ECDSA signature.
///
/// This is the Swift equivalent of Solidity's `ecrecover(hash, v, r, s)`.
public func recoverAddress(messageHash: Data, signature: EthSignature) throws -> EthAddress {
    let compactSig = signature.r + signature.s
    let recoverySig = try P256K.Recovery.ECDSASignature(
        compactRepresentation: compactSig,
        recoveryId: Int32(signature.v)
    )

    let digest = SHA256Digest(messageHash)
    let recoveredPubKey = try P256K.Recovery.PublicKey(
        digest,
        signature: recoverySig,
        format: .uncompressed
    )

    // Derive Ethereum address: keccak256(uncompressed_pubkey[1..65])[-20:]
    let pubkeyData = recoveredPubKey.dataRepresentation
    let pubkeyBody = pubkeyData.dropFirst() // skip 0x04 prefix
    let hash = Keccak256.hash(Data(pubkeyBody))
    return EthAddress(hash.suffix(20))
}
