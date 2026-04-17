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

    /// The URLSession used for all RPC calls (legacy; `transport` is authoritative).
    ///
    /// Kept for backward compatibility with `LocalWalletProvider` and the legacy
    /// `ChannelOpener.openChannel(keyPair:channel:)` path. New code should use `transport`.
    public let urlSession: URLSession

    /// The HTTP transport used by `EthRPC` for all blockchain RPC calls.
    ///
    /// Defaults to a `URLSessionTransport` wrapping `urlSession`.
    /// iOS clients inject `CellularTransport` via `PaymentConnectivityManager.internetTransport`
    /// so payment traffic is deterministically routed over cellular when WiFi has no WAN uplink.
    public let transport: any HTTPTransport

    /// The EIP-712 domain for voucher signing.
    public var voucherDomain: EIP712.Domain {
        EIP712.Domain(
            name: "Tempo Stream Channel",
            version: "1",
            chainId: chainId,
            verifyingContract: escrowContract
        )
    }

    /// Create with a URLSession (backward-compatible convenience init).
    public init(escrowContract: EthAddress, paymentToken: EthAddress, chainId: UInt64,
                rpcURL: URL? = nil, urlSession: URLSession = .shared) {
        self.escrowContract = escrowContract
        self.paymentToken = paymentToken
        self.chainId = chainId
        self.rpcURL = rpcURL
        self.urlSession = urlSession
        self.transport = URLSessionTransport(session: urlSession)
    }

    /// Create with an explicit HTTP transport (e.g. `CellularTransport` on iOS).
    public init(escrowContract: EthAddress, paymentToken: EthAddress, chainId: UInt64,
                rpcURL: URL? = nil, transport: any HTTPTransport) {
        self.escrowContract = escrowContract
        self.paymentToken = paymentToken
        self.chainId = chainId
        self.rpcURL = rpcURL
        self.urlSession = .shared  // legacy compat; transport is authoritative
        self.transport = transport
    }
}

// MARK: - Known configurations

public extension TempoConfig {
    /// Tempo Moderato testnet.
    ///
    /// - Chain ID: 42431
    /// - Escrow: TempoStreamChannel deployed at 0x50bb629A22DBeA358238806D6D8c899c8c73Ad2e (CLOSE_GRACE_PERIOD = 24h)
    /// - Token: pathUSD at 0x20C0000000000000000000000000000000000000
    /// - RPC: https://rpc.moderato.tempo.xyz
    static let testnet = TempoConfig(
        escrowContract: try! EthAddress(hex: "0x50bb629A22DBeA358238806D6D8c899c8c73Ad2e"),
        paymentToken: try! EthAddress(hex: "0x20C0000000000000000000000000000000000000"),
        chainId: 42431,
        rpcURL: URL(string: "https://rpc.moderato.tempo.xyz")
    )
}
