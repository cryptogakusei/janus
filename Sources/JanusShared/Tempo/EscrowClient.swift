import Foundation

/// Read-only client for the on-chain TempoStreamChannel escrow contract.
///
/// Wraps `EthRPC.call()` with typed ABI encoding/decoding for the functions
/// we need: `getChannel(bytes32)` and `computeChannelId(...)`.
///
/// Used by the provider to verify that a client's claimed channel actually
/// exists on-chain with the expected deposit before accepting vouchers.
public struct EscrowClient: Sendable {

    private let rpc: EthRPC
    private let escrowAddress: EthAddress

    public init(rpc: EthRPC, escrowAddress: EthAddress) {
        self.rpc = rpc
        self.escrowAddress = escrowAddress
    }

    public init(config: TempoConfig) {
        self.rpc = EthRPC(rpcURL: config.rpcURL!, transport: config.transport)
        self.escrowAddress = config.escrowContract
    }

    // MARK: - On-chain channel data

    /// The on-chain channel state, matching ITempoStreamChannel.Channel.
    public struct OnChainChannel: Sendable {
        public let finalized: Bool
        public let closeRequestedAt: UInt64
        public let payer: EthAddress
        public let payee: EthAddress
        public let token: EthAddress
        public let authorizedSigner: EthAddress
        public let deposit: UInt128
        public let settled: UInt128

        /// Whether this channel exists on-chain (payer != address(0)).
        public var exists: Bool {
            payer.data != Data(repeating: 0, count: 20)
        }
    }

    // MARK: - getChannel(bytes32 channelId) → Channel

    /// Fetch a channel's on-chain state by ID.
    ///
    /// Returns `OnChainChannel` which may not exist (check `.exists`).
    public func getChannel(channelId: Data) async throws -> OnChainChannel {
        precondition(channelId.count == 32)

        // Function selector: keccak256("getChannel(bytes32)")[:4]
        let selector = Keccak256.hash(Data("getChannel(bytes32)".utf8)).prefix(4)
        let calldata = selector + ABI.Value.bytes32(channelId).encoded

        let result = try await rpc.call(to: escrowAddress, data: calldata)
        return try decodeChannel(result)
    }

    // MARK: - computeChannelId(address,address,address,bytes32,address) → bytes32

    /// Compute a channel ID on-chain (calls the contract's view function).
    ///
    /// This mirrors `Channel.computeId()` but is the authoritative on-chain version.
    public func computeChannelId(
        payer: EthAddress,
        payee: EthAddress,
        token: EthAddress,
        salt: Data,
        authorizedSigner: EthAddress
    ) async throws -> Data {
        let selector = Keccak256.hash(
            Data("computeChannelId(address,address,address,bytes32,address)".utf8)
        ).prefix(4)
        let calldata = selector + ABI.encode([
            .address(payer),
            .address(payee),
            .address(token),
            .bytes32(salt),
            .address(authorizedSigner),
        ])

        let result = try await rpc.call(to: escrowAddress, data: calldata)
        guard result.count >= 32 else { throw RPCError.decodingFailed }
        return Data(result.prefix(32))
    }

    // MARK: - Decoding

    /// Decode a Channel struct from ABI-encoded return data.
    ///
    /// Layout (8 fields × 32 bytes each = 256 bytes):
    /// [0]  bool finalized        — slot 0, bit
    /// [1]  uint64 closeRequestedAt — slot 1
    /// [2]  address payer         — slot 2
    /// [3]  address payee         — slot 3
    /// [4]  address token         — slot 4
    /// [5]  address authorizedSigner — slot 5
    /// [6]  uint128 deposit       — slot 6
    /// [7]  uint128 settled       — slot 7
    private func decodeChannel(_ data: Data) throws -> OnChainChannel {
        // The struct is returned as 8 fields × 32 bytes = 256 bytes.
        // Some compilers add a 32-byte offset pointer (288 bytes total) — handle both.
        let base: Int
        if data.count >= 288 {
            base = 32  // Skip offset pointer
        } else if data.count >= 256 {
            base = 0   // No offset pointer
        } else {
            throw RPCError.decodingFailed
        }

        func slot(_ i: Int) -> Data {
            let start = base + i * 32
            return Data(data[start..<start+32])
        }

        let finalized = slot(0).last != 0
        let closeRequestedAt = readUInt64(slot(1))
        let payer = try readAddress(slot(2))
        let payee = try readAddress(slot(3))
        let token = try readAddress(slot(4))
        let authorizedSigner = try readAddress(slot(5))
        let deposit = readUInt128(slot(6))
        let settled = readUInt128(slot(7))

        return OnChainChannel(
            finalized: finalized,
            closeRequestedAt: closeRequestedAt,
            payer: payer,
            payee: payee,
            token: token,
            authorizedSigner: authorizedSigner,
            deposit: deposit,
            settled: settled
        )
    }

    private func readAddress(_ slot: Data) throws -> EthAddress {
        // Address is in the last 20 bytes of a 32-byte slot
        guard slot.count == 32 else { throw RPCError.decodingFailed }
        return EthAddress(slot.suffix(20))
    }

    private func readUInt64(_ slot: Data) -> UInt64 {
        // Read last 8 bytes as big-endian UInt64
        let bytes = Array(slot.suffix(8))
        var value: UInt64 = 0
        for b in bytes { value = value << 8 | UInt64(b) }
        return value
    }

    private func readUInt128(_ slot: Data) -> UInt128 {
        // Read last 16 bytes as big-endian UInt128
        let bytes = Array(slot.suffix(16))
        var value = UInt128(high: 0, low: 0)
        for b in bytes { value = value << 8 | UInt128(UInt64(b)) }
        return value
    }
}

/// A 128-bit unsigned integer, matching Solidity's uint128.
///
/// Used for deposit and settled amounts in the escrow contract.
/// Swift doesn't have a built-in UInt128, so we use a simple struct.
public struct UInt128: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64 = 0, low: UInt64) {
        self.high = high
        self.low = low
    }

    public init(_ value: UInt64) {
        self.high = 0
        self.low = value
    }

    /// Failable conversion to UInt64 (returns nil if value > UInt64.max).
    public var toUInt64: UInt64? {
        high == 0 ? low : nil
    }

    public var description: String {
        if high == 0 { return "\(low)" }
        // For display purposes when high != 0
        return "UInt128(\(high),\(low))"
    }

    public static func < (lhs: UInt128, rhs: UInt128) -> Bool {
        if lhs.high != rhs.high { return lhs.high < rhs.high }
        return lhs.low < rhs.low
    }
}

// Extension for shifting/ORing used in byte decoding
extension UInt128 {
    static func << (lhs: UInt128, rhs: Int) -> UInt128 {
        guard rhs > 0 else { return lhs }
        if rhs >= 128 { return UInt128(high: 0, low: 0) }
        if rhs >= 64 {
            return UInt128(high: lhs.low << (rhs - 64), low: 0)
        }
        let newHigh = (lhs.high << rhs) | (lhs.low >> (64 - rhs))
        let newLow = lhs.low << rhs
        return UInt128(high: newHigh, low: newLow)
    }

    static func | (lhs: UInt128, rhs: UInt128) -> UInt128 {
        UInt128(high: lhs.high | rhs.high, low: lhs.low | rhs.low)
    }
}
