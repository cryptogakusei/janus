import Foundation

/// Ethereum JSON-RPC client for contract calls and transaction submission.
///
/// Supports both read-only `eth_call` and transaction lifecycle methods
/// (`eth_sendRawTransaction`, `eth_getTransactionCount`, `eth_gasPrice`,
/// `eth_getTransactionReceipt`) needed for on-chain channel operations.
public struct EthRPC: Sendable {

    public let rpcURL: URL

    public init(rpcURL: URL) {
        self.rpcURL = rpcURL
    }

    /// Call a contract function (eth_call) and return the raw hex result.
    public func call(to: EthAddress, data: Data, block: String = "latest") async throws -> Data {
        let callParams: [String: String] = [
            "to": to.checksumAddress,
            "data": data.ethHexPrefixed,
        ]
        let result = try await rpcCall(method: "eth_call", params: [callParams, block] as [Any])
        guard let hex = result as? String else { throw RPCError.invalidResponse }
        return try Data(ethHex: hex)
    }

    /// Get the transaction count (nonce) for an address.
    public func getTransactionCount(address: EthAddress, block: String = "latest") async throws -> UInt64 {
        let result = try await rpcCall(method: "eth_getTransactionCount", params: [address.checksumAddress, block])
        return try decodeHexUInt64(result)
    }

    /// Get the current gas price.
    public func gasPrice() async throws -> UInt64 {
        let result = try await rpcCall(method: "eth_gasPrice", params: [String]())
        return try decodeHexUInt64(result)
    }

    /// Send a signed raw transaction. Returns the transaction hash.
    public func sendRawTransaction(signedTx: Data) async throws -> String {
        let result = try await rpcCall(method: "eth_sendRawTransaction", params: [signedTx.ethHexPrefixed])
        guard let txHash = result as? String else {
            throw RPCError.invalidResponse
        }
        return txHash
    }

    /// Get a transaction receipt. Returns nil if the transaction is still pending.
    public func getTransactionReceipt(txHash: String) async throws -> TransactionReceipt? {
        let json = try await rpcCallRaw(method: "eth_getTransactionReceipt", params: [txHash])
        guard let result = json["result"] as? [String: Any] else {
            return nil // pending
        }
        let statusHex = result["status"] as? String ?? "0x0"
        let gasUsedHex = result["gasUsed"] as? String ?? "0x0"
        return TransactionReceipt(
            transactionHash: txHash,
            status: statusHex == "0x1",
            gasUsed: (try? decodeHexUInt64(gasUsedHex as Any)) ?? 0
        )
    }

    /// Wait for a transaction to be mined, polling with the given interval.
    public func waitForReceipt(txHash: String, pollInterval: TimeInterval = 2, timeout: TimeInterval = 60) async throws -> TransactionReceipt {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let receipt = try await getTransactionReceipt(txHash: txHash) {
                return receipt
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw RPCError.rpcError("Transaction not mined within \(Int(timeout))s")
    }

    /// Call the Tempo testnet faucet to fund an address.
    public func fundAddress(_ address: EthAddress) async throws {
        let _ = try await rpcCall(method: "tempo_fundAddress", params: [address.checksumAddress])
    }

    // MARK: - Private helpers

    private func rpcCall(method: String, params: Any) async throws -> Any {
        let json = try await rpcCallRaw(method: method, params: params)
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown RPC error"
            throw RPCError.rpcError(message)
        }
        guard let result = json["result"] else {
            throw RPCError.invalidResponse
        }
        return result as Any
    }

    private func rpcCallRaw(method: String, params: Any) async throws -> [String: Any] {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RPCError.httpError
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw RPCError.invalidResponse
        }
        return json
    }

    private func decodeHexUInt64(_ value: Any) throws -> UInt64 {
        guard let hex = value as? String else { throw RPCError.invalidResponse }
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let val = UInt64(clean, radix: 16) else { throw RPCError.decodingFailed }
        return val
    }
}

/// A simplified transaction receipt.
public struct TransactionReceipt: Sendable {
    public let transactionHash: String
    public let status: Bool  // true = success
    public let gasUsed: UInt64
}

public enum RPCError: Error, LocalizedError {
    case httpError
    case invalidResponse
    case rpcError(String)
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .httpError: return "HTTP request failed"
        case .invalidResponse: return "Invalid JSON-RPC response"
        case .rpcError(let msg): return "RPC error: \(msg)"
        case .decodingFailed: return "Failed to decode contract response"
        }
    }
}
