import Foundation

/// Client → Provider: authorize payment via a signed Tempo voucher.
///
/// The voucher's `cumulativeAmount` is monotonically increasing — each authorization
/// supersedes the previous one, following the Tempo payment channel model.
public struct VoucherAuthorization: Codable, Sendable {
    public let requestID: String
    public let quoteID: String
    public let signedVoucher: SignedVoucher

    public init(requestID: String, quoteID: String, signedVoucher: SignedVoucher) {
        self.requestID = requestID
        self.quoteID = quoteID
        self.signedVoucher = signedVoucher
    }

    /// Convenience: the cumulative amount from the voucher.
    public var cumulativeAmount: UInt64 {
        signedVoucher.voucher.cumulativeAmount
    }

    /// Convenience: the channel ID from the voucher.
    public var channelId: Data {
        signedVoucher.voucher.channelId
    }
}

/// Channel information sent by the client on first request.
///
/// Replaces `SessionGrant` for Tempo-based sessions. Instead of a backend-signed
/// grant, the client provides the channel parameters so the provider can reconstruct
/// the channel and verify vouchers.
///
/// In Step 3b (on-chain), the provider will also verify that this channel exists
/// on-chain with the claimed deposit. For Step 3a (off-chain), the provider trusts
/// the channel info (same trust model as the current SessionGrant).
public struct ChannelInfo: Codable, Sendable {
    public let payerAddress: EthAddress
    public let payeeAddress: EthAddress
    public let tokenAddress: EthAddress
    public let salt: Data  // 32 bytes
    public let authorizedSigner: EthAddress
    public let deposit: UInt64
    public let channelId: Data  // 32 bytes — provider verifies this matches computeId()

    public init(
        payerAddress: EthAddress,
        payeeAddress: EthAddress,
        tokenAddress: EthAddress,
        salt: Data,
        authorizedSigner: EthAddress,
        deposit: UInt64,
        channelId: Data
    ) {
        self.payerAddress = payerAddress
        self.payeeAddress = payeeAddress
        self.tokenAddress = tokenAddress
        self.salt = salt
        self.authorizedSigner = authorizedSigner
        self.deposit = deposit
        self.channelId = channelId
    }

    /// Construct from an existing Channel object.
    public init(channel: Channel, config: TempoConfig) {
        self.payerAddress = channel.payer
        self.payeeAddress = channel.payee
        self.tokenAddress = channel.token
        self.salt = channel.salt
        self.authorizedSigner = channel.authorizedSigner
        self.deposit = channel.deposit
        self.channelId = channel.channelId
    }
}
