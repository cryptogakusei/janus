import Foundation

/// Minimal Solidity ABI encoding for Ethereum.
///
/// Supports the subset needed for EIP-712 struct hashing and escrow contract calls:
/// - `uint256`, `address`, `bytes32`, `bool`
/// - `abi.encode(...)` — padded, concatenated encoding
/// - `abi.encodePacked(...)` — tightly packed, no padding
public enum ABI {

    /// A value that can be ABI-encoded.
    public enum Value {
        case uint256(Data)       // 32-byte big-endian unsigned integer
        case address(EthAddress) // 20 bytes, left-padded to 32
        case bytes32(Data)       // exactly 32 bytes
        case bool(Bool)          // 0 or 1, left-padded to 32

        /// Standard ABI encoding: each value padded to 32 bytes.
        public var encoded: Data {
            switch self {
            case .uint256(let data):
                return leftPad(data, to: 32)
            case .address(let addr):
                return leftPad(addr.data, to: 32)
            case .bytes32(let data):
                precondition(data.count == 32)
                return data
            case .bool(let flag):
                return leftPad(Data([flag ? 1 : 0]), to: 32)
            }
        }

        /// Packed encoding: no padding, tightly concatenated.
        public var packed: Data {
            switch self {
            case .uint256(let data):
                return leftPad(data, to: 32) // uint256 is always 32 bytes even in packed
            case .address(let addr):
                return addr.data             // 20 bytes, no padding
            case .bytes32(let data):
                return data                  // 32 bytes
            case .bool(let flag):
                return Data([flag ? 1 : 0])  // 1 byte
            }
        }
    }

    /// ABI-encode multiple values (standard encoding, each padded to 32 bytes).
    public static func encode(_ values: [Value]) -> Data {
        values.reduce(Data()) { $0 + $1.encoded }
    }

    /// ABI-encodePacked: tightly concatenated, no padding.
    public static func encodePacked(_ values: [Value]) -> Data {
        values.reduce(Data()) { $0 + $1.packed }
    }
}

// MARK: - Convenience initializers for ABI.Value

public extension ABI.Value {
    /// Create a uint256 from a Swift integer.
    static func uint256(_ value: UInt64) -> ABI.Value {
        var bigEndian = value.bigEndian
        let data = withUnsafeBytes(of: &bigEndian) { Data($0) }
        return .uint256(data)
    }

    /// Create a uint256 from a Swift Int (must be non-negative).
    static func uint256(from int: Int) -> ABI.Value {
        precondition(int >= 0, "uint256 cannot be negative")
        return .uint256(UInt64(int))
    }
}

// MARK: - Helpers

private func leftPad(_ data: Data, to size: Int) -> Data {
    if data.count >= size { return data.suffix(size) }
    return Data(repeating: 0, count: size - data.count) + data
}
