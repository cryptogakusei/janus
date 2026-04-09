import XCTest
@testable import JanusClient
import JanusShared

/// Tests for dual mode: RelayLocalTransport and response routing.
///
/// These tests verify the local transport adapter and the response queue
/// routing logic without requiring real MPC connections.
@MainActor
final class DualModeTests: XCTestCase {

    private var relay: MPCRelay!

    override func setUp() {
        super.setUp()
        relay = MPCRelay()
    }

    override func tearDown() {
        relay = nil
        super.tearDown()
    }

    // MARK: - RelayLocalTransport basics

    func testEnableLocalClient_createsTransport() {
        let transport = relay.enableLocalClient()
        XCTAssertNotNil(relay.localTransport)
        XCTAssertTrue(transport === relay.localTransport)
    }

    func testLocalTransport_initialState_disconnected() {
        let transport = relay.enableLocalClient()
        XCTAssertNil(transport.connectedProvider)
        XCTAssertEqual(transport.connectionState, .disconnected)
        XCTAssertEqual(transport.connectionMode, .disconnected)
        XCTAssertFalse(transport.isSearching)
    }

    func testLocalTransport_connectionMode_directWhenConnected() {
        let transport = relay.enableLocalClient()
        // Simulate provider connection
        let announce = ServiceAnnounce(
            providerID: "prov-1", providerName: "Test Mac",
            providerPubkey: "", providerEthAddress: ""
        )
        transport.connectedProvider = announce
        XCTAssertEqual(transport.connectionMode, .direct)
    }

    func testLocalTransport_connectionMode_disconnectedWhenNil() {
        let transport = relay.enableLocalClient()
        transport.connectedProvider = nil
        XCTAssertEqual(transport.connectionMode, .disconnected)
    }

    func testLocalTransport_startStopSearching_noOps() {
        let transport = relay.enableLocalClient()
        // These should not crash or change state
        transport.startSearching()
        transport.stopSearching()
        transport.checkConnectionHealth()
        XCTAssertFalse(transport.isSearching)
    }

    func testLocalTransport_sendThrows_whenNoProvider() {
        let transport = relay.enableLocalClient()
        let envelope = try! MessageEnvelope.wrap(
            type: .promptRequest, senderID: "client-1",
            payload: PromptRequest(
                requestID: "req-1", sessionID: "sess-1",
                taskType: .summarize, promptText: "test",
                parameters: .init()
            )
        )
        XCTAssertThrowsError(try transport.send(envelope))
    }

    // MARK: - ClientEngine with RelayLocalTransport

    func testClientEngine_acceptsLocalTransport() {
        let transport = relay.enableLocalClient()
        let engine = ClientEngine(transport: transport)
        XCTAssertNil(engine.compositeRef, "compositeRef should be nil for non-CompositeTransport transport")
        XCTAssertEqual(engine.connectionState, .disconnected)
    }

    func testClientEngine_forwardsConnectionState_fromLocalTransport() {
        let transport = relay.enableLocalClient()
        let engine = ClientEngine(transport: transport)

        // Simulate provider appearing
        let announce = ServiceAnnounce(
            providerID: "prov-1", providerName: "Test Mac",
            providerPubkey: "", providerEthAddress: ""
        )
        transport.connectedProvider = announce
        transport.connectionState = .connected

        // Give Combine publishers time to propagate
        let expectation = XCTestExpectation(description: "State propagation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(engine.connectionState, .connected)
        XCTAssertNotNil(engine.connectedProvider)
        XCTAssertEqual(engine.connectedProvider?.providerID, "prov-1")
    }

    func testClientEngine_receivesMessages_viaLocalTransport() throws {
        let transport = relay.enableLocalClient()
        let engine = ClientEngine(transport: transport)

        // Set up engine state to accept a quote
        engine.pendingRequestID = "req-1"
        engine.requestState = .waitingForQuote

        // Simulate provider sending a quote through the local transport.
        // Call handleMessage directly (onMessageReceived dispatches via Task,
        // which won't resolve synchronously in tests).
        let quote = QuoteResponse(
            requestID: "req-1", priceCredits: 5,
            priceTier: "medium", expiresAt: Date().addingTimeInterval(60)
        )
        let envelope = try MessageEnvelope.wrap(
            type: .quoteResponse, senderID: "prov-1", payload: quote
        )
        engine.handleMessage(envelope)

        XCTAssertNotNil(engine.currentQuote)
        XCTAssertEqual(engine.currentQuote?.priceCredits, 5)
    }

    // MARK: - enableLocalClient mirrors existing provider state

    func testEnableLocalClient_mirrorsExistingProvider() {
        // Pre-populate relay with a provider (simulating already connected)
        let announce = ServiceAnnounce(
            providerID: "prov-1", providerName: "Test Mac",
            providerPubkey: "", providerEthAddress: ""
        )
        relay.reachableProviders["prov-1"] = announce

        let transport = relay.enableLocalClient()
        XCTAssertNotNil(transport.connectedProvider)
        XCTAssertEqual(transport.connectedProvider?.providerID, "prov-1")
        XCTAssertEqual(transport.connectionState, .connected)
    }

    func testEnableLocalClient_noProvider_staysDisconnected() {
        // No providers registered
        let transport = relay.enableLocalClient()
        XCTAssertNil(transport.connectedProvider)
        XCTAssertEqual(transport.connectionState, .disconnected)
    }
}
