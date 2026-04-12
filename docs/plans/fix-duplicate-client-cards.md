# Fix: Duplicate Client Cards After Reconnect

## Context

The stable-client-identity feature groups client cards by persistent device identity (`clientIdentity` Ed25519 pubkey) instead of transport-level senderID. But the same iPhone still shows as multiple cards after reconnecting.

**Root causes identified by both systems-architect and exploration agent:**

1. **Bug 3 (P0 — primary cause):** `removeChannelIfMatch` prunes `sessionToIdentity` but deliberately keeps `sessionToSender`. After settlement, the stale `sessionToSender` entry has no identity mapping → `clientSummaries` falls back to senderID → ghost card. When the device reconnects with a new senderID + new sessionID, a second (correct) card appears.

2. **Bug 1 (P0):** `sessionToIdentity` is not persisted. After provider restart, restored channels have no identity mapping → fall back to senderID until client sends a request.

3. **Bug 2 (P0):** `sessionToSender` is not populated for restored channels. `clientSummaries` iterates `sessionToSender`, so restored channels are invisible in the UI (stats show "N Sessions" but 0 client cards).

4. **Bug 4 (P2):** Transient — race between MPC connect and first PromptRequest. Self-resolving, cosmetic only.

---

## Design Decisions

1. **Prune `sessionToSender` + `lastResponses` in `removeChannelIfMatch`** — The comment "needed for send() routing" is wrong for removed channels. A settled/removed channel has nothing to route to. Keeping it creates ghost cards. Also prune `lastResponses` to prevent stale `SessionSync` on reconnect with same sessionID.

2. **Update `activeSessionCount` in `removeChannelIfMatch`** — Currently stale after settlement (channels removed but count not updated). Add `activeSessionCount = channels.count`.

3. **Persist `sessionToIdentity`** — Add to `PersistedProviderState` as optional field. Restore in `init`. This ensures restored channels have correct identity grouping immediately.

4. **Iterate `channels.keys` in `clientSummaries`** — Instead of `sessionToSender` (which is a routing table, not a UI data source). `channels` is the source of truth for "sessions that exist." This eliminates the need for placeholder senderIDs and defensive guards. (Architecture reviewer recommendation — avoids dual-purposing `sessionToSender`.)

---

## Implementation Steps

### Step 1: Full cleanup in `removeChannelIfMatch`

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift` — `removeChannelIfMatch()`

Prune all session-related state and update `activeSessionCount`:

```swift
/// Remove a channel only if its channelId still matches (guards against a reconnected client replacing the channel).
/// Prunes all session-related state: identity mapping, sender routing, and cached responses.
private func removeChannelIfMatch(sessionID: String, expectedChannelId: Data, onlyIfSettled: Bool = false) {
    guard channels[sessionID]?.channelId == expectedChannelId else { return }
    if onlyIfSettled {
        guard channels[sessionID]?.unsettledAmount == 0 else { return }
    }
    channels.removeValue(forKey: sessionID)
    sessionToIdentity.removeValue(forKey: sessionID)
    sessionToSender.removeValue(forKey: sessionID)
    lastResponses.removeValue(forKey: sessionID)
    activeSessionCount = channels.count
    persistState()
}
```

**Dependencies:** None.

---

### Step 2: Add `sessionToIdentity` to `PersistedProviderState`

**Modify:** `Sources/JanusShared/Persistence/SessionStore.swift`

Add optional field (backward compatible via `decodeIfPresent`):

```swift
/// Identity mappings for unsettled sessions (sessionID → device pubkey base64).
/// Only unsettled channels survive restart; other identity mappings are re-established on reconnect.
public var sessionToIdentity: [String: String]?
```

Add to `init` parameter list with default `nil`. Add `decodeIfPresent` line in custom decoder.

**Dependencies:** None.

---

### Step 3: Persist `sessionToIdentity` in `persistState()`

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift` — `persistState()`

Pass `sessionToIdentity` (filtered to only sessions with unsettled channels) to `PersistedProviderState`:

```swift
// Only persist identity mappings for unsettled sessions — those are the only channels restored on restart.
// Non-unsettled identity mappings are re-established when clients reconnect and send a PromptRequest.
let unsettledIdentities = sessionToIdentity.filter { unsettled[$0.key] != nil }
let state = PersistedProviderState(
    ...
    unsettledChannels: unsettled.isEmpty ? nil : unsettled,
    sessionToIdentity: unsettledIdentities.isEmpty ? nil : unsettledIdentities
)
```

**Dependencies:** Step 2.

---

