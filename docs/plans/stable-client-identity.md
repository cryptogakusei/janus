# Feature: Group Client Cards by Stable Device Identity

## Context

The provider UI shows one card per client in the "Clients" section. Currently, `clientSummaries` in `ProviderEngine.swift` groups sessions by `senderID` (MPC peer hash). However, `senderID` changes on every MPC reconnect, so the same iPhone shows as multiple client cards — one per historical session. A provider with 2 real devices may see 10+ client cards after several reconnects.

**Root cause:** There is no stable device identity. `senderID` is transport-level (changes per connection). `userPubkey` in `SessionGrant` is per-session (new `JanusKeyPair()` on every `SessionManager.create()`). Neither is usable for grouping.

**Solution:** Introduce a persistent device identity key on the client, send it to the provider in every `PromptRequest`, and group client cards by this stable identity.

---

## Design Decisions

1. **Device identity key** — A `JanusKeyPair` persisted to `client_device_identity.json`, independent of session lifecycle. Created once on first use, reused forever. The `publicKeyBase64` becomes the stable device fingerprint.

2. **`clientIdentity` field on `PromptRequest`** — Lightweight (one base64 string). Sent on every request so the provider always has the mapping. Optional field with `decodeIfPresent` for backward compat with old clients.

3. **Provider groups by identity, falls back to senderID** — `sessionToIdentity: [String: String]` maps `sessionID -> clientIdentity`. `clientSummaries` groups by identity when available, falls back to `senderID` for old clients. No persistence changes — the mapping rebuilds automatically from incoming requests.

4. **Transport protocol extended for multi-senderID lookups** — A single identity may have multiple historical senderIDs. `displayName(forSenderIDs:)` and `isConnected(senderIDs:)` check any associated senderID. Default implementations derive from existing `connectedClients` dict.

5. **Message routing unaffected** — `send()` still uses `sessionToSender[sessionID]` for per-session routing. The identity grouping is UI-only.

---

## Implementation Steps

### Step 1: Add `clientIdentity` to `PromptRequest`

**Modify:** `Sources/JanusShared/Protocol/PromptRequest.swift`

- Add `public let clientIdentity: String?` field
- Add to `init` with default `nil`
- No custom decoder needed — `Codable` synthesis handles optionals automatically (decodes as `nil` when missing)

```swift
/// Stable device identity (Ed25519 pubkey base64). Used by provider to group sessions from the same device.
public let clientIdentity: String?
```

**Dependencies:** None.

---

### Step 2: Create persistent device identity on the client

**Modify:** `JanusApp/JanusClient/SessionManager.swift`

Add a cached static method that loads or creates a device-level identity key:

```swift
private static var _cachedIdentity: JanusKeyPair?

/// Stable device identity — persisted independently of session state.
/// Cached in memory after first load to avoid disk I/O on every request.
static func deviceIdentityKey(store: JanusStore = .appDefault) -> JanusKeyPair {
    if let cached = _cachedIdentity { return cached }
    let filename = "client_device_identity.json"
    if let data = store.load(DeviceIdentity.self, from: filename),
       let rawData = Data(base64Encoded: data.privateKeyBase64),
       let kp = try? JanusKeyPair(privateKeyRaw: rawData) {
        _cachedIdentity = kp
        return kp
    }
    // Create new identity (first launch or corrupted file)
    let kp = JanusKeyPair()
    try? store.save(DeviceIdentity(privateKeyBase64: kp.privateKeyBase64), as: filename)
    _cachedIdentity = kp
    return kp
}

/// Clear the persisted device identity (e.g., for device transfer or privacy reset).
static func clearDeviceIdentity(store: JanusStore = .appDefault) {
    store.delete("client_device_identity.json")
    _cachedIdentity = nil
}

private struct DeviceIdentity: Codable {
    let privateKeyBase64: String
}
```

**Key fixes from review:**
- No force-unwrap — `guard let` for base64 decoding (P0: crash on corrupted file)
- Static cache — avoids disk I/O on every `submitRequest()` call (P1: performance)
- `clearDeviceIdentity()` — allows identity reset for device transfer/privacy (P1: missing escape hatch)

**Dependencies:** None.

---

### Step 3: Populate `clientIdentity` in client requests

**Modify:** `JanusApp/JanusClient/ClientEngine.swift` — `submitRequest()` (~line 203)

- Load the device identity key and pass its pubkey in the request:

```swift
let request = PromptRequest(
    ...
    clientIdentity: SessionManager.deviceIdentityKey().publicKeyBase64
)
```

**Dependencies:** Steps 1, 2.

---

### Step 4: Build identity mapping on the provider

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift`

Add a new dictionary:

```swift
/// Maps sessionID -> stable client identity (device pubkey base64)
private var sessionToIdentity: [String: String] = [:]
```

In `handlePromptRequest()` (line 418), after `sessionToSender[request.sessionID] = senderID`:

```swift
if let identity = request.clientIdentity {
    sessionToIdentity[request.sessionID] = identity
}
```

**Dependencies:** Step 1.

---

### Step 5: Add `senderIDs` to `ClientSummary` and rewrite grouping

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift`

