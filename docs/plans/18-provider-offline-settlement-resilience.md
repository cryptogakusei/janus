# Fix #18: Provider Offline Settlement Resilience

## Summary

When internet is lost, the provider sometimes stops being discoverable (disappears from client
discovery UI). Root cause: the disconnect-triggered settlement path fires RPC calls without
checking network status, blocking `@MainActor` for up to 2+ minutes, which starves the Bonjour
NWListener and kills advertising.

Discovered during offline mesh test (2026-04-18): two providers, two clients on single Archer A7
batman-adv mesh. Internet unplugged → one provider disappeared, one survived. Same binary,
non-deterministic outcome.

Reviewed by systems-architect and architecture-reviewer agents. **Awaiting implementation approval.**

---

## Root Cause

`settleAllChannelsOnChain(isRetry: false)` is called from `settleAllSessions()` (triggered on
client disconnect) **with no network status guard**. The periodic and threshold settlement paths
both check `lastPathStatus == .satisfied` before attempting RPC calls. The disconnect path is the
only one missing this guard.

**Why it blocks Bonjour:**
- `ProviderEngine` is `@MainActor` — only one thing runs at a time
- When offline, URLSession hangs for 15 seconds per RPC call (default TCP timeout)
- Multiple RPC calls per channel: `fundAddress` + `gasPrice` + `getTransactionCount` = up to 45s
- Plus a hardcoded `Task.sleep(nanoseconds: 20_000_000_000)` (20s) for channel-not-yet-on-chain retry
- `NWListener` (Bonjour) runs on `queue: .main` — starves during the MainActor freeze
- After ~25s starvation, TCP keepalives expire, mDNS deregisters the service

**Why non-deterministic:**
- If DNS resolves fast (negative cache for `rpc.moderato.tempo.xyz`), RPC calls fail in
  milliseconds → MainActor unblocks quickly → Bonjour survives
- If TCP connection hangs on a dead route, full 15s timeout per call → Bonjour dies

**Existing guards in the periodic and threshold paths (for reference):**
- Periodic settlement: `ProviderEngine.swift:367` — `guard self.lastPathStatus == .satisfied`
- Threshold settlement: `ProviderEngine.swift:863` — `guard lastPathStatus == .satisfied`
- Disconnect path: `ProviderEngine.swift:293–295` — **NO GUARD (the bug)**

---

## Three PRs

### PR 1 — P0: Add missing network guard (3-line fix, ships alone)

**File:** `JanusApp/JanusProvider/ProviderEngine.swift`

**Where:** At line 400 (blank line between the `defer` block closing brace and `guard let ethKP`).

**Before (lines 391–401):**
```swift
        isSettling = true
        defer {
            isSettling = false
            if let queued = pendingSettlementRequest {
                pendingSettlementRequest = nil
                Task { await settleAllChannelsOnChain(isRetry: queued.isRetry, removeAfterSettlement: queued.removeAfterSettlement) }
            }
        }

        guard let ethKP = providerEthKeyPair, let rpcURL = tempoConfig.rpcURL else { return }
```

**After:**
```swift
        isSettling = true
        defer {
            isSettling = false
            if let queued = pendingSettlementRequest {
                pendingSettlementRequest = nil
                Task { await settleAllChannelsOnChain(isRetry: queued.isRetry, removeAfterSettlement: queued.removeAfterSettlement) }
            }
        }

        // Guard: don't attempt RPC calls when network is unavailable.
        // Unsettled channels are persisted — NWPathMonitor triggers retryPendingSettlements()
        // when connectivity returns. Matches the guards already at lines 367 and 863.
        guard lastPathStatus == .satisfied else {
            print("Settlement deferred: network unavailable — will retry on reconnect")
            persistState()
            return
        }

        guard let ethKP = providerEthKeyPair, let rpcURL = tempoConfig.rpcURL else { return }
```

**Why `persistState()` in the guard branch:** If a client disconnects while offline, the channel
state from `handleTabSettlementVoucher` may not have been flushed to disk yet. This ensures
unsettled credits survive an app restart.

**Notes from review:**
- When the guard triggers, `isSettling = true` has already been set, so the `defer` block fires
  on `return`, resets `isSettling = false`, and drains any queued settlement — which hits the
  same guard again. Safe no-op loop (not infinite: `pendingSettlementRequest` is nil-ed before
  re-dispatch).
- `persistState()` has no side effects here; it is already called from multiple paths.

