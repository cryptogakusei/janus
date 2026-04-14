import XCTest
@testable import JanusClient
import JanusShared

/// Tests for Feature #11a: Wallet Key Persistence (Keychain).
///
/// Each test uses a unique Keychain service derived from a UUID to prevent
/// cross-test contamination (Keychain state persists between test runs).
/// tearDown deletes the test entry.
final class WalletKeychainTests: XCTestCase {

    private var testService: String!
    private var testAccount: String!

    override func setUp() {
        super.setUp()
        // Unique namespace per test instance — no cross-test contamination.
        testService = "com.janus.test.\(UUID().uuidString)"
        testAccount = "eth-wallet-key-test"
    }

    override func tearDown() {
        JanusWalletKeychain.delete(service: testService, account: testAccount)
        testService = nil
        testAccount = nil
        super.tearDown()
    }

    // MARK: - Basic round-trip

    func testSaveAndLoad_roundTrip() throws {
        let keyPair = try EthKeyPair()
        let saved = JanusWalletKeychain.save(keyPair, service: testService, account: testAccount)
        XCTAssertTrue(saved, "save() should return true on success")

        let loaded = JanusWalletKeychain.load(service: testService, account: testAccount)
        XCTAssertNotNil(loaded, "load() should return the saved key")
        XCTAssertEqual(loaded?.address, keyPair.address, "Loaded address must match saved address")
    }

    func testLoad_returnsNil_whenEmpty() {
        let result = JanusWalletKeychain.load(service: testService, account: testAccount)
        XCTAssertNil(result, "load() should return nil when no key has been saved")
    }

    // MARK: - loadOrCreate

    func testLoadOrCreate_generatesAndPersists() throws {
        let first = JanusWalletKeychain.loadOrCreate(service: testService, account: testAccount)
        XCTAssertNotNil(first, "loadOrCreate() should return a key")

        let second = JanusWalletKeychain.loadOrCreate(service: testService, account: testAccount)
        XCTAssertNotNil(second, "loadOrCreate() should return same key on second call")
        XCTAssertEqual(first?.address, second?.address, "Same key must be returned on second call")
    }

    // MARK: - Overwrite

    func testSave_overwritesDuplicate() throws {
        let keyA = try EthKeyPair()
        let keyB = try EthKeyPair()

        JanusWalletKeychain.save(keyA, service: testService, account: testAccount)
        let savedB = JanusWalletKeychain.save(keyB, service: testService, account: testAccount)
        XCTAssertTrue(savedB, "Overwrite save should succeed")

        let loaded = JanusWalletKeychain.load(service: testService, account: testAccount)
        XCTAssertEqual(loaded?.address, keyB.address, "After overwrite, load() should return key B")
        XCTAssertNotEqual(loaded?.address, keyA.address, "Key A must no longer be present")
    }

    // MARK: - Migration guard

    func testMigrationGuard_doesNotOverwriteExistingKey() throws {
        // Simulate: Keychain already has a key (from a prior launch).
        let originalKey = try EthKeyPair()
        JanusWalletKeychain.save(originalKey, service: testService, account: testAccount)

        // Simulate: init(persisted:) migration path fires — load() is non-nil, so save is skipped.
        let keychainKey = JanusWalletKeychain.load(service: testService, account: testAccount)
        if keychainKey == nil {
            // This branch would trigger a save — but it should NOT be entered.
            XCTFail("Migration guard failed: Keychain had a key but load() returned nil")
        }

        // Key should still be the original one.
        let loaded = JanusWalletKeychain.load(service: testService, account: testAccount)
        XCTAssertEqual(loaded?.address, originalKey.address, "Existing Keychain key must not be overwritten")
    }
}
