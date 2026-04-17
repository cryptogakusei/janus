# Feature #15b: Remove Session TTL + Dedicated History File

## Context

Each client session is represented by a `PersistedClientSession` (saved to
`client_session_{providerID}.json`) that bundles:

- A `SessionGrant` with a hard-coded 1-hour `expiresAt`
- On-chain Tempo payment channel state (credits, keypair, channel ID)
- History entries (`[HistoryEntry]` — prompt/response pairs)

When the user is inactive for more than one hour, `PersistedClientSession.isValid`
returns `false` (line 82, `SessionStore.swift`). `SessionManager.restore()` treats a
non-`isValid` session as absent and returns `nil` (line 127–129, `SessionManager.swift`).
`ClientEngine.createSession()` then creates a brand-new session: a new Tempo channel is
opened on-chain (fresh 100-credit deposit) and history starts empty.

Two user-visible problems result:

1. **Credits reset** — a new on-chain channel is opened with a fresh 100-credit deposit,
   even when the existing channel still has credits remaining.

2. **History wiped** — all prompt/response history is discarded, even though the user
   expects it to persist like any other chat app.

---

## Design

### Fix 1 — Remove Session TTL

The `isValid` guard was originally designed for a backend-signed session model. In the
Tempo architecture, trust comes entirely from the on-chain payment channel. There is no
backend to re-auth with; expiry only causes harm.

Remove `persisted.isValid` from the `guard` in `SessionManager.restore()`. The session
file (`client_session_{providerID}.json`) now persists until the app is deleted or the
user manually resets — same as any other app's local data.

The `expiresAt` field is kept in the struct for backward compat with existing files, but
changed from `now + 1 hour` to a far-future constant (`2099-01-01`) in `create()`.
`isValid` is marked `@available(*, deprecated)` — it is dead code but not deleted
(removing a `public` property from `JanusShared` is source-breaking).

### Fix 2 — Dedicated History File

History is extracted from `PersistedClientSession` into its own file
`history_{providerID}.json`. This file:

- **Never expires** — completely decoupled from session lifecycle
- **Persists across session renewals** — survives credits running out, channel re-opens,
  forced reconnects
- **Is per-provider** — each provider relationship has its own history file
- **Is first-class** — not a secondary field inside the session; a proper independent
  store, same model as Claude app

The session file (`client_session_{providerID}.json`) continues to exist and still
persists credits, channel state, spend state, and the session grant. Only history moves.

**Migration:** On first load after upgrading, if `client_session_{providerID}.json`
contains non-empty history AND no `history_{providerID}.json` exists yet, the old
embedded history is drained into the new file. After that, `persist()` always writes
`history: []` in the session file — the field stays in the struct for decoding old files
but is never populated on new writes.

---

## Storage Layout (after this plan)

```
Application Support/Janus/
├── client_session_{providerID}.json   ← session grant, channel state, credits, keypair ref
│                                         (history field always [] on new writes)
└── history_{providerID}.json          ← conversation history, never expires
```

---

## What Is Removed / Changed

| Item | Change | Reason |
|------|--------|--------|
| `persisted.isValid` guard in `restore()` | Removed | TTL irrelevant in Tempo; causes fund loss and history wipe |
| `expiresAt = Date().addingTimeInterval(3600)` | Changed to 2099-01-01 | Makes intent explicit in persisted JSON |
| `history: [HistoryEntry]` write in `persist()` | Always writes `[]` | History now lives in dedicated file |
| `PersistedClientSession.isValid` | Deprecated, not deleted | Source-breaking to remove from public API |
| `recordHistory()` persistence call | Calls `persistHistory()` instead of `persist()` | Writes to history file, not session file |

---

## Exact Code Changes

### Change 1 — New `PersistedHistory` struct in `SessionStore.swift`

**File:** `Sources/JanusShared/Persistence/SessionStore.swift`
**Location:** Add after `HistoryEntry` definition (after line 14)

