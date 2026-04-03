import XCTest
@testable import JanusShared

final class RelayProtocolTests: XCTestCase {

    // MARK: - RelayEnvelope round-trip

    func testRelayEnvelopeSerializationRoundTrip() throws {
        let inner = MessageEnvelope(
            type: .promptRequest,
            senderID: "client-123",
            payload: Data("test-payload".utf8)
        )
        let envelope = try RelayEnvelope.wrap(
            envelope: inner,
            destinationID: "provider-456",
            originID: "client-123",
            routeID: "route-789"
        )

        let data = try envelope.serialized()
        let decoded = try RelayEnvelope.deserialize(from: data)

        XCTAssertEqual(decoded.routeID, "route-789")
        XCTAssertEqual(decoded.destinationID, "provider-456")
        XCTAssertEqual(decoded.originID, "client-123")
        XCTAssertEqual(decoded.hopCount, 0)
        XCTAssertEqual(decoded.maxHops, 3)
    }

    func testRelayEnvelopeUnwrapRecoverOriginalMessage() throws {
        let inner = try MessageEnvelope.wrap(
            type: .promptRequest,
            senderID: "client-ABC",
            payload: ["prompt": "hello world"]
        )
        let relay = try RelayEnvelope.wrap(
            envelope: inner,
            destinationID: "provider-XYZ",
            originID: "client-ABC"
        )

        // Serialize → deserialize → unwrap inner
        let data = try relay.serialized()
        let decoded = try RelayEnvelope.deserialize(from: data)
        let recovered = try decoded.unwrapInner()

        XCTAssertEqual(recovered.type, .promptRequest)
        XCTAssertEqual(recovered.senderID, "client-ABC")
        XCTAssertEqual(recovered.messageID, inner.messageID)

        // Verify payload content survived the relay wrapping
        let payloadDict = try recovered.unwrap(as: [String: String].self)
        XCTAssertEqual(payloadDict["prompt"], "hello world")
    }

    func testRelayEnvelopePreservesHopCount() throws {
        let inner = MessageEnvelope(
            type: .ping,
            senderID: "test",
            payload: Data()
        )
        let envelope = RelayEnvelope(
            routeID: "r1",
            destinationID: "dest",
            originID: "orig",
            hopCount: 2,
            maxHops: 5,
            innerEnvelope: try inner.serialized()
        )

        let data = try envelope.serialized()
        let decoded = try RelayEnvelope.deserialize(from: data)

        XCTAssertEqual(decoded.hopCount, 2)
        XCTAssertEqual(decoded.maxHops, 5)
    }

    // MARK: - RelayAnnounce

    func testRelayAnnounceSerializationRoundTrip() throws {
        let announce = RelayAnnounce(
            relayName: "iPhone-Relay",
            reachableProviders: [
                RelayProviderInfo(
                    providerID: "prov-1",
                    providerName: "Mac Studio",
                    providerPubkey: "abc123",
                    providerEthAddress: "0x1234"
                ),
                RelayProviderInfo(
                    providerID: "prov-2",
                    providerName: "MacBook Pro",
                    providerPubkey: "def456",
                    providerEthAddress: nil
                ),
            ]
        )

        let data = try JSONEncoder.janus.encode(announce)
        let decoded = try JSONDecoder.janus.decode(RelayAnnounce.self, from: data)

        XCTAssertEqual(decoded.relayName, "iPhone-Relay")
        XCTAssertEqual(decoded.reachableProviders.count, 2)
        XCTAssertEqual(decoded.reachableProviders[0].providerName, "Mac Studio")
        XCTAssertEqual(decoded.reachableProviders[1].providerEthAddress, nil)
    }

    func testRelayProviderInfoFromServiceAnnounce() {
        let service = ServiceAnnounce(
            providerID: "prov-99",
            providerName: "Test Provider",
            modelTier: "large-text-v1",
            providerPubkey: "pubkey-base64",
            providerEthAddress: "0xABCD"
        )

        let info = RelayProviderInfo(from: service)

        XCTAssertEqual(info.providerID, "prov-99")
        XCTAssertEqual(info.providerName, "Test Provider")
        XCTAssertEqual(info.providerPubkey, "pubkey-base64")
        XCTAssertEqual(info.providerEthAddress, "0xABCD")
        XCTAssertEqual(info.id, "prov-99") // Identifiable conformance
    }

    // MARK: - MessageType relay cases

    func testRelayMessageTypesSerialize() throws {
        let relayEnv = MessageEnvelope(
            type: .relayEnvelope,
            senderID: "relay-1",
            payload: Data()
        )
        let relayAnn = MessageEnvelope(
            type: .relayAnnounce,
            senderID: "relay-1",
            payload: Data()
        )

        let envData = try relayEnv.serialized()
        let annData = try relayAnn.serialized()

        let decodedEnv = try MessageEnvelope.deserialize(from: envData)
        let decodedAnn = try MessageEnvelope.deserialize(from: annData)

        XCTAssertEqual(decodedEnv.type, .relayEnvelope)
        XCTAssertEqual(decodedAnn.type, .relayAnnounce)
    }

    // MARK: - Edge cases

    func testRelayEnvelopeWithLargePayload() throws {
        // Simulate a large inference response being relayed
        let bigPayload = String(repeating: "x", count: 100_000)
        let inner = try MessageEnvelope.wrap(
            type: .inferenceResponse,
            senderID: "provider-1",
            payload: ["text": bigPayload]
        )
        let relay = try RelayEnvelope.wrap(
            envelope: inner,
            destinationID: "client-1",
            originID: "provider-1"
        )

        let data = try relay.serialized()
        let decoded = try RelayEnvelope.deserialize(from: data)
        let recovered = try decoded.unwrapInner()
        let result = try recovered.unwrap(as: [String: String].self)

        XCTAssertEqual(result["text"]?.count, 100_000)
    }

    func testRelayEnvelopeInnerEnvelopeIsOpaque() throws {
        // The relay should be able to forward without parsing inner content
        let inner = MessageEnvelope(
            type: .voucherAuthorization,
            senderID: "client-1",
            payload: Data("sensitive-voucher-data".utf8)
        )
        let innerData = try inner.serialized()

        let relay = RelayEnvelope(
            routeID: "r1",
            destinationID: "provider-1",
            originID: "client-1",
            innerEnvelope: innerData
        )

        // Relay serializes and deserializes without touching inner
        let wireData = try relay.serialized()
        let decoded = try RelayEnvelope.deserialize(from: wireData)

        // Inner bytes should be identical — relay doesn't modify them
        XCTAssertEqual(decoded.innerEnvelope, innerData)
    }
}
