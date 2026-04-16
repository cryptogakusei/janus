# Plan #14a — Interface-aware Connection Routing

## Problem

When an iPhone is connected to an offline mesh WiFi (Opal router with no WAN uplink) AND has cellular data active, iOS does not automatically fall back to cellular for internet-bound payment/blockchain calls. WiFi Assist only activates when WiFi signal is *degraded* — a healthy AP with no internet backhaul looks fine to iOS because the local network responds correctly. Payment/channel operations silently fail even with cellular available.

**Validated empirically (2026-04-16):** iPhone on offline Opal mesh + cellular active → channel open and top-up both failed. iOS never routed to cellular.

---

## Confirmed State Machine

| Operation | Transport | Interface | Cellular allowed? | Queued if unavailable? |
|---|---|---|---|---|
| Inference request | Bonjour/TCP | WiFi only (mesh) | ❌ Never | ❌ No — provider unreachable |
| Inference request | MPC | WiFi Direct / Bluetooth | ❌ Impossible by design | ❌ No — provider unreachable |
| Tab voucher signing | Local ECDSA | None (CPU only) | N/A | N/A |
| Tab voucher delivery | Same as inference | WiFi / WiFi Direct / BT | ❌ Never | ❌ No — piggybacks inference session |
| Channel open | EthRPC | WiFi-with-internet → cellular | ✅ Yes (fallback) | ✅ Yes — retry when internet returns |
| Channel top-up | EthRPC | WiFi-with-internet → cellular | ✅ Yes (fallback) | ✅ Yes — retry when internet returns |
| On-chain settlement | EthRPC | WiFi-with-internet → cellular | ✅ Yes (fallback) | ✅ Yes — retry when internet returns |
| Deferred settlement flush | EthRPC | WiFi-with-internet → cellular | ✅ Yes (fallback) | ✅ Yes — triggered by connectivity change |
| Faucet funding (`fundAddress`) | EthRPC | WiFi-with-internet → cellular | ✅ Yes (fallback) | ✅ Yes |
| `getChannel` (read-only RPC) | EthRPC | WiFi-with-internet → cellular | ✅ Yes (fallback) | ❌ No — fail with error, caller handles |
| `waitForReceipt` (polling) | EthRPC | WiFi-with-internet → cellular | ✅ Yes (fallback) | ❌ No — fail with error, retry via queue |
| `getTransactionCount` / `gasPrice` | EthRPC | WiFi-with-internet → cellular | ✅ Yes (fallback) | ❌ No — fail, upstream op retries |

**Summary rule:**
- **Anything Janus protocol** (inference, vouchers) → WiFi/BT only, cellular never touches it
- **Anything EthRPC** → internet-seeking, cellular is fallback, write ops queued if neither available, read ops fail with error

---

## Architecture

Four layers, implemented in sequence:

```
[PaymentConnectivityManager]     — detects which interface has real internet (active probe)
        │
        ▼
[TempoConfig.urlSession]         — threads the internet-aware URLSession to all EthRPC sites
        │
        ▼
[QueueingWalletProvider]         — wraps WalletProvider, queues sendTransaction when offline,
        │                          idempotent retry with persisted signed bytes
        ▼
[BonjourBrowser]                 — independent: prohibits cellular on all inference connections
```

---

## P0 Issues (must resolve before implementation)

### P0-1: NWPathMonitor cannot detect WiFi-without-WAN

`NWPathMonitor(requiredInterfaceType: .wifi)` reports `.satisfied` for any WiFi association, including an offline mesh AP. There is no `NWPath` property that distinguishes "WiFi with internet" from "WiFi with no WAN uplink."

**Without a fix:** `PaymentConnectivityManager` publishes `.wifiWithInternet` when connected to the offline mesh. The internet-aware `URLSession` is pinned to WiFi. All blockchain RPC calls hit the mesh router, get no DNS, time out. Feature is a no-op.

**Fix — active HTTP probe:**
After `NWPathMonitor` reports WiFi `.satisfied`, fire a lightweight `eth_blockNumber` JSON-RPC call to `TempoConfig.rpcURL` over a WiFi-pinned `URLSession` (3-second timeout). If it succeeds → publish `.wifiWithInternet`. If it times out or returns a network error → publish `.cellularOnly` (if cellular path `.satisfied`) or `.unavailable`. Re-probe on every path update and on a 30-second periodic timer while WiFi is connected. During the probe window, publish `.probing` — the queue holds, no operations fire.

