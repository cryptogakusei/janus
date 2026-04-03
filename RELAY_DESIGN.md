# Multi-Hop Relay Design

## Motivation

Today Janus requires the client iPhone to be in direct MPC range (~30m Bluetooth/WiFi Direct) of the provider Mac. Multi-hop relay breaks this limitation: nearby phones forward opaque message bundles so a client two rooms away, across a courtyard, or around a corner can still reach the provider.

This is what turns Janus from "connect your phone to your Mac" into a mesh AI network.

---

## 1. Topology

### Mode 1 (current): Direct
```
Client ──MPC── Provider
```

### Mode 2 (this design): Single-hop relay
```
Client ──MPC── Relay ──MPC── Provider
```

### Mode 3 (future): Multi-hop relay
```
Client ──MPC── Relay A ──MPC── Relay B ──MPC── Provider
```

This design focuses on Mode 2. Mode 3 is a generalization that uses the same protocol with hopCount > 1.

---

## 2. What is a relay?

A relay is an iPhone running Janus in relay mode. It:

- **Browses** for nearby providers (like a client does)
- **Advertises** itself as a relay (so clients can find it)
- **Forwards** message bundles bidirectionally between clients and providers
- **Cannot** read encrypted payloads, generate vouchers, or claim payments
- **Does not** run inference or hold payment state

A relay maintains two independent MPC connections:
- **Upstream**: relay → provider (relay acts as MPC browser, provider sees it as a client)
- **Downstream**: client → relay (relay acts as MPC advertiser, client sees it as a relay)

### App modes

The Janus iPhone app gains a third mode alongside "Client" and existing functionality:

| Mode | Browses for | Advertises as | Processes messages |
|------|-------------|---------------|-------------------|
| Client | providers + relays | — | sends requests, signs vouchers |
| Relay | providers | relay | forwards opaque bundles |

A single phone could potentially run Client + Relay simultaneously (use a provider via relay while also relaying for others), but v2 treats these as exclusive modes.

---

## 3. Discovery

### Service types

MPC discovery uses Bonjour service types. Today there is one:

- `janus-ai` — provider advertising inference service

Add a second:

- `janus-relay` — relay advertising forwarding service

### Discovery flow

**Relay startup:**
1. Relay browses for `janus-ai` (finds providers)
2. Relay connects to discovered providers, receives `ServiceAnnounce`
3. Relay begins advertising on `janus-relay` with discovery info listing reachable providers

**Client discovery:**
1. Client browses for `janus-ai` (direct providers) AND `janus-relay` (relays)
2. If a direct provider is found, connect directly (Mode 1, unchanged)
3. If only relays are found, examine which providers they can reach
4. Client connects to the relay that can reach the best provider
5. Relay forwards the provider's `ServiceAnnounce` to the client

### Relay discovery info

MPC discovery info is limited to key-value string pairs (max ~400 bytes). The relay encodes a compact summary:

```
{
    "type": "relay",
    "providers": "prov_abc1,prov_def2",   // comma-separated provider IDs
    "hopCount": "1"                        // how many hops to provider
}
```

This lets the client decide which relay to connect to without a full handshake.

---

## 4. Message routing

### Relay envelope

The relay needs to know where to forward a message without understanding its contents. Wrap the existing `MessageEnvelope` in a routing layer:

```swift
struct RelayEnvelope: Codable {
    let routeID: String              // unique per client-provider pair
    let destinationID: String        // target provider ID or client session ID
    let originID: String             // original sender ID
    let hopCount: Int                // current hop count
    let maxHops: Int                 // TTL (default: 3)
    let innerEnvelope: Data          // the original MessageEnvelope, opaque bytes
}
```

### Forwarding rules

When a relay receives a `RelayEnvelope`:

1. **Check TTL**: if `hopCount >= maxHops`, drop the message
2. **Route to provider**: if `destinationID` matches a connected provider, unwrap `innerEnvelope` and send it directly via that provider's MPC session
3. **Route to client**: if `destinationID` matches a connected client's session, unwrap `innerEnvelope` and send it via that client's MPC session
4. **Forward to next relay** (Mode 3 only): increment `hopCount`, forward to the next relay that can reach `destinationID`

### Message flow: client → provider (via relay)

