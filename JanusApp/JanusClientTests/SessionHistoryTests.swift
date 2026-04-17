import XCTest
@testable import JanusClient
import JanusShared

/// Regression tests for Feature #15b: Remove Session TTL + Dedicated History File.
///
/// Guards four key invariants:
///   1. restore() succeeds for sessions with expiresAt in the past (TTL guard removed)
///   2. init(persisted:) migrates embedded history → history_{providerID}.json on first launch
///   3. init(keyPair:grant:) loads pre-existing history file (survives session renewal)
///   4. clearPersistedSession() deletes both the session file and the history file
@MainActor
final class SessionHistoryTests: XCTestCase {

    private var testStore: JanusStore!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JanusHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testStore = JanusStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        testStore = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeHistory(count: Int) -> [HistoryEntry] {
        (1...count).map { i in
            let receipt = Receipt(
                sessionID: "sess-h", requestID: "req-\(i)",
                providerID: "prov-h", creditsCharged: i, cumulativeSpend: i,
                providerSignature: "sig-\(i)"
            )
            return HistoryEntry(
                task: .summarize,
                prompt: "Prompt \(i)",
                response: InferenceResponse(
                    requestID: "req-\(i)", outputText: "Response \(i)",
                    creditsCharged: i, cumulativeSpend: i, receipt: receipt
                )
            )
        }
    }

    // MARK: - Invariant 1: restore() ignores session TTL

    /// Core #15b regression: a session whose expiresAt is in the past must restore
    /// successfully. Before #15b, persisted.isValid == false caused restore() to return nil,
    /// opening a new channel and wiping history. With the guard removed, the session
    /// is restored regardless of the timestamp in expiresAt.
    @available(*, deprecated) // suppress isValid deprecation in assertion below
    func testRestore_succeeds_forExpiredSession() async throws {
        let providerID = "expired-ttl-test"

        // Create and persist a valid session
        let manager = await SessionManager.create(providerID: providerID, store: testStore)

        // Now overwrite the session file with an expired expiresAt
        let sessionFilename = "client_session_\(providerID).json"
        guard var persisted = testStore.load(PersistedClientSession.self, from: sessionFilename) else {
            XCTFail("Session file should exist after create()")
            return
        }

        // Reconstruct with an expired grant (expiresAt 2 hours ago)
        let expiredGrant = SessionGrant(
            sessionID: persisted.sessionGrant.sessionID,
            userPubkey: persisted.sessionGrant.userPubkey,
            providerID: providerID,
            maxCredits: persisted.sessionGrant.maxCredits,
            expiresAt: Date().addingTimeInterval(-7200)
        )
        let expired = PersistedClientSession(
            privateKeyBase64: persisted.privateKeyBase64,
            sessionGrant: expiredGrant,
            spendState: persisted.spendState
        )
        XCTAssertFalse(expired.isValid, "Precondition: session should be expired")
        try testStore.save(expired, as: sessionFilename)

        // restore() must succeed — TTL guard removed in #15b
        let restored = SessionManager.restore(providerID: providerID, store: testStore)
        XCTAssertNotNil(restored,
            "restore() must succeed for expired session — TTL guard was removed in #15b")
        XCTAssertEqual(restored?.sessionGrant.providerID, providerID)
    }

    // MARK: - Invariant 2: Migration from embedded history