```swift
/// Standalone per-provider history file — accumulates across session renewals.
/// Stored as `history_{providerID}.json`, never expires, never deleted by session logic.
public struct PersistedHistory: Codable, Sendable {
    public var entries: [HistoryEntry]

    public init(entries: [HistoryEntry] = []) {
        self.entries = entries
    }
}
```

---

### Change 2 — Deprecate `isValid` in `SessionStore.swift`

**File:** `Sources/JanusShared/Persistence/SessionStore.swift`
**Location:** Lines 80–83

**Before:**
```swift
/// Whether this session is still valid (not expired).
public var isValid: Bool {
    sessionGrant.expiresAt > Date()
}
```

**After:**
```swift
/// Whether this session is still valid (not expired).
///
/// - Note: Deprecated as of #15b. `SessionManager.restore()` no longer gates on
///   this — Tempo sessions do not expire based on wall-clock time. Retained for
///   diagnostic use and backwards test compatibility only.
@available(*, deprecated, message: "TTL-based expiry removed in #15b. Do not add new callers.")
public var isValid: Bool {
    sessionGrant.expiresAt > Date()
}
```

---

### Change 3 — `SessionManager.restore()`: remove `isValid` guard

**File:** `JanusApp/JanusClient/SessionManager.swift`
**Location:** Lines 122–133

**Before:**
```swift
static func restore(providerID: String, store: JanusStore = .appDefault) -> SessionManager? {
    let perProviderFile = filename(for: providerID)
    let legacyFile = "client_session.json"
    let file = store.load(PersistedClientSession.self, from: perProviderFile) != nil ? perProviderFile : legacyFile
    guard let persisted = store.load(PersistedClientSession.self, from: file),
          persisted.isValid,
          persisted.sessionGrant.providerID == providerID else {
        return nil
    }
    return try? SessionManager(persisted: persisted, store: store)
}
```

**After:**
```swift
static func restore(providerID: String, store: JanusStore = .appDefault) -> SessionManager? {
    let perProviderFile = filename(for: providerID)
    let legacyFile = "client_session.json"
    let file = store.load(PersistedClientSession.self, from: perProviderFile) != nil ? perProviderFile : legacyFile
    guard let persisted = store.load(PersistedClientSession.self, from: file),
          persisted.sessionGrant.providerID == providerID else {
        return nil
    }
    return try? SessionManager(persisted: persisted, store: store)
}
```

**Diff:** Remove `persisted.isValid,` from the `guard`. The providerID check is retained.

---

### Change 4 — `SessionManager.create()`: replace TTL constant

**File:** `JanusApp/JanusClient/SessionManager.swift`
**Location:** Line 190

**Before:**
```swift
let expiresAt = Date().addingTimeInterval(3600)
```

**After:**
```swift
// No session TTL — Tempo channel trust is on-chain.
let expiresAt = Date(timeIntervalSince1970: 4_070_908_800) // 2099-01-01 UTC
```

---

### Change 5 — `SessionManager`: add history filename helper + `persistHistory()`

**File:** `JanusApp/JanusClient/SessionManager.swift`
**Location:** Add after `filename(for:)` static method (after line ~116)

```swift
private static func historyFilename(for providerID: String) -> String {
    "history_\(providerID).json"
}
```

Add `persistHistory()` after `persist()` (after line ~564):

```swift
private func persistHistory() {
    let ph = PersistedHistory(entries: history)
    do {
        try store.save(ph, as: Self.historyFilename(for: providerID))
    } catch {
        print("Failed to persist history: \(error)")
    }
}
```

---

### Change 6 — `SessionManager.persist()`: stop writing history

**File:** `JanusApp/JanusClient/SessionManager.swift`
**Location:** Line 550 inside `persist()`

**Before:**
```swift
history: history,
```

**After:**
```swift
history: [],   // history now lives in history_{providerID}.json
```

---

### Change 7 — `SessionManager.recordHistory()`: call `persistHistory()` not `persist()`

**File:** `JanusApp/JanusClient/SessionManager.swift`
**Location:** Lines 467–470