```
Client                      Relay                       Provider
  │                           │                            │
  │  RelayEnvelope{           │                            │
  │    dest: providerID       │                            │
  │    inner: PromptRequest   │                            │
  │  }                        │                            │
  │ ─────────────────────────>│                            │
  │                           │  MessageEnvelope{          │
  │                           │    PromptRequest           │
  │                           │  }                         │
  │                           │ ──────────────────────────>│
  │                           │                            │
  │                           │  MessageEnvelope{          │
  │                           │    QuoteResponse           │
  │                           │  }                         │
  │                           │ <──────────────────────────│
  │  RelayEnvelope{           │                            │
  │    dest: clientSessionID  │                            │
  │    inner: QuoteResponse   │                            │
  │  }                        │                            │
  │ <─────────────────────────│                            │
```

### Why the relay unwraps before forwarding to the provider

The provider doesn't know about relays. It receives standard `MessageEnvelope` messages exactly as if the client were directly connected. This means **zero changes to provider code** for basic relay support.

The relay maintains a routing table mapping `senderID → client MPC peer` so it can route responses back. When the provider sends a response, the relay looks up which client it belongs to and wraps it in a `RelayEnvelope` for the return trip.

---

## 5. Provider transparency

A key design goal: **the provider doesn't need to know whether a client is direct or relayed.**

