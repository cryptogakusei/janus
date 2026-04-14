# Feature #17: Backend Dead Code Removal

## Context

Janus originally had a Vapor backend for session issuance — providers registered, clients fetched signed session grants, and the backend's Ed25519 signature on each grant was the trust anchor. This has been fully superseded by Tempo on-chain payment channels: sessions are now created locally, trust comes from on-chain channel verification, and the backend signature is never set or verified.

The worklog explicitly flags this as a cleanup task (line 1596). Dead code accumulates confusion and makes future features harder to reason about.

---

## What to Remove

### 1. `JanusBackend/` directory — DELETE ENTIRELY

**Location:** `/Users/soubhik/Projects/janus/JanusBackend/`

A standalone Vapor package that is completely disconnected from the main project:
- Not listed in the main `Package.swift` — cannot be built as part of the project
- References `DemoConfig` which doesn't exist anywhere — **compilation error if ever built**
- Signs `SessionGrant.backendSignature` — but this signature is never verified by any client or provider
- 4 files: `App.swift`, `Routes.swift`, `Stores.swift`, `VaporExtensions.swift`

**Action:** Delete the entire `JanusBackend/` directory.

---

### 2. `SessionGrant.backendSignature` field — REMOVE

**Location:** `Sources/JanusShared/Models/SessionGrant.swift:14,22,29`

Always set to `""` (empty string) in `SessionManager.create()`. Never verified by provider or client. The field is purely vestigial — it survives in JSON round-trips but carries no trust value.

**Current:**
```swift
public struct SessionGrant: Codable, Sendable {
    public let sessionID: String
    public let userPubkey: String
    public let providerID: String
    public let maxCredits: Int
    public let expiresAt: Date
    public let backendSignature: String   // ← REMOVE
}
```

**Action:** Remove `backendSignature` field, parameter from `init`, and assignment in `SessionManager.swift:153`.

**Backward compatibility:** `SessionGrant` uses **synthesized** `Codable` conformance — there is no custom decoder on `SessionGrant`. Swift's synthesized `Decodable` automatically ignores unknown JSON keys. Old persisted sessions with `"backendSignature"` in their JSON will decode cleanly after removal. No custom decoder work needed.

---

### 3. `SessionGrant.signableFields` — REMOVE

**Location:** `Sources/JanusShared/Models/SessionGrant.swift:33–41`

Computed property returning `[sessionID, userPubkey, providerID, maxCredits, expiresAt]` for use in signing. Only ever used by `JanusBackend/Routes.swift` (dead) — never called in main project.

**Note:** `Receipt.signableFields` is a separate property on a different type that IS actively used. Do not touch it.

**Action:** Remove `signableFields` computed property from `SessionGrant`.

---

### 4. `SessionGrant` struct doc comment — UPDATE

**Location:** `Sources/JanusShared/Models/SessionGrant.swift:3–7`

Current doc comment says:
```
/// A session grant issued by the backend, authorizing a client to spend
/// up to `maxCredits` at a specific provider.
///
/// The backend signs: session_id, user_pubkey, provider_id, max_credits, expires_at.
/// The provider verifies this signature using the hardcoded backend public key.
```

All three lines are now false. Sessions are created locally; there is no backend signing or verification.

**Action:** Rewrite to describe sessions as locally-created with Tempo channel verification.

---

### 5. Stale comments in `ClientEngine.swift` — UPDATE

**Location:** `JanusApp/JanusClient/ClientEngine.swift`

- Line 162: `"Tries to restore a persisted session first; creates a new one via backend API if none found."` — misleading, no backend API call happens
- Line 195: `"Request grant from backend (async)"` — misleading, this is local session creation

**Action:** Update comments to accurately describe local session creation via Tempo.

---

### 6. Stale comment in `SessionManager.swift` — UPDATE

**Location:** `JanusApp/JanusClient/SessionManager.swift:140`

Comment uses outdated framing around "backend grants".

**Action:** Update to reflect that sessions are created locally with Tempo channel verification.

---

### 7. Minor stale doc comments — UPDATE

**`Sources/JanusShared/JanusShared.swift:4`:** `"and domain models used by the provider, client, and backend."` — "backend" no longer exists.

**`Sources/JanusShared/Protocol/VoucherAuthorization.swift:31–33`:** `"Replaces SessionGrant for Tempo-based sessions. Instead of a backend-signed grant..."` — the framing is stale since `SessionGrant` no longer has a backend signature. Update to describe the current model.

**Action:** Update both comments to remove backend references.

---

