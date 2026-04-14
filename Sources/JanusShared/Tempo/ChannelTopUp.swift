import Foundation

/// Handles on-chain channel top-up: fund (testnet), approve escrow, call topUp.
///
/// Mirrors `ChannelOpener` exactly. Increases an existing channel's deposit
/// without closing and reopening it — cheaper and preserves channel continuity.
public struct ChannelTopUp: Sendable {

    public let rpc: EthRPC
    public let config: TempoConfig

    public init(config: TempoConfig) {
        guard let url = config.rpcURL else {
            fatalError("ChannelTopUp requires a TempoConfig with rpcURL")
        }
        self.rpc = EthRPC(rpcURL: url)
        self.config = config
    }

    /// Result of the top-up process.
    public enum TopUpResult: Sendable {
        case topped(approveTxHash: String, topUpTxHash: String, newDeposit: UInt64)
        case failed(String)
    }

    /// Fund, approve, and top up an existing channel on-chain using a WalletProvider.
    ///
    /// - Parameter progressHandler: Optional closure called before each stage with a human-readable status string.
    public func topUp(
        wallet: any WalletProvider,
        channel: Channel,
        additionalDeposit: UInt64,
        progressHandler: ((String) -> Void)? = nil
    ) async -> TopUpResult {
        let escrow = config.escrowContract
        let token = config.paymentToken

        // Step 1: Fund via testnet faucet
        progressHandler?("Funding wallet...")
        do {
            try await rpc.fundAddress(wallet.address)
        } catch {
            print("Faucet call failed (may already be funded): \(error.localizedDescription)")
        }

        // Step 2: Approve escrow to spend additionalDeposit tokens
        progressHandler?("Approving token spend...")
        let approveData = EthTransaction.approveCalldata(spender: escrow, amount: additionalDeposit)
        let approveTxHash: String
        do {
            approveTxHash = try await wallet.sendTransaction(
                to: token, data: approveData, value: 0, chainId: config.chainId
            )
            let receipt = try await rpc.waitForReceipt(txHash: approveTxHash)
            guard receipt.status else {
                return .failed("Approve tx reverted: \(approveTxHash)")
            }
        } catch {
            return .failed("Approve failed: \(error.localizedDescription)")
        }

        // Step 3: Call topUp on escrow contract
        progressHandler?("Topping up channel...")
        let topUpData = EthTransaction.topUpCalldata(
            channelId: channel.channelId,
            additionalDeposit: additionalDeposit
        )
        let topUpTxHash: String
        do {
            topUpTxHash = try await wallet.sendTransaction(
                to: escrow, data: topUpData, value: 0, chainId: config.chainId
            )
            let receipt = try await rpc.waitForReceipt(txHash: topUpTxHash)
            guard receipt.status else {
                return .failed("TopUp tx reverted: \(topUpTxHash)")
            }
        } catch {
            return .failed("TopUp tx failed: \(error.localizedDescription)")
        }

        // Step 4: Verify on-chain and get confirmed new deposit
        progressHandler?("Verifying on-chain...")
        let escrowClient = EscrowClient(rpc: rpc, escrowAddress: escrow)
        guard let onChain = try? await escrowClient.getChannel(channelId: channel.channelId),
              onChain.exists else {
            return .failed("Could not verify top-up on-chain")
        }
        guard let newDeposit = onChain.deposit.toUInt64 else {
            return .failed("Deposit exceeds UInt64 range")
        }
        return .topped(approveTxHash: approveTxHash, topUpTxHash: topUpTxHash, newDeposit: newDeposit)
    }
}