### Step 4: Restore `sessionToIdentity` on startup

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift` — `init`

After restoring unsettled channels, also restore identity mappings:

```swift
if let unsettled = persisted.unsettledChannels, !unsettled.isEmpty {
    self.channels = unsettled
    self.activeSessionCount = unsettled.count
    // Restore identity mappings so clientSummaries groups correctly
    if let identities = persisted.sessionToIdentity {
        self.sessionToIdentity = identities
    }
    print("Restored \(unsettled.count) unsettled channel(s) from previous session")
}
```

No placeholder `sessionToSender` entries needed — Step 5 changes `clientSummaries` to iterate `channels.keys` instead.

**Dependencies:** Step 2.

---

### Step 5: Refactor `clientSummaries` to iterate `channels.keys`

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift` — `clientSummaries`

Change the iteration source from `sessionToSender` to `channels.keys`. This is the source of truth for "sessions that exist" and eliminates ghost cards from stale `sessionToSender` entries:

```swift
var clientSummaries: [ClientSummary] {
    var summaries: [String: ClientSummary] = [:]
    var senderIDSets: [String: Set<String>] = [:]

    for sessionID in channels.keys {
        let senderID = sessionToSender[sessionID]
        // Use stable identity if available, fall back to senderID, then sessionID
        let identity = sessionToIdentity[sessionID] ?? senderID ?? sessionID
        let channel = channels[sessionID]

        var summary = summaries[identity] ?? ClientSummary(
            id: identity,
            senderIDs: [],
            ...
        )
        if let senderID {
            senderIDSets[identity, default: []].insert(senderID)
        }
        // ... rest unchanged
    }
    // ... rest unchanged
}
```

Key changes:
- Iterates `channels.keys` (source of truth) instead of `sessionToSender` (routing table)
- `senderID` is now optional (`sessionToSender[sessionID]` may be nil for restored channels)
- Identity fallback chain: `sessionToIdentity` → `senderID` → `sessionID`
- Only inserts into `senderIDSets` when a real senderID exists

**Dependencies:** None (but logically after Steps 1-4).

---

## Files Summary

| File | Action | Changes |
|------|--------|---------|
| `JanusApp/JanusProvider/ProviderEngine.swift` | Modify | (1) Full cleanup in `removeChannelIfMatch`, (2) persist `sessionToIdentity` in `persistState()`, (3) restore identity in `init`, (4) refactor `clientSummaries` to iterate `channels.keys` |
| `Sources/JanusShared/Persistence/SessionStore.swift` | Modify | Add `sessionToIdentity: [String: String]?` to `PersistedProviderState` |

**Total:** ~20 lines changed across 2 files (all modifications, no new files).

---

## What Does NOT Change

- Client-side code — `clientIdentity` already sent correctly on every request
- `ProviderStatusView` — no UI changes, just correct data flowing through
- Settlement logic — unchanged
- Transport layer — unchanged
- `removeChannelIfMatch` channelId guard — unchanged (still safe against reconnect races)

---

## Verification

1. **Build:** `xcodebuild` builds the provider target
2. **Ghost card test:** Connect iPhone → send request → disconnect → settlement succeeds → reconnect → should see 1 card (not 2)
3. **Provider restart test:** Send requests → force-quit provider → relaunch → restored channels should show with correct identity grouping (not senderID fallback)
4. **Backward compat:** Existing `provider_state.json` without `sessionToIdentity` field loads correctly (`decodeIfPresent` defaults to nil)
5. **Clean state:** No channels, no sessions → 0 client cards, no ghost entries

---

## Risks

- **Low:** Mostly fixing cleanup logic (pruning stale entries) and adding persistence for an existing dict.
- **`clientSummaries` iteration change:** Switching from `sessionToSender` to `channels.keys` means sessions that exist in `sessionToSender` but not in `channels` become invisible. This is the desired behavior — such sessions are settled/removed and should not produce cards.

---

## Review Findings Incorporated

Based on **systems-architect review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| P2 | `lastResponses` not pruned in `removeChannelIfMatch` | Added to Step 1 cleanup |
| P2 | `activeSessionCount` stale after channel removal | Added `activeSessionCount = channels.count` to Step 1 |
| P3 | Placeholder senderID needs code comment | Eliminated — Step 5 iterates `channels.keys` instead |
| P3 | Persistence filter needs explanatory comment | Added comment in Step 3 |

Based on **architecture-reviewer review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| P2 | Iterate `channels.keys` instead of `sessionToSender` in `clientSummaries` | Adopted as Step 5 — eliminates placeholder senderIDs entirely |
| P2 | `activeSessionCount` drift | Same fix as above (Step 1) |
| P3 | Step 5 plan text had contradictory code blocks | Rewritten cleanly |
| P3 | Identity persistence filter needs comment | Same fix as above (Step 3) |

**Confirmed sound:** Pruning `sessionToSender` in `removeChannelIfMatch` (no active routing depends on it), backward compatibility of `PersistedProviderState` change, root cause analysis complete.
