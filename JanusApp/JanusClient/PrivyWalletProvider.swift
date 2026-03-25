import Foundation
import PrivySDK
import JanusShared

/// A `WalletProvider` backed by Privy's embedded Ethereum wallet.
///
/// Signs vouchers using Privy's EIP-712 `eth_signTypedData_v4` and sends
/// transactions using Privy's `eth_sendTransaction`. The private key never
/// leaves Privy's secure infrastructure — the app only sees signatures.
final class PrivyWalletProvider: WalletProvider, @unchecked Sendable {

    private let wallet: any EmbeddedEthereumWallet

    public let address: EthAddress

    init(wallet: any EmbeddedEthereumWallet) {
        self.wallet = wallet
        // Parse the wallet address from Privy's hex string
        self.address = (try? EthAddress(hex: wallet.address)) ?? EthAddress(Data(repeating: 0, count: 20))
    }

    /// Sign a Tempo voucher using Privy's EIP-712 typed data signing.
    ///
    /// Constructs the full EIP-712 typed data structure matching our Voucher type
    /// and sends it to Privy's embedded wallet for signing.
    public func signVoucher(_ voucher: Voucher, config: TempoConfig) async throws -> SignedVoucher {
        let domain = config.voucherDomain

        // Build EIP-712 typed data for Privy
        let typedData = EthereumRpcRequest.EIP712TypedData(
            domain: .init(
                name: domain.name,
                version: domain.version,
                chainId: Int(config.chainId),
                verifyingContract: config.escrowContract.checksumAddress
            ),
            primaryType: "Voucher",
            types: [
                "EIP712Domain": [
                    .init("name", type: "string"),
                    .init("version", type: "string"),
                    .init("chainId", type: "uint256"),
                    .init("verifyingContract", type: "address"),
                ],
                "Voucher": [
                    .init("channelId", type: "bytes32"),
                    .init("cumulativeAmount", type: "uint128"),
                ],
            ],
            message: VoucherMessage(
                channelId: voucher.channelId.ethHexPrefixed,
                cumulativeAmount: String(voucher.cumulativeAmount)
            )
        )

        let rpcRequest = try EthereumRpcRequest.ethSignTypedDataV4(
            address: wallet.address, typedData: typedData
        )
        let signatureHex = try await wallet.provider.request(rpcRequest)

        // Parse the 65-byte signature (hex) into EthSignature
        let signature = try parseSignature(hex: signatureHex)
        return SignedVoucher(voucher: voucher, signature: signature)
    }

    /// Send a transaction via Privy's embedded wallet provider.
    public func sendTransaction(
        to: EthAddress,
        data: Data,
        value: UInt64,
        chainId: UInt64
    ) async throws -> String {
        let transaction = EthereumRpcRequest.UnsignedEthTransaction(
            to: to.checksumAddress,
            data: data.ethHexPrefixed,
            value: value > 0 ? .int(Int(value)) : .int(0),
            chainId: .hexadecimalNumber("0x" + String(chainId, radix: 16)),
            maxFeePerGas: .hexadecimalNumber("0x1e8480") // 2,000,000
        )

        let rpcRequest = try EthereumRpcRequest.ethSendTransaction(transaction: transaction)
        let txHash = try await wallet.provider.request(rpcRequest)
        return txHash
    }

    // MARK: - Helpers

    /// Parse a hex-encoded 65-byte signature into EthSignature (r, s, v).
    private func parseSignature(hex: String) throws -> EthSignature {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard cleaned.count == 130 else {
            throw WalletProviderError.signingFailed("Invalid signature length: \(cleaned.count / 2) bytes")
        }

        guard let sigData = Data(hexString: cleaned) else {
            throw WalletProviderError.signingFailed("Invalid hex in signature")
        }

        let r = sigData.prefix(32)
        let s = sigData[32..<64]
        let vByte = sigData[64]
        // Normalize v: Privy returns 27/28, EthSignature.v expects 0/1
        let v = vByte >= 27 ? vByte - 27 : vByte

        return EthSignature(r: r, s: Data(s), v: v)
    }
}

/// Codable message struct for EIP-712 Voucher encoding.
private struct VoucherMessage: Encodable, Sendable {
    let channelId: String
    let cumulativeAmount: String
}

// MARK: - Data hex parsing helper

private extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
