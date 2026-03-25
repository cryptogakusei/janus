import Foundation

/// Common envelope wrapping all Janus protocol messages.
///
/// Every message exchanged over MPC is serialized as a MessageEnvelope JSON.
/// The `type` field identifies the payload kind, and the `payload` carries
/// the type-specific data as raw JSON.
public struct MessageEnvelope: Codable, Sendable {
    public let type: MessageType
    public let messageID: String
    public let timestamp: Date
    public let senderID: String
    public let payload: Data

    public init(type: MessageType, senderID: String, payload: Data) {
        self.type = type
        self.messageID = UUID().uuidString
        self.timestamp = Date()
        self.senderID = senderID
        self.payload = payload
    }

    /// Encode a typed payload into an envelope.
    public static func wrap<T: Encodable>(
        type: MessageType,
        senderID: String,
        payload: T
    ) throws -> MessageEnvelope {
        let data = try JSONEncoder.janus.encode(payload)
        return MessageEnvelope(type: type, senderID: senderID, payload: data)
    }

    /// Decode the payload into a specific type.
    public func unwrap<T: Decodable>(as: T.Type) throws -> T {
        try JSONDecoder.janus.decode(T.self, from: payload)
    }

    /// Serialize the entire envelope to Data for sending over MPC.
    public func serialized() throws -> Data {
        try JSONEncoder.janus.encode(self)
    }

    /// Deserialize a received Data blob into a MessageEnvelope.
    public static func deserialize(from data: Data) throws -> MessageEnvelope {
        try JSONDecoder.janus.decode(MessageEnvelope.self, from: data)
    }
}

/// All protocol message types.
public enum MessageType: String, Codable, Sendable {
    case serviceAnnounce
    case promptRequest
    case quoteResponse
    case spendAuthorization
    case inferenceResponse
    case errorResponse
    case sessionSync
    case voucherAuthorization
    case ping
    case pong
}

// MARK: - Shared JSON coding configuration

extension JSONEncoder {
    /// Standard encoder for all Janus protocol messages.
    static let janus: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    /// Standard decoder for all Janus protocol messages.
    static let janus: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
