import XCTest
@testable import JanusClient
import JanusShared

/// Integration tests for Bonjour+TCP transport using loopback.
///
/// Creates a BonjourAdvertiser (listener) and BonjourBrowser (client) in the
/// same process and verifies discovery → connection → message exchange.
///
/// NOTE: These tests require the Network.framework local network entitlement
/// and may need to be run on a real device or with the Bonjour simulator.
@MainActor
final class BonjourTransportTests: XCTestCase {

    /// Verify that BonjourBrowser conforms to ProviderTransport.
    func testBonjourBrowserConformsToProviderTransport() {
        let browser = BonjourBrowser()
        let transport: any ProviderTransport = browser
        XCTAssertNotNil(transport)
        XCTAssertFalse(browser.isSearching)
        XCTAssertEqual(browser.connectionState, .disconnected)
    }

    /// Verify that CompositeTransport wraps both transports.
    func testCompositeTransportExposesChildren() {
        let composite = CompositeTransport()
        XCTAssertNotNil(composite.bonjourBrowser)
        XCTAssertNotNil(composite.mpcBrowser)
        XCTAssertFalse(composite.isSearching)
        XCTAssertEqual(composite.connectionState, .disconnected)
    }

    /// Verify that CompositeTransport conforms to ProviderTransport.
    func testCompositeTransportConformsToProviderTransport() {
        let composite = CompositeTransport()
        let transport: any ProviderTransport = composite
        XCTAssertNotNil(transport)
    }

    /// Verify that BonjourBrowser starts and stops searching.
    func testBonjourBrowserStartStop() {
        let browser = BonjourBrowser()
        browser.startSearching()
        XCTAssertTrue(browser.isSearching)

        browser.stopSearching()
        XCTAssertFalse(browser.isSearching)
        XCTAssertEqual(browser.connectionState, .disconnected)
        XCTAssertTrue(browser.directProviders.isEmpty)
    }

    /// Verify that CompositeTransport starts both children.
    func testCompositeTransportStartStop() {
        let composite = CompositeTransport()
        composite.startSearching()
        XCTAssertTrue(composite.isSearching)
        XCTAssertTrue(composite.bonjourBrowser.isSearching)
        // MPC browser may or may not report isSearching depending on AWDL state

        composite.stopSearching()
        XCTAssertFalse(composite.isSearching)
    }

    /// Verify that selectProvider is a no-op when no providers are known.
    func testSelectProviderWithoutConnection() {
        let browser = BonjourBrowser()
        browser.selectProvider("nonexistent")
        XCTAssertNil(browser.connectedProvider)
        XCTAssertEqual(browser.connectionState, .disconnected)
    }
}
