import Foundation

/// A `WalletProvider` that guarantees idempotent on-chain transaction submission.
///
/// ## Problem it solves
/// `LocalWalletProvider.sendTransaction` fetches a fresh nonce before every call.
/// If a transaction is submitted and mined but the response is lost (network flap),
/// a naive retry would fetch a new nonce and submit a **second** transaction —
/// double-executing a financial operation (e.g. channel top-up).
///
/// ## How it works
/// 1. Before first submission: sign the transaction and persist
///    `(channelId, operationType, signedBytes, expectedTxHash)` to disk.
/// 2. On retry: resubmit the **same** signed bytes (same nonce, same hash).
/// 3. If the RPC returns "nonce too low" / "already known": check whether
///    `expectedTxHash` was mined. If mined → return success, clear record.
/// 4. On confirmed success: delete the persisted record.
///
/// ## Deduplication
/// Keyed by `(channelId, operationType)`. Only one pending tx per (channel, type)
/// at a time. Calling `sendTransaction` again for the same key resubmits the
/// persisted transaction rather than building a new one.
///
/// ## Persistence
/// Records written to Application Support — survive app termination.
/// On next launch `loadPersistedState()` restores all pending records.
public actor QueueingWalletProvider: WalletProvider {

    nonisolated private let keyPair: EthKeyPair
    private let rpc: EthRPC
    private let signingProvider: LocalWalletProvider

    public nonisolated var address: EthAddress { keyPair.address }

    /// Identifies a pending (submitted but unconfirmed) transaction.
    private struct PendingTx: Codable {
        let channelId: String       // hex string (or "" for non-channel ops)
        let operationType: String   // "approve" | "open" | "topUp" | "settle"
        let signedBytes: Data       // raw signed bytes — resubmit unchanged on retry
        let expectedTxHash: String  // keccak256(signedBytes), used to check receipt
    }

    /// In-memory dedup map. Keyed by `channelId:operationType`.
    private var pendingTxs: [String: PendingTx] = [:]

    public init(keyPair: EthKeyPair, rpc: EthRPC) {
        self.keyPair = keyPair
        self.rpc = rpc
        self.signingProvider = LocalWalletProvider(keyPair: keyPair)
        // Restore any pending txs from a previous session
        for tx in (Self.loadAllPersisted() ?? []) {
            pendingTxs[Self.dedupKey(channelId: tx.channelId, operationType: tx.operationType)] = tx
        }
    }

    // MARK: - WalletProvider conformance

    public func signVoucher(_ voucher: Voucher, config: TempoConfig) async throws -> SignedVoucher {
        // Local ECDSA signing — no network, always works
        try await signingProvider.signVoucher(voucher, config: config)
    }

    /// Standard `sendTransaction` — no dedup context.
    /// Used for one-off transactions not tied to a channel lifecycle.
    public func sendTransaction(
        to: EthAddress,
        data: Data,
        value: UInt64,
        chainId: UInt64
    ) async throws -> String {
        return try await sendTransaction(
            to: to, data: data, value: value, chainId: chainId,
            channelId: "", operationType: "generic-\(UUID().uuidString)"
        )
    }

    // MARK: - Idempotent send

    /// Idempotent `sendTransaction` with explicit dedup context.
    ///
    /// This is the primary entry point for all channel operations.
    ///
    /// - Parameters:
    ///   - channelId: Hex string of the channel ID (for dedup key).
    ///   - operationType: "approve" | "open" | "topUp" | "settle"
    public func sendTransaction(
        to: EthAddress,
        data: Data,
        value: UInt64,
        chainId: UInt64,
        channelId: String,
        operationType: String
    ) async throws -> String {
        let key = Self.dedupKey(channelId: channelId, operationType: operationType)

        // Already have a persisted tx for this operation — resubmit same bytes
        if let existing = pendingTxs[key] {
            print("[QueueingWallet] Retrying persisted \(operationType) for channel \(channelId.prefix(8))…")
            return try await resubmit(existing, key: key)
        }

        // First attempt: sign → persist → submit
        let (signedBytes, txHash) = try await buildAndSign(
            to: to, data: data, value: value, chainId: chainId
        )
        let pending = PendingTx(
            channelId: channelId,
            operationType: operationType,
            signedBytes: signedBytes,
            expectedTxHash: txHash
        )

        // Persist BEFORE submitting — ensures retry is possible even if app is killed post-send
        pendingTxs[key] = pending
        Self.persist(pending, key: key)

        return try await submit(signedBytes: signedBytes, expectedTxHash: txHash, key: key)
    }

    // MARK: - Internal

    private func buildAndSign(
        to: EthAddress,
        data: Data,
        value: UInt64,
        chainId: UInt64
    ) async throws -> (signedBytes: Data, txHash: String) {
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
        // tx hash = keccak256 of the signed RLP bytes
        let txHash = "0x" + Keccak256.hash(signed).map { String(format: "%02x", $0) }.joined()
        return (signed, txHash)
    }

    private func submit(signedBytes: Data, expectedTxHash: String, key: String) async throws -> String {
        do {
            let txHash = try await rpc.sendRawTransaction(signedTx: signedBytes)
            clearPending(key: key)
            return txHash
        } catch let error as RPCError {
            if isNonceTooLow(error) || isKnownTransaction(error) {
                // Transaction was already submitted — verify it was mined
                if let receipt = try? await rpc.getTransactionReceipt(txHash: expectedTxHash),
                   receipt.status {
                    print("[QueueingWallet] Tx already mined: \(expectedTxHash)")
                    clearPending(key: key)
                    return expectedTxHash
                }
            }
            throw error
        }
    }

    private func resubmit(_ tx: PendingTx, key: String) async throws -> String {
        try await submit(signedBytes: tx.signedBytes, expectedTxHash: tx.expectedTxHash, key: key)
    }

    private func clearPending(key: String) {
        pendingTxs.removeValue(forKey: key)
        Self.deletePersisted(key: key)
    }

    // MARK: - Error classification

    private func isNonceTooLow(_ error: RPCError) -> Bool {
        guard case .rpcError(let msg) = error else { return false }
        let lower = msg.lowercased()
        return lower.contains("nonce too low") || lower.contains("nonce already used")
    }

    private func isKnownTransaction(_ error: RPCError) -> Bool {
        guard case .rpcError(let msg) = error else { return false }
        let lower = msg.lowercased()
        return lower.contains("already known") || lower.contains("replacement transaction")
    }

    // MARK: - Persistence

    private static func dedupKey(channelId: String, operationType: String) -> String {
        "\(channelId):\(operationType)"
    }

    private static var storageDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("JanusPayments/PendingTxs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(key: String) -> URL {
        let safe = key
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return storageDir.appendingPathComponent("\(safe).json")
    }

    private static func persist(_ tx: PendingTx, key: String) {
        guard let data = try? JSONEncoder().encode(tx) else { return }
        try? data.write(to: fileURL(key: key), options: .atomic)
    }

    private static func deletePersisted(key: String) {
        try? FileManager.default.removeItem(at: fileURL(key: key))
    }

    private static func loadAllPersisted() -> [PendingTx]? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageDir, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PendingTx.self, from: data)
        }
    }
}
