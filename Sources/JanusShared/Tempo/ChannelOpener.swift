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

    /// Fund, approve, and open a channel on-chain using a WalletProvider.
    ///
    /// The wallet handles nonce management and signing internally,
    /// so this method only needs to build calldata and wait for receipts.
    ///
    /// - Parameter progressHandler: Optional closure called before each stage with a human-readable status string.
    public func openChannel(wallet: any WalletProvider, channel: Channel,
                            progressHandler: ((String) -> Void)? = nil) async -> OpenResult {
        let escrow = config.escrowContract
        let token = config.paymentToken

        // Check if channel already exists on-chain
        let escrowClient = EscrowClient(rpc: rpc, escrowAddress: escrow)
        if let onChain = try? await escrowClient.getChannel(channelId: channel.channelId),
           onChain.exists {
            return .alreadyOpen(channelId: channel.channelId)
        }

        // Step 1: Fund via testnet faucet
        progressHandler?("Funding wallet...")
        do {
            try await rpc.fundAddress(wallet.address)
            try await Task.sleep(nanoseconds: 3_000_000_000)
        } catch {
            print("Faucet call failed (may already be funded): \(error.localizedDescription)")
        }

        // Step 2: Approve escrow to spend pathUSD
        progressHandler?("Approving token spend...")
        let approveData = EthTransaction.approveCalldata(
            spender: escrow,
            amount: UInt64(channel.deposit) * 10
        )

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

        // Step 3: Open channel
        progressHandler?("Opening payment channel...")
        let openData = EthTransaction.openChannelCalldata(
            payee: channel.payee,
            token: token,
            deposit: channel.deposit,
            salt: channel.salt,
            authorizedSigner: channel.authorizedSigner
        )

        let openTxHash: String
        do {
            openTxHash = try await wallet.sendTransaction(
                to: escrow, data: openData, value: 0, chainId: config.chainId
            )
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

    /// Legacy overload for direct EthKeyPair usage.
    public func openChannel(keyPair: EthKeyPair, channel: Channel) async -> OpenResult {
        let wallet = LocalWalletProvider(keyPair: keyPair, rpcURL: config.rpcURL)
        return await openChannel(wallet: wallet, channel: channel)
    }
}
