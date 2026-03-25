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

    /// Result of a settlement attempt.
    public enum SettleResult: Sendable {
        case settled(txHash: String, amount: UInt64)
        case noVoucher
        case alreadySettled
        case failed(String)
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
                return .failed("Channel does not exist on-chain")
            }
            if onChain.finalized {
                return .failed("Channel is finalized")
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
            return .failed("Failed to get gas info: \(error.localizedDescription)")
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
                return .failed("Settle tx reverted: \(txHash)")
            }
            return .settled(txHash: txHash, amount: amount)
        } catch {
            return .failed("Settle failed: \(error.localizedDescription)")
        }
    }
}
