import Foundation

/// Routing wrapper for messages forwarded through relay nodes.
///
/// The relay reads the routing fields (destinationID, originID, hopCount)
/// but treats `innerEnvelope` as opaque bytes — it forwards without parsing.
/// The provider never sees this wrapper; the relay unwraps before delivery.
public struct RelayEnvelope: Codable, Sendable {
    /// Unique route identifier for this client-provider pair.
    public let routeID: String
    /// Target provider ID (client→provider) or client session ID (provider→client).
    public let destinationID: String
    /// Original sender's ID (client session ID or provider ID).
    public let originID: String
    /// Current hop count (incremented at each relay).
    public let hopCount: Int
    /// Maximum allowed hops before the message is dropped.
    public let maxHops: Int
    /// The original MessageEnvelope serialized as opaque bytes.
    public let innerEnvelope: Data

    public init(
        routeID: String = UUID().uuidString,
        destinationID: String,
        originID: String,
        hopCount: Int = 0,
        maxHops: Int = 3,
        innerEnvelope: Data
    ) {
        self.routeID = routeID
        self.destinationID = destinationID
        self.originID = originID
        self.hopCount = hopCount
        self.maxHops = maxHops
        self.innerEnvelope = innerEnvelope
    }

    /// Wrap a MessageEnvelope into a RelayEnvelope for forwarding.
    public static func wrap(
        envelope: MessageEnvelope,
        destinationID: String,
        originID: String,
        routeID: String = UUID().uuidString
    ) throws -> RelayEnvelope {
        let data = try envelope.serialized()
        return RelayEnvelope(
            routeID: routeID,
            destinationID: destinationID,
            originID: originID,
            innerEnvelope: data
        )
    }

    /// Extract the inner MessageEnvelope.
    public func unwrapInner() throws -> MessageEnvelope {
        try MessageEnvelope.deserialize(from: innerEnvelope)
    }

    /// Serialize for sending over MPC.
    public func serialized() throws -> Data {
        try JSONEncoder.janus.encode(self)
    }

    /// Deserialize from received MPC data.
    public static func deserialize(from data: Data) throws -> RelayEnvelope {
        try JSONDecoder.janus.decode(RelayEnvelope.self, from: data)
    }
}