From the provider's perspective:
- A "client" connects via MPC (it's actually the relay)
- That "client" sends `PromptRequest` messages with valid session IDs and vouchers
- The provider processes them normally and sends responses back

The relay appears as just another MPC peer to the provider. The provider's `MPCAdvertiser` already supports multiple clients — the relay is simply another connected peer that happens to forward messages on behalf of others.

### Implication for settlement

Payment channels are client ↔ provider. The voucher is signed by the client's wallet and settled on-chain by the provider. The relay is completely outside the payment flow. Settlement works identically whether the request was direct or relayed.

---

## 6. Client changes

The client needs to:

1. **Browse for relays** in addition to providers (second `MCNearbyServiceBrowser` for `janus-relay`)
2. **Prefer direct connections** — only use relay if no direct provider is available
3. **Wrap messages in RelayEnvelope** when communicating through a relay
4. **Unwrap RelayEnvelopes** from relay responses to extract the inner `MessageEnvelope`

### Connection routing

The client browses for both `janus-ai` (providers) and `janus-relay` (relays) simultaneously.

**Default behavior (production):**
```
1. Direct provider found     → connect directly (Mode 1)
2. No direct provider after 5s, relay found → connect via relay (Mode 2)
3. Neither found             → keep scanning
```

**Force relay mode (developer toggle):**
```
1. Ignore all direct provider discoveries
2. Only connect through relays
3. Used for testing relay path when all devices are in the same room
```

The toggle is a `forceRelayMode` bool in `MPCBrowser`, exposed in the client UI as a developer setting. In production it defaults to off.

```swift
// In MPCBrowser
@Published var forceRelayMode = false

// In browser(_:foundPeer:) for "janus-ai" service:
if forceRelayMode { return }  // skip direct providers
```

### Connection mode indicator

The client UI shows which path is active:

| Mode | Badge | Color |
|------|-------|-------|
| Direct | "Direct" | green |
| Relayed | "via Relay" | blue |
| Disconnected | "Disconnected" | gray |

This is visible during testing and in production so the user always knows how they're connected.

### Relay-aware MPCBrowser

Extend `MPCBrowser` to track both providers and relays:

```swift
@Published var connectionMode: ConnectionMode = .disconnected

enum ConnectionMode {
    case disconnected
    case direct              // connected to provider via MPC
    case relayed(relayName: String)  // connected to provider through relay
}

// Separate browser for relay discovery
private var relayBrowser: MCNearbyServiceBrowser  // browses "janus-relay"
private var relayPeerID: MCPeerID?                // connected relay
```

---

## 7. Relay implementation

### MPCRelay class

The relay is a new class that combines browser + advertiser functionality:

```swift
class MPCRelay: ObservableObject {
    // Upstream: connections to providers
    private let providerBrowser: MCNearbyServiceBrowser  // browses "janus-ai"
    private var providerSessions: [MCPeerID: MCSession]  // per-provider sessions
    var reachableProviders: [String: ServiceAnnounce]     // providerID → announce

    // Downstream: connections from clients
    private let clientAdvertiser: MCNearbyServiceAdvertiser  // advertises "janus-relay"
    private var clientSessions: [MCPeerID: MCSession]        // per-client sessions

    // Routing table
    private var clientRoutes: [String: MCPeerID]   // senderID → client peer
    private var providerRoutes: [String: MCPeerID]  // providerID → provider peer
}
```

### Relay lifecycle

1. **Start**: browse for providers, wait for at least one connection
2. **Advertise**: once a provider is connected, start advertising as relay
3. **Forward**: when clients connect and send RelayEnvelopes, forward to the right provider
4. **Route responses**: when providers send responses, look up the client and wrap in RelayEnvelope
5. **Handle disconnects**: if a provider disconnects, stop advertising that provider; if a client disconnects, clean up routing state

---

## 8. Security model

### Phase 1 (v2): Trusted relay

The relay can read message contents (they're plaintext JSON). This is acceptable for the initial version where the relay is typically the user's own second phone or a trusted friend's device.

The relay **cannot**:
- Forge vouchers (doesn't have the client's wallet private key)
- Claim payments (isn't the channel payee)
- Forge receipts (doesn't have the provider's signing key)
- Replay messages (provider tracks sequence numbers and cumulative spend)

What the relay **can** see in Phase 1:
- Prompt text and inference responses
- Session IDs, provider IDs
- Credit amounts

### Phase 2 (future): End-to-end encryption

Add E2E encryption between client and provider so the relay only sees opaque bytes:

1. Client and provider perform ECDH key exchange using their existing ETH keypairs
2. Derive a shared secret → AES-256-GCM session key
3. Client encrypts the `MessageEnvelope` payload before wrapping in `RelayEnvelope`
4. Provider decrypts after unwrapping
5. Relay sees only `RelayEnvelope` with opaque `innerEnvelope` bytes

The key exchange can happen during the initial `ServiceAnnounce` / session setup — the client already knows the provider's ETH address from `ServiceAnnounce.providerEthAddress`.

---

## 9. Relay incentives (future)

Phase 1 relays are altruistic. Future options:

### Option A: Provider fee split
Provider pays a percentage of earned credits to the relay. Requires the relay to have an ETH address and the provider to send a separate settlement.

### Option B: Relay earns inference credits
Relay accumulates credits from the provider that it can spend on its own inference requests later. A "relay for 10 minutes, earn 1 free request" model.

### Option C: Client tips relay
Client opens a micro payment channel with the relay. Adds complexity but is the most incentive-compatible.

### Recommendation
Option B is the simplest and most natural. Relaying is lightweight (forwarding JSON), so the reward should be proportional. Implementation: provider tracks relay ID alongside session state and issues relay credits on settlement.

---

## 10. Implementation plan

### Phase 1: Core relay forwarding (MVP — make it work)

Goal: A message goes from client through relay to provider and back. Payment still works.

**Protocol layer (JanusShared)**
- [ ] `RelayEnvelope` type — routing wrapper with destinationID, originID, hopCount, maxHops, innerEnvelope
- [ ] `RelayAnnounce` type — relay identity + list of reachable provider IDs
- [ ] New `MessageType` cases: `.relayEnvelope`, `.relayAnnounce`

**Relay (iPhone relay mode)**
- [ ] `MPCRelay` class — browses `janus-ai` for providers, advertises on `janus-relay` for clients
- [ ] Provider connection management — per-provider MPC sessions, receives `ServiceAnnounce`
- [ ] Client connection management — per-client MPC sessions, accepts incoming connections
- [ ] Routing table — maps senderID → client peer, providerID → provider peer
- [ ] Forward client→provider: unwrap `RelayEnvelope`, send bare `MessageEnvelope` to provider
- [ ] Forward provider→client: receive `MessageEnvelope`, wrap in `RelayEnvelope`, send to client
- [ ] Relay lifecycle — only advertise after at least one provider is connected; stop advertising if all providers disconnect
- [ ] `RelayView` SwiftUI screen — relay status, connected providers list, connected clients list, forwarded message count

**Client (iPhone client mode)**
- [ ] Relay discovery — second `MCNearbyServiceBrowser` for `janus-relay` service type
- [ ] `forceRelayMode` toggle — developer setting to ignore direct providers
- [ ] Connection routing logic — prefer direct, fall back to relay after 5s timeout (or immediately in force relay mode)
- [ ] `ConnectionMode` enum — `.disconnected`, `.direct`, `.relayed(relayName:)`
- [ ] Wrap outgoing messages in `RelayEnvelope` when in relayed mode
- [ ] Unwrap incoming `RelayEnvelope` to extract inner `MessageEnvelope`
- [ ] Connection mode badge in UI — "Direct" (green) / "via Relay" (blue)

**App structure**
- [ ] Mode selector in iPhone app — Client / Relay toggle (settings or launch screen)
- [ ] Relay mode within existing JanusClient target (not a separate Xcode target)

**Testing — relay path**
- [ ] Mac as provider, iPhone 1 as relay, iPhone 2 as client (force relay on)
- [ ] End-to-end: send prompt → receive response via relay
- [ ] Verify payment: voucher signing + on-chain settlement works through relay
- [ ] Verify relay stats: forwarded count matches request count

**Regression — direct path (MUST PASS before moving to Phase 2)**

Every scenario below was a real bug we found and fixed. All must still work.

*Basic direct connection:*
- [ ] iPhone 1 as client (force relay OFF), Mac as provider — direct connection works
- [ ] iPhone 2 as client (force relay OFF), Mac as provider — direct connection works
- [ ] Send inference request, receive response, credits deducted correctly

*Multi-client (was: connect/disconnect loop, phantom connections, per-client session isolation):*
- [ ] Both iPhones as clients simultaneously to Mac provider
- [ ] Both send inference requests — both get correct responses
- [ ] One iPhone locks screen — other iPhone's connection stays alive (per-client MCSession isolation)
- [ ] Locked iPhone returns to foreground — auto-reconnects without affecting the other

*Disconnect/reconnect (was: auto-reconnect race condition, stuck at .connecting, stale connections):*
- [ ] Client disconnects (kill app) — provider detects disconnect, triggers settlement
- [ ] Client relaunches — auto-reconnects to provider within ~2 seconds
- [ ] Client locks screen for 30s, unlocks — foreground health check detects stale state, reconnects
- [ ] Connection timeout: if provider is off, client shows "Connection Failed" after 2 attempts (not stuck at .connecting forever)

*Session persistence (was: history lost on reconnect, backwards-compat JSON decode failures):*
- [ ] Kill and relaunch client — session restores with correct credits and history
- [ ] Kill and relaunch provider — client reconnects, resumes existing session
- [ ] Provider restart mid-session — SessionSync recovers spend state

*Disconnect mid-request (was: spend state divergence, client stuck at "Getting quote"):*
- [ ] Send request, kill provider before response arrives — client shows timeout error after 20s
- [ ] Reconnect — SessionSync recovers if provider processed the request
- [ ] Client UI shows "Provider disconnected during request" if connection drops mid-flight

*Payment and settlement (was: insufficient funds, channel not on-chain, fire-and-forget Task cancelled):*
- [ ] Full payment flow: prompt → quote → voucher → response → receipt verification
- [ ] Provider settles on client disconnect — settlement TX succeeds on Tempo testnet
- [ ] Channel opens on-chain even if client app is backgrounded briefly (retryChannelOpenIfNeeded)
- [ ] Provider funds via faucet before settlement (no "insufficient funds for gas" errors)
- [ ] Receipt signature verification passes (provider pubkey check)

---

### Phase 2: Robustness (make it reliable)

Goal: Handle all the ways connections can break. Multiple providers. Provider awareness.

**Disconnect handling**
- [ ] Relay detects provider disconnect — notify connected clients with error, stop advertising that provider
- [ ] Relay detects client disconnect — clean up routing table, no further action needed
- [ ] Client detects relay disconnect — trigger existing 20s timeout, fall back to direct if available
- [ ] Mid-request relay failure — client timeout fires, SessionSync recovers state on reconnect

**Request timeout propagation**
- [ ] Relay tracks in-flight requests (requestID → timestamp)
- [ ] If provider doesn't respond within relay's own timeout, relay sends `ErrorResponse` back to client
- [ ] Prevents client from waiting full 20s when relay already knows provider is gone

**Multi-provider support**
- [ ] Relay connects to multiple providers simultaneously
- [ ] Relay advertises all reachable providers in discovery info
- [ ] Routes messages by `destinationID` to the correct provider session
- [ ] Client can pick which provider to use from the relay's list

**Provider relay awareness**
- [ ] Optional `relayedVia` field on `MessageEnvelope` — relay stamps its identity when forwarding
- [ ] Provider can log/display which clients are direct vs relayed
- [ ] Provider dashboard shows connection mode per client (direct/relayed)
- [ ] No behavioral change — provider treats all clients the same, just extra metadata

**Dual mode (relay + client on same phone)**
- [ ] Allow relay phone to also act as a client — send its own queries while relaying for others
- [ ] Share upstream provider MPC session between relay forwarding and local ClientEngine
- [ ] Relay UI shows both relay stats and a "Send Prompt" button for local queries
- [ ] Route local requests without RelayEnvelope wrapping (direct on shared session)

**Battery management**
- [ ] Show battery level in RelayView
- [ ] Auto-stop relay when battery drops below 20%
- [ ] Warning banner when battery is low while relaying

### iOS background execution limitation

The relay phone's screen must stay on while relaying. This is an iOS platform constraint, not a bug.

**Why the relay can't run in the background:**

MultipeerConnectivity (MPC) sessions are suspended when an iOS app is backgrounded or the screen is locked. iOS tears down the peer-to-peer connections within seconds of suspension. There is no background mode that keeps MPC alive:

| Background Mode | Duration | Why it doesn't work |
|---|---|---|
| `beginBackgroundTask` | ~30 seconds | Too short — relay needs indefinite runtime |
| Background fetch | ~30 seconds, iOS-scheduled | Not on-demand, too short |
| Background audio | Indefinite | Requires actual audio playback; Apple rejects apps abusing this |
| Background location | Indefinite | Requires genuine GPS use; Apple rejects if location isn't core functionality |
| CoreBluetooth BLE | Indefinite | Works for raw BLE, but MPC uses WiFi+Bluetooth combo, not raw BLE |

Apps like Google Maps keep working when locked because they use the `location` background mode with genuine GPS updates — they make stateless HTTP requests, not persistent peer-to-peer sessions. There is no equivalent background mode for "keep MPC sessions alive."

**Current solution:** `UIApplication.shared.isIdleTimerDisabled = true` while relay is active. This prevents auto-lock (same approach used by navigation apps, DJ apps, and kiosk apps). The user must not manually lock the phone while relaying. The idle timer is re-enabled when the relay stops.

**Future alternative:** Rewrite the relay networking layer using raw CoreBluetooth (BLE), which supports background execution via `bluetooth-central` and `bluetooth-peripheral` capabilities. Trade-offs: lose MPC's automatic discovery, session management, and reliable delivery (~2MB/s throughput); gain background operation at lower throughput (~100KB/s). This would be a major rewrite, considered for Phase 3+ if background relaying becomes critical.

**Relay auto-discovery updates**
- [ ] Relay re-broadcasts updated provider list when providers connect/disconnect
- [ ] Client re-evaluates relay choice if a better relay appears (closer to a preferred provider)

**Regression — direct path (MUST PASS before moving to Phase 3)**
Run the full Phase 1 regression suite above (all sections: basic, multi-client, disconnect/reconnect, session persistence, disconnect mid-request, payment and settlement).

---

### Phase 3: Multi-hop (make it a mesh)

Goal: Messages traverse more than one relay. Client → Relay A → Relay B → Provider.

**Protocol extensions**
- [ ] `hopCount` increment at each relay, drop if `>= maxHops`
- [ ] `routeTrace` field on `RelayEnvelope` — ordered list of relay IDs the message passed through
- [ ] Response routing uses reversed `routeTrace` (no route discovery needed for responses)

**Relay-to-relay forwarding**
- [ ] Relays browse for other relays (`janus-relay`) in addition to providers
- [ ] Relay routing decision: if `destinationID` not directly reachable, forward to a neighbor relay that can reach it
- [ ] Gossip protocol — relays share their reachable provider lists with neighbor relays
- [ ] Loop prevention — relay drops messages where own ID appears in `routeTrace`

**Route optimization**
- [ ] Prefer shortest path (fewest hops)
- [ ] Track latency per relay hop, prefer lower-latency routes
- [ ] Route caching — remember successful routes for repeated requests

**Regression — direct path (MUST PASS before moving to Phase 4)**
Run the full Phase 1 regression suite (all sections: basic, multi-client, disconnect/reconnect, session persistence, disconnect mid-request, payment and settlement).

---

### Phase 4: Security (make it private)

Goal: Relay cannot read message contents. End-to-end encryption between client and provider.

**Key exchange**
- [ ] ECDH key agreement using existing ETH keypairs (secp256k1)
- [ ] Client derives shared secret from provider's ETH public key (available in `ServiceAnnounce.providerEthAddress`)
- [ ] Key exchange happens during session setup, before first request

**Payload encryption**
- [ ] AES-256-GCM encryption of `MessageEnvelope` payload (prompt text, responses, vouchers)
- [ ] `RelayEnvelope.innerEnvelope` becomes opaque ciphertext — relay sees only routing headers
- [ ] Provider decrypts after unwrapping relay envelope
- [ ] Nonce management — per-message nonce derived from messageID

**Metadata protection**
- [ ] Evaluate which `RelayEnvelope` fields leak information (destinationID reveals which provider)
- [ ] Optional: encrypt destinationID with relay's key so only the relay can route (onion-style)
- [ ] Future: full onion routing where each hop only knows the next hop

**Regression — direct path (MUST PASS before moving to Phase 5)**
Run the full Phase 1 regression suite (all sections: basic, multi-client, disconnect/reconnect, session persistence, disconnect mid-request, payment and settlement).
Additionally:
- [ ] E2E encryption works on direct connections too (not just relayed) — direct clients should also encrypt payloads

---

### Phase 5: Incentives (make it sustainable)

Goal: Relays earn something for forwarding. Sustainable mesh economics.

**Relay identity**
- [ ] Relay generates/persists an ETH keypair (same as client/provider)
- [ ] Relay announces its ETH address so it can receive payments
- [ ] Relay identity persisted across app restarts

**Relay credit model (Option B: earn inference credits)**
- [ ] Provider tracks which requests were relayed and by whom
- [ ] Provider accumulates relay credits per forwarded request (e.g., 1 credit per 10 forwarded)
- [ ] Relay can redeem credits for its own inference requests to the same provider
- [ ] Credits tracked in provider's `PersistedProviderState`

**On-chain relay payment (future)**
- [ ] Client opens a micro payment channel with relay (separate from provider channel)
- [ ] Per-hop fee: small fixed cost per forwarded message
- [ ] Relay settles its channel independently
- [ ] Three-party settlement: client pays provider (inference) + relay (forwarding)

**Reputation**
- [ ] Track relay uptime, forwarding success rate, latency overhead
- [ ] Providers publish relay reputation scores (on-chain or gossip)
- [ ] Clients prefer relays with higher reputation

---

## 11. Test setup

### Hardware
- **Mac**: Provider (unchanged, runs JanusProvider)
- **iPhone 1**: Relay mode (runs JanusClient in relay mode)
- **iPhone 2**: Client mode with `forceRelayMode = true`

All three devices on the same desk. Force relay mode ensures iPhone 2 ignores the Mac's direct MPC advertisement and only connects through iPhone 1.

### Test plan

| # | Step | Expected |
|---|------|----------|
| 1 | Launch Provider on Mac | Model loads, advertising starts |
| 2 | Launch Relay on iPhone 1 | Discovers Mac provider, starts advertising as relay |
| 3 | Launch Client on iPhone 2 (force relay ON) | Discovers iPhone 1 relay, connects through it |
| 4 | Client UI shows "via Relay" badge | Confirms relayed connection mode |
| 5 | Send inference request | Request flows: iPhone 2 → iPhone 1 → Mac |
| 6 | Response arrives on client | Response flows: Mac → iPhone 1 → iPhone 2 |
| 7 | Verify relay stats | iPhone 1 shows forwarded message count |
| 8 | Verify payment works | Voucher signed by client, settled by provider — relay not involved |
| 9 | Kill relay (iPhone 1) | Client gets timeout, shows disconnect |
| 10 | Disable force relay, reconnect | Client connects directly to Mac (Mode 1 fallback) |

### Validation criteria
- Inference response text is identical whether direct or relayed
- Payment channel and settlement work the same (relay is transparent)
- Relay forwarded-message count matches request count
- Client timeout fires correctly when relay dies mid-request

---

## 12. Open questions

1. **Should the relay be a third Xcode target or a mode within JanusClient?**
   - Separate target: cleaner separation, but more build complexity
   - Mode within client: simpler, and a phone could switch between client/relay dynamically
   - Recommendation: mode within client app (toggle in settings)

2. **How does the client know the relay is honest?**
   - Phase 1: trust-based (relay is your friend's phone)
   - Phase 2: E2E encryption makes honesty irrelevant (relay can't read or modify)
   - Phase 3: relay reputation based on successful forwards / on-chain attestations

3. **What happens if the relay dies mid-request?**
   - Client sees a timeout (existing 20s timeout handles this)
   - Client can retry through a different relay or wait for direct connection
   - Provider may have already processed the request — SessionSync handles state recovery on reconnect

4. **MPC peer limits?**
   - MPC supports up to 8 peers per session
   - Relay uses separate sessions per client and per provider, so the limit is per-session
   - A single relay could support ~6 simultaneous clients and ~2 providers comfortably

5. **Battery impact on the relay phone?**
   - MPC over Bluetooth is relatively low power
   - Relay only forwards small JSON payloads (not streaming video)
   - Should display battery usage estimate in RelayView
   - Consider auto-stopping relay when battery < 20%