### 8. `PromptRequest.sessionGrant` — EVALUATE, likely keep

**Location:** `Sources/JanusShared/Protocol/PromptRequest.swift:15`

Optional field sent by client on first request. Provider receives it and caches the session, but never verifies `backendSignature`. The field still serves a purpose: it carries `maxCredits`, `expiresAt`, `providerID`, `userPubkey` to the provider for session setup. Provider code in `ProviderEngine.swift` never reads `backendSignature` — only uses session metadata fields.

**Action:** Keep the field — it carries real session metadata. Just remove `backendSignature` from `SessionGrant` itself (Step 2 above handles this).

---

## Files Changed

| File | Change |
|------|--------|
| `JanusBackend/` (entire directory) | Delete |
| `Sources/JanusShared/Models/SessionGrant.swift` | Remove `backendSignature`, `signableFields`; rewrite struct doc comment |
| `Sources/JanusShared/JanusShared.swift` | Remove "backend" from doc comment (line 4) |
| `Sources/JanusShared/Protocol/VoucherAuthorization.swift` | Update stale framing (lines 31–33) |
| `JanusApp/JanusClient/ClientEngine.swift` | Update stale comments (lines 162, 195) |
| `JanusApp/JanusClient/SessionManager.swift` | Update stale comment (line 140); remove `backendSignature: ""` from init call (line 153) |
| `Tests/JanusSharedTests/ProtocolTests.swift` | Remove `backendSignature:` from init calls (lines 68, 187, 203); delete `testSessionGrantSignableFields` |
| `Tests/JanusSharedTests/PersistenceTests.swift` | Remove `backendSignature:` from `SessionGrant(...)` init calls (lines 28, 61, 108, 188); keep raw JSON fixture at line 155 as-is (backward compat test) |
| `Tests/JanusSharedTests/SessionPersistenceRegressionTests.swift` | Remove `backendSignature:` from `makeGrant()` helper (line 33); keep raw JSON fixtures (lines 233, 249) as-is |
| `Tests/JanusSharedTests/OnChainTests.swift` | Remove `backendSignature:` from init calls (lines 193, 223); keep raw JSON fixture (line 249) as-is |

---

## What NOT to Remove

| Item | Reason to keep |
|------|---------------|
| `SessionGrant` struct itself | Still used — carries maxCredits, expiresAt, providerID, userPubkey |
| `PromptRequest.sessionGrant` | Still used — provider receives session metadata from client on first connect |
| `JanusKeyPair`, `JanusSigner`, `JanusVerifier` | Still used for provider receipt signing / client receipt verification |
| `Receipt.signableFields` | Actively used — different type, different purpose, do not touch |
| Raw JSON `"backendSignature"` in test fixtures | Intentionally kept — proves synthesized decoder ignores unknown keys (backward compat regression tests) |
| `ProtocolTests.testSessionGrantRoundTrip` | Still valid — just remove backendSignature from the fixture |
| `ProtocolTests.testPromptRequestRoundTrip` | Still valid — just remove backendSignature from the SessionGrant init call |

---

## Test Impact

- `ProtocolTests.testSessionGrantRoundTrip` (line 187) — update fixture to remove `backendSignature`
- `ProtocolTests.testPromptRequestRoundTrip` (line 68) — update `SessionGrant(...)` init call
- `ProtocolTests.testSessionGrantSignableFields` — **DELETE** (tests a method being removed)
- `PersistenceTests.swift` lines 28, 61, 108, 188 — remove `backendSignature:` parameter from `SessionGrant(...)` calls
- `PersistenceTests.swift` line 155 — **keep raw JSON** (proves backward compat)
- `SessionPersistenceRegressionTests.swift` line 33 — update `makeGrant()` helper
- `SessionPersistenceRegressionTests.swift` lines 233, 249 — **keep raw JSON** (backward compat)
- `OnChainTests.swift` lines 193, 223 — remove `backendSignature:` parameter
- `OnChainTests.swift` line 249 — **keep raw JSON** (backward compat)
- All other tests — no impact

---

## Backward Compatibility

Clients with old persisted sessions on disk have a `SessionGrant` JSON with `backendSignature` field. After this change, `SessionGrant`'s synthesized `Decodable` conformance automatically ignores the unknown key. The raw JSON fixtures left in the test files serve as regression tests for exactly this behavior. No migration needed.

---

## Verification

```
xcodebuild test -scheme Janus-Package -destination 'platform=macOS'
```

All existing tests minus deleted ones should pass. No new tests needed — this is removal only.
