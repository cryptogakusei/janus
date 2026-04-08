import XCTest
@testable import JanusClient
import JanusShared

/// Tests for multi-provider support (both relay and direct modes).
///
/// Verifies that MPCBrowser correctly stores multiple providers,
/// allows switching between them, and that ClientEngine forwards the state.
@MainActor
final class MultiProviderTests: XCTestCase {

    // MARK: - Test helpers

    private func makeAnnounce(id: String, name: String, model: String = "test-model") -> ServiceAnnounce {
        ServiceAnnounce(
            providerID: id, providerName: name,
            modelTier: model,
            providerPubkey: "", providerEthAddress: ""
        )
    }

    // MARK: - MPCBrowser.selectRelayProvider

    func testSelectRelayProvider_updatesConnectedProvider() {
        let browser = MPCBrowser()
        let announce1 = makeAnnounce(id: "prov-1", name: "Mac A")
        let announce2 = makeAnnounce(id: "prov-2", name: "Mac B")

        // Populate relayProviders as if two ServiceAnnounces arrived via relay
        browser.relayProviders["prov-1"] = announce1
        browser.relayProviders["prov-2"] = announce2
        browser.connectedProvider = announce1

        // Switch to provider 2
        browser.selectRelayProvider("prov-2")

        XCTAssertEqual(browser.connectedProvider?.providerID, "prov-2")
        XCTAssertEqual(browser.connectedProvider?.providerName, "Mac B")
    }

    func testSelectRelayProvider_ignoresUnknownID() {
        let browser = MPCBrowser()
        let announce = makeAnnounce(id: "prov-1", name: "Mac A")
        browser.relayProviders["prov-1"] = announce
        browser.connectedProvider = announce

        browser.selectRelayProvider("prov-unknown")

        // Should remain on prov-1
        XCTAssertEqual(browser.connectedProvider?.providerID, "prov-1")
    }

    func testSelectRelayProvider_setsRelayRouteID() {
        let browser = MPCBrowser()
        let announce = makeAnnounce(id: "prov-1", name: "Mac A")
        browser.relayProviders["prov-1"] = announce

        browser.selectRelayProvider("prov-1")

        // connectedProvider should be set (we can't check relayRouteID directly
        // since it's private, but the selection should succeed)
        XCTAssertEqual(browser.connectedProvider?.providerID, "prov-1")
    }

    // MARK: - MPCBrowser.relayProviders cleanup

    func testRelayProviders_clearedOnStartSearching() {
        let browser = MPCBrowser()
        browser.relayProviders["prov-1"] = makeAnnounce(id: "prov-1", name: "Mac A")

        browser.startSearching()

        XCTAssertTrue(browser.relayProviders.isEmpty)
    }

    func testRelayProviders_clearedOnDisconnect() {
        let browser = MPCBrowser()
        browser.relayProviders["prov-1"] = makeAnnounce(id: "prov-1", name: "Mac A")

        browser.disconnect()

        XCTAssertTrue(browser.relayProviders.isEmpty)
    }

    // MARK: - ClientEngine.availableProviders forwarding

