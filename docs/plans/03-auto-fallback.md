# Feature #3: Auto-Fallback (Direct → Relay)

**Status:** Planned
**Dependencies:** #2 (Dual Mode) — completed

## Context

When a client can't connect directly to a provider (e.g., AWDL fails, out of range), it enters `.connectionFailed` after 2 timeouts and stops browsing entirely. The user must manually switch to relay mode. Now that dual mode (#2) exists, any nearby Janus phone is a potential relay — but the client doesn't know to look for one.

**Goal:** After direct connection fails, automatically start browsing for relays alongside continued direct attempts. Accept whichever path connects first.

---

## Current Behavior (MPCBrowser.swift)

1. `startSearching()` → starts provider browser (or relay browser if `forceRelayMode`)
2. Direct peer found → `.connecting` → invite with 10s timeout
3. First timeout → `.disconnected` → retry (reset sessions, restart browser)
4. Second timeout → `.connectionFailed` → **stop all browsing** <-- the gap
5. User stuck unless they manually switch mode

Key lines:
- `startConnectionTimeout()` (line 264-292): timeout logic, `consecutiveTimeouts` counter
- `connectionFailed` set at line 272 when `consecutiveTimeouts >= maxTimeoutsBeforeWarning` (2)
- Lines 273-274: stops both browsers on failure

---

## Design

### Approach: Parallel browsing after failure threshold

Instead of stopping on `.connectionFailed`, start the relay browser too and keep the provider browser running. This creates a "race" — first successful path wins.

### Changes to `MPCBrowser.swift`

**1. Modify `startConnectionTimeout()` — on 2nd timeout, start relay browser instead of stopping**

Current (lines 270-274):
```swift
if consecutiveTimeouts >= maxTimeoutsBeforeWarning {
    print("[Browser] Provider found but can't connect after \(consecutiveTimeouts) attempts — WiFi likely off on provider")
    connectionState = .connectionFailed
    stopProviderBrowser()
    stopRelayBrowser()
}
```

New:
```swift
if consecutiveTimeouts >= maxTimeoutsBeforeWarning {
    print("[Browser] Direct connection failed after \(consecutiveTimeouts) attempts — falling back to relay search")
    connectionState = .connectionFailed
    // Don't stop browsing — start relay browser as fallback
    if !forceRelayMode {
        startRelayBrowser()
    }
    // Reset sessions and retry direct too
    resetProviderSession()
    resetRelaySession()
    // Keep provider browser running for direct race
    startProviderBrowser()
}
```

**2. Guard `foundPeer` to allow relay discovery during `.connectionFailed`**

Current (line 368):
```swift
guard connectionState == .disconnected || connectionState == .connectionFailed else { return }
```

Already allows discovery in `.connectionFailed` — no change needed.

**3. Direct connection wins → disconnect relay**

Already handled (lines 438-443): when direct connects, relay is disconnected and relay browser stopped. No change needed.

**4. Relay connection wins → stop retrying direct**

Already handled (lines 567-572): when relay ServiceAnnounce arrives, both browsers are stopped. No change needed.

**5. Add a status message for fallback state**

In `DiscoveryView.swift`, update the `.connectionFailed` empty state to mention relay search.

**6. Reset `consecutiveTimeouts` when relay connects**

Already done at line 465 in `handleRelaySessionChange(.connected)`.

---

## What does NOT change

- `forceRelayMode` behavior — still skips direct entirely
- Direct-only happy path — works exactly as before
- Relay-only happy path — works exactly as before
- Dual mode — unaffected, uses `RelayLocalTransport` not `MPCBrowser`
- `checkConnectionHealth()` — already restarts browsers correctly
- `handleProviderLostViaRelay()` — already attempts direct fallback

---

## Files to modify

| File | Change | Lines |
|------|--------|-------|
| `MPCBrowser.swift` | Modify timeout handler to start relay browser on fallback | ~10 changed |
| `DiscoveryView.swift` | Update `.connectionFailed` empty state text | ~3 changed |

**Total:** ~13 lines changed. No new files.

---

## Verification

1. `xcodebuild test` — all 22 iOS tests pass (no behavioral change to existing paths)
2. Manual test — direct mode works as before (provider in range)
3. Manual test — direct fails, relay auto-discovered:
   - Phone A: Dual mode (acting as relay + client)
   - Phone B: Client mode, provider out of direct range (or kill provider's WiFi briefly)
   - Phone B should show `.connectionFailed` then auto-discover Phone A as relay
   - Phone B connects through Phone A, sends query, gets response
4. Manual test — direct recovers while on relay:
   - While Phone B is on relay, restore direct path
   - On next `checkConnectionHealth()` or reconnect cycle, direct should win