Update `ClientSummary`:

```swift
struct ClientSummary: Identifiable {
    let id: String          // stable identity (pubkey) or fallback senderID
    var senderIDs: [String] // all transport-level senderIDs for this identity
    var sessionIDs: [String]
    // ... rest unchanged
}
```

Rewrite `clientSummaries` computed property (lines 71-107):

```swift
var clientSummaries: [ClientSummary] {
    var summaries: [String: ClientSummary] = [:]
    var senderIDSets: [String: Set<String>] = [:]  // Use Set to avoid O(n) contains checks

    for (sessionID, senderID) in sessionToSender {
        // Use stable identity if available, fall back to senderID
        let identity = sessionToIdentity[sessionID] ?? senderID
        let channel = channels[sessionID]

        var summary = summaries[identity] ?? ClientSummary(
            id: identity,
            senderIDs: [],
            sessionIDs: [],
            totalCreditsUsed: 0, maxCredits: 0,
            requestCount: 0, errorCount: 0,
            lastActive: nil, logs: []
        )
        senderIDSets[identity, default: []].insert(senderID)
        summary.sessionIDs.append(sessionID)
        // ... rest of aggregation unchanged
        summaries[identity] = summary
    }

    // Convert senderID sets to arrays
    for (identity, senderSet) in senderIDSets {
        summaries[identity]?.senderIDs = Array(senderSet)
    }
    // ... sorting unchanged
}
```

**Dependencies:** Step 4.

---

### Step 6: Extend transport protocol for multi-senderID lookups

**Modify:** `JanusApp/JanusProvider/ProviderAdvertiserTransport.swift`

Add two new methods with default implementations:

```swift
/// Get display name for any of the given senderIDs.
func displayName(forSenderIDs senderIDs: [String]) -> String?

/// Check if ANY of the given senderIDs is currently connected.
func isConnected(senderIDs: [String]) -> Bool
```

Default implementations:

```swift
func displayName(forSenderIDs senderIDs: [String]) -> String? {
    for id in senderIDs {
        if let name = connectedClients[id] { return name }
    }
    return nil
}

func isConnected(senderIDs: [String]) -> Bool {
    senderIDs.contains { connectedClients[$0] != nil }
}
```

**IMPORTANT:** `MPCAdvertiser` has explicit overrides of `displayName(forSender:)` and `isConnected(senderID:)` using its own `senderToPeer` mapping — it does NOT use the protocol defaults. New multi-senderID methods MUST also be explicitly implemented in `MPCAdvertiser`:

```swift
// In MPCAdvertiser
func displayName(forSenderIDs senderIDs: [String]) -> String? {
    for id in senderIDs {
        if let peer = senderToPeer[id] { return peer.displayName }
    }
    return nil
}

func isConnected(senderIDs: [String]) -> Bool {
    senderIDs.contains { senderToPeer[$0] != nil }
}
```

`BonjourAdvertiser` and `CompositeAdvertiser` use the protocol defaults (they rely on `connectedClients` dict).

**Dependencies:** None.

---

### Step 7: Update provider UI to use identity-based lookups

**Modify:** `JanusApp/JanusProvider/ProviderStatusView.swift` — `clientCard()` (line 191)

```swift
let deviceName = advertiser.displayName(forSenderIDs: client.senderIDs)
let shortID = String(client.id.suffix(6))
let name = deviceName.map { "\($0) (\(shortID))" } ?? "Client \(shortID)"
let connected = advertiser.isConnected(senderIDs: client.senderIDs)
```

**Dependencies:** Steps 5, 6.

---

## Files Summary

| File | Action | Changes |
|------|--------|---------|
| `Sources/JanusShared/Protocol/PromptRequest.swift` | Modify | Add `clientIdentity: String?` field |
| `JanusApp/JanusClient/SessionManager.swift` | Modify | Add `deviceIdentityKey()` static method + `DeviceIdentity` struct |
| `JanusApp/JanusClient/ClientEngine.swift` | Modify | Populate `clientIdentity` in `submitRequest()` |
| `JanusApp/JanusProvider/ProviderEngine.swift` | Modify | Add `sessionToIdentity` dict, populate in `handlePromptRequest()`, add `senderIDs` to `ClientSummary`, rewrite grouping |
| `JanusApp/JanusProvider/ProviderAdvertiserTransport.swift` | Modify | Add `displayName(forSenderIDs:)` and `isConnected(senderIDs:)` with defaults |
| `JanusApp/JanusProvider/ProviderStatusView.swift` | Modify | Switch to `senderIDs`-based lookups in `clientCard()` |

**Total:** ~50-60 lines across 6 files (all modifications, no new files).

---

## What Does NOT Change

- Message routing — `sessionToSender` still handles per-session transport routing
- Persistence — `sessionToIdentity` is runtime-only, rebuilds from incoming requests
- `SessionGrant.userPubkey` — unchanged, still per-session (different purpose)
- Transport layer (MPC/Bonjour) — unaffected
- Settlement / payment flows — unaffected

