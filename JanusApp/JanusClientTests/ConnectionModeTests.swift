import XCTest
@testable import JanusClient

/// Tests for MPCBrowser.ConnectionMode display labels.
///
/// These are pure enum tests — no MPC framework needed.
@MainActor
final class ConnectionModeTests: XCTestCase {

    func testDirectMode_displayLabel() {
        let mode = MPCBrowser.ConnectionMode.direct
        XCTAssertEqual(mode.displayLabel, "Direct")
    }

    func testRelayedMode_displayLabel() {
        let mode = MPCBrowser.ConnectionMode.relayed(relayName: "Bob's iPhone")
        XCTAssertEqual(mode.displayLabel, "via Bob's iPhone")
    }

    func testDisconnectedMode_displayLabel() {
        let mode = MPCBrowser.ConnectionMode.disconnected
        XCTAssertEqual(mode.displayLabel, "Disconnected")
    }

    func testConnectionMode_equality() {
        XCTAssertEqual(MPCBrowser.ConnectionMode.direct, MPCBrowser.ConnectionMode.direct)
        XCTAssertEqual(MPCBrowser.ConnectionMode.disconnected, MPCBrowser.ConnectionMode.disconnected)
        XCTAssertEqual(
            MPCBrowser.ConnectionMode.relayed(relayName: "A"),
            MPCBrowser.ConnectionMode.relayed(relayName: "A")
        )
        XCTAssertNotEqual(
            MPCBrowser.ConnectionMode.relayed(relayName: "A"),
            MPCBrowser.ConnectionMode.relayed(relayName: "B")
        )
        XCTAssertNotEqual(MPCBrowser.ConnectionMode.direct, MPCBrowser.ConnectionMode.disconnected)
    }

    func testConnectionState_rawValues() {
        XCTAssertEqual(MPCBrowser.ConnectionState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(MPCBrowser.ConnectionState.connecting.rawValue, "connecting")
        XCTAssertEqual(MPCBrowser.ConnectionState.connected.rawValue, "connected")
        XCTAssertEqual(MPCBrowser.ConnectionState.connectionFailed.rawValue, "Connection Failed")
    }
}
