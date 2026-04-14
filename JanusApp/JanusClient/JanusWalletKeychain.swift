import Foundation
import Security
import JanusShared

/// Keychain persistence for the client's local ETH wallet key.
///
/// One stable key per device, shared across all sessions and providers.
/// Survives app reinstall — prerequisite for real-money channel funding.
enum JanusWalletKeychain {

    // Injectable for test isolation — production uses these defaults.
    static let defaultService = "com.janus.app"
    static let defaultAccount = "eth-wallet-key"

    /// Load the persisted ETH keypair from Keychain. Returns nil if not found.
    static func load(service: String = defaultService,
                     account: String = defaultAccount) -> EthKeyPair? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? EthKeyPair(privateKey: data)
    }

    /// Persist the ETH keypair to Keychain. Overwrites any existing entry.
    /// Returns true on success, false on failure (logs OSStatus on failure).
    @discardableResult
    static func save(_ keyPair: EthKeyPair,
                     service: String = defaultService,
                     account: String = defaultAccount) -> Bool {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecValueData: keyPair.privateKeyData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecAttrSynchronizable: false
            ]
            let update: [CFString: Any] = [
                kSecValueData: keyPair.privateKeyData,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
            ]
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        if status != errSecSuccess {
            print("JanusWalletKeychain: save failed with OSStatus \(status)")
            return false
        }
        return true
    }

    /// Load existing key from Keychain, or generate a new one and save it.
    /// Returns nil only if EthKeyPair generation fails (CryptoKit error — extremely rare).
    static func loadOrCreate(service: String = defaultService,
                             account: String = defaultAccount) -> EthKeyPair? {
        if let existing = load(service: service, account: account) { return existing }
        guard let fresh = try? EthKeyPair() else {
            print("JanusWalletKeychain: EthKeyPair() generation failed")
            return nil
        }
        let saved = save(fresh, service: service, account: account)
        if !saved {
            print("JanusWalletKeychain: WARNING — key generated but not persisted to Keychain")
        }
        return fresh
    }

    /// Delete the Keychain entry. Used in tests and future key-rotation flows.
    static func delete(service: String = defaultService,
                       account: String = defaultAccount) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false
        ]
        SecItemDelete(query as CFDictionary)
    }
}
