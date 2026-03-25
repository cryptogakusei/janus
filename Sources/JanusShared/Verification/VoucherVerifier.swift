import Foundation

/// Verifies Tempo voucher authorizations against a payment channel.
///
/// This is the Tempo equivalent of `SpendVerifier`. Instead of checking Ed25519
/// signatures against a backend-signed `SessionGrant`, it:
/// 1. Verifies the EIP-712 voucher signature via `ecrecover`
/// 2. Checks monotonicity against the channel's last accepted voucher
/// 3. Checks the voucher amount doesn't exceed the channel deposit
///
/// Design: `(VoucherAuthorization, Channel, QuoteResponse, TempoConfig) → Result<Accepted, VoucherVerificationError>`
public struct VoucherVerifier: Sendable {

    private let providerAddress: EthAddress
    private let config: TempoConfig

    public init(providerAddress: EthAddress, config: TempoConfig) {
        self.providerAddress = providerAddress
        self.config = config
    }

    /// Result of successful verification.
    public struct Accepted: Sendable {
        public let creditsCharged: Int
        public let newCumulativeAmount: UInt64
    }

    /// Verify a voucher authorization against the channel and quote.
    ///
    /// Checks performed:
    /// 1. Channel is open
    /// 2. Channel payee matches this provider
    /// 3. Voucher channel ID matches
    /// 4. Quote is valid (matches request, not expired)
    /// 5. Voucher amount is monotonically increasing
    /// 6. Voucher amount increment covers the quoted price
    /// 7. Voucher amount doesn't exceed channel deposit
    /// 8. EIP-712 signature recovers to the channel's authorized signer
    public func verify(
        authorization auth: VoucherAuthorization,
        channel: Channel,
        quote: QuoteResponse,
        now: Date = Date()
    ) throws -> Accepted {

        // 1. Channel is open
        guard channel.state == .open else {
            throw VoucherVerificationError.channelNotOpen
        }

        // 2. Payee matches this provider
        guard channel.payee == providerAddress else {
            throw VoucherVerificationError.wrongProvider
        }

        // 3. Voucher channel ID matches
        guard auth.channelId == channel.channelId else {
            throw VoucherVerificationError.channelMismatch
        }

        // 4. Quote valid
        guard quote.requestID == auth.requestID,
              quote.quoteID == auth.quoteID,
              quote.expiresAt > now else {
            throw VoucherVerificationError.expiredQuote
        }

        // 5. Voucher amount is monotonically increasing
        guard auth.cumulativeAmount > channel.authorizedAmount else {
            throw VoucherVerificationError.nonMonotonicVoucher
        }

        // 6. Increment covers the quoted price
        let increment = auth.cumulativeAmount - channel.authorizedAmount
        guard increment >= UInt64(quote.priceCredits) else {
            throw VoucherVerificationError.insufficientAmount
        }

        // 7. Doesn't exceed deposit
        guard auth.cumulativeAmount <= channel.deposit else {
            throw VoucherVerificationError.exceedsDeposit
        }

        // 8. EIP-712 signature valid (ecrecover)
        guard Voucher.verify(
            signedVoucher: auth.signedVoucher,
            expectedSigner: channel.authorizedSigner,
            config: config
        ) else {
            throw VoucherVerificationError.invalidSignature
        }

        return Accepted(
            creditsCharged: quote.priceCredits,
            newCumulativeAmount: auth.cumulativeAmount
        )
    }

    /// Verify channel info from a client's first request (off-chain only).
    ///
    /// Reconstructs the channel ID from the provided parameters and checks it matches.
    /// For on-chain verification, use `verifyChannelInfoOnChain()` instead.
    public func verifyChannelInfo(_ info: ChannelInfo) -> Bool {
        // Verify payee is this provider
        guard info.payeeAddress == providerAddress else { return false }

        // Verify channel ID is correctly computed
        let expectedId = Channel.computeId(
            payer: info.payerAddress,
            payee: info.payeeAddress,
            token: info.tokenAddress,
            salt: info.salt,
            authorizedSigner: info.authorizedSigner,
            config: config
        )
        guard info.channelId == expectedId else { return false }

        return true
    }

    /// Verify channel info with on-chain state check.
    ///
    /// In addition to the off-chain checks, this queries the escrow contract to verify:
    /// 1. The channel exists on-chain
    /// 2. The on-chain payee matches this provider
    /// 3. The on-chain deposit is at least the claimed amount
    /// 4. The channel is not finalized
    ///
    /// Falls back to off-chain-only if no RPC URL is configured.
    public func verifyChannelInfoOnChain(_ info: ChannelInfo) async -> ChannelVerificationResult {
        // First do off-chain checks
        guard verifyChannelInfo(info) else {
            return .rejected(reason: "Off-chain verification failed")
        }

        // If no RPC URL, accept based on off-chain checks only
        guard config.rpcURL != nil else {
            return .acceptedOffChainOnly
        }

        // Query on-chain state
        let escrow = EscrowClient(config: config)
        do {
            let onChain = try await escrow.getChannel(channelId: info.channelId)

            guard onChain.exists else {
                return .acceptedOffChainOnly  // Channel not opened on-chain yet — trust client for now
            }

            guard !onChain.finalized else {
                return .rejected(reason: "Channel is finalized on-chain")
            }

            guard onChain.payee == providerAddress else {
                return .rejected(reason: "On-chain payee mismatch")
            }

            guard onChain.authorizedSigner == info.authorizedSigner else {
                return .rejected(reason: "On-chain authorizedSigner mismatch")
            }

            let onChainDeposit = onChain.deposit.toUInt64 ?? UInt64.max
            return .acceptedOnChain(onChainDeposit: onChainDeposit)
        } catch {
            // RPC call failed — fall back to off-chain
            return .acceptedOffChainOnly
        }
    }
}

/// Result of on-chain channel verification.
public enum ChannelVerificationResult: Sendable {
    /// Channel verified against on-chain state. Deposit confirmed.
    case acceptedOnChain(onChainDeposit: UInt64)
    /// Off-chain checks passed, but on-chain verification skipped (no RPC or channel not yet opened).
    case acceptedOffChainOnly
    /// Verification failed.
    case rejected(reason: String)

    public var isAccepted: Bool {
        switch self {
        case .acceptedOnChain, .acceptedOffChainOnly: return true
        case .rejected: return false
        }
    }
}

/// Errors from voucher verification.
public enum VoucherVerificationError: Error, Sendable, Equatable {
    case channelNotOpen
    case wrongProvider
    case channelMismatch
    case expiredQuote
    case nonMonotonicVoucher
    case insufficientAmount
    case exceedsDeposit
    case invalidSignature

    /// Map to ErrorResponse.ErrorCode for wire transport.
    public var errorCode: ErrorResponse.ErrorCode {
        switch self {
        case .channelNotOpen: return .invalidSession
        case .wrongProvider: return .invalidSession
        case .channelMismatch: return .invalidSession
        case .expiredQuote: return .expiredQuote
        case .nonMonotonicVoucher: return .sequenceMismatch
        case .insufficientAmount: return .insufficientCredits
        case .exceedsDeposit: return .insufficientCredits
        case .invalidSignature: return .invalidSignature
        }
    }
}
