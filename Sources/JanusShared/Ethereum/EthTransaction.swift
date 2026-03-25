import Foundation

/// A legacy (Type 0) Ethereum transaction with EIP-155 replay protection.
///
/// Supports building, signing, and serializing transactions for on-chain calls
/// (e.g., ERC-20 approve, escrow open). Uses the chain ID in the signing hash
/// to prevent cross-chain replay attacks.
public struct EthTransaction: Sendable {

    public let nonce: UInt64
    public let gasPrice: UInt64
    public let gasLimit: UInt64
    public let to: EthAddress
    public let value: UInt64
    public let data: Data
    public let chainId: UInt64

    public init(
        nonce: UInt64,
        gasPrice: UInt64,
        gasLimit: UInt64,
        to: EthAddress,
        value: UInt64 = 0,
        data: Data,
        chainId: UInt64
    ) {
        self.nonce = nonce
        self.gasPrice = gasPrice
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
        self.chainId = chainId
    }

    /// Sign this transaction and return the raw RLP-encoded bytes ready for eth_sendRawTransaction.
    ///
    /// EIP-155 signing:
    /// 1. Hash: keccak256(RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]))
    /// 2. Sign the hash with secp256k1
    /// 3. Encode: RLP([nonce, gasPrice, gasLimit, to, value, data, v, r, s])
    ///    where v = chainId * 2 + 35 + recoveryId
    public func sign(with keyPair: EthKeyPair) throws -> Data {
        // Build unsigned transaction items for EIP-155 signing
        let unsignedItems: [RLP.Item] = [
            RLP.encodeUInt(nonce),
            RLP.encodeUInt(gasPrice),
            RLP.encodeUInt(gasLimit),
            .bytes(to.data),
            RLP.encodeUInt(value),
            .bytes(data),
            RLP.encodeUInt(chainId),
            RLP.encodeUInt(0),
            RLP.encodeUInt(0),
        ]

        let unsignedRLP = RLP.encode(.list(unsignedItems))
        let signingHash = Keccak256.hash(unsignedRLP)

        // Sign with recoverable ECDSA
        let sig = try keyPair.signRecoverable(messageHash: signingHash)

        // EIP-155: v = chainId * 2 + 35 + recoveryId
        let v = chainId * 2 + 35 + UInt64(sig.v)

        // Build signed transaction
        let signedItems: [RLP.Item] = [
            RLP.encodeUInt(nonce),
            RLP.encodeUInt(gasPrice),
            RLP.encodeUInt(gasLimit),
            .bytes(to.data),
            RLP.encodeUInt(value),
            .bytes(data),
            RLP.encodeUInt(v),
            .bytes(sig.r),
            .bytes(sig.s),
        ]

        return RLP.encode(.list(signedItems))
    }
}

// MARK: - Calldata builders (wallet-agnostic)

public extension EthTransaction {

    /// ABI calldata for ERC-20 `approve(spender, amount)`.
    static func approveCalldata(spender: EthAddress, amount: UInt64) -> Data {
        let selector = Keccak256.hash(Data("approve(address,uint256)".utf8)).prefix(4)
        return selector + ABI.encode([.address(spender), .uint256(amount)])
    }

    /// ABI calldata for escrow `open(payee, token, deposit, salt, authorizedSigner)`.
    static func openChannelCalldata(
        payee: EthAddress, token: EthAddress, deposit: UInt64,
        salt: Data, authorizedSigner: EthAddress
    ) -> Data {
        let selector = Keccak256.hash(
            Data("open(address,address,uint128,bytes32,address)".utf8)
        ).prefix(4)
        return selector + ABI.encode([
            .address(payee), .address(token), .uint256(deposit),
            .bytes32(salt), .address(authorizedSigner),
        ])
    }

    /// ABI calldata for escrow `settle(channelId, cumulativeAmount, signature)`.
    static func settleChannelCalldata(
        channelId: Data, cumulativeAmount: UInt64, voucherSignature: Data
    ) -> Data {
        let selector = Keccak256.hash(
            Data("settle(bytes32,uint128,bytes)".utf8)
        ).prefix(4)
        let sigLength = ABI.Value.uint256(UInt64(voucherSignature.count)).encoded
        let sigPadded = voucherSignature + Data(repeating: 0, count: (32 - voucherSignature.count % 32) % 32)
        return selector
            + ABI.Value.bytes32(channelId).encoded
            + ABI.Value.uint256(cumulativeAmount).encoded
            + ABI.Value.uint256(UInt64(96)).encoded
            + sigLength
            + sigPadded
    }
}

// MARK: - Full transaction builders (for LocalWalletProvider / raw key signing)

public extension EthTransaction {

    /// Build an ERC-20 `approve(spender, amount)` transaction.
    static func approve(
        token: EthAddress,
        spender: EthAddress,
        amount: UInt64,
        nonce: UInt64,
        gasPrice: UInt64,
        chainId: UInt64
    ) -> EthTransaction {
        EthTransaction(
            nonce: nonce, gasPrice: gasPrice, gasLimit: 2_000_000,
            to: token, data: approveCalldata(spender: spender, amount: amount), chainId: chainId
        )
    }

    /// Build an escrow `open(payee, token, deposit, salt, authorizedSigner)` transaction.
    static func openChannel(
        escrow: EthAddress,
        payee: EthAddress,
        token: EthAddress,
        deposit: UInt64,
        salt: Data,
        authorizedSigner: EthAddress,
        nonce: UInt64,
        gasPrice: UInt64,
        chainId: UInt64
    ) -> EthTransaction {
        EthTransaction(
            nonce: nonce, gasPrice: gasPrice, gasLimit: 2_000_000,
            to: escrow,
            data: openChannelCalldata(
                payee: payee, token: token, deposit: deposit,
                salt: salt, authorizedSigner: authorizedSigner
            ),
            chainId: chainId
        )
    }

    /// Build an escrow `settle(channelId, cumulativeAmount, signature)` transaction.
    ///
    /// The signature is the client's EIP-712 voucher signature (65 bytes: r || s || v).
    /// Must be called by the payee (provider).
    static func settleChannel(
        escrow: EthAddress,
        channelId: Data,
        cumulativeAmount: UInt64,
        voucherSignature: Data,
        nonce: UInt64,
        gasPrice: UInt64,
        chainId: UInt64
    ) -> EthTransaction {
        EthTransaction(
            nonce: nonce, gasPrice: gasPrice, gasLimit: 2_000_000,
            to: escrow,
            data: settleChannelCalldata(
                channelId: channelId, cumulativeAmount: cumulativeAmount,
                voucherSignature: voucherSignature
            ),
            chainId: chainId
        )
    }
}
