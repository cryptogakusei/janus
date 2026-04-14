# Feature #11a: Wallet Key Persistence (Keychain)

## Context

The client's ETH keypair (`ethPrivateKeyHex`) is currently stored as a plain hex string inside `client_session_{providerID}.json` in the app's Application Support directory. It is regenerated each time a new session is created and lost on app reinstall.

Before real money can flow into channels, this key must survive app reinstall. The Keychain is the correct durable store on Apple platforms — it persists across reinstalls and (optionally) syncs via iCloud.

This is Feature #11a — a prerequisite for #11b (channel top-up) and #11c (funding UX).

---

## Design Decisions

### One stable wallet key, not per-session

Currently each session/provider pair gets its own fresh ETH key. With real funds at stake, the key must be a stable device identity:

- One ETH keypair per device, shared across all sessions and all providers
- Channel uniqueness is maintained by the salt, which is derived from `sessionGrant.sessionID` (a UUID). Same key + different session = different salt = different channel
- The payer address (`channel.payer`) becomes stable, which is actually desirable: it's the user's on-chain identity across sessions

**Orphaned channel note:** When a session expires and a new session is created to the same provider, a new `sessionID` → new salt → new channel is opened. The old channel's funds are locked until on-chain timeout or a close utility is built. This was also true before this plan (different key = different channel). Channel resumption/closure is a future concern tracked in #11b/#11c.

### Device-local Keychain (not iCloud sync for now)

Start with `kSecAttrSynchronizable = false` (explicit, not default):
- Simpler and safer — no risk of syncing a signing key to an unexpected device
- iCloud sync can be added in #11c when the full funding UX is designed
- **UI note for #11c:** The UI should display a notice that the wallet key is device-only and should not be funded heavily until backup is implemented

### `kSecAttrAccessibleAfterFirstUnlock`

The app may need to access the key during background tasks (e.g., voucher signing during settlement). `AfterFirstUnlock` allows access after the user has unlocked the device once, even if the screen is subsequently locked. `WhenUnlocked` would block background access.

---

## What to Build

### 1. `JanusWalletKeychain` helper — NEW FILE

**Location:** `JanusApp/JanusClient/JanusWalletKeychain.swift`

