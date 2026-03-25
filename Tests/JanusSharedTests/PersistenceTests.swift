import XCTest
@testable import JanusShared

final class PersistenceTests: XCTestCase {

    private var store: JanusStore!
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("janus-test-\(UUID().uuidString)", isDirectory: true)
        store = JanusStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - JanusStore basics

    func testSaveAndLoadRoundTrip() throws {
        let grant = SessionGrant(
            sessionID: "sess-1",
            userPubkey: "pubkey-base64",
            providerID: "prov-1",
            maxCredits: 100,
            expiresAt: Date().addingTimeInterval(3600),
            backendSignature: "sig-base64"
        )
        try store.save(grant, as: "test_grant.json")
        let loaded = store.load(SessionGrant.self, from: "test_grant.json")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.sessionID, "sess-1")
        XCTAssertEqual(loaded?.maxCredits, 100)
        XCTAssertEqual(loaded?.providerID, "prov-1")
    }

    func testLoadNonexistentReturnsNil() {
        let result = store.load(SessionGrant.self, from: "does_not_exist.json")
        XCTAssertNil(result)
    }

    func testDeleteRemovesFile() throws {
        let state = SpendState(sessionID: "sess-1")
        try store.save(state, as: "state.json")
        XCTAssertNotNil(store.load(SpendState.self, from: "state.json"))
        store.delete("state.json")
        XCTAssertNil(store.load(SpendState.self, from: "state.json"))
    }

    // MARK: - PersistedClientSession

    func testClientSessionRoundTrip() throws {
        let kp = JanusKeyPair()
        let grant = SessionGrant(
            sessionID: "sess-client",
            userPubkey: kp.publicKeyBase64,
            providerID: "prov-1",
            maxCredits: 50,
            expiresAt: Date().addingTimeInterval(3600),
            backendSignature: "sig"
        )
        var spendState = SpendState(sessionID: "sess-client")
        spendState.advance(creditsCharged: 8)

        let receipt = Receipt(
            sessionID: "sess-client",
            requestID: "req-1",
            providerID: "prov-1",
            creditsCharged: 8,
            cumulativeSpend: 8,
            providerSignature: "rsig"
        )

        let persisted = PersistedClientSession(
            privateKeyBase64: kp.privateKeyBase64,
            sessionGrant: grant,
            spendState: spendState,
            receipts: [receipt]
        )

        try store.save(persisted, as: "client.json")
        let loaded = store.load(PersistedClientSession.self, from: "client.json")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.sessionGrant.sessionID, "sess-client")
        XCTAssertEqual(loaded?.spendState.cumulativeSpend, 8)
        XCTAssertEqual(loaded?.spendState.sequenceNumber, 1)
        XCTAssertEqual(loaded?.receipts.count, 1)
        XCTAssertEqual(loaded?.remainingCredits, 42)
        XCTAssertTrue(loaded?.isValid ?? false)

        // Verify keypair can be restored
        let keyData = Data(base64Encoded: loaded!.privateKeyBase64)!
        let restoredKP = try JanusKeyPair(privateKeyRaw: keyData)
        XCTAssertEqual(restoredKP.publicKeyBase64, kp.publicKeyBase64)
    }

    func testExpiredSessionIsInvalid() throws {
        let persisted = PersistedClientSession(
            privateKeyBase64: JanusKeyPair().privateKeyBase64,
            sessionGrant: SessionGrant(
                sessionID: "expired",
                userPubkey: "pub",
                providerID: "prov",
                maxCredits: 100,
                expiresAt: Date().addingTimeInterval(-1), // already expired
                backendSignature: "sig"
            ),
            spendState: SpendState(sessionID: "expired")
        )
        XCTAssertFalse(persisted.isValid)
    }

    // MARK: - PersistedProviderState

    func testProviderStateRoundTrip() throws {
        let kp = JanusKeyPair()

        let persisted = PersistedProviderState(
            providerID: "prov-1",
            privateKeyBase64: kp.privateKeyBase64,
            receiptsIssued: [],
            totalRequestsServed: 2,
            totalCreditsEarned: 8
        )

        try store.save(persisted, as: "provider.json")
        let loaded = store.load(PersistedProviderState.self, from: "provider.json")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.providerID, "prov-1")
        XCTAssertEqual(loaded?.totalRequestsServed, 2)
        XCTAssertEqual(loaded?.totalCreditsEarned, 8)

        // Verify keypair can be restored
        let keyData = Data(base64Encoded: loaded!.privateKeyBase64)!
        let restoredKP = try JanusKeyPair(privateKeyRaw: keyData)
        XCTAssertEqual(restoredKP.publicKeyBase64, kp.publicKeyBase64)
    }

    // MARK: - Backwards compatibility

    func testClientSessionDecodesWithoutHistoryField() throws {
        // Simulate an old file that was written before the `history` field was added
        let oldJson = """
        {
            "privateKeyBase64": "\(JanusKeyPair().privateKeyBase64)",
            "sessionGrant": {
                "sessionID": "old-sess",
                "userPubkey": "pub",
                "providerID": "prov",
                "maxCredits": 100,
                "expiresAt": "\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)))",
                "backendSignature": "sig"
            },
            "spendState": {
                "sessionID": "old-sess",
                "cumulativeSpend": 15,
                "sequenceNumber": 3,
                "updatedAt": "\(ISO8601DateFormatter().string(from: Date()))"
            },
            "receipts": []
        }
        """
        // Write raw JSON (no history key)
        let url = tempDir.appendingPathComponent("old_client.json")
        try oldJson.data(using: .utf8)!.write(to: url)

        // Should decode successfully with history defaulting to []
        let loaded = store.load(PersistedClientSession.self, from: "old_client.json")
        XCTAssertNotNil(loaded, "Should decode old format without history field")
        XCTAssertEqual(loaded?.sessionGrant.sessionID, "old-sess")
        XCTAssertEqual(loaded?.spendState.cumulativeSpend, 15)
        XCTAssertEqual(loaded?.history.count, 0, "History should default to empty array")
        XCTAssertEqual(loaded?.remainingCredits, 85)
    }

    // MARK: - Overwrite behavior

    func testSaveOverwritesPreviousValue() throws {
        var state = SpendState(sessionID: "sess-1")
        try store.save(state, as: "state.json")

        state.advance(creditsCharged: 10)
        try store.save(state, as: "state.json")

        let loaded = store.load(SpendState.self, from: "state.json")
        XCTAssertEqual(loaded?.cumulativeSpend, 10)
    }
}
