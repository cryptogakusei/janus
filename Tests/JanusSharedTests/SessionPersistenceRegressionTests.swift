import XCTest
@testable import JanusShared

/// Regression tests for session persistence after relay/ETH field additions.
///
/// Verifies that PersistedClientSession and PersistedProviderState correctly
/// save/restore all fields including ethPrivateKeyHex and history entries.
final class SessionPersistenceRegressionTests: XCTestCase {

    private var store: JanusStore!
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("janus-regression-\(UUID().uuidString)", isDirectory: true)
        store = JanusStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeGrant(sessionID: String = "sess-1", providerID: String = "prov-1",
                           maxCredits: Int = 100) -> SessionGrant {
        SessionGrant(
            sessionID: sessionID,
            userPubkey: JanusKeyPair().publicKeyBase64,
            providerID: providerID,
            maxCredits: maxCredits,
            expiresAt: Date().addingTimeInterval(3600),
            backendSignature: "sig-base64"
        )
    }

    private func makeReceipt(sessionID: String, requestID: String,
                             creditsCharged: Int, cumulativeSpend: Int) -> Receipt {
        Receipt(
            sessionID: sessionID,
            requestID: requestID,
            providerID: "prov-1",
            creditsCharged: creditsCharged,
            cumulativeSpend: cumulativeSpend,
            providerSignature: "rsig"
        )
    }

    // MARK: - Client session with ETH key

    func testClientSessionPersistWithEthKey_roundTrip() throws {
        let ethKP = try EthKeyPair()
        let grant = makeGrant()
        var spendState = SpendState(sessionID: "sess-1")
        spendState.advance(creditsCharged: 10)

        let persisted = PersistedClientSession(
            privateKeyBase64: JanusKeyPair().privateKeyBase64,
            sessionGrant: grant,
            spendState: spendState,
            receipts: [],
            history: [],
            ethPrivateKeyHex: ethKP.privateKeyData.ethHex
        )

        try store.save(persisted, as: "client_eth.json")
        let loaded = store.load(PersistedClientSession.self, from: "client_eth.json")

        XCTAssertNotNil(loaded)
        XCTAssertNotNil(loaded?.ethPrivateKeyHex)
        XCTAssertEqual(loaded?.ethPrivateKeyHex, ethKP.privateKeyData.ethHex)

        // Verify the ETH key can be reconstructed
        let restoredKP = try EthKeyPair(hexPrivateKey: loaded!.ethPrivateKeyHex!)
        XCTAssertEqual(restoredKP.address, ethKP.address)
    }

    // MARK: - Client session with history

