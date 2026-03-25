import Foundation

/// Recursive Length Prefix (RLP) encoding for Ethereum transactions.
///
/// RLP is the serialization format used by Ethereum for transactions, state tries,
/// and wire protocol messages. It encodes arbitrarily nested arrays of binary data.
///
/// Spec: https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/
public enum RLP {

    /// An item that can be RLP-encoded: either raw bytes or a list of items.
    public enum Item {
        case bytes(Data)
        case list([Item])
    }

    /// Encode a single RLP item.
    public static func encode(_ item: Item) -> Data {
        switch item {
        case .bytes(let data):
            return encodeBytes(data)
        case .list(let items):
            let payload = items.reduce(Data()) { $0 + encode($1) }
            return encodeLength(payload.count, offset: 0xc0) + payload
        }
    }

    /// Encode a UInt64 as minimal big-endian bytes (no leading zeros).
    public static func encodeUInt(_ value: UInt64) -> Item {
        if value == 0 {
            return .bytes(Data())
        }
        var be = value.bigEndian
        let data = withUnsafeBytes(of: &be) { Data($0) }
        // Strip leading zeros
        let stripped = data.drop(while: { $0 == 0 })
        return .bytes(Data(stripped))
    }

    // MARK: - Private

    private static func encodeBytes(_ data: Data) -> Data {
        if data.count == 1 && data[data.startIndex] < 0x80 {
            // Single byte in [0x00, 0x7f] — encoded as itself
            return data
        }
        return encodeLength(data.count, offset: 0x80) + data
    }

    private static func encodeLength(_ length: Int, offset: Int) -> Data {
        if length < 56 {
            return Data([UInt8(offset + length)])
        }
        let lengthBytes = minimalBigEndian(UInt64(length))
        return Data([UInt8(offset + 55 + lengthBytes.count)]) + lengthBytes
    }

    private static func minimalBigEndian(_ value: UInt64) -> Data {
        var be = value.bigEndian
        let data = withUnsafeBytes(of: &be) { Data($0) }
        let stripped = data.drop(while: { $0 == 0 })
        return stripped.isEmpty ? Data([0]) : Data(stripped)
    }
}
