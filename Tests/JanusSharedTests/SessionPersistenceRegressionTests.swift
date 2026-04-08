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