### P0-2: Non-idempotent transaction queue

`LocalWalletProvider.sendTransaction` fetches a **fresh nonce** before every call (`rpc.getTransactionCount`). If a queued transaction is submitted and mined but the response is lost during a network flap, retrying will:
1. Fetch a new nonce (the old one is already consumed on-chain)
2. Build a new transaction with new nonce
3. Submit it → **double-execute the financial operation**

Channel top-up executing twice would double-charge the client. Channel open executing twice would fail on the second attempt with a contract error (channel already exists), which is recoverable — but top-up is not.

**Fix — persist signed bytes before first submission:**
`QueueingWalletProvider` must:
1. Sign the transaction and persist `(channelId, operationType, signedBytes, txHash)` to disk **before** first RPC submission
2. On retry: resubmit the **same** `signedBytes` (same nonce, same hash)
3. If RPC returns "nonce already used" or "known transaction": check if `txHash` was mined via `eth_getTransactionReceipt`
4. If mined → return success, remove from persistent queue
5. On confirmed success → remove from persistent queue

---

## Implementation

### Step 1: Thread URLSession through TempoConfig (S)

**File:** `Sources/JanusShared/Tempo/TempoConfig.swift`

Add one property:
```swift
public let urlSession: URLSession

public init(..., urlSession: URLSession = .shared) {
    ...
    self.urlSession = urlSession
}
```

**File:** `Sources/JanusShared/Ethereum/EthRPC.swift`

Add injectable session (default `.shared` for backward compat):
```swift
public struct EthRPC: Sendable {
    public let rpcURL: URL
    private let session: URLSession

    public init(rpcURL: URL, session: URLSession = .shared) {
        self.rpcURL = rpcURL
        self.session = session
    }
}
```

Replace `URLSession.shared.data(for: request)` with `session.data(for: request)` at EthRPC.swift:108.

**All downstream consumers** (`ChannelOpener`, `ChannelTopUp`, `ChannelSettler`, `EscrowClient`) already accept `TempoConfig` — they construct `EthRPC(rpcURL: config.rpcURL)`. Change each to `EthRPC(rpcURL: config.rpcURL, session: config.urlSession)`. No other changes to these files.

`LocalWalletProvider`: add `session: URLSession = .shared` parameter, thread to `EthRPC(rpcURL: url, session: session)`.

**Affected files:**
- `Sources/JanusShared/Tempo/TempoConfig.swift` — add `urlSession`
- `Sources/JanusShared/Ethereum/EthRPC.swift` — injectable session
- `Sources/JanusShared/Tempo/WalletProvider.swift` — thread to EthRPC
- `Sources/JanusShared/Tempo/ChannelOpener.swift:21` — pass `config.urlSession`
- `Sources/JanusShared/Tempo/ChannelTopUp.swift:16` — pass `config.urlSession`
- `Sources/JanusShared/Tempo/ChannelSettler.swift:20` — pass `config.urlSession`
- `Sources/JanusShared/Tempo/EscrowClient.swift:21` — pass `config.urlSession`

All changes backward-compatible (default `.shared`). Existing tests compile unchanged.

---

### Step 2: BonjourBrowser cellular prohibition (S, parallel with Step 1)

**File:** `JanusApp/JanusClient/BonjourBrowser.swift`

**Lines 60-62** (`startSearching` — `NWBrowser` params):
```swift
let params = NWParameters()
params.includePeerToPeer = true
params.prohibitedInterfaceTypes = [.cellular]   // ADD
```

**Lines 193-199** (`connectToEndpoint` — `NWConnection` params):
```swift
let params = NWParameters(tls: nil, tcp: tcpOptions)
params.includePeerToPeer = true
params.prohibitedInterfaceTypes = [.cellular]   // ADD
// Do NOT use requiredInterfaceType = .wifi — that blocks AWDL peer-to-peer discovery
```

**Also fix `scheduleReconnect`:** The current 2-second flat retry has no cap. Add exponential backoff with a maximum:
```swift
private var reconnectAttempts = 0
private let maxReconnectDelay: TimeInterval = 60

func scheduleReconnect() {
    let delay = min(2.0 * pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
    reconnectAttempts += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.connectToEndpoint(...)
    }
}
// Reset reconnectAttempts = 0 on successful connection
```