    /// First launch after upgrading to #15b: the session file has embedded history and
    /// no history_{providerID}.json exists yet. init(persisted:) must:
    ///   a) Load the embedded history into self.history
    ///   b) Write history_{providerID}.json with the migrated entries
    ///   c) Leave the session file unmodified (migration is non-destructive)
    func testRestore_migratesEmbeddedHistory_toHistoryFile() async throws {
        let providerID = "migration-test"
        let sessionFilename = "client_session_\(providerID).json"
        let historyFilename = "history_\(providerID).json"

        // Simulate a pre-#15b session file: valid session with embedded history
        let entries = makeHistory(count: 3)
        let kp = JanusKeyPair()
        let grant = SessionGrant(
            sessionID: UUID().uuidString,
            userPubkey: kp.publicKeyBase64,
            providerID: providerID,
            maxCredits: 100,
            // Use far-future expiry so the session is clearly valid (TTL not the test subject)
            expiresAt: Date(timeIntervalSince1970: 4_070_908_800)
        )
        let preUpgrade = PersistedClientSession(
            privateKeyBase64: kp.privateKeyBase64,
            sessionGrant: grant,
            spendState: SpendState(sessionID: grant.sessionID),
            history: entries
        )
        try testStore.save(preUpgrade, as: sessionFilename)

        // Confirm no history file exists yet (pre-upgrade state)
        XCTAssertNil(testStore.load(PersistedHistory.self, from: historyFilename),
                     "Precondition: no history file should exist before migration")

        // Restore triggers init(persisted:) which runs migration
        let restored = SessionManager.restore(providerID: providerID, store: testStore)
        XCTAssertNotNil(restored, "Session should restore successfully")

        // (a) In-memory history should contain migrated entries
        XCTAssertEqual(restored?.history.count, 3,
                       "Migrated history must appear in restored session")
        XCTAssertEqual(restored?.history[0].prompt, "Prompt 1")

        // (b) history_{providerID}.json must now exist with the migrated entries
        let historyFile = testStore.load(PersistedHistory.self, from: historyFilename)
        XCTAssertNotNil(historyFile, "Migration must create history_{providerID}.json")
        XCTAssertEqual(historyFile?.entries.count, 3,
                       "History file must contain all migrated entries")

        // (c) Session file must still decode (non-destructive — embedded history field preserved)
        let sessionFile = testStore.load(PersistedClientSession.self, from: sessionFilename)
        XCTAssertNotNil(sessionFile, "Session file must still be readable after migration")
    }

    // MARK: - Invariant 3: New session picks up pre-existing history file

    /// Credit exhaustion / channel re-open scenario: a new session is created for the same
    /// provider. The new session's init(keyPair:grant:) must load the history file written
    /// by the old session so conversation continuity is preserved.
    func testCreate_loadsPreExistingHistoryFile() async throws {
        let providerID = "renewal-test"
        let historyFilename = "history_\(providerID).json"

        // Simulate an existing history file from the old session
        let entries = makeHistory(count: 5)
        let ph = PersistedHistory(entries: entries)
        try testStore.save(ph, as: historyFilename)

        // Create a brand-new session (simulates session renewal after credit exhaustion)
        let newSession = await SessionManager.create(providerID: providerID, store: testStore)

        XCTAssertEqual(newSession.history.count, 5,
                       "New session must load pre-existing history from history_{providerID}.json")
        XCTAssertEqual(newSession.history[0].prompt, "Prompt 1",
                       "History order must be preserved")
    }

    // MARK: - Invariant 4: clearPersistedSession deletes both files

    /// Manual reset must delete both client_session_{id}.json and history_{id}.json.
    /// Leaving an orphaned history file would cause it to reappear on the next
    /// session creation (invariant 3 picks it up).
    func testClearPersistedSession_deletesBothFiles() async throws {
        let providerID = "clear-test"
        let sessionFilename = "client_session_\(providerID).json"
        let historyFilename = "history_\(providerID).json"

        // Create a session so the session file exists
        let manager = await SessionManager.create(providerID: providerID, store: testStore)

        // Write a history file manually (simulates recordHistory() having been called)
        let ph = PersistedHistory(entries: makeHistory(count: 2))
        try testStore.save(ph, as: historyFilename)

        // Both files must exist before clearing
        XCTAssertNotNil(testStore.load(PersistedClientSession.self, from: sessionFilename),
                        "Precondition: session file must exist")
        XCTAssertNotNil(testStore.load(PersistedHistory.self, from: historyFilename),
                        "Precondition: history file must exist")

        // Clear — must delete both
        manager.clearPersistedSession()

        XCTAssertNil(testStore.load(PersistedClientSession.self, from: sessionFilename),
                     "clearPersistedSession() must delete client_session_{providerID}.json")
        XCTAssertNil(testStore.load(PersistedHistory.self, from: historyFilename),
                     "clearPersistedSession() must also delete history_{providerID}.json")
    }
}
