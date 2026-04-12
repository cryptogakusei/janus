import Foundation

/// Handles on-chain settlement for payment channels.
///
/// Called by the provider when a client disconnects, submitting the latest
/// voucher to the escrow contract to claim earned funds. The escrow verifies
/// the client's EIP-712 signature on-chain and transfers pathUSD to the provider.
///
/// Settlement is idempotent — calling settle with a cumulative amount equal to
/// or less than the already-settled amount is a no-op (the contract ignores it).
public struct ChannelSettler: Sendable {

    public let rpc: EthRPC
    public let config: TempoConfig

    public init(config: TempoConfig) {
        guard let url = config.rpcURL else {
            fatalError("ChannelSettler requires a TempoConfig with rpcURL")
        }
        self.rpc = EthRPC(rpcURL: url)
        self.config = config
    }

    /// Categorized failure reasons for on-chain settlement.
    public enum SettleFailureReason: Sendable, CustomStringConvertible {
        /// Channel has not been opened on-chain (client may still be opening it).
        case channelNotOnChain
        /// Channel is closed or expired on-chain — permanent, cannot settle.
        case channelFinalized
        /// Failed to fetch gas price or transaction nonce.
        case gasInfoUnavailable(String)
        /// Settlement transaction was mined but reverted.
        case transactionReverted(txHash: String)
        /// Signing, submission, or receipt polling failed.
        case submissionFailed(String)

        /// Whether this failure is permanent (channel should be removed) or transient (keep for retry).
        public var isPermanent: Bool {
            switch self {
            case .channelFinalized, .transactionReverted: return true
            case .channelNotOnChain, .gasInfoUnavailable, .submissionFailed: return false
            }
        }

        public var description: String {
            switch self {
            case .channelNotOnChain:
                return "Channel does not exist on-chain"
            case .channelFinalized:
                return "Channel is finalized"
            case .gasInfoUnavailable(let detail):
                return "Failed to get gas info: \(detail)"
            case .transactionReverted(let txHash):
                return "Settle tx reverted: \(txHash)"
            case .submissionFailed(let detail):
                return "Settle failed: \(detail)"
            }
        }
    }

    /// Result of a settlement attempt.
    public enum SettleResult: Sendable {
        case settled(txHash: String, amount: UInt64)
        case noVoucher
        case alreadySettled
        case failed(SettleFailureReason)
    }

    /// Settle a channel on-chain using the provider's ETH keypair and the latest voucher.
    ///
    /// - Parameters:
    ///   - providerKeyPair: The provider's ETH keypair (must be the channel's payee)
    ///   - channel: The channel with the latest accepted voucher
    /// - Returns: The settlement result
    public func settle(providerKeyPair: EthKeyPair, channel: Channel) async -> SettleResult {
        guard let signedVoucher = channel.latestVoucher else {
            return .noVoucher
        }

        let amount = signedVoucher.voucher.cumulativeAmount
        guard amount > channel.settledAmount else {
            return .alreadySettled
        }

        // Check current on-chain state to avoid wasting gas
        let escrowClient = EscrowClient(rpc: rpc, escrowAddress: config.escrowContract)
        if let onChain = try? await escrowClient.getChannel(channelId: channel.channelId) {
            if !onChain.exists {
                return .failed(.channelNotOnChain)
            }
            if onChain.finalized {
                return .failed(.channelFinalized)
            }
            if let onChainSettled = onChain.settled.toUInt64, onChainSettled >= amount {
                return .alreadySettled
            }
        }
        // If RPC check fails, proceed anyway — the tx will revert if something is wrong

        let gasPrice: UInt64
        let nonce: UInt64
        do {
            gasPrice = try await rpc.gasPrice()
            nonce = try await rpc.getTransactionCount(address: providerKeyPair.address)
        } catch {
            return .failed(.gasInfoUnavailable(error.localizedDescription))
        }

        // The signature needs v = 27/28 for on-chain ecrecover (not 0/1)
        let sig = signedVoucher.signature
        let onChainSig = sig.r + sig.s + Data([sig.ethV])

        let tx = EthTransaction.settleChannel(
            escrow: config.escrowContract,
            channelId: channel.channelId,
            cumulativeAmount: amount,
            voucherSignature: onChainSig,
            nonce: nonce,
            gasPrice: gasPrice,
            chainId: config.chainId
        )

        do {
            let signed = try tx.sign(with: providerKeyPair)
            let txHash = try await rpc.sendRawTransaction(signedTx: signed)
            let receipt = try await rpc.waitForReceipt(txHash: txHash)
            guard receipt.status else {
                return .failed(.transactionReverted(txHash: txHash))
            }
            return .settled(txHash: txHash, amount: amount)
        } catch {
            return .failed(.submissionFailed(error.localizedDescription))
        }
    }
}
