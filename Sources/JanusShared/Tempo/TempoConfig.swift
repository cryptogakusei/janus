import Foundation

/// Configuration for the Tempo payment channel network.
///
/// Holds chain-specific constants (escrow contract address, chain ID, token address)
/// and the EIP-712 domain used for voucher signing.
public struct TempoConfig: Sendable {

    /// The escrow smart contract address.
    public let escrowContract: EthAddress

    /// The TIP-20 token used for payments (e.g. pathUSD).
    public let paymentToken: EthAddress

    /// The chain ID of the network.
    public let chainId: UInt64

    /// The JSON-RPC endpoint URL (optional — nil for off-chain-only mode).
    public let rpcURL: URL?

    /// The EIP-712 domain for voucher signing.
    public var voucherDomain: EIP712.Domain {
        EIP712.Domain(
            name: "Tempo Stream Channel",
            version: "1",
            chainId: chainId,
            verifyingContract: escrowContract
        )
    }

    public init(escrowContract: EthAddress, paymentToken: EthAddress, chainId: UInt64, rpcURL: URL? = nil) {
        self.escrowContract = escrowContract
        self.paymentToken = paymentToken
        self.chainId = chainId
        self.rpcURL = rpcURL
    }
}

// MARK: - Known configurations

public extension TempoConfig {
    /// Tempo Moderato testnet.
    ///
    /// - Chain ID: 42431
    /// - Escrow: TempoStreamChannel deployed at 0xaB7409f3ea73952FC8C762ce7F01F245314920d9
    /// - Token: pathUSD at 0x20C0000000000000000000000000000000000000
    /// - RPC: https://rpc.moderato.tempo.xyz
    static let testnet = TempoConfig(
        escrowContract: try! EthAddress(hex: "0xaB7409f3ea73952FC8C762ce7F01F245314920d9"),
        paymentToken: try! EthAddress(hex: "0x20C0000000000000000000000000000000000000"),
        chainId: 42431,
        rpcURL: URL(string: "https://rpc.moderato.tempo.xyz")
    )
}
