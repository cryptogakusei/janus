# Feature #8: Bonjour+TCP Transport

**Status:** Planned
**Dependencies:** None (parallel to existing MPC transport)

## Context

All device-to-device communication uses Multipeer Connectivity (MPC) over AWDL, which is unreliable: visibility flickers cause spurious disconnects, concurrent sessions can't be multiplexed, and connection handshakes are slow. Feature #5 (direct multi-provider) was reverted because AWDL couldn't support it.

Feature #8 adds Bonjour+TCP as a parallel transport using Network.framework (`NWBrowser`, `NWListener`, `NWConnection`). Devices on the same LAN discover each other via mDNS and communicate over plain TCP — fast, reliable, and natively supports multiple concurrent connections. MPC stays as fallback for zero-infrastructure scenarios.

```
Current (MPC/AWDL):
  iPhone ~~~AWDL radio~~~ Mac
  (ad-hoc direct link, no router needed, but unreliable)

New (Bonjour+TCP):
  iPhone ---WiFi--→ Router ←--WiFi--- Mac
  (standard TCP over local network, reliable, needs router)
```

---

## Design Decisions

1. **Distinct service type `_janus-tcp._tcp`** — MPC internally registers `_janus-ai._tcp` as its Bonjour service. Using the same type for Network.framework would cause cross-discovery: `NWBrowser` would find MPC advertisers and vice versa, producing connection failures. The TCP transport uses `_janus-tcp._tcp` to avoid collision. Both Info.plist files need this added to `NSBonjourServices`.
2. **Reuse `.direct` ConnectionMode** — Bonjour+TCP direct is semantically identical to MPC direct from the user's perspective. No new enum case.
3. **Multi-provider from day one** — `NWBrowser` naturally discovers all services; maintain multiple `NWConnection` instances. This gives us Feature #5 (direct multi-provider) for free over TCP.
4. **Both transports stay running** — `CompositeTransport` starts both `BonjourBrowser` and `MPCBrowser` in parallel and keeps both active. Bonjour is preferred for sending (connects faster: ~100-200ms vs AWDL's ~2-5s). MPC stays warm as instant fallback — no cold-restart delay if Bonjour disconnects. Slightly more radio/battery usage, but much better reconnect UX.
5. **Provider-side protocol** — Introduce `ProviderAdvertiserTransport` to abstract `MPCAdvertiser` vs `BonjourAdvertiser`, keeping `ProviderStatusView` transport-agnostic.
6. **Length-prefix TCP framing** — 4-byte big-endian UInt32 length header + JSON payload, with 16MB max message size to prevent OOM from malformed headers. Shared utility in `JanusShared`.
7. **TCP keepalive** — Configure `NWProtocolTCP.Options` with `keepaliveIdle=10, keepaliveInterval=5, keepaliveCount=3` so silently dropped connections (laptop lid close) are detected within ~25 seconds. Supplements the existing `.ping`/`.pong` application-level heartbeat.

---

## Design: Parallel Transports with Auto-Selection

### Key Insight

The `ProviderTransport` protocol (created in Feature #2) already abstracts the transport layer. `ClientEngine` doesn't care whether it talks to `MPCBrowser`, `RelayLocalTransport`, or a new `BonjourBrowser` — it just calls `startSearching()`, `send()`, and observes `connectionState`. A new `CompositeTransport` wraps both `BonjourBrowser` and `MPCBrowser`, racing them and using whichever connects first.

On the provider side, a new `ProviderAdvertiserTransport` protocol mirrors this pattern, letting `ProviderStatusView` wire up a `CompositeAdvertiser` that runs both `MPCAdvertiser` and `BonjourAdvertiser` simultaneously.

### Architecture

```
CLIENT SIDE                              PROVIDER SIDE

CompositeTransport                       CompositeAdvertiser
  ├── BonjourBrowser ──TCP──→              ├── BonjourAdvertiser (NWListener)
  │     _janus-tcp._tcp                    │     _janus-tcp._tcp
  │     [preferred, faster]                │     (accepts TCP connections)
  │                                        │
  └── MPCBrowser ──AWDL──→                 └── MPCAdvertiser (MCAdvertiser)
        _janus-ai._tcp                           _janus-ai._tcp
        [stays warm as fallback]                 (accepts MPC invitations)

Both transports run simultaneously on both sides.
Bonjour preferred for sending; MPC stays warm as instant fallback.
Reply routing: CompositeAdvertiser tracks which transport each senderID used.
```

---

## Changes

### Step 1: TCP Framing Utility

**Create:** `Sources/JanusShared/Protocol/TCPFraming.swift`

Shared between client and provider targets. TCP delivers a byte stream, not discrete messages — this utility adds message boundaries.

- `TCPFramer.frame(_ data: Data) -> Data` — prepends 4-byte big-endian UInt32 length header
- `TCPFramer.Deframer` class — accumulates incoming TCP data chunks, emits complete frames via callback. Handles partial reads (one `receive()` may deliver half a frame or two concatenated frames).
- `maxFrameSize = 16 * 1024 * 1024` (16MB) — rejects frames with length headers above this to prevent OOM from malformed/malicious data.

```swift
enum TCPFramer {
    static let maxFrameSize = 16 * 1024 * 1024  // 16MB

    static func frame(_ data: Data) -> Data { ... }

    class Deframer {
        var onFrame: ((Data) -> Void)?
        var onError: ((Error) -> Void)?  // oversized frame, etc.
        func append(_ data: Data) { ... }  // buffer + yield complete frames
    }
}
```

### Step 2: Provider-Side Transport Protocol

**Create:** `JanusApp/JanusProvider/ProviderAdvertiserTransport.swift`

```swift
@MainActor
protocol ProviderAdvertiserTransport: AnyObject {
    var isAdvertising: Bool { get }
    var connectedClients: [String: String] { get }  // clientID → display name
    var onMessageReceived: ((MessageEnvelope, String) -> Void)? { get set }
    var onClientDisconnected: ((String) -> Void)? { get set }
    func startAdvertising()
    func stopAdvertising()
    func send(_ envelope: MessageEnvelope, to senderID: String) throws
    func updateServiceAnnounce(providerPubkey: String, providerEthAddress: String?)
}
```

Mirrors the public API of `MPCAdvertiser` that `ProviderStatusView` and `ProviderEngine` actually use.

### Step 3: Conform MPCAdvertiser to Protocol

**Modify:** `JanusApp/JanusProvider/MPCAdvertiser.swift`

- Add `: ProviderAdvertiserTransport` conformance
- Change `onMessageReceived` callback from `((MessageEnvelope, MCPeerID) -> Void)?` to `((MessageEnvelope, String) -> Void)?` — the `String` is `senderID`. `ProviderStatusView` already ignores the `MCPeerID` parameter.
- Rename existing `connectedClients: [MCPeerID: String]` to `connectedPeers: [MCPeerID: String]` (internal to MPC). Implement protocol's `connectedClients: [String: String]` as a computed property that maps through `senderToPeer`. Update `ProviderStatusView` references from `advertiser.connectedClients` to use the protocol property.

### Step 4: BonjourAdvertiser (Provider-Side)

**Create:** `JanusApp/JanusProvider/BonjourAdvertiser.swift`

`@MainActor class BonjourAdvertiser: ObservableObject, ProviderAdvertiserTransport`

- `NWListener` on dynamic TCP port, Bonjour service type `_janus-tcp._tcp`
- TCP options: `keepaliveIdle=10, keepaliveInterval=5, keepaliveCount=3` via `NWProtocolTCP.Options`
- Per-client state: `clientConnections: [String: NWConnection]`, `clientDeframers: [String: TCPFramer.Deframer]`
- Client identity bootstrapping: on new connection, assign a temporary UUID as `clientID`. Send `ServiceAnnounce` immediately on the raw connection (no senderID routing needed). When the first `MessageEnvelope` arrives, extract `senderID` and build `senderToConnection: [String: NWConnection]` mapping — mirrors `MPCAdvertiser.senderToPeer` pattern.
- Receive loop: `connection.receive()` → `deframer.append()` → `MessageEnvelope.deserialize()` → register senderID mapping → `onMessageReceived`
- `send(_:to:)`: look up `NWConnection` by senderID, frame with `TCPFramer.frame()`, `connection.send()`
- On `.failed`/`.cancelled`: clean up, invoke `onClientDisconnected`
- All `@Published` updates dispatched to `MainActor`

Key pattern — NWConnection uses a pull-based receive model (must re-call `receive` after each completion):
```swift
private func receiveLoop(connection: NWConnection, clientID: String) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
        Task { @MainActor in
            if let data { self?.deframers[clientID]?.append(data) }
            if error == nil { self?.receiveLoop(connection: connection, clientID: clientID) }
        }
    }
}
```

### Step 5: BonjourBrowser (Client-Side)

**Create:** `JanusApp/JanusClient/BonjourBrowser.swift`

`@MainActor class BonjourBrowser: ObservableObject, ProviderTransport`

- `NWBrowser` for `_janus-tcp._tcp`
- TCP options: same keepalive settings as BonjourAdvertiser
- On `browseResultsChangedHandler`: track discovered endpoints, connect to each via `NWConnection`. When a browse result is removed, check if the `NWConnection` is still `.ready` — if so, keep it (TCP survives browse changes). Only remove from `directProviders` when the `NWConnection` itself transitions to `.failed`.
- Per-provider state: `providerConnections: [String: NWConnection]`, `providerDeframers: [String: TCPFramer.Deframer]`
- First message from each connection is `ServiceAnnounce` — populates `directProviders: [String: ServiceAnnounce]` dict
- `connectedProvider` points to the currently selected provider
- `@Published var directProviders: [String: ServiceAnnounce]` for multi-provider support
- `send(_:)` routes to active provider's `NWConnection`
- `selectProvider(_ providerID:)` switches active connection (instant, no disconnect — just changes which `NWConnection` `send()` targets)
- `checkConnectionHealth()` checks `NWConnection.state` — TCP has explicit state, unlike MPC
- Auto-reconnect on `.failed` with backoff

### Step 6: CompositeTransport (Client-Side Auto-Selection)

**Create:** `JanusApp/JanusClient/CompositeTransport.swift`

`@MainActor class CompositeTransport: ObservableObject, ProviderTransport`

- Owns `BonjourBrowser` + `MPCBrowser`
- `startSearching()` starts both in parallel — **both stay running** (no stopping the loser)
- Subscribes to both `connectionStatePublisher`. Bonjour is preferred: when Bonjour connects, `send()` routes through it. If only MPC connects, `send()` routes through MPC. If Bonjour disconnects, MPC is already warm as instant fallback — no cold-restart delay.
- Forwards the active (preferred) transport's published properties via Combine
- Exposes `mpcBrowser: MPCBrowser` for relay-specific features (`relayProviders`, `forceRelayMode`)
- Exposes `bonjourBrowser: BonjourBrowser` for direct multi-provider features (`directProviders`)

### Step 7: CompositeAdvertiser (Provider-Side)

**Create:** `JanusApp/JanusProvider/CompositeAdvertiser.swift`

`@MainActor class CompositeAdvertiser: ObservableObject, ProviderAdvertiserTransport`

- Owns `MPCAdvertiser` + `BonjourAdvertiser`
- Tracks `senderTransport: [String: ProviderAdvertiserTransport]` — which transport each client connected through
- `send(_:to:)` routes to correct child transport based on sender's transport
- `startAdvertising()` / `stopAdvertising()` starts/stops both
- Merges `connectedClients` from both children with dedup (if a client connects via both transports simultaneously, prefer the Bonjour connection)
- `onClientDisconnected` only fires when the client is disconnected from ALL transports, not just one

### Step 8: Wire Up Provider Side

**Modify:** `JanusApp/JanusProvider/ProviderStatusView.swift`

- Replace `MPCAdvertiser` with `CompositeAdvertiser`
- Same callback wiring pattern (now protocol-based)
- Both MPC and Bonjour advertise simultaneously — clients connect via whichever transport they prefer

### Step 9: Wire Up Client Side

**Modify:** `JanusApp/JanusClient/ClientEngine.swift`

- Default `init()` changes from `MPCBrowser()` to `CompositeTransport()`
- `browserRef` becomes `compositeRef: CompositeTransport?` — accesses `mpcBrowser` for relay features and `bonjourBrowser` for direct multi-provider
- `availableProviders` subscription merges relay providers (MPC path) + direct providers (Bonjour path) via `combineLatest`
- `selectProvider()` routes to Bonjour `selectProvider()` when in Bonjour direct mode, or relay `selectRelayProvider()` when in relay mode

**Modify:** `JanusApp/JanusClient/DiscoveryView.swift`

- `engine.browserRef` references → `engine.compositeRef?.mpcBrowser` for force relay toggle
- No other UI changes — provider picker already works off `availableProviders`

**Note:** `JanusClientApp.swift` dual mode path unchanged — uses `RelayLocalTransport`, not the composite.

### Step 10: Tests

**Create:** `JanusApp/JanusClientTests/TCPFramingTests.swift`
- Single frame, partial frame, concatenated frames, empty payload, large payload

**Create:** `JanusApp/JanusClientTests/BonjourTransportTests.swift`
- Loopback test: `NWListener` + `BonjourBrowser` in same process, verify discovery → connection → framed message exchange → disconnect

Existing `MultiProviderTests` continue passing (they test `MPCBrowser` directly).

---

## Files changed

| File | Change |
|------|--------|
| `Sources/JanusShared/Protocol/TCPFraming.swift` | New — length-prefix framing for TCP streams |
| `JanusProvider/ProviderAdvertiserTransport.swift` | New — provider-side transport protocol |
| `JanusProvider/MPCAdvertiser.swift` | Conform to `ProviderAdvertiserTransport`, change callback signature |
| `JanusProvider/BonjourAdvertiser.swift` | New — `NWListener` + Bonjour advertising + per-client TCP connections |
| `JanusProvider/CompositeAdvertiser.swift` | New — wraps MPC + Bonjour advertisers, routes replies |
| `JanusProvider/ProviderStatusView.swift` | Use `CompositeAdvertiser` instead of `MPCAdvertiser` |
| `JanusClient/BonjourBrowser.swift` | New — `NWBrowser` + `NWConnection` per provider, multi-provider support |
| `JanusClient/CompositeTransport.swift` | New — races Bonjour + MPC, auto-selects winner |
| `JanusClient/ClientEngine.swift` | Use `CompositeTransport`, merge available providers from both transports |
| `JanusClient/DiscoveryView.swift` | Update `browserRef` → `compositeRef` for force relay toggle |
| `JanusClient/Info.plist` | Add `_janus-tcp._tcp` to `NSBonjourServices` |
| `JanusProvider/Info.plist` | Add `_janus-tcp._tcp` to `NSBonjourServices` |
| `JanusClientTests/TCPFramingTests.swift` | New — framing unit tests |
| `JanusClientTests/BonjourTransportTests.swift` | New — loopback integration test |

## What does NOT change

- `ProviderTransport.swift` — protocol is sufficient as-is
- `MPCBrowser.swift` — continues working unchanged for MPC/relay path
- `MPCRelay.swift` / `RelayLocalTransport` — dual mode unchanged
- `SessionManager.swift` — per-provider persistence works regardless of transport
- `ProviderEngine.swift` — works with `senderID` strings, transport-agnostic
- All protocol messages (`MessageEnvelope`, `ServiceAnnounce`, etc.)
- Payment flows (Tempo channels, vouchers, receipts)
- Info.plist — `_janus-ai._tcp` already declared (MPC). Need to add `_janus-tcp._tcp` to both apps' `NSBonjourServices` arrays.

---

## Verification

1. `xcodebuild test` — all existing + new tests pass
2. Manual test — single Mac provider, iPhone direct via Bonjour+TCP (should connect faster than MPC)
3. Manual test — two Mac providers, iPhone discovers both via Bonjour, picker appears, switch between them
4. Manual test — MPC fallback: disable WiFi on iPhone, verify it falls back to MPC/AWDL
5. Manual test — relay mode still works (MPC path, regression)
6. Manual test — dual mode still works (RelayLocalTransport, regression)