**Testing:**
1. Start provider, connect a client, run enough inference to cross the settlement threshold
2. Unplug WAN from Archer A7 (internet gone, WiFi stays up)
3. Disconnect the client app
4. Verify provider stays visible in discovery on both iPhones
5. Verify console: `"Settlement deferred: network unavailable — will retry on reconnect"`
6. Replug WAN cable
7. Verify console: `"Network restored — retrying pending settlements..."`
8. Verify settlement completes and appears in the activity log

---

### PR 2 — P1: Bonjour off main queue + active RPC probe

Two sub-fixes shipped together — both address the same structural resilience gap.

#### 2A: Move NWListener off `queue: .main`

**File:** `JanusApp/JanusProvider/BonjourAdvertiser.swift`

Even with PR 1, any future long `@MainActor` operation could starve Bonjour. Moving the listener
to a dedicated queue makes advertising structurally independent of `@MainActor` scheduling.

**Add property after line 31 (after `private var retryCount = 0`):**
```swift
    /// Dedicated queue for NWListener and NWConnection events.
    /// Decouples Bonjour health from @MainActor scheduling.
    private let networkQueue = DispatchQueue(label: "com.janus.bonjour.network", qos: .userInitiated)
```

**Change line 112:**
```swift
// Before:
listener.start(queue: .main)
// After:
listener.start(queue: networkQueue)
```

**Change line 212:**
```swift
// Before:
connection.start(queue: .main)
// After:
connection.start(queue: networkQueue)
```

All state-update handlers in `BonjourAdvertiser` already use `Task { @MainActor in ... }` (verified
at lines 73, 106, 182, 188, 195, 219) — no other changes needed for correctness.

**Note:** `NWConnection.send` completion blocks (lines 143, 273) will now fire on `networkQueue`
instead of `.main`. Current blocks only call `print()` so this is safe. Add a comment near
`send(_:to:)` warning future authors that send completions run on `networkQueue`, not `@MainActor`.

#### 2B: Active RPC probe for WiFi-with-no-WAN

**File:** `JanusApp/JanusProvider/ProviderEngine.swift`

**The problem:** On the mesh network, `NWPathMonitor` reports `.satisfied` when connected to the
Archer A7's WiFi AP — even when the A7's WAN cable is unplugged. The PR 1 `lastPathStatus`
guard passes, and the provider still attempts 15-second-timeout RPC calls.

**Add property after line 166:**
```swift
    /// Result of the most recent RPC connectivity probe.
    /// Initialized to false — an initial probe runs in startNetworkMonitor() before
    /// any settlement is attempted. Guards against WiFi-satisfied-but-no-WAN.
    private var lastRPCProbeSucceeded: Bool = false
```

**Add method after `startNetworkMonitor()`, before `deinit` (line 342):**
```swift
    /// Fires a lightweight eth_gasPrice call to verify actual WAN connectivity.
    /// Uses a two-Task timeout pattern to avoid conflating real Task cancellation
    /// with a probe timeout.
    private func probeRPCConnectivity() async -> Bool {
        guard let rpcURL = tempoConfig.rpcURL else { return false }
        let rpc = EthRPC(rpcURL: rpcURL, transport: tempoConfig.transport)
        let probeTask = Task { _ = try await rpc.gasPrice() }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            probeTask.cancel()
        }
        do {
            try await probeTask.value
            timeoutTask.cancel()
            return true
        } catch {
            timeoutTask.cancel()
            return false
        }
    }
```

**Why two Tasks instead of a TaskGroup:** The previous draft used `throw CancellationError()` as a
control flow signal inside a TaskGroup, which conflates a deliberate timeout with a real Task
cancellation (e.g. if the enclosing Task is cancelled, the probe would spuriously return false).
The two-Task pattern cancels cleanly: if the probe succeeds, the timeout is cancelled; if the
timeout fires, the probe is cancelled. Either way the function returns the correct result.

**Update `startNetworkMonitor()` (lines 324–340):**

Add an initial probe call on first start, and probe before retrying on network restore:

```swift
    func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasUnsatisfied = self.lastPathStatus != .satisfied
                self.lastPathStatus = path.status
                if wasUnsatisfied && path.status == .satisfied {
                    let rpcOK = await self.probeRPCConnectivity()
                    self.lastRPCProbeSucceeded = rpcOK
                    if rpcOK {
                        print("Network restored (RPC verified) — retrying pending settlements...")
                        await self.retryPendingSettlements()
                    } else {
                        print("Network path satisfied but RPC probe failed — settlement deferred")
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        self.networkMonitor = monitor

        // Run initial probe to catch WiFi-with-no-WAN on cold start.
        // Without this, lastRPCProbeSucceeded stays false and blocks settlement
        // until the first NWPathMonitor unsatisfied→satisfied transition.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastRPCProbeSucceeded = await self.probeRPCConnectivity()
        }
    }
```