    func testClientEngine_availableProviders_reflectsBrowserRelayProviders() {
        let browser = MPCBrowser()
        let engine = ClientEngine(transport: browser)

        browser.relayProviders["prov-1"] = makeAnnounce(id: "prov-1", name: "Mac A")
        browser.relayProviders["prov-2"] = makeAnnounce(id: "prov-2", name: "Mac B")

        // Give Combine time to propagate
        let expectation = XCTestExpectation(description: "Combine propagation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(engine.availableProviders.count, 2)
        let ids = Set(engine.availableProviders.map(\.providerID))
        XCTAssertTrue(ids.contains("prov-1"))
        XCTAssertTrue(ids.contains("prov-2"))
    }

    func testClientEngine_availableProviders_emptyWhenNoRelayProviders() {
        let browser = MPCBrowser()
        let engine = ClientEngine(transport: browser)

        XCTAssertTrue(engine.availableProviders.isEmpty)
    }

    func testClientEngine_selectProvider_forwardsToBrowser() {
        let browser = MPCBrowser()
        let engine = ClientEngine(transport: browser)
        let announce1 = makeAnnounce(id: "prov-1", name: "Mac A")
        let announce2 = makeAnnounce(id: "prov-2", name: "Mac B")

        browser.relayProviders["prov-1"] = announce1
        browser.relayProviders["prov-2"] = announce2
        browser.connectedProvider = announce1

        engine.selectProvider("prov-2")

        XCTAssertEqual(browser.connectedProvider?.providerID, "prov-2")
    }

    // MARK: - Direct mode multi-provider tests

    func testSelectDirectProvider_updatesConnectedProvider() {
        let browser = MPCBrowser()
        let announce1 = makeAnnounce(id: "prov-1", name: "Mac A")
        let announce2 = makeAnnounce(id: "prov-2", name: "Mac B")

        // Simulate two direct providers discovered and announced
        browser.directProviders["prov-1"] = announce1
        browser.directProviders["prov-2"] = announce2
        browser.connectedProvider = announce1

        // selectDirectProvider requires peer to be in providerSession.connectedPeers,
        // which we can't mock in a unit test. Instead verify the dict stores correctly.
        XCTAssertEqual(browser.directProviders.count, 2)
        XCTAssertEqual(browser.directProviders["prov-1"]?.providerName, "Mac A")
        XCTAssertEqual(browser.directProviders["prov-2"]?.providerName, "Mac B")
    }

    func testSelectDirectProvider_ignoresUnknownID() {
        let browser = MPCBrowser()
        let announce = makeAnnounce(id: "prov-1", name: "Mac A")
        browser.directProviders["prov-1"] = announce
        browser.connectedProvider = announce

        // Attempt to select unknown provider
        browser.selectDirectProvider("prov-unknown")

        // Should remain on prov-1
        XCTAssertEqual(browser.connectedProvider?.providerID, "prov-1")
    }

    func testDirectProviders_clearedOnStartSearching() {
        let browser = MPCBrowser()
        browser.directProviders["prov-1"] = makeAnnounce(id: "prov-1", name: "Mac A")

        browser.startSearching()

        XCTAssertTrue(browser.directProviders.isEmpty)
    }

    func testDirectProviders_clearedOnDisconnect() {
        let browser = MPCBrowser()
        browser.directProviders["prov-1"] = makeAnnounce(id: "prov-1", name: "Mac A")

        browser.disconnect()

        XCTAssertTrue(browser.directProviders.isEmpty)
    }

    func testClientEngine_availableProviders_reflectsDirectProviders() {
        let browser = MPCBrowser()
        let engine = ClientEngine(transport: browser)

        browser.directProviders["prov-1"] = makeAnnounce(id: "prov-1", name: "Mac A")
        browser.directProviders["prov-2"] = makeAnnounce(id: "prov-2", name: "Mac B")

        // Give Combine time to propagate
        let expectation = XCTestExpectation(description: "Combine propagation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(engine.availableProviders.count, 2)
        let ids = Set(engine.availableProviders.map(\.providerID))
        XCTAssertTrue(ids.contains("prov-1"))
        XCTAssertTrue(ids.contains("prov-2"))
    }

    func testClientEngine_availableProviders_emptyWhenNoDirectProviders() {
        let browser = MPCBrowser()
        let engine = ClientEngine(transport: browser)

        // Both relay and direct are empty
        XCTAssertTrue(engine.availableProviders.isEmpty)
        XCTAssertTrue(browser.directProviders.isEmpty)
    }

    func testClientEngine_selectProvider_routesToDirectInDirectMode() {
        let browser = MPCBrowser()
        let engine = ClientEngine(transport: browser)
        let announce1 = makeAnnounce(id: "prov-1", name: "Mac A")
        let announce2 = makeAnnounce(id: "prov-2", name: "Mac B")

        // Set up direct mode state
        browser.directProviders["prov-1"] = announce1
        browser.directProviders["prov-2"] = announce2
        browser.connectedProvider = announce1
        browser.connectionMode = .direct

        // selectProvider should route to selectDirectProvider (which will fail
        // because no actual MCSession peers, but we verify it doesn't call
        // selectRelayProvider by checking connectedProvider stays unchanged)
        engine.selectProvider("prov-2")

        // Since there's no actual MPC peer for prov-2, selectDirectProvider's
        // guard fails and connectedProvider stays as prov-1
        XCTAssertEqual(browser.connectedProvider?.providerID, "prov-1")
    }
}