---

### Step 3: PaymentConnectivityManager (M)

**New file:** `JanusApp/JanusClient/PaymentConnectivityManager.swift`

```swift
@MainActor
final class PaymentConnectivityManager: ObservableObject {

    enum InternetReachability: Equatable {
        case probing        // path changed, active check in flight — queue holds
        case wifiWithInternet
        case cellularOnly
        case unavailable
    }

    @Published private(set) var internetReachability: InternetReachability = .probing

    // URLSession for payment calls — allows cellular, waits for connectivity
    var internetSession: URLSession { ... } // see below

    func enqueuePaymentOperation(label: String, _ op: @escaping @Sendable () async -> Void)
    func startMonitoring()
    func stopMonitoring()
}
```

**Single NWPathMonitor (not dual):**
Use one `NWPathMonitor()` (no interface type filter). In `pathUpdateHandler`, inspect `path.usesInterfaceType(.wifi)` and `path.usesInterfaceType(.cellular)` on the same `NWPath` object. This is atomic — no synchronization race between two monitors.

```swift
private let monitor = NWPathMonitor()

func startMonitoring() {
    monitor.pathUpdateHandler = { [weak self] path in
        Task { @MainActor [weak self] in
            self?.handlePathUpdate(path)
        }
    }
    monitor.start(queue: DispatchQueue(label: "com.janus.connectivity", qos: .utility))
}

private func handlePathUpdate(_ path: NWPath) {
    // Pattern from ProviderEngine.startNetworkMonitor()
    if path.status == .satisfied {
        internetReachability = .probing
        Task { await probe() }
    } else {
        internetReachability = .unavailable
    }
}
```

**Active probe (resolves P0-1):**
```swift
private func probe() async {
    // WiFi-pinned session — 3s timeout, no cellular
    let wifiSession = makeWifiPinnedSession(timeout: 3)
    let request = makeEthBlockNumberRequest()  // eth_blockNumber to TempoConfig.rpcURL
    do {
        _ = try await wifiSession.data(for: request)
        internetReachability = .wifiWithInternet
        flushQueueIfNeeded()
    } catch {
        // WiFi has no internet — check cellular
        let cellularPath = NWPathMonitor(requiredInterfaceType: .cellular).currentPath
        if cellularPath.status == .satisfied {
            internetReachability = .cellularOnly
            flushQueueIfNeeded()
        } else {
            internetReachability = .unavailable
        }
    }
}
```

Probe must be debounced — if a new path update arrives while a probe is in flight, cancel the old probe `Task` and start a new one.

Re-probe on 30-second timer while `internetReachability != .wifiWithInternet`.

**internetSession property:**
```swift
var internetSession: URLSession {
    switch internetReachability {
    case .wifiWithInternet:
        return wifiSession        // URLSession pinned to WiFi
    case .cellularOnly:
        return cellularSession    // URLSession with allowsCellularAccess = true,
                                  // allowsExpensiveNetworkAccess = true,
                                  // waitsForConnectivity = false,
                                  // timeoutIntervalForResource = 10s
    case .probing, .unavailable:
        return cellularSession    // best effort — will fail, QueueingWalletProvider handles
    }
}
```

Note: `multipathServiceType = .handover` requires Apple entitlement (`com.apple.developer.networking.multipath`). Check `JanusClient.entitlements` — if absent, use explicit session selection above instead.

**Operation queue:**
```swift
private var pendingOperations: [(id: UUID, label: String, op: @Sendable () async -> Void)] = []

func enqueuePaymentOperation(label: String, _ op: @escaping @Sendable () async -> Void) {
    let id = UUID()
    pendingOperations.append((id: id, label: label, op: op))
    // cap queue depth at 20
}

private func flushQueueIfNeeded() {
    guard !pendingOperations.isEmpty else { return }
    let ops = pendingOperations
    pendingOperations = []
    Task {
        for item in ops {           // serial — not concurrent
            await item.op()
        }
    }
}
```

---

### Step 4: QueueingWalletProvider (L, resolves P0-2)

**New file:** `Sources/JanusShared/Tempo/QueueingWalletProvider.swift`

