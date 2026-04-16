import Foundation

/// Abstracts Ethereum wallet operations needed by the Janus client.
///
/// Primary implementation: `LocalWalletProvider` — wraps a raw `EthKeyPair` for
/// offline-capable signing and on-chain transaction sending.
///
/// This protocol lives in JanusShared so both the shared library and the client app
/// can reference it without pulling platform-specific SDKs into the provider or test targets.
public protocol WalletProvider: Sendable {

    /// The Ethereum address of this wallet.
    var address: EthAddress { get }

    /// Sign a Tempo voucher using EIP-712 typed data signing.
    func signVoucher(_ voucher: Voucher, config: TempoConfig) async throws -> SignedVoucher

    /// Send a raw transaction and return the tx hash.
    /// Used for channel opening (approve + open) and other on-chain operations.
    func sendTransaction(
        to: EthAddress,
        data: Data,
        value: UInt64,
        chainId: UInt64
    ) async throws -> String
}

/// A wallet provider backed by a local `EthKeyPair`.
///
/// Signs vouchers and transactions directly using the raw private key.
/// Used by the provider (settlement), tests, and as an offline fallback.
public struct LocalWalletProvider: WalletProvider {

    private let keyPair: EthKeyPair
    private let rpc: EthRPC?

    public var address: EthAddress { keyPair.address }

    /// Create with a keypair and optional RPC for transaction sending.
    /// If rpc is nil, `sendTransaction` will throw.
    public init(keyPair: EthKeyPair, rpcURL: URL? = nil, urlSession: URLSession = .shared) {
        self.keyPair = keyPair
        self.rpc = rpcURL.map { EthRPC(rpcURL: $0, session: urlSession) }
    }

    public func signVoucher(_ voucher: Voucher, config: TempoConfig) async throws -> SignedVoucher {
        try voucher.sign(with: keyPair, config: config)
    }

    public func sendTransaction(
        to: EthAddress,
        data: Data,
        value: UInt64,
        chainId: UInt64
    ) async throws -> String {
        guard let rpc else {
            throw WalletProviderError.noRPC
        }
        let gasPrice = try await rpc.gasPrice()
        let nonce = try await rpc.getTransactionCount(address: keyPair.address)
        let tx = EthTransaction(
            nonce: nonce,
            gasPrice: gasPrice,
            gasLimit: 2_000_000,
            to: to,
            value: value,
            data: data,
            chainId: chainId
        )
        let signed = try tx.sign(with: keyPair)
        return try await rpc.sendRawTransaction(signedTx: signed)
    }
}

public enum WalletProviderError: Error, LocalizedError {
    case noRPC
    case signingFailed(String)
    case transactionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noRPC: return "No RPC endpoint configured for transaction sending"
        case .signingFailed(let reason): return "Signing failed: \(reason)"
        case .transactionFailed(let reason): return "Transaction failed: \(reason)"
        }
    }
}