**Before:**
```swift
func recordHistory(task: TaskType, prompt: String, response: InferenceResponse) {
    history.insert(HistoryEntry(task: task, prompt: prompt, response: response), at: 0)
    persist()
}
```

**After:**
```swift
func recordHistory(task: TaskType, prompt: String, response: InferenceResponse) {
    history.insert(HistoryEntry(task: task, prompt: prompt, response: response), at: 0)
    persistHistory()
}
```

---

### Change 8 — `SessionManager.init(persisted:)`: load history from file + migrate

**File:** `JanusApp/JanusClient/SessionManager.swift`
**Location:** Line 149 inside `init(persisted:store:)` — replace `self.history = persisted.history`

**Before:**
```swift
self.history = persisted.history
```

**After:**
```swift
// Load history from the dedicated history file.
// Migration: if no history file exists yet but the old session file has embedded
// history, drain it into the new file (one-time migration on first upgrade launch).
let hFilename = Self.historyFilename(for: persisted.sessionGrant.providerID)
if let existing = store.load(PersistedHistory.self, from: hFilename) {
    self.history = existing.entries
} else if !persisted.history.isEmpty {
    // First launch after #15b — migrate embedded history to dedicated file.
    self.history = persisted.history
    let ph = PersistedHistory(entries: persisted.history)
    try? store.save(ph, as: hFilename)
} else {
    self.history = []
}
```

---

### Change 9 — `SessionManager.init(keyPair:grant:store:)`: load existing history on new session

**File:** `JanusApp/JanusClient/SessionManager.swift`
**Location:** Inside the fresh-session init (lines ~206–215), add before `persist()`

```swift
// Load any pre-existing history for this provider (survives session renewal).
if let existing = store.load(PersistedHistory.self,
                              from: Self.historyFilename(for: grant.providerID)) {
    self.history = existing.entries
}
persist()
```

This ensures that if a new session is created (e.g. after credit exhaustion), the history
from the old session's file is picked up automatically — no carry-forward logic needed
in `ClientEngine`.

---

### Change 10 — `SessionManager.clearPersistedSession()`: also delete history file

**File:** `JanusApp/JanusClient/SessionManager.swift`
**Location:** Lines 537–540

**Before:**
```swift
func clearPersistedSession() {
    store.delete(Self.filename(for: providerID))
}
```

**After:**
```swift
func clearPersistedSession() {
    store.delete(Self.filename(for: providerID))
    store.delete(Self.historyFilename(for: providerID))
}
```

---

### Change 11 — `ClientEngine.createSession()`: remove old `responseHistory = []`

**File:** `JanusApp/JanusClient/ClientEngine.swift`
**Location:** `else` branch of `createSession()`, line ~232

**Before:**
```swift
responseHistory = []
```

**After:**
```swift
responseHistory = manager.history  // history file loaded in SessionManager.init
```

No carry-forward logic needed here — the history file is loaded automatically inside
`SessionManager.init(keyPair:grant:store:)` (Change 9).

---

### Change 12 — Tests: suppress `isValid` deprecation warnings

**File:** `Tests/JanusSharedTests/PersistenceTests.swift`

Annotate any test method that calls `isValid` with `@available(*, deprecated)` to
suppress the warning without deleting the test:

```swift
@available(*, deprecated) // suppress isValid deprecation — retained for round-trip coverage
func testClientSessionRoundTrip() throws { ... }

@available(*, deprecated) // isValid arithmetically correct; no longer used in restore()
func testExpiredSessionIsInvalid() throws { ... }
```

---

## Migration Strategy

| Scenario | Before | After |
|----------|--------|-------|
| Session expired (>1 hour inactive) | New channel + reset credits + empty history | Session restored, credits intact, history intact |
| Session not expired | Restore succeeds (unchanged) | Unchanged |
| First launch after upgrade (old file has embedded history) | N/A | History migrated to `history_{providerID}.json` on first load |
| New session created (credit exhaustion) | History wiped | New session picks up `history_{providerID}.json` automatically |
| No files (first ever launch) | New session, empty history | New session, empty history (unchanged) |
| User manually resets | Session + history both deleted | Session + history both deleted (Change 10) |