```swift
import Foundation
import Security

enum JanusWalletKeychain {
    // Injectable for testing — production uses these defaults
    static let defaultService = "com.janus.app"
    static let defaultAccount = "eth-wallet-key"

    /// Load the persisted ETH keypair from Keychain. Returns nil if not found.
    static func load(service: String = defaultService, account: String = defaultAccount) -> EthKeyPair? {
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
    /// Returns true on success, false on failure (logs the OSStatus on failure).
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
    /// Returns nil only if key generation fails (CryptoKit error — extremely rare).
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

    /// Delete the Keychain entry. Used in tests only.
    static func delete(service: String = defaultService, account: String = defaultAccount) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

**Key design notes:**
- `EthKeyPair(privateKey: data)` — correct initializer (not `privateKeyRaw:`)
- `kSecAttrSynchronizable: false` explicit in all queries and add attributes
- `kSecAttrAccessible` included in `SecItemUpdate` dict (not just `SecItemAdd`)
- `loadOrCreate()` returns `EthKeyPair?` not `EthKeyPair` — no `fatalError`
- `save()` returns `Bool` and logs `OSStatus` on failure
- `service`/`account` injectable for test isolation
- `delete()` method for test tearDown

---

### 2. `SessionManager.init(persisted:)` — ADD MIGRATION

**Location:** `JanusApp/JanusClient/SessionManager.swift:102–129` (the restore init)

After the existing `ethKeyPair` is restored from JSON (line 121-126), add a one-shot promotion to Keychain. This fires **once per session restore**, not on every reconnect:

```swift
// Existing restore code (lines 121-126):
if let ethHex = persisted.ethPrivateKeyHex {
    do {
        let ethKP = try EthKeyPair(hexPrivateKey: ethHex)
        self.ethKeyPair = ethKP
        print("Restored ETH keypair: \(ethKP.address)")
        // Promote to Keychain if not already there (one-time migration)
        if JanusWalletKeychain.load() == nil {
            JanusWalletKeychain.save(ethKP)
            print("Migrated ETH keypair to Keychain: \(ethKP.address)")
        }
    } catch {
        print("WARNING: Failed to restore ETH keypair...")
    }
}
```

The `JanusWalletKeychain.load() == nil` guard ensures the Keychain write happens only on the first launch after this feature ships, not on every subsequent restore.

---

### 3. `SessionManager.setupTempoChannel()` — UPDATE

**Location:** `JanusApp/JanusClient/SessionManager.swift:188–197`

**Current:**
```swift
if let existing = self.ethKeyPair {
    ethKP = existing
} else if let newKP = try? EthKeyPair() {
    ethKP = newKP
} else { return }
```

**New:**
```swift
if let existing = self.ethKeyPair {
    ethKP = existing
} else if let keychainKP = JanusWalletKeychain.loadOrCreate() {
    ethKP = keychainKP
} else {
    print("SessionManager: ETH key unavailable — cannot set up Tempo channel")
    return
}
self.ethKeyPair = ethKP
```

Migration (JSON → Keychain) happens in `init(persisted:)`, not here. This function only uses whatever key is already in memory or Keychain.

---

### 4. `SessionManager.persist()` — KEEP `ethPrivateKeyHex` as cache

**Location:** `JanusApp/JanusClient/SessionManager.swift:365–383`

No change. `ethPrivateKeyHex` stays in session JSON as a secondary fast-restore cache. Keychain is the durable store; JSON is the convenience cache that may be absent after reinstall.

---

## Files Changed

| File | Change |
|------|--------|
| `JanusApp/JanusClient/JanusWalletKeychain.swift` | New file — Keychain wrapper |
| `JanusApp/JanusClient/SessionManager.swift` | Add migration in `init(persisted:)`; update `setupTempoChannel()` |

No changes to `JanusShared` — Keychain is a platform-specific concern and stays in `JanusApp`.

---

## Migration

| Scenario | Behavior |
|----------|----------|
| New install (no prior session) | `loadOrCreate()` generates fresh key, saves to Keychain |
| Existing install with valid session JSON | `init(persisted:)` restores key from JSON; `load() == nil` guard fires once → promoted to Keychain |
| Subsequent app launches (Keychain has key) | `load()` returns key; `load() == nil` guard does NOT fire → no redundant write |
| App reinstall (JSON gone, Keychain survives) | `load()` returns existing key → same payer address → existing channels accessible |
| App reinstall + Keychain wiped | `loadOrCreate()` generates fresh key → old channels orphaned (unavoidable) |
| Session expires, new session to same provider | New `sessionID` → new salt → new channel opened; old channel funds locked until close utility |

---

## What NOT to Build

| Item | Reason to defer |
|------|----------------|
| iCloud Keychain sync (`kSecAttrSynchronizable = true`) | Deferred to #11c — requires deliberate UX around multi-device wallet |
| Keychain access group (cross-app sharing) | Not needed until a companion app exists |
| Key backup/export UI | Deferred to #11c — track as requirement |
| Provider ETH key to Keychain | Provider controls payee side; lower urgency; deferred |
| Channel-close utility for orphaned channels | Tracked in #11b/#11c |

---

## Test Plan

**File:** `JanusApp/JanusClientTests/WalletKeychainTests.swift`

Use injectable `service`/`account` parameters with a UUID suffix per test class to avoid cross-test contamination. Clean up in `tearDown` using `JanusWalletKeychain.delete()`.

1. `testSaveAndLoad_roundTrip` — save a key, load it back, verify addresses match
2. `testLoadOrCreate_returnsSameKeyOnSecondCall` — call twice, verify same address
3. `testSave_overwritesDuplicate` — save key A, save key B to same service/account, load → key B
4. `testLoad_returnsNil_whenEmpty` — fresh service/account, `load()` returns nil
5. `testMigrationGuard_doesNotOverwriteExistingKey` — pre-populate Keychain, call `init(persisted:)` path, verify original key unchanged

---

## Verification

```
xcodebuild test -scheme Janus-Package -destination 'platform=macOS'
xcodebuild test -scheme JanusApp -destination 'platform=macOS'
```

Manual steps:
1. Launch app → connect to provider → confirm channel opens
2. Inspect Keychain: `security find-generic-password -s "com.janus.app"` — entry should exist
3. Delete app data (Application Support/Janus/) — relaunch → confirm same ETH address (Keychain restored)
4. Full reinstall → relaunch → confirm same ETH address

**Dev build note:** On macOS, unsigned or ad-hoc signed builds may trigger a Keychain permission dialog on first access ("JanusClient wants to use your confidential information stored in Keychain"). This is expected behavior in development, not a bug.
