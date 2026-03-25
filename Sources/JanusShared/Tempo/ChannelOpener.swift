import Foundation

/// Handles on-chain channel setup: fund (testnet), approve escrow, open channel.
///
/// Called by the client after `setupTempoChannel()` creates the off-chain channel state.
/// Performs three sequential on-chain transactions:
/// 1. Fund the client address via testnet faucet (skipped if already funded)
/// 2. Approve the escrow contract to spend pathUSD
/// 3. Call `escrow.open()` to create the payment channel on-chain
///
/// All operations are idempotent — safe to retry on failure.
public struct ChannelOpener: Sendable {

    public let rpc: EthRPC
    public let config: TempoConfig

    public init(config: TempoConfig) {
        guard let url = config.rpcURL else {
            fatalError("ChannelOpener requires a TempoConfig with rpcURL")
        }
        self.rpc = EthRPC(rpcURL: url)
        self.config = config
    }

    /// Result of the channel opening process.
    public enum OpenResult: Sendable {
        case opened(channelId: Data, approveTxHash: String, openTxHash: String)
        case alreadyOpen(channelId: Data)
        case failed(String)
    }

    /// Fund, approve, and open a channel on-chain.
    ///
    /// - Parameters:
    ///   - keyPair: The client's ETH keypair (payer + signer)
    ///   - channel: The off-chain channel state (contains payee, token, salt, deposit)
    /// - Returns: The result of the operation
    public func openChannel(keyPair: EthKeyPair, channel: Channel) async -> OpenResult {
        let escrow = config.escrowContract
        let token = config.paymentToken

        // Check if channel already exists on-chain
        let escrowClient = EscrowClient(rpc: rpc, escrowAddress: escrow)
        if let onChain = try? await escrowClient.getChannel(channelId: channel.channelId),
           onChain.exists {
            return .alreadyOpen(channelId: channel.channelId)
        }

        // Step 1: Fund via testnet faucet
        do {
            try await rpc.fundAddress(keyPair.address)
            // Brief delay for faucet tx to confirm
            try await Task.sleep(nanoseconds: 3_000_000_000)
        } catch {
            // Non-fatal — may already be funded
            print("Faucet call failed (may already be funded): \(error.localizedDescription)")
        }

        // Get gas price and nonce
        let gasPrice: UInt64
        let startNonce: UInt64
        do {
            gasPrice = try await rpc.gasPrice()
            startNonce = try await rpc.getTransactionCount(address: keyPair.address)
        } catch {
            return .failed("Failed to get gas info: \(error.localizedDescription)")
        }

        // Step 2: Approve escrow to spend pathUSD
        let approveTx = EthTransaction.approve(
            token: token,
            spender: escrow,
            amount: UInt64(channel.deposit) * 10,  // approve more than needed for top-ups
            nonce: startNonce,
            gasPrice: gasPrice,
            chainId: config.chainId
        )

        let approveTxHash: String
        do {
            let signed = try approveTx.sign(with: keyPair)
            approveTxHash = try await rpc.sendRawTransaction(signedTx: signed)
            let receipt = try await rpc.waitForReceipt(txHash: approveTxHash)
            guard receipt.status else {
                return .failed("Approve tx reverted: \(approveTxHash)")
            }
        } catch {
            return .failed("Approve failed: \(error.localizedDescription)")
        }

        // Step 3: Open channel
        let openTx = EthTransaction.openChannel(
            escrow: escrow,
            payee: channel.payee,
            token: token,
            deposit: channel.deposit,
            salt: channel.salt,
            authorizedSigner: channel.authorizedSigner,
            nonce: startNonce + 1,
            gasPrice: gasPrice,
            chainId: config.chainId
        )

        let openTxHash: String
        do {
            let signed = try openTx.sign(with: keyPair)
            openTxHash = try await rpc.sendRawTransaction(signedTx: signed)
            let receipt = try await rpc.waitForReceipt(txHash: openTxHash)
            guard receipt.status else {
                return .failed("Open tx reverted: \(openTxHash)")
            }
        } catch {
            return .failed("Open channel failed: \(error.localizedDescription)")
        }

        return .opened(
            channelId: channel.channelId,
            approveTxHash: approveTxHash,
            openTxHash: openTxHash
        )
    }
}
