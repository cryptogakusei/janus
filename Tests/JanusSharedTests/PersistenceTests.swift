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
        XCTAssertEqual(loaded?.channelOpenedOnChain, false, "channelOpenedOnChain should default to false for old JSON")
    }

    func testChannelOpenedOnChainRoundTrip() throws {
        let kp = JanusKeyPair()
        let grant = SessionGrant(
            sessionID: "sess-chan",
            userPubkey: kp.publicKeyBase64,
            providerID: "prov-chan",
            maxCredits: 100,
            expiresAt: Date().addingTimeInterval(3600),
            backendSignature: "sig"
        )
        let persisted = PersistedClientSession(
            privateKeyBase64: kp.privateKeyBase64,
            sessionGrant: grant,
            spendState: SpendState(sessionID: "sess-chan"),
            channelOpenedOnChain: true
        )
        try store.save(persisted, as: "client_chan.json")
        let loaded = store.load(PersistedClientSession.self, from: "client_chan.json")

        XCTAssertEqual(loaded?.channelOpenedOnChain, true, "channelOpenedOnChain should survive round-trip")
    }

    // MARK: - settledChannelAmounts persistence

    func testSettledChannelAmountsPersistenceRoundTrip() throws {
        let state = PersistedProviderState(
            providerID: "test",
            privateKeyBase64: "dGVzdA==",
            settledChannelAmounts: ["0xabc": 42, "0xdef": 100]
        )
        let data = try JSONEncoder.janus.encode(state)
        let decoded = try JSONDecoder.janus.decode(PersistedProviderState.self, from: data)
        XCTAssertEqual(decoded.settledChannelAmounts?["0xabc"], 42)
        XCTAssertEqual(decoded.settledChannelAmounts?["0xdef"], 100)
    }

    func testSettledChannelAmounts_decodesNilFromOldFormat() throws {
        let json = """
        {"providerID":"test","privateKeyBase64":"dGVzdA==","totalRequestsServed":0,"totalCreditsEarned":0}
        """
        let decoded = try JSONDecoder.janus.decode(PersistedProviderState.self, from: Data(json.utf8))
        XCTAssertNil(decoded.settledChannelAmounts)
    }

    /// Key invariant: after recovering settledAmount from local cache, subsequent vouchers
    /// produce correct unsettledAmount — not inflated by prior settled spend.
    func testCachedSettledAmountProducesCorrectUnsettledAmount() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let salt = Keccak256.hash(Data("test-cache-recovery".utf8))
        var channel = Channel(
            payer: clientKP.address,
            payee: providerKP.address,
            token: EthAddress(Data(repeating: 0, count: 20)),
            salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 100,
            config: TempoConfig.testnet
        )

        // Simulate cache recovery: 57 credits were settled in a prior session
        channel.recordSettlement(amount: 57)
        XCTAssertEqual(channel.settledAmount, 57)
        XCTAssertEqual(channel.unsettledAmount, 0)

        // Client sends voucher for cumulative 60 (3 new credits above the prior 57)
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 60)
        let signed = try voucher.sign(with: clientKP, config: TempoConfig.testnet)
        try channel.acceptVoucher(signed)

        // unsettledAmount must be 3, not 60 (which would be the inflated value without cache recovery)
        XCTAssertEqual(channel.unsettledAmount, 3)
        XCTAssertEqual(channel.authorizedAmount, 60)
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
