# Feature #2: Dual Mode (Relay + Client on Same Phone)

**Status:** Implemented (2026-04-08)
**Commit:** c42f714

## Context

Relay mode and client mode were mutually exclusive — `@AppStorage("appMode")` switched between `RelayView` and `DiscoveryView`. A phone acting as relay couldn't send its own queries. This wasted the relay phone's potential and meant relay auto-fallback (#3) would require a dedicated relay device.

**Goal:** A phone can simultaneously relay messages for other clients AND send its own queries to the provider, sharing the upstream MPC session.

## Design Decision: ProviderTransport Protocol

Evaluated 3 approaches:
- **A) Merge into DualModeEngine** — rejected: 900+ line god class, destroys separation of concerns
- **B) ProviderTransport protocol** — chosen: ClientEngine doesn't care how messages reach the provider, just needs send/receive/state
- **C) MPCRelay owns ClientEngine** — rejected: converges to B, tangled ownership for SwiftUI

## Response Routing

**The hard problem:** Provider sends responses with `senderID = providerID`, not the requesting client's ID. The relay can't tell from the envelope alone whether a response is for a local or forwarded request.

**Initial approach (FIFO queue):** Track request order assuming sequential processing. Failed during manual testing — the two-round-trip flow (promptRequest→quoteResponse→voucherAuth→inferenceResponse) causes unpredictable ordering because the local client's voucherAuth arrives instantly while the remote client's has MPC latency.

**Final approach (requestID map):** Extract `requestID` from each request sent to the provider, store `requestID → (local | remote(clientPeer))`. When response arrives, extract `requestID` from payload and look up the map. Order-independent, works with any interleaving.

## Files Changed

| File | Change |
|------|--------|
| `ProviderTransport.swift` | **NEW** — protocol + ConnectionState/ConnectionMode enums |
| `MPCBrowser.swift` | Conformed to ProviderTransport, typealiases for moved enums |
| `ClientEngine.swift` | Accepts `any ProviderTransport` via `init(transport:)` |
| `MPCRelay.swift` | Added `RelayLocalTransport`, `sendLocalMessage()`, `requestRouting` map, `enableLocalClient()` |
| `DualModeView.swift` | **NEW** — combined relay stats bar + client UI |
| `JanusClientApp.swift` | Three-way mode switching: client/relay/dual |
| `DiscoveryView.swift` | Added "Switch to Dual Mode" menu item |
| `RelayView.swift` | Added "Dual Mode" menu item |
| `DualModeTests.swift` | **NEW** — 11 unit tests for local transport + engine integration |

## Testing

- 22 unit tests (11 new + 11 existing), all passing
- 6 manual scenarios verified:
  1. Client-only regression (no behavioral change)
  2. Mode switching (client/relay/dual, all transitions)
  3. Dual mode local queries (relay phone sends own queries)
  4. Remote client through relay (Phone B via Phone A in dual mode)
  5. Interleaved requests (A and B send back-to-back, no cross-talk)
  6. Provider disconnect/reconnect (both phones recover)
