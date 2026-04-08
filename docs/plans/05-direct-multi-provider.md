# Feature #5: Direct Mode Multi-Provider Support

**Status:** Planned
**Dependencies:** #4 (Multi-Provider Relay Support)

## Context

In direct mode, the client connects to the first provider found via MPC and stops browsing. If multiple providers are nearby, the user has no way to see or switch between them. The relay path (#4) supports multi-provider because the relay holds simultaneous connections, but direct mode is 1:1.

**Goal:** In direct mode, continue browsing after first connection. Show a provider picker when multiple direct providers are discoverable, and allow switching (disconnect + reconnect).

---

## Design: Connect-then-Switch

### Approach

Connect to the first provider found (fast initial UX), but keep the provider browser running. Store all discovered providers via their ServiceAnnounce. When the user selects a different provider, disconnect from the current one and connect to the new one.

### Key Difference from Relay Multi-Provider

- Relay switching is instant (just change `destinationID`, zero latency)
- Direct switching requires disconnect → reconnect (few seconds, risk of failure)
- UI should indicate switching is in progress

### Changes

**MPCBrowser.swift:**
- Don't stop `providerBrowser` after first connection (or restart it after connecting)
- Store discovered direct providers in a `directProviders: [MCPeerID: ServiceAnnounce]` dict
- Add `selectDirectProvider(_ peerID: MCPeerID)` — disconnect current, invite new peer
- Handle the transition state (briefly disconnected while switching)

**ClientEngine.swift:**
- `availableProviders` already published — populate from `directProviders` when in direct mode

**DiscoveryView.swift:**
- Provider picker already exists — just needs to work when `availableProviders > 1` regardless of mode

### Considerations

- MPC provider browser discovery info doesn't include ServiceAnnounce (that comes after connection). We'd need to either:
  - a) Connect briefly to each to get their ServiceAnnounce (complex)
  - b) Include basic info (name, model) in MPC discovery info dict (simpler, limited to ~400 bytes)
  - c) Show only peer display names until connected (least info, simplest)
- Provider selection is NOT signal-based — MPC doesn't expose RSSI or distance

---

## Verification

1. Two Macs running JanusProvider, one iPhone in client mode
2. iPhone discovers both, connects to first, picker appears with second
3. Switch to second Mac — brief "Connecting..." state, then connected
4. Send query to second Mac — response arrives correctly
5. Switch back to first Mac — works
