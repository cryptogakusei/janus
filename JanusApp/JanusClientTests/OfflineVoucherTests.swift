import XCTest
@testable import JanusClient
import JanusShared

/// Tests for Feature #12a: Offline Voucher Signing.
///
/// Verifies that voucher signing always uses the local EthKeyPair
/// (via LocalWalletProvider), ensuring offline operation — no network calls for signing.
@MainActor
final class OfflineVoucherTests: XCTestCase {

    private var testStore: JanusStore!
    private var testProviderEthAddress: String!

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JanusTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testStore = JanusStore(directory: tempDir)
        testProviderEthAddress = (try? EthKeyPair())?.address.checksumAddress ?? "0x" + String(repeating: "ab", count: 20)
    }

    override func tearDown() {
        testStore = nil
        testProviderEthAddress = nil
        super.tearDown()
    }

    // MARK: - Create path

    /// After create() + setupTempoChannel(), walletProvider must be LocalWalletProvider.
    func testCreateInit_usesLocalWalletProvider() async throws {
        let manager = await SessionManager.create(
            providerID: "test-provider",
            store: testStore
        )
        manager.setupTempoChannel(providerEthAddress: testProviderEthAddress)

        XCTAssertNotNil(manager.walletProvider)
        XCTAssertTrue(manager.walletProvider is LocalWalletProvider,
                      "Expected LocalWalletProvider, got \(type(of: manager.walletProvider!))")
    }

    // MARK: - Offline voucher signing

    /// createVoucherAuthorization() must succeed without any network calls.
    func testOfflineVoucherSigning_noNetworkRequired() async throws {
        let manager = await SessionManager.create(
            providerID: "test-provider",
            store: testStore
        )
        manager.setupTempoChannel(providerEthAddress: testProviderEthAddress)

        let auth = try await manager.createVoucherAuthorization(
            requestID: "req-1", quoteID: "q-1", priceCredits: 5
        )

        XCTAssertNotNil(auth)
        XCTAssertEqual(auth.requestID, "req-1")
    }

    // MARK: - Restore path

    /// Persisted ethKeyPair must survive restore.
    func testRestoreInit_alwaysRestoresEthKeyPair() async throws {
        // Create a session and persist it
        let manager = await SessionManager.create(
            providerID: "restore-test",
            store: testStore
        )
        manager.setupTempoChannel(providerEthAddress: testProviderEthAddress)

        let originalEthAddress = manager.ethKeyPair?.address
        XCTAssertNotNil(originalEthAddress, "ethKeyPair should exist after setupTempoChannel")

        let restored = SessionManager.restore(
            providerID: "restore-test",
            store: testStore
        )
        XCTAssertNotNil(restored, "Session should restore successfully")

        // ETH keypair should be restored from persisted data, not regenerated
        XCTAssertNotNil(restored?.ethKeyPair, "ethKeyPair should be restored")
        XCTAssertEqual(restored?.ethKeyPair?.address, originalEthAddress,
                       "Restored ethKeyPair should match original")

        // After setup, walletProvider should be LocalWalletProvider
        restored?.setupTempoChannel(providerEthAddress: testProviderEthAddress)
        XCTAssertTrue(restored?.walletProvider is LocalWalletProvider)
        XCTAssertEqual(restored?.walletProvider?.address, originalEthAddress)
    }

    // MARK: - Channel ID stability

    /// Channel ID must be identical after app restart (restore → setupTempoChannel).
    func testChannelId_stableAcrossRestart() async throws {
        let manager = await SessionManager.create(
            providerID: "stability-test",
            store: testStore
        )
        manager.setupTempoChannel(providerEthAddress: testProviderEthAddress)

        let originalChannelId = manager.channel?.channelId
        let originalEthAddress = manager.ethKeyPair?.address
        XCTAssertNotNil(originalChannelId, "Channel should exist after setup")
        XCTAssertNotNil(originalEthAddress)

        // Restore and set up channel again (simulates app restart)
        let restored = SessionManager.restore(
            providerID: "stability-test",
            store: testStore
        )
        XCTAssertNotNil(restored)
        restored?.setupTempoChannel(providerEthAddress: testProviderEthAddress)

        XCTAssertEqual(restored?.ethKeyPair?.address, originalEthAddress,
                       "ETH key should be the same after restore")
        XCTAssertEqual(restored?.channel?.channelId, originalChannelId,
                       "Channel ID must be stable across restarts — same key, same signer, same channelId")
    }

    // MARK: - Corrupted key handling

    /// When ethPrivateKeyHex is corrupted in JSON, the Keychain key is used as fallback,
    /// maintaining identity continuity (same address as before the corruption).
    func testRestoreInit_corruptedEthKey_fallsBackToKeychain() async throws {
        // Create and persist a session — setupTempoChannel saves the key to Keychain
        let manager = await SessionManager.create(
            providerID: "corrupt-test",
            store: testStore
        )
        manager.setupTempoChannel(providerEthAddress: testProviderEthAddress)
        let keychainAddress = manager.ethKeyPair?.address
        XCTAssertNotNil(keychainAddress)

        // Corrupt the persisted ethPrivateKeyHex by overwriting the file
        let filename = "client_session_corrupt-test.json"
        if let persisted = testStore.load(PersistedClientSession.self, from: filename) {
            let corrupted = PersistedClientSession(
                privateKeyBase64: persisted.privateKeyBase64,
                sessionGrant: persisted.sessionGrant,
                spendState: persisted.spendState,
                receipts: persisted.receipts,
                history: persisted.history,
                ethPrivateKeyHex: "not-a-valid-hex-key"
            )
            try testStore.save(corrupted, as: filename)
        }

        // Restore — should succeed despite corrupted JSON key
        let restored = SessionManager.restore(
            providerID: "corrupt-test",
            store: testStore
        )
        XCTAssertNotNil(restored, "Session should still restore even with corrupted ETH key")

        // ethKeyPair should be nil (failed to parse from corrupted JSON)
        XCTAssertNil(restored?.ethKeyPair, "Corrupted JSON key should not restore")

        // setupTempoChannel falls back to Keychain — provides identity continuity
        restored?.setupTempoChannel(providerEthAddress: testProviderEthAddress)
        XCTAssertNotNil(restored?.ethKeyPair, "Key should be recovered from Keychain")
        XCTAssertEqual(restored?.ethKeyPair?.address, keychainAddress,
                       "Keychain fallback must preserve the same ETH address (identity continuity)")
        XCTAssertTrue(restored?.walletProvider is LocalWalletProvider)
    }
}