---

## Execution Order

1. `SessionStore.swift` — add `PersistedHistory` struct (Change 1) + deprecate `isValid` (Change 2)
2. `SessionManager.swift` — remove `isValid` guard (Change 3) + replace TTL (Change 4) — same commit as step 1
3. `SessionManager.swift` — add `historyFilename` + `persistHistory()` (Change 5)
4. `SessionManager.swift` — stop writing history in `persist()` (Change 6) + update `recordHistory()` (Change 7) + update `init(persisted:)` migration (Change 8) + update `init(keyPair:grant:)` (Change 9) + update `clearPersistedSession()` (Change 10)
5. `ClientEngine.swift` — update `responseHistory` line (Change 11)
6. Tests — suppress deprecation warnings (Change 12) + add regression tests

Steps 3–5 should be one commit. Step 1–2 can be a separate commit.

---

## Files Modified

| File | Change |
|------|--------|
| `Sources/JanusShared/Persistence/SessionStore.swift` | Add `PersistedHistory`; deprecate `isValid` |
| `JanusApp/JanusClient/SessionManager.swift` | Remove TTL; add history file helpers; migration in init |
| `JanusApp/JanusClient/ClientEngine.swift` | `responseHistory = manager.history` |
| `Tests/JanusSharedTests/PersistenceTests.swift` | Suppress `isValid` deprecation warnings |
| `Tests/JanusSharedTests/SessionPersistenceRegressionTests.swift` | Add history file round-trip test + expired session restore test |

---

## Key Invariants

1. **Session persists indefinitely** — `client_session_{providerID}.json` survives until
   app deletion or manual reset. Credits and channel state are always recoverable.
2. **History persists independently** — `history_{providerID}.json` is never touched by
   session logic. It only grows (via `persistHistory()`) or is deleted (via
   `clearPersistedSession()`).
3. **History order** — always newest-first (index 0 = most recent).
4. **Per-provider isolation** — both files are keyed by `providerID`. Two providers never
   share history or session state.
5. **Migration is one-time and non-destructive** — old embedded history is copied to the
   new file on first load; the session file is not modified during migration.
6. **No carry-forward logic in `ClientEngine`** — history continuity is handled entirely
   inside `SessionManager.init`, not at the call site.

---

## Potential Compile Errors / Logic Bugs

| Location | Risk | Mitigation |
|----------|------|------------|
| `PersistenceTests.swift` — `loaded?.isValid` | Deprecation warning → error if `-warnings-as-errors` | `@available(*, deprecated)` on test method |
| `init(persisted:)` migration — `try? store.save(...)` | Disk write failure silently discards migration | Non-fatal — worst case user sees empty history on first launch; migration retries next launch |
| `init(keyPair:grant:)` — history load before `persist()` | `persist()` writes `history: []` which would overwrite the loaded history in the session file | Correct — `persist()` writes `[]` to session file, `history` property holds the loaded entries in memory, `persistHistory()` manages the history file separately |
| `clearPersistedSession()` — no external callers currently | Future reset UX must call this method | Documented on the method |

---

## Verification

```bash
# Build shared package
xcodebuild build -scheme Janus-Package -destination 'platform=macOS'

# Run all shared tests
xcodebuild test -scheme Janus-Package -destination 'platform=macOS'

# Build iOS client
xcodebuild build -project JanusApp/JanusApp.xcodeproj -scheme JanusClient \
  -destination 'generic/platform=iOS'
```

**Manual test:**
1. Connect to provider, make 2–3 requests. Note credit balance and history count.
2. Verify two files exist in Application Support: `client_session_{id}.json` and
   `history_{id}.json`. Verify `client_session` has `history: []`.
3. Force-quit app. Wait 90 minutes (or advance system clock past `expiresAt`).
4. Relaunch. Reconnect to same provider.
5. **Expected:** history intact, credits unchanged.
6. Simulate credit exhaustion (manually set `cumulativeSpend` = deposit in the JSON).
   Reconnect → new channel opens → **history still shows previous entries**.