```swift
public actor QueueingWalletProvider: WalletProvider {

    private struct PendingTransaction: Codable {
        let id: UUID
        let channelId: String
        let operationType: String   // "open" | "topUp" | "settle"
        let signedBytes: Data
        let txHash: String
    }

    private let inner: WalletProvider
    private let connectivityManager: PaymentConnectivityManager  // weak ref
    private var pendingTx: [String: PendingTransaction] = [:]    // keyed by channelId+opType

    // WalletProvider.signVoucher — delegates directly (local, always works)
    public func signVoucher(...) -> ... { inner.signVoucher(...) }

    // WalletProvider.sendTransaction — queues when offline, idempotent retry
    public func sendTransaction(...) async throws -> String {
        let key = channelId + ":" + operationType

        // If we have a persisted tx for this op, resubmit same signed bytes
        if let existing = pendingTx[key] {
            return try await resubmit(existing)
        }

        // Sign first, persist before submitting
        let (signedBytes, txHash) = try await inner.sign(...)
        let pending = PendingTransaction(id: UUID(), channelId: channelId,
                                         operationType: operationType,
                                         signedBytes: signedBytes, txHash: txHash)
        persist(pending, forKey: key)

        return try await submit(pending, forKey: key)
    }

    private func resubmit(_ tx: PendingTransaction) async throws -> String {
        do {
            return try await rpc.sendRawTransaction(signedTx: tx.signedBytes)
        } catch let error where isNonceTooLow(error) || isKnownTransaction(error) {
            // Already mined — verify
            if let receipt = try? await rpc.getTransactionReceipt(txHash: tx.txHash),
               receipt.status == "0x1" {
                clearPersisted(forKey: ...)
                return tx.txHash    // success
            }
            throw error
        }
    }
}
```

Persistence: write to `FileManager.default.urls(for: .applicationSupportDirectory)` — survives app termination (resolves E-04).

---

### Step 5: Wire PaymentConnectivityManager into ClientEngine (S)

**File:** `JanusApp/JanusClient/ClientEngine.swift`

```swift
let connectivityManager = PaymentConnectivityManager()

// In init:
connectivityManager.startMonitoring()

// When constructing TempoConfig for SessionManager:
let config = TempoConfig.testnet(urlSession: connectivityManager.internetSession)
```

**File:** `JanusApp/JanusClient/SessionManager.swift`

SessionManager does **not** need to know about connectivity. It constructs `LocalWalletProvider` and passes it to `ChannelOpener`. The `TempoConfig` it receives already has the internet-aware URLSession baked in. No queue logic in `SessionManager` — that belongs entirely in `QueueingWalletProvider`.

One addition: when a blockchain operation fails due to network, `SessionManager` should call `connectivityManager.enqueuePaymentOperation` to register a retry. This is the only coupling point.

---

## Files to Create / Modify

| File | Action | Size |
|---|---|---|
| `JanusApp/JanusClient/PaymentConnectivityManager.swift` | CREATE | ~120 lines |
| `Sources/JanusShared/Tempo/QueueingWalletProvider.swift` | CREATE | ~100 lines |
| `Sources/JanusShared/Tempo/TempoConfig.swift` | MODIFY | +3 lines |
| `Sources/JanusShared/Ethereum/EthRPC.swift` | MODIFY | +4 lines |
| `Sources/JanusShared/Tempo/WalletProvider.swift` | MODIFY | +2 lines |
| `Sources/JanusShared/Tempo/ChannelOpener.swift` | MODIFY | +1 line |
| `Sources/JanusShared/Tempo/ChannelTopUp.swift` | MODIFY | +1 line |
| `Sources/JanusShared/Tempo/ChannelSettler.swift` | MODIFY | +1 line |
| `Sources/JanusShared/Tempo/EscrowClient.swift` | MODIFY | +1 line |
| `JanusApp/JanusClient/BonjourBrowser.swift` | MODIFY | +4 lines |
| `JanusApp/JanusClient/ClientEngine.swift` | MODIFY | +5 lines |
| `JanusApp/JanusClient/SessionManager.swift` | MODIFY | +8 lines |
| `JanusApp/JanusClientTests/PaymentConnectivityManagerTests.swift` | CREATE | ~80 lines |

