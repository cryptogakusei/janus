# Feature #4: Multi-Provider Relay Support

**Status:** Implemented (2026-04-08)
**Dependencies:** #2 (Dual Mode) — completed

## Context

The relay already connects to multiple providers and stores them in `reachableProviders`. It already routes by `destinationID` in `forwardToProvider()`. It already forwards `ServiceAnnounce` from each provider to clients. But the **client only tracks one provider** — each new `ServiceAnnounce` overwrites `connectedProvider`, and `RelayAnnounce` auto-picks the first provider.

**Goal:** When connected via relay, the client can see and choose between multiple providers.

---

## Current Flow

1. Relay sends `RelayAnnounce` with `[RelayProviderInfo]` (thin: ID, name, pubkey, ethAddr)
2. Client picks first provider, stores `relayProviderID` (MPCBrowser.swift:545-549)
3. Relay forwards `ServiceAnnounce` from each provider (full: model, pricing, tasks, availability)
4. Client overwrites `connectedProvider` with each one (MPCBrowser.swift:571-572)
5. Client sends requests with `destinationID = relayProviderID`

**What already works:**
- Relay routing by `destinationID` (MPCRelay.swift:209-216)
- Relay storing multiple providers in `providerRoutes` dict
- Relay forwarding all ServiceAnnounces to all clients

**What's broken for multi-provider:**
- Client overwrites `connectedProvider` on each ServiceAnnounce
- Client auto-picks first provider from RelayAnnounce with no UI
- No way for user to switch providers without reconnecting

---

## Design

### Step 1: MPCBrowser stores all relay providers

**File:** `MPCBrowser.swift`

Add a published dict of all providers available through the relay:

```swift
@Published var relayProviders: [String: ServiceAnnounce] = [:]  // providerID → announce
```

In `handleRelayData()` when ServiceAnnounce arrives via relay:
- Store in `relayProviders[announce.providerID] = announce` (don't overwrite `connectedProvider`)
- If no provider selected yet (`connectedProvider == nil`), auto-select the first one
- If currently selected provider, keep it

In `handleRelayData()` when RelayAnnounce arrives:
- Remove providers from `relayProviders` that are no longer in the reachable list
- If current `connectedProvider` was removed, auto-select next available or nil

### Step 2: Add provider switching method

**File:** `MPCBrowser.swift`

```swift
func selectRelayProvider(_ providerID: String) {
    guard let announce = relayProviders[providerID] else { return }
    connectedProvider = announce
    relayProviderID = providerID
    relayRouteID = UUID().uuidString
}
```

### Step 3: Forward through ClientEngine

**File:** `ClientEngine.swift`

Expose relay providers and selection:
```swift
@Published var availableProviders: [ServiceAnnounce] = []
```

Subscribe to `browserRef?.relayProviders` changes and publish as `availableProviders`.

```swift
func selectProvider(_ providerID: String) {
    browserRef?.selectRelayProvider(providerID)
}
```

### Step 4: Provider picker UI in DiscoveryView

**File:** `DiscoveryView.swift`

When `engine.availableProviders.count > 1`, show a provider picker above the single provider card:

```swift
if engine.availableProviders.count > 1 {
    providerPicker
}
providerInfoCard(provider)  // shows currently selected
```

The picker is a simple list/segmented control showing provider name + model tier. Tapping switches.

### Step 5: Clean up on disconnect

**File:** `MPCBrowser.swift`

Clear `relayProviders` in:
- `startSearching()` (reset)
- `stopSearching()` (cleanup)
- `handleProviderLostViaRelay()` (remove specific provider)
- Relay disconnect (clear all)

---

## Files changed

| File | Change |
|------|--------|
| `MPCBrowser.swift` | `relayProviders` dict, `selectRelayProvider()`, update `handleRelayData()`, pruning on `RelayAnnounce`, cleanup in 5 spots |
| `MPCRelay.swift` | `RelayLocalTransport.relayProviders`, `selectProvider()`, Combine subscription from relay's `reachableProviders`, `sendLocalMessage` routes to selected provider |
| `ClientEngine.swift` | `availableProviders` published, `selectProvider()` forwarding for both MPCBrowser and RelayLocalTransport |
| `DiscoveryView.swift` | Provider picker UI (horizontal scroll, appears when >1 provider) |
| `DualModeView.swift` | Same provider picker for dual mode |
| `SessionManager.swift` | Per-provider persistence (`client_session_{providerID}.json`) — fixes session overwrite on provider switch |
| `MultiProviderTests.swift` | **NEW** — 8 unit tests for selection, cleanup, Combine forwarding |

## Bugs found during testing

1. **DualModeView missing picker** — picker was only added to DiscoveryView, not DualModeView
2. **Session overwrite** — single `client_session.json` file meant switching providers overwrote the previous session. Credits reset to 100 on switch-back. Fixed with per-provider filenames.
3. **`sendLocalMessage` routing** — always picked first connected provider session instead of the selected one. Fixed to route via `providerRoutes[selectedProviderID]`.

---

## What does NOT change

- Direct connection path — single provider, no picker needed
- Relay forwarding logic in `MPCRelay.swift` — already works
- Dual mode — uses `RelayLocalTransport`, only sees one provider (the relay's upstream)
- `RelayAnnounce` / `RelayProviderInfo` / `ServiceAnnounce` structs — no protocol changes

---

## Verification

1. `xcodebuild test` — all 22 iOS tests pass
2. Manual test — single provider via relay still works (no UI change when only 1 provider)
3. Manual test — two providers:
   - Mac A: JanusProvider (e.g., "MacBook Pro")
   - Mac B: JanusProvider (e.g., "Mac Mini")
   - Phone A: Dual mode (relay) — connects to both Macs, relay stats show 2 providers
   - Phone B: Client mode via relay — should see both providers, picker appears
   - Phone B: Select Mac A → send query → response from Mac A
   - Phone B: Switch to Mac B → send query → response from Mac B
4. Manual test — provider disconnect:
   - Quit Mac B while Phone B is using it → Phone B auto-switches to Mac A (or shows picker)
   - Relay stats update to 1 provider
