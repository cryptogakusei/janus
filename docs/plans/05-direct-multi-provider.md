# Feature #5: Direct Mode Multi-Provider Support

**Status:** Reverted (2026-04-08) — AWDL unreliable for concurrent MPC sessions. Deferred to Bonjour+TCP transport (roadmap #8).
**Dependencies:** #4 (Multi-Provider Relay Support) — completed

## Context

In direct mode, `MPCBrowser` connected to the first discovered provider and immediately stopped browsing (`stopProviderBrowser()`). The `foundPeer` handler also rejected new peers unless `connectionState == .disconnected`. This meant if two Macs were running JanusProvider nearby, the iPhone only ever saw one.

Feature #4 solved this for relay mode. Feature #5 extends the same multi-provider UX to direct mode — but with a key advantage: `MCSession` natively supports multiple connected peers (up to 8), so switching is instant with no disconnect/reconnect.

---

## Design: Same Session, Multiple Peers

### Key Insight

`MCSession` supports multiple connected peers natively. Instead of disconnect/reconnect, all discovered providers are invited into the same `providerSession`. Switching providers just changes which peer receives `send()` calls via `providerPeerID`.

### Changes

**MPCBrowser.swift:**
- Added `directProviders: [String: ServiceAnnounce]`, `directProviderPeers: [String: MCPeerID]`, `directPeerProviderIDs: [MCPeerID: String]` maps
- `foundPeer` now accepts additional providers when `connectionState == .connected && connectionMode == .direct`
- `handleProviderSessionChange(.connected)` no longer calls `stopProviderBrowser()` — keeps discovering
- `handleDirectData` maps ServiceAnnounce to peer via the three dicts
- Added `selectDirectProvider(_ providerID:)` — updates `providerPeerID` without disconnect
- Disconnect handling auto-switches to next available direct provider
- All three dicts cleared in `startSearching()`, `disconnect()`, `checkConnectionHealth()`

**ClientEngine.swift:**
- `availableProviders` now merges relay and direct via `combineLatest` (mutually exclusive by mode)
- `selectProvider()` routes to `selectDirectProvider()` when `connectionMode == .direct`

**MultiProviderTests.swift:**
- 7 new direct mode tests (selection, unknown ID, cleanup, Combine forwarding, engine routing)

---

## Files changed

| File | Change |
|------|--------|
| `MPCBrowser.swift` | `directProviders` + peer maps, keep browser running, accept additional peers, `selectDirectProvider()`, disconnect auto-switch, cleanup |
| `ClientEngine.swift` | `combineLatest` for relay+direct → `availableProviders`, mode-aware `selectProvider()` |
| `MultiProviderTests.swift` | 7 new direct mode unit tests |

## What does NOT change

- Relay multi-provider path — already works from Feature #4
- `DiscoveryView.swift` / `DualModeView.swift` — picker UI already built, triggers on `availableProviders.count > 1`
- `SessionManager.swift` — per-provider persistence already works from Feature #4
- `ServiceAnnounce` / protocol messages — no protocol changes
- `RelayLocalTransport` — dual mode unaffected

---

## Verification

1. `xcodebuild test` — all 45 tests pass (15 multi-provider: 8 relay + 7 direct)
2. Manual test — single direct provider still works (no picker, no behavior change)
3. Manual test — two providers in direct mode:
   - Mac A: JanusProvider ("MacBook Pro")
   - Mac B: JanusProvider ("Mac Mini")
   - iPhone: Client mode (direct) — discovers both, connects to both, picker appears
   - Select Mac A → send query → response from Mac A
   - Switch to Mac B → send query → response from Mac B
   - Switch back → credits preserved (per-provider sessions from Feature #4)
4. Manual test — provider disconnect:
   - Quit Mac B while iPhone is using it → auto-switches to Mac A
   - Restart Mac B → appears in picker again after ~2s
5. Manual test — relay mode still works (regression check)