**Update the PR 1 guard in `settleAllChannelsOnChain` to also check the probe:**

```swift
        guard lastPathStatus == .satisfied else {
            print("Settlement deferred: network unavailable — will retry on reconnect")
            persistState()
            return
        }
        // Secondary check: NWPathMonitor says satisfied but WiFi may have no WAN uplink
        // (mesh AP with no internet). Also guards the periodic timer (isRetry: true) via
        // the probe that fires before retryPendingSettlements() in startNetworkMonitor.
        guard lastRPCProbeSucceeded else {
            print("Settlement deferred: RPC probe failed (no WAN uplink) — will retry on reconnect")
            persistState()
            return
        }
```

**Why remove the `!isRetry` condition (changed from draft):**
The earlier draft used `if !isRetry && !lastRPCProbeSucceeded` to skip the check on retry paths,
assuming retry is always triggered after a successful probe. But the periodic settlement timer
(line 372) calls `settleAllChannelsOnChain(isRetry: true)` and only checks `lastPathStatus` — not
the probe. Removing `!isRetry` makes the guard apply uniformly to all paths. The only cost:
retry paths do a cached boolean check rather than assuming success. The boolean is updated by the
probe, which runs after every `unsatisfied → satisfied` transition.

**Testing (additional for PR 2):**
1. Connect Mac to Archer A7 WiFi with WAN cable **unplugged** from A7
2. Start provider — `NWPathMonitor` reports `.satisfied`
3. Verify console shows initial probe result (pass/fail)
4. Disconnect a client
5. Verify console: `"Settlement deferred: RPC probe failed (no WAN uplink)"`
6. Verify Bonjour advertising continues on both iPhones
7. Plug WAN back into A7
8. Verify probe fires, settlement retries, completes

---

### PR 3 — P2: Hardening

#### 3A: Move 20-second retry sleep off `@MainActor`

**File:** `JanusApp/JanusProvider/ProviderEngine.swift`
**Lines:** 466–511 (comment at 466, `if` statement at 468)

The 20-second `Task.sleep` at line 470 occupies a MainActor suspension slot, delaying any other
`@MainActor` work (UI updates, new request handling) for the full 20 seconds. Spawn the retry
block as a separate `Task` so the MainActor is free during the wait.

Read lines 468–511 carefully before implementing — the `// ... same switch/case body` shorthand
below must be replaced with the full switch statement from those lines, updated to use
`self.` prefixes and the captured values.

**Before (lines 466–511):**
```swift
        // Retry pending channels after waiting for on-chain opening (disconnect path only)
        // Client needs ~15s total: 3s faucet wait + approve tx + open tx
        if !pendingChannels.isEmpty {
            print("Waiting 20s for \(pendingChannels.count) channel(s) to appear on-chain...")
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            for (sessionID, channel) in pendingChannels {
                let result = await settler.settle(providerKeyPair: ethKP, channel: channel)
                switch result {
                    // ... full 40-line switch statement (lines 473–509) ...
                }
            }
        }
```

**After:**
```swift
        // Retry pending channels after waiting for on-chain opening.
        // Spawned as a separate Task so @MainActor is free during the 20s wait.
        if !pendingChannels.isEmpty {
            let capturedChannels = pendingChannels
            let capturedEthKP = ethKP
            let capturedConfig = tempoConfig      // capture by value, not self.tempoConfig
            let capturedRemove = removeAfterSettlement
            Task { @MainActor [weak self] in
                print("Waiting 20s for \(capturedChannels.count) channel(s) to appear on-chain...")
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.lastPathStatus == .satisfied else {
                    print("Pending channel retry deferred: network unavailable")
                    return
                }
                guard let settler = ChannelSettler(config: capturedConfig) else { return }
                for (sessionID, channel) in capturedChannels {
                    let result = await settler.settle(providerKeyPair: capturedEthKP, channel: channel)
                    switch result {
                        // FULL switch/case body from lines 473–509, with:
                        // - self.channels[sessionID] instead of channels[sessionID]
                        // - self.removeChannelIfMatch(...) instead of removeChannelIfMatch(...)
                        // - self.appendLog(...) instead of appendLog(...)
                        // - capturedRemove instead of removeAfterSettlement
                    }
                }
            }
        }
```