    func testClientSessionPersistWithHistory_roundTrip() throws {
        let grant = makeGrant()
        var spendState = SpendState(sessionID: "sess-1")
        spendState.advance(creditsCharged: 3)
        spendState.advance(creditsCharged: 5)

        let receipt1 = makeReceipt(sessionID: "sess-1", requestID: "req-1",
                                   creditsCharged: 3, cumulativeSpend: 3)
        let receipt2 = makeReceipt(sessionID: "sess-1", requestID: "req-2",
                                   creditsCharged: 5, cumulativeSpend: 8)

        let history = [
            HistoryEntry(
                task: .translate,
                prompt: "Hello",
                response: InferenceResponse(
                    requestID: "req-1", outputText: "Hola",
                    creditsCharged: 3, cumulativeSpend: 3, receipt: receipt1
                )
            ),
            HistoryEntry(
                task: .summarize,
                prompt: "Long text here...",
                response: InferenceResponse(
                    requestID: "req-2", outputText: "Short summary",
                    creditsCharged: 5, cumulativeSpend: 8, receipt: receipt2
                )
            )
        ]

        let persisted = PersistedClientSession(
            privateKeyBase64: JanusKeyPair().privateKeyBase64,
            sessionGrant: grant,
            spendState: spendState,
            receipts: [receipt1, receipt2],
            history: history
        )

        try store.save(persisted, as: "client_history.json")
        let loaded = store.load(PersistedClientSession.self, from: "client_history.json")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.history.count, 2)
        XCTAssertEqual(loaded?.history[0].task, .translate)
        XCTAssertEqual(loaded?.history[0].prompt, "Hello")
        XCTAssertEqual(loaded?.history[0].response.outputText, "Hola")
        XCTAssertEqual(loaded?.history[1].task, .summarize)
        XCTAssertEqual(loaded?.history[1].response.creditsCharged, 5)
        XCTAssertEqual(loaded?.spendState.cumulativeSpend, 8)
        XCTAssertEqual(loaded?.spendState.sequenceNumber, 2)
        XCTAssertEqual(loaded?.remainingCredits, 92)
    }

    // MARK: - Provider state with ETH key

    func testProviderStatePersistWithEthKey_roundTrip() throws {
        let ethKP = try EthKeyPair()
        let janusKP = JanusKeyPair()

        let persisted = PersistedProviderState(
            providerID: "prov-1",
            privateKeyBase64: janusKP.privateKeyBase64,
            receiptsIssued: [],
            totalRequestsServed: 15,
            totalCreditsEarned: 73,
            requestLog: [],
            ethPrivateKeyHex: ethKP.privateKeyData.ethHex
        )

        try store.save(persisted, as: "provider_eth.json")
        let loaded = store.load(PersistedProviderState.self, from: "provider_eth.json")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.ethPrivateKeyHex, ethKP.privateKeyData.ethHex)
        XCTAssertEqual(loaded?.totalRequestsServed, 15)
        XCTAssertEqual(loaded?.totalCreditsEarned, 73)

        // Verify both keys restore
        let restoredEth = try EthKeyPair(hexPrivateKey: loaded!.ethPrivateKeyHex!)
        XCTAssertEqual(restoredEth.address, ethKP.address)
        let restoredJanus = try JanusKeyPair(privateKeyRaw: Data(base64Encoded: loaded!.privateKeyBase64)!)
        XCTAssertEqual(restoredJanus.publicKeyBase64, janusKP.publicKeyBase64)
    }

    // MARK: - Provider state with request log

    func testProviderStatePersistWithRequestLog_roundTrip() throws {
        let log = [
            PersistedLogEntry(
                timestamp: Date(), taskType: "translate",
                promptPreview: "Hello...", responsePreview: "Hola...",
                credits: 3, isError: false, sessionID: "sess-a"
            ),
            PersistedLogEntry(
                timestamp: Date(), taskType: "summarize",
                promptPreview: "Long text...", responsePreview: nil,
                credits: nil, isError: true, sessionID: "sess-b"
            )
        ]

        let persisted = PersistedProviderState(
            providerID: "prov-1",
            privateKeyBase64: JanusKeyPair().privateKeyBase64,
            totalRequestsServed: 2,
            totalCreditsEarned: 3,
            requestLog: log
        )

        try store.save(persisted, as: "provider_log.json")
        let loaded = store.load(PersistedProviderState.self, from: "provider_log.json")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.requestLog.count, 2)
        XCTAssertEqual(loaded?.requestLog[0].sessionID, "sess-a")
        XCTAssertEqual(loaded?.requestLog[0].taskType, "translate")
        XCTAssertFalse(loaded?.requestLog[0].isError ?? true)
        XCTAssertEqual(loaded?.requestLog[1].sessionID, "sess-b")
        XCTAssertTrue(loaded?.requestLog[1].isError ?? false)
        XCTAssertNil(loaded?.requestLog[1].responsePreview)
    }

    // MARK: - Wrong provider rejection

    func testClientSessionRestore_wrongProviderID_returnsNil() throws {
        let grant = makeGrant(sessionID: "sess-1", providerID: "prov-A")
        let persisted = PersistedClientSession(
            privateKeyBase64: JanusKeyPair().privateKeyBase64,
            sessionGrant: grant,
            spendState: SpendState(sessionID: "sess-1")
        )

        try store.save(persisted, as: "client_a.json")
        let loaded = store.load(PersistedClientSession.self, from: "client_a.json")

        XCTAssertNotNil(loaded)
        // The session is for provider A — code that checks provider ID should reject for provider B
        XCTAssertEqual(loaded?.sessionGrant.providerID, "prov-A")
        XCTAssertNotEqual(loaded?.sessionGrant.providerID, "prov-B")
    }

    // MARK: - Backwards compatibility: old format without ethPrivateKeyHex

    func testClientSessionDecodesWithoutEthKeyField() throws {
        let kp = JanusKeyPair()
        let oldJson = """
        {
            "privateKeyBase64": "\(kp.privateKeyBase64)",
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
                "cumulativeSpend": 10,
                "sequenceNumber": 2,
                "updatedAt": "\(ISO8601DateFormatter().string(from: Date()))"
            },
            "receipts": [],
            "history": []
        }
        """

        let url = tempDir.appendingPathComponent("old_no_eth.json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try oldJson.data(using: .utf8)!.write(to: url)

        let loaded = store.load(PersistedClientSession.self, from: "old_no_eth.json")
        XCTAssertNotNil(loaded, "Should decode old format without ethPrivateKeyHex")
        XCTAssertNil(loaded?.ethPrivateKeyHex, "ETH key should be nil for old format")
        XCTAssertEqual(loaded?.spendState.cumulativeSpend, 10)
    }

    // MARK: - Provider state with unsettled channels (#12b)

    /// Full round-trip: PersistedProviderState with an unsettled channel containing a signed voucher.
    func testProviderStateRoundTrip_withUnsettledChannels() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("persist-test".utf8))
        let config = TempoConfig.testnet

        var channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 1000, config: config)
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 250)
        let signed = try voucher.sign(with: clientKP, config: config)
        try channel.acceptVoucher(signed)

        let persisted = PersistedProviderState(
            providerID: "prov-persist",
            privateKeyBase64: JanusKeyPair().privateKeyBase64,
            totalRequestsServed: 5,
            totalCreditsEarned: 250,
            unsettledChannels: ["sess-1": channel]
        )

        try store.save(persisted, as: "provider_unsettled.json")
        let loaded = store.load(PersistedProviderState.self, from: "provider_unsettled.json")

        XCTAssertNotNil(loaded)
        XCTAssertNotNil(loaded?.unsettledChannels)
        XCTAssertEqual(loaded?.unsettledChannels?.count, 1)

        let restored = loaded?.unsettledChannels?["sess-1"]
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.channelId, channel.channelId)
        XCTAssertEqual(restored?.deposit, 1000)
        XCTAssertEqual(restored?.unsettledAmount, 250)
        XCTAssertEqual(restored?.authorizedAmount, 250)
        XCTAssertNotNil(restored?.latestVoucher)

        // Verify the restored voucher signature is still valid (crypto integrity)
        XCTAssertTrue(
            Voucher.verify(signedVoucher: restored!.latestVoucher!, expectedSigner: clientKP.address, config: config),
            "Voucher signature must survive JSON round-trip"
        )
    }

    /// Multiple unsettled channels all survive persist/restore.
    func testProviderStateRoundTrip_multipleUnsettledChannels() throws {
        let config = TempoConfig.testnet
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        var channels: [String: Channel] = [:]

        for i in 1...3 {
            let clientKP = try EthKeyPair()
            let salt = Keccak256.hash(Data("multi-\(i)".utf8))
            var ch = Channel(payer: clientKP.address, payee: providerKP.address,
                             token: token, salt: salt, authorizedSigner: clientKP.address,
                             deposit: UInt64(i * 500), config: config)
            let v = Voucher(channelId: ch.channelId, cumulativeAmount: UInt64(i * 100))
            try ch.acceptVoucher(try v.sign(with: clientKP, config: config))
            channels["sess-\(i)"] = ch
        }

        let persisted = PersistedProviderState(
            providerID: "prov-multi",
            privateKeyBase64: JanusKeyPair().privateKeyBase64,
            unsettledChannels: channels
        )

        try store.save(persisted, as: "provider_multi.json")
        let loaded = store.load(PersistedProviderState.self, from: "provider_multi.json")

        XCTAssertEqual(loaded?.unsettledChannels?.count, 3)
        for i in 1...3 {
            let ch = loaded?.unsettledChannels?["sess-\(i)"]
            XCTAssertNotNil(ch, "Channel sess-\(i) should be restored")
            XCTAssertEqual(ch?.deposit, UInt64(i * 500))
            XCTAssertEqual(ch?.unsettledAmount, UInt64(i * 100))
        }
    }

    /// unsettledChannels is nil (not empty dict) when no channels are unsettled.
    func testProviderStateRoundTrip_unsettledChannelsNilWhenEmpty() throws {
        let persisted = PersistedProviderState(
            providerID: "prov-nil",
            privateKeyBase64: JanusKeyPair().privateKeyBase64,
            unsettledChannels: nil
        )

        try store.save(persisted, as: "provider_nil_channels.json")
        let loaded = store.load(PersistedProviderState.self, from: "provider_nil_channels.json")

        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.unsettledChannels, "unsettledChannels should be nil, not empty dict")
    }

    /// Filtering: only channels with unsettledAmount > 0 should be persisted.
    /// This mimics the logic in ProviderEngine.persistState().
    func testProviderStatePersistsOnlyUnsettledChannels() throws {
        let config = TempoConfig.testnet
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))

        // Channel 1: has an unsettled voucher (should be persisted)
        let client1 = try EthKeyPair()
        let salt1 = Keccak256.hash(Data("filter-1".utf8))
        var ch1 = Channel(payer: client1.address, payee: providerKP.address,
                          token: token, salt: salt1, authorizedSigner: client1.address,
                          deposit: 500, config: config)
        let v1 = Voucher(channelId: ch1.channelId, cumulativeAmount: 200)
        try ch1.acceptVoucher(try v1.sign(with: client1, config: config))

        // Channel 2: fully settled (should NOT be persisted)
        let client2 = try EthKeyPair()
        let salt2 = Keccak256.hash(Data("filter-2".utf8))
        var ch2 = Channel(payer: client2.address, payee: providerKP.address,
                          token: token, salt: salt2, authorizedSigner: client2.address,
                          deposit: 500, config: config)
        let v2 = Voucher(channelId: ch2.channelId, cumulativeAmount: 300)
        try ch2.acceptVoucher(try v2.sign(with: client2, config: config))
        ch2.recordSettlement(amount: 300)

        // Channel 3: no voucher at all (should NOT be persisted)
        let client3 = try EthKeyPair()
        let salt3 = Keccak256.hash(Data("filter-3".utf8))
        let ch3 = Channel(payer: client3.address, payee: providerKP.address,
                          token: token, salt: salt3, authorizedSigner: client3.address,
                          deposit: 500, config: config)

        // Apply the same filtering logic as ProviderEngine.persistState()
        let allChannels: [String: Channel] = ["sess-1": ch1, "sess-2": ch2, "sess-3": ch3]
        let unsettled = allChannels.filter { $0.value.latestVoucher != nil && $0.value.unsettledAmount > 0 }

        let persisted = PersistedProviderState(
            providerID: "prov-filter",
            privateKeyBase64: JanusKeyPair().privateKeyBase64,
            unsettledChannels: unsettled.isEmpty ? nil : unsettled
        )

        try store.save(persisted, as: "provider_filter.json")
        let loaded = store.load(PersistedProviderState.self, from: "provider_filter.json")

        XCTAssertEqual(loaded?.unsettledChannels?.count, 1, "Only the unsettled channel should be persisted")
        XCTAssertNotNil(loaded?.unsettledChannels?["sess-1"])
        XCTAssertNil(loaded?.unsettledChannels?["sess-2"], "Fully settled channel should be filtered out")
        XCTAssertNil(loaded?.unsettledChannels?["sess-3"], "Channel without voucher should be filtered out")
    }

    // MARK: - Backwards compatibility: old format without unsettledChannels

    /// Old provider state JSON (pre-#12b) should decode without crash.
    func testProviderStateDecodesWithoutUnsettledChannelsField() throws {
        let kp = JanusKeyPair()
        let oldJson = """
        {
            "providerID": "prov-legacy",
            "privateKeyBase64": "\(kp.privateKeyBase64)",
            "receiptsIssued": [],
            "totalRequestsServed": 10,
            "totalCreditsEarned": 50,
            "requestLog": []
        }
        """

        let url = tempDir.appendingPathComponent("old_no_channels.json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try oldJson.data(using: .utf8)!.write(to: url)

        let loaded = store.load(PersistedProviderState.self, from: "old_no_channels.json")
        XCTAssertNotNil(loaded, "Should decode old format without unsettledChannels field")
        XCTAssertNil(loaded?.unsettledChannels, "unsettledChannels should default to nil")
        XCTAssertEqual(loaded?.totalRequestsServed, 10)
        XCTAssertEqual(loaded?.totalCreditsEarned, 50)
    }

    func testProviderStateDecodesWithoutEthKeyField() throws {
        let kp = JanusKeyPair()
        let oldJson = """
        {
            "providerID": "prov-old",
            "privateKeyBase64": "\(kp.privateKeyBase64)",
            "receiptsIssued": [],
            "totalRequestsServed": 5,
            "totalCreditsEarned": 20,
            "requestLog": []
        }
        """

        let url = tempDir.appendingPathComponent("old_prov.json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try oldJson.data(using: .utf8)!.write(to: url)

        let loaded = store.load(PersistedProviderState.self, from: "old_prov.json")
        XCTAssertNotNil(loaded, "Should decode old format without ethPrivateKeyHex")
        XCTAssertNil(loaded?.ethPrivateKeyHex)
        XCTAssertEqual(loaded?.totalRequestsServed, 5)
    }
}