**Not modified:** `ProviderEngine.swift` (Mac has no cellular — document as known limitation), `MPCBrowser.swift` (MPC is architecturally cellular-incapable).

---

## Test Cases

### PaymentConnectivityManagerTests (new file)
| # | Test | Verifies |
|---|---|---|
| 1 | WiFi path satisfied + probe succeeds → `.wifiWithInternet` | Active probe happy path |
| 2 | WiFi path satisfied + probe times out + cellular satisfied → `.cellularOnly` | WiFi-without-WAN detection |
| 3 | WiFi path satisfied + probe times out + no cellular → `.unavailable` | Full offline detection |
| 4 | Path changes → state transitions to `.probing` before probe completes | Probing state published |
| 5 | Queue flushes serially on internet restore | Queue order preserved |
| 6 | Queue does not double-execute on second internet restore | No double-flush |
| 7 | Queue holds while `.probing` | No premature execution |
| 8 | `internetSession` is not `URLSession.shared` | Custom session returned |

### QueueingWalletProviderTests (new file)
| # | Test | Verifies |
|---|---|---|
| 9 | First submission — signs, persists, submits | Persist-before-submit |
| 10 | Retry — resubmits same signed bytes, not new tx | Idempotency |
| 11 | "Nonce too low" + receipt found → success | Double-submit handling |
| 12 | Duplicate enqueue same op → no-op | Dedup by channelId+opType |
| 13 | App restart with persisted pending tx → resubmits | Persistence survives termination |

### BonjourTransportTests (additions)
| # | Test | Verifies |
|---|---|---|
| 14 | NWBrowser params prohibit cellular | `.cellular` in prohibitedInterfaceTypes |
| 15 | NWConnection params prohibit cellular | Same |
| 16 | `requiredInterfaceType` is NOT set | AWDL peer-to-peer not blocked |

### ClientEngineTests (additions)
| # | Test | Verifies |
|---|---|---|
| 17 | Channel open when `.unavailable` → enqueued | Queue engagement |
| 18 | Queue flushes when `.cellularOnly` | Cellular fallback fires |
| 19 | Top-up when `.unavailable` → single enqueue (no duplicate) | E-05 guard |

---

## Edge Cases

| # | Case | Handling |
|---|---|---|
| E-01 | Captive portal (WiFi satisfied, DNS works, RPC unreachable) | Active probe catches this — probe times out → `.cellularOnly` |
| E-02 | Connectivity change during live RPC call | `URLSession` task fails with network error; `QueueingWalletProvider` re-enqueues |
| E-03 | Initial state before first path update | Default `.probing` — queue holds until first probe resolves (~100ms) |
| E-04 | App terminated with queued ops | `QueueingWalletProvider` persists to disk; restored on next launch |
| E-05 | Multiple top-up taps while offline | Dedup by (channelId, "topUp") — second tap is no-op |
| E-06 | Rapid path update toggling | Probe debounced — in-flight probe cancelled on new path update |
| E-07 | `multipathServiceType = .handover` entitlement absent | Fallback to explicit session selection — no crash, correct behavior |
| E-08 | Airplane mode | Both paths `.unsatisfied` → `.unavailable` → queue holds |
| E-09 | Cellular disabled by user | Cellular path `.unsatisfied` → `.unavailable` if WiFi also has no internet |
| E-10 | Client roams between mesh APs | Path update fires, probe re-runs, `BonjourBrowser.scheduleReconnect` handles TC reconnect |
| E-11 | VPN active | Probe catches VPN-tunneled-over-offline-WiFi case — probe fails → cellular fallback |
| E-12 | WiFi drops mid-request | `URLSession` task fails; upstream op handled by `QueueingWalletProvider` retry |

---

## Known Limitations

- **Provider-side (Mac):** `ProviderEngine` also calls `EthRPC` for settlement. Macs have no cellular. The TempoConfig URLSession threading (Step 1) ensures the provider uses `URLSession.shared` by default — no regression. If a provider is on an offline mesh with no ethernet internet, settlement will fail and retry when internet returns via the existing `NWPathMonitor` in `ProviderEngine`. No cellular fallback on Mac — accepted limitation for #14a.

- **Queue TTL:** Queued operations do not expire in this version. A top-up queued while offline will execute when internet returns, even hours later. This is intentional — the user explicitly requested the top-up.
