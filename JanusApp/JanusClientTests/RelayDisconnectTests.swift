import XCTest
@testable import JanusClient
import JanusShared

/// Protocol-level tests for relay disconnect handling.
///
/// Verifies that the new providerUnreachable error code and
/// empty RelayAnnounce round-trip correctly through the protocol.
@MainActor
final class RelayDisconnectTests: XCTestCase {

    // MARK: - RelayAnnounce with empty providers

    func testRelayAnnounce_emptyProviders_roundTrips() throws {
        let announce = RelayAnnounce(relayName: "TestRelay", reachableProviders: [])
        let envelope = try MessageEnvelope.wrap(type: .relayAnnounce, senderID: "relay", payload: announce)
        let data = try envelope.serialized()
        let restored = try MessageEnvelope.deserialize(from: data)

        XCTAssertEqual(restored.type, .relayAnnounce)
        let decoded = try restored.unwrap(as: RelayAnnounce.self)
        XCTAssertEqual(decoded.relayName, "TestRelay")
        XCTAssertTrue(decoded.reachableProviders.isEmpty, "Empty providers list should survive round-trip")
    }

    // MARK: - providerUnreachable ErrorResponse

    func testProviderUnreachableError_roundTrips() throws {
        let error = ErrorResponse(
            requestID: nil,
            errorCode: .providerUnreachable,
            errorMessage: "Provider is no longer reachable through this relay"
        )
        let envelope = try MessageEnvelope.wrap(type: .errorResponse, senderID: "relay", payload: error)
        let data = try envelope.serialized()
        let restored = try MessageEnvelope.deserialize(from: data)

        XCTAssertEqual(restored.type, .errorResponse)
        let decoded = try restored.unwrap(as: ErrorResponse.self)
        XCTAssertEqual(decoded.errorCode, .providerUnreachable)
        XCTAssertNil(decoded.requestID, "Relay doesn't know requestID — should be nil")
        XCTAssertTrue(decoded.errorMessage.contains("reachable"))
    }

    // MARK: - RelayEnvelope wrapping an ErrorResponse

    func testRelayEnvelope_wrappingErrorResponse_roundTrips() throws {
        // Simulate what MPCRelay.sendProviderUnreachableError does
        let error = ErrorResponse(
            requestID: nil,
            errorCode: .providerUnreachable,
            errorMessage: "Provider is no longer reachable through this relay"
        )
        let innerEnvelope = try MessageEnvelope.wrap(
            type: .errorResponse,
            senderID: "relay",
            payload: error
        )
        let relayEnvelope = try RelayEnvelope.wrap(
            envelope: innerEnvelope,
            destinationID: "client",
            originID: "relay"
        )

        // Serialize and deserialize
        let data = try relayEnvelope.serialized()
        let restored = try RelayEnvelope.deserialize(from: data)

        XCTAssertEqual(restored.destinationID, "client")
        XCTAssertEqual(restored.originID, "relay")

        // Unwrap inner envelope
        let unwrapped = try restored.unwrapInner()
        XCTAssertEqual(unwrapped.type, .errorResponse)

        let decoded = try unwrapped.unwrap(as: ErrorResponse.self)
        XCTAssertEqual(decoded.errorCode, .providerUnreachable)
    }
}
