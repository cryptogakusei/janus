import XCTest
@testable import JanusClient
import JanusShared

/// Tests for Feature #12a: Offline Voucher Signing.
///
/// Verifies that voucher signing always uses the local EthKeyPair
/// (via LocalWalletProvider), even when a Privy wallet is injected.
/// This ensures offline operation — no network calls for signing.
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

    /// After create() + setupTempoChannel(), walletProvider must be LocalWalletProvider
    /// even when a mock Privy wallet is injected.
    func testCreateInit_alwaysUsesLocalSignerEvenWithPrivy() async throws {
        let privyKP = try EthKeyPair()
        let mockPrivy = MockWalletProvider(keyPair: privyKP)

        let manager = await SessionManager.create(
            providerID: "test-provider",
            walletProvider: mockPrivy,
            store: testStore
        )
        manager.setupTempoChannel(providerEthAddress: testProviderEthAddress)

        // walletProvider should be LocalWalletProvider, NOT the mock Privy
        XCTAssertNotNil(manager.walletProvider)
        XCTAssertTrue(manager.walletProvider is LocalWalletProvider,
                      "Expected LocalWalletProvider, got \(type(of: manager.walletProvider!))")
        // Signer address should be the local key, not Privy
        XCTAssertNotEqual(manager.walletProvider?.address, privyKP.address,
                          "walletProvider address should NOT be the Privy address")
        // Privy identity should be captured
        XCTAssertEqual(manager.privyIdentityAddress, privyKP.address)
    }

    // MARK: - Offline voucher signing

    /// createVoucherAuthorization() must succeed without any network calls.
    /// The mock Privy wallet's signVoucher should NOT be called.
    func testOfflineVoucherSigning_noNetworkRequired() async throws {
        let privyKP = try EthKeyPair()
        let mockPrivy = MockWalletProvider(keyPair: privyKP)

        let manager = await SessionManager.create(
            providerID: "test-provider",
            walletProvider: mockPrivy,
            store: testStore
        )
        manager.setupTempoChannel(providerEthAddress: testProviderEthAddress)

        // Sign a voucher — should use local key, not Privy
        let auth = try await manager.createVoucherAuthorization(
            requestID: "req-1", quoteID: "q-1", priceCredits: 5
        )

        XCTAssertNotNil(auth)
        XCTAssertEqual(auth.requestID, "req-1")
        // Mock Privy should NOT have been called
        XCTAssertEqual(mockPrivy.signCallCount, 0,
                       "Privy wallet should not be called for signing — local key should handle it")
    }

    // MARK: - Restore path

    /// Persisted ethKeyPair must survive restore even when Privy is injected.
    func testRestoreInit_alwaysRestoresEthKeyPair() async throws {
        // Create a session and persist it
        let manager = await SessionManager.create(
            providerID: "restore-test",
            walletProvider: nil,
            store: testStore
        )
        manager.setupTempoChannel(providerEthAddress: testProviderEthAddress)

        let originalEthAddress = manager.ethKeyPair?.address
        XCTAssertNotNil(originalEthAddress, "ethKeyPair should exist after setupTempoChannel")

        // Now restore with a mock Privy wallet injected
        let privyKP = try EthKeyPair()
        let mockPrivy = MockWalletProvider(keyPair: privyKP)

        let restored = SessionManager.restore(
            providerID: "restore-test",
            walletProvider: mockPrivy,
            store: testStore
        )
        XCTAssertNotNil(restored, "Session should restore successfully")

        // ETH keypair should be restored from persisted data, not regenerated
        XCTAssertNotNil(restored?.ethKeyPair, "ethKeyPair should be restored")
        XCTAssertEqual(restored?.ethKeyPair?.address, originalEthAddress,
                       "Restored ethKeyPair should match original")

        // walletProvider should NOT be Privy — it's nil until setupTempoChannel
        // (restore init no longer sets walletProvider)
        // After setup, it should be LocalWalletProvider
        restored?.setupTempoChannel(providerEthAddress: testProviderEthAddress)
        XCTAssertTrue(restored?.walletProvider is LocalWalletProvider)
        XCTAssertEqual(restored?.walletProvider?.address, originalEthAddress)
    }

    // MARK: - Channel ID stability

    /// Channel ID must be identical after app restart (restore → setupTempoChannel).
    /// This proves the ethKeyPair restore fix works — if the key were regenerated,
    /// channelId would change (authorizedSigner is an input to computeId()).
    func testChannelId_stableAcrossRestart() async throws {
        let manager = await SessionManager.create(
            providerID: "stability-test",
            walletProvider: nil,
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
            walletProvider: nil,
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

    /// When ethPrivateKeyHex is corrupted, a new key is generated and the system stays functional.
    func testRestoreInit_corruptedEthKey_generatesNewKey() async throws {
        // Create and persist a session
        let manager = await SessionManager.create(
            providerID: "corrupt-test",
            walletProvider: nil,
            store: testStore
        )
        manager.setupTempoChannel(providerEthAddress: testProviderEthAddress)
        let originalAddress = manager.ethKeyPair?.address
        XCTAssertNotNil(originalAddress)

        // Corrupt the persisted ethPrivateKeyHex by overwriting the file
        // We need to load, modify, and re-save the persisted session
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

        // Restore — should succeed despite corrupted key
        let restored = SessionManager.restore(
            providerID: "corrupt-test",
            walletProvider: nil,
            store: testStore
        )
        XCTAssertNotNil(restored, "Session should still restore even with corrupted ETH key")

        // ethKeyPair should be nil (failed to restore)
        XCTAssertNil(restored?.ethKeyPair, "Corrupted key should not restore")

        // setupTempoChannel should generate a new key and work
        restored?.setupTempoChannel(providerEthAddress: testProviderEthAddress)
        XCTAssertNotNil(restored?.ethKeyPair, "New key should be generated")
        XCTAssertNotEqual(restored?.ethKeyPair?.address, originalAddress,
                          "New key should have different address")
        XCTAssertTrue(restored?.walletProvider is LocalWalletProvider)
    }
}

// MARK: - MockWalletProvider for Xcode tests

/// Duplicated from SPM tests since JanusClientTests can't import JanusSharedTests.
private final class MockWalletProvider: WalletProvider, @unchecked Sendable {
    private let keyPair: EthKeyPair
    private(set) var signCallCount = 0

    var address: EthAddress { keyPair.address }

    init(keyPair: EthKeyPair) {
        self.keyPair = keyPair
    }

    func signVoucher(_ voucher: Voucher, config: TempoConfig) async throws -> SignedVoucher {
        signCallCount += 1
        return try voucher.sign(with: keyPair, config: config)
    }

    func sendTransaction(to: EthAddress, data: Data, value: UInt64, chainId: UInt64) async throws -> String {
        throw WalletProviderError.noRPC
    }
}