**`isSettling` semantics:** `isSettling` is set to `false` via `defer` before this Task fires.
A concurrent settlement could start during the 20s window. Safe — `ChannelSettler.settle()` is
idempotent (`.alreadySettled` if another settlement already succeeded).

#### 3B: Replace `fatalError` in `ChannelSettler.init` with failable init

**File:** `Sources/JanusShared/Tempo/ChannelSettler.swift` lines 16–20

**Before:**
```swift
    public init(config: TempoConfig) {
        guard let url = config.rpcURL else {
            fatalError("ChannelSettler requires a TempoConfig with rpcURL")
        }
        self.rpc = EthRPC(rpcURL: url, transport: config.transport)
        self.config = config
    }
```

**After:**
```swift
    /// Returns nil if config has no rpcURL (off-chain-only mode — skips settlement gracefully).
    public init?(config: TempoConfig) {
        guard let url = config.rpcURL else { return nil }
        self.rpc = EthRPC(rpcURL: url, transport: config.transport)
        self.config = config
    }
```

**Call site in `ProviderEngine.swift` (line 403 and ~410):**
```swift
// Before:
        let rpc = EthRPC(rpcURL: rpcURL)
        // ...
        let settler = ChannelSettler(config: tempoConfig)

// After:
        let rpc = EthRPC(rpcURL: rpcURL, transport: tempoConfig.transport)   // also fixes transport inconsistency
        // ...
        guard let settler = ChannelSettler(config: tempoConfig) else { return }
```

**Test file:** Any `ChannelSettler(config:)` call in `OnChainTests.swift` becomes
`ChannelSettler(config:)!` (force-unwrap is appropriate — tests use a known-good config).

#### 3C: Note — `fundProviderIfNeeded()` missing transport (P3, tracked only)

`ProviderEngine.swift:282` creates `EthRPC(rpcURL: rpcURL)` without `transport`. Same
inconsistency as line 403 above. Fix in same PR as 3B for consistency. Not a correctness issue
on macOS (default `URLSessionTransport` is used), but latent risk if transport is ever customised.

---

## Files Changed

| File | PR | Change |
|------|----|--------|
| `JanusApp/JanusProvider/ProviderEngine.swift` | 1 | Add `lastPathStatus` guard in `settleAllChannelsOnChain` |
| `JanusApp/JanusProvider/BonjourAdvertiser.swift` | 2 | Add `networkQueue`; move listener + connections off `.main`; comment on send completions |
| `JanusApp/JanusProvider/ProviderEngine.swift` | 2 | Add `lastRPCProbeSucceeded` (default `false`), `probeRPCConnectivity()`, initial probe in `startNetworkMonitor`, update guard |
| `JanusApp/JanusProvider/ProviderEngine.swift` | 3 | Spawn 20s retry block as separate Task; fix `EthRPC` transport at line 403 |
| `Sources/JanusShared/Tempo/ChannelSettler.swift` | 3 | `init` → `init?` |
| `JanusApp/JanusProvider/ProviderEngine.swift` | 3 | `guard let settler = ChannelSettler(...)`; fix `EthRPC` transport at line 282 |
| `Tests/JanusSharedTests/OnChainTests.swift` | 3 | Force-unwrap `ChannelSettler` init in tests |

## Dependency Order

```
PR 1 (P0) ── ships alone, no dependencies
    │
    ├── PR 2 (P1) ── adds to the guard block introduced by PR 1
    │
    └── PR 3 (P2) ── independent of PR 2; both touch ProviderEngine but non-overlapping sections
                     merge PR 2 first to avoid conflicts in settleAllChannelsOnChain
```

## Review Status

- **Systems-architect:** Approve with changes — all blocking issues addressed in this revision
- **Architecture-reviewer:** Approve with changes — all blocking issues addressed in this revision

**Blocking issues resolved:**
1. `lastRPCProbeSucceeded` default changed from `true` to `false`; initial probe added to `startNetworkMonitor()`
2. Periodic settlement bypass fixed by removing `!isRetry` condition from probe guard
3. `probeRPCConnectivity()` rewritten with proper two-Task timeout pattern
4. PR 3A expanded with full implementation notes (switch/case body guidance)

## Do Not Implement

**Awaiting implementation approval.**