---

## Backward Compatibility

- **Old clients** (without `clientIdentity`): `sessionToIdentity` won't have an entry -> falls back to `senderID` as grouping key -> current behavior preserved (one card per session)
- **Old provider state files**: `PromptRequest` uses Codable synthesis, missing `clientIdentity` decodes as `nil` automatically
- **Mixed client versions**: Each client independently sends or omits `clientIdentity` — no coordination needed

---

## Verification

1. **Build:** `swift test` passes, `xcodebuild` builds both targets
2. **New client, single device:** Connect iPhone -> send requests -> reconnect multiple times -> provider shows ONE client card with aggregated stats
3. **Two devices:** Connect 2 iPhones -> provider shows exactly 2 client cards
4. **Old client fallback:** Client without `clientIdentity` gets its own card per senderID (existing behavior)
5. **Device identity persistence:** Force-quit client -> relaunch -> same identity key -> same client card on provider

---

## Edge Cases

- **`senderIDs` growth:** Mitigated by using `Set<String>` during aggregation (P3 fix). Stale entries are pruned when channels are removed.
- **Provider restart:** `sessionToIdentity` is lost. Rebuilds on next `PromptRequest` from each client. Until then, new sessions show as separate cards briefly.
- **Same device name:** Two iPhones both named "iPhone" — `displayName` returns the same string but they have different identity keys, so they still get separate cards. Correct behavior.
- **Corrupted identity file:** Gracefully falls through to create a new identity. Loses grouping continuity but doesn't crash (P0 fix).

---

## Additional Step: Prune stale identity entries on channel removal (P2)

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift` — `removeChannelIfMatch()`

When a channel is removed, clean up `sessionToIdentity` (UI grouping only). Do **NOT** prune `sessionToSender` — it's used by `send()` for message routing and removing it breaks routing for reconnecting clients.

```swift
private func removeChannelIfMatch(sessionID: String, expectedChannelId: Data, onlyIfSettled: Bool = false) {
    guard channels[sessionID]?.channelId == expectedChannelId else { return }
    if onlyIfSettled {
        guard channels[sessionID]?.unsettledAmount == 0 else { return }
    }
    channels.removeValue(forKey: sessionID)
    sessionToIdentity.removeValue(forKey: sessionID)
    // NOTE: sessionToSender is NOT pruned — it's needed for send() routing
    persistState()
}
```

This prevents unbounded growth of the identity mapping without breaking transport routing.

---

## Security Note

The device identity private key is stored as plaintext base64 in `client_device_identity.json` (Application Support directory). This is consistent with existing session keys and ETH keys in the codebase. However, this key has a longer lifetime (never rotates). On iOS, the app sandbox provides adequate protection. On macOS, any process running as the same user can read it.

**Accepted tradeoff for v1:** Consistent with existing patterns, acceptable for testnet. Migration to Keychain for all long-lived keys is a future follow-up.

---

## Review Findings Incorporated

Based on **systems-architect review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| P0 (Bug) | Force-unwrap crash on corrupted identity file | Use `guard let` for base64 decoding in `deviceIdentityKey()` (Step 2) |
| P1 | Disk I/O on every request | Cache keypair in `static var` after first load (Step 2) |
| P1 | No way to reset device identity | Added `clearDeviceIdentity()` method (Step 2) |
| P2 | Unbounded growth of `sessionToIdentity` | Prune `sessionToIdentity` in `removeChannelIfMatch()` (Additional Step) |
| P2 | Private key in plaintext (long-lived) | Acknowledged as tradeoff; Keychain migration deferred (Security Note) |
| P3 | O(n) `contains` on `senderIDs` array | Use `Set<String>` during aggregation (Step 5) |
| P3 | No verification of identity claims | Noted as future enhancement |

**Confirmed sound:** Core approach, backward compat in all directions, Ed25519 keypair over simpler alternatives.

Based on **architecture-reviewer review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| MUST-FIX | `MPCAdvertiser` has explicit overrides of single-senderID methods — new multi-senderID methods won't use protocol defaults | Added explicit `displayName(forSenderIDs:)` and `isConnected(senderIDs:)` implementations in `MPCAdvertiser` (Step 6) |
| MUST-FIX | Pruning `sessionToSender` in `removeChannelIfMatch()` breaks `send()` routing for reconnecting clients | Only prune `sessionToIdentity`, NOT `sessionToSender` (Additional Step) |
| SHOULD-FIX | Missing test for `clientIdentity` Codable round-trip | Add test verifying `PromptRequest` with `clientIdentity` encodes/decodes correctly |
| SHOULD-FIX | `clientSummaries` rewrite code sample is truncated | Full implementation to be written during implementation |
| SHOULD-FIX | `@MainActor` isolation not documented (explains why plain `Bool`/`Dict` is thread-safe) | `ProviderEngine` is `@MainActor`-isolated; `sessionToIdentity` access is serialized |
