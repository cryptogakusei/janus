import Foundation

/// A Tempo payment channel — an on-chain escrow between a payer (client) and payee (provider).
///
/// Lifecycle:
/// 1. Client calls `escrow.open(payee, token, deposit, salt, authorizedSigner)` → creates channel on-chain
/// 2. Client sends signed `Voucher`s off-chain (cumulative, monotonically increasing) per request
/// 3. Provider calls `escrow.settle(channelId, cumulativeAmount, signature)` to claim payment
/// 4. Either party can `close` the channel to finalize and withdraw remaining funds
///
/// The channel ID is deterministically computed from the parameters, matching the on-chain computation.
public struct Channel: Codable, Sendable, Equatable {

    /// Deterministic channel identifier (keccak256 of ABI-encoded parameters).
    public let channelId: Data // 32 bytes

    /// The client (funds depositor).
    public let payer: EthAddress

    /// The provider (payment recipient).
    public let payee: EthAddress

    /// The ERC-20 token address (address(0) for native ETH).
    public let token: EthAddress

    /// Unique salt to distinguish channels with the same payer/payee/token.
    public let salt: Data // 32 bytes

    /// Address authorized to sign vouchers on behalf of the payer.
    /// Typically the payer themselves, but can be a delegate.
    public let authorizedSigner: EthAddress

    /// The total amount deposited into the escrow.
    public let deposit: UInt64

    /// Current channel state.
    public var state: ChannelState

    /// The highest cumulative amount settled on-chain so far.
    public var settledAmount: UInt64

    /// The latest signed voucher held by the provider.
    public var latestVoucher: SignedVoucher?

    /// When the latest voucher was accepted (for TTL-based cleanup of stale channels).
    public var lastVoucherAt: Date?

    public init(
        payer: EthAddress,
        payee: EthAddress,
        token: EthAddress,
        salt: Data,
        authorizedSigner: EthAddress,
        deposit: UInt64,
        config: TempoConfig
    ) {
        precondition(salt.count == 32, "salt must be 32 bytes")
        self.payer = payer
        self.payee = payee
        self.token = token
        self.salt = salt
        self.authorizedSigner = authorizedSigner
        self.deposit = deposit
        self.state = .open
        self.settledAmount = 0
        self.latestVoucher = nil
        self.lastVoucherAt = nil
        self.channelId = Channel.computeId(
            payer: payer, payee: payee, token: token,
            salt: salt, authorizedSigner: authorizedSigner,
            config: config
        )
    }

    /// Compute the channel ID, mirroring the on-chain `keccak256(abi.encode(...))`.
    public static func computeId(
        payer: EthAddress,
        payee: EthAddress,
        token: EthAddress,
        salt: Data,
        authorizedSigner: EthAddress,
        config: TempoConfig
    ) -> Data {
        let encoded = ABI.encode([
            .address(payer),
            .address(payee),
            .address(token),
            .bytes32(salt),
            .address(authorizedSigner),
            .address(config.escrowContract),
            .uint256(config.chainId),
        ])
        return Keccak256.hash(encoded)
    }
}

/// Payment channel states.
public enum ChannelState: String, Codable, Sendable {
    case open            // Channel is active, vouchers can be signed/settled
    case closeRequested  // One party requested close, waiting for challenge period
    case closed          // Channel is finalized, funds withdrawn
    case expired         // Channel expired without activity
}

// MARK: - Channel operations

public extension Channel {

    /// The remaining unsettled balance in the channel.
    var remainingDeposit: UInt64 {
        deposit > settledAmount ? deposit - settledAmount : 0
    }

    /// The current authorized (but not yet settled) amount from the latest voucher.
    var authorizedAmount: UInt64 {
        latestVoucher?.voucher.cumulativeAmount ?? 0
    }

    /// The amount authorized but not yet settled on-chain.
    var unsettledAmount: UInt64 {
        authorizedAmount > settledAmount ? authorizedAmount - settledAmount : 0
    }

    /// Whether the channel can accept a voucher for the given cumulative amount.
    func canAuthorize(cumulativeAmount: UInt64) -> Bool {
        guard state == .open else { return false }
        guard cumulativeAmount > authorizedAmount else { return false } // must be monotonically increasing
        guard cumulativeAmount <= deposit else { return false }         // can't exceed deposit
        return true
    }

    /// Accept a new voucher (provider-side). Validates monotonicity and deposit bounds.
    mutating func acceptVoucher(_ signedVoucher: SignedVoucher) throws {
        let amount = signedVoucher.voucher.cumulativeAmount
        guard state == .open else {
            throw ChannelError.channelNotOpen
        }
        guard signedVoucher.voucher.channelId == channelId else {
            throw ChannelError.wrongChannel
        }
        guard amount > authorizedAmount else {
            throw ChannelError.nonMonotonicVoucher
        }
        guard amount <= deposit else {
            throw ChannelError.exceedsDeposit
        }
        latestVoucher = signedVoucher
        lastVoucherAt = Date()
    }

    /// Record an on-chain settlement (provider calls `escrow.settle()`).
    mutating func recordSettlement(amount: UInt64) {
        settledAmount = max(settledAmount, amount)
    }
}

/// Errors from channel operations.
public enum ChannelError: Error, LocalizedError {
    case channelNotOpen
    case wrongChannel
    case nonMonotonicVoucher
    case exceedsDeposit
    case insufficientDeposit

    public var errorDescription: String? {
        switch self {
        case .channelNotOpen: return "Channel is not open"
        case .wrongChannel: return "Voucher is for a different channel"
        case .nonMonotonicVoucher: return "Voucher amount must be strictly increasing"
        case .exceedsDeposit: return "Voucher amount exceeds channel deposit"
        case .insufficientDeposit: return "Insufficient deposit for requested amount"
        }
    }
}
