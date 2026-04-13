# Feature #13: Periodic & Threshold-Based Settlement

## Context

Currently the provider only settles payment channels when a client disconnects (`settleAllSessions()` in `onClientDisconnected`). This means:

- A client connected for hours accumulates unsettled vouchers — the provider's earned credits are at risk
- The provider has no control over when settlement happens — it's entirely at the client's mercy
- If the provider crashes before the client disconnects, unsettled vouchers may be lost (mitigated by #12b persistence, but settlement timing is still suboptimal)

This feature adds two new settlement triggers alongside the existing disconnect trigger, with provider-configurable parameters.

## Current State

- `settleAllChannelsOnChain(isRetry:)` — existing method, iterates all channels, idempotent
- `isSettling` guard — prevents concurrent settlement runs
- `pendingSettlementCredits` — computed property summing `unsettledAmount` across all channels
- `persistState()` — saves channels and provider state to disk
- `PersistedProviderState` — already has `unsettledChannels`, custom decoder with `decodeIfPresent`
- `removeChannelIfMatch()` — removes channel after settlement (currently always called)

---

## Design Decisions

1. **Aggregate threshold, not per-client** — The provider's risk is total unsettled exposure across all clients. 20 clients at 9 credits each = 180 credits at risk, but a per-client threshold of 10 would never trigger. Aggregate catches this.

2. **Provider-configurable** — Different providers have different risk tolerances. Persist settings in `PersistedProviderState` so they survive restart.

3. **Timer uses `Task.sleep` loop, not `Timer`** — `Timer` requires RunLoop scheduling. A `Task.sleep` loop on `@MainActor` is simpler, cancellable, and consistent with existing patterns in the codebase (network monitor, retry loops).

4. **Threshold check on every voucher acceptance** — This is the moment `pendingSettlementCredits` changes. Cheap check (one comparison), avoids polling.

5. **Sensible defaults** — 5 minutes interval, 50 credits threshold. Both enabled by default. Provider can adjust or disable either (0 = disabled for both).

6. **Existing `isSettling` guard handles races** — Timer fire + threshold trigger + disconnect could overlap. The guard ensures only one settlement runs at a time. Others are skipped (safe because settlement is idempotent — next trigger will pick up remaining).

7. **`removeAfterSettlement` parameter on `settleAllChannelsOnChain`** — Disconnect-triggered settlement removes channels (client is gone). Periodic/threshold settlement keeps channels alive (client is still connected, just zeroes `unsettledAmount` via `recordSettlement`). Without this, settling an active channel would break the session.

8. **Skip faucet funding for periodic/threshold triggers** — The provider is already funded on startup via `fundProviderIfNeeded()`. Calling the faucet + waiting 3s on every periodic settlement is wasteful. Use `isRetry: true` to skip this. (The `isRetry` parameter already skips faucet — we repurpose it here since the semantics are the same: "provider is already funded, just settle.")

---

## Implementation Steps

### Step 1: Add settings fields to `PersistedProviderState`

**Modify:** `Sources/JanusShared/Persistence/SessionStore.swift`

Add fields to struct:

```swift
/// Settlement interval in seconds (0 = disabled). Nil means never persisted (use engine default).
public var settlementIntervalSeconds: Int?
/// Aggregate unsettled credit threshold for auto-settlement (0 = disabled). Nil means never persisted.
public var settlementThreshold: Int?
```

Add to `init` signature with defaults:

```swift
public init(
    // ... existing params ...,
    settlementIntervalSeconds: Int? = nil,
    settlementThreshold: Int? = nil
) {
    // ... existing assignments ...
    self.settlementIntervalSeconds = settlementIntervalSeconds
    self.settlementThreshold = settlementThreshold
}
```

Add `decodeIfPresent` lines in custom decoder:

```swift
settlementIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .settlementIntervalSeconds)
settlementThreshold = try container.decodeIfPresent(Int.self, forKey: .settlementThreshold)
```

**Dependencies:** None.

---

### Step 2: Add `removeAfterSettlement` parameter to `settleAllChannelsOnChain`

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift`

Change signature:

```swift
private func settleAllChannelsOnChain(isRetry: Bool = false, removeAfterSettlement: Bool = true) async {
```

Guard `removeChannelIfMatch` calls behind the parameter — in both the first-pass and retry-pass `.settled` cases:

```swift
case .settled(let txHash, let amount):
    channels[sessionID]?.recordSettlement(amount: amount)
    // ... existing logging + SettlementNotice (future) ...
    if removeAfterSettlement {
        removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId, onlyIfSettled: true)
    }
```

Same for `.alreadySettled` cases — only remove if `removeAfterSettlement` is true.

Existing callers (`settleAllSessions`, `retryPendingSettlements`) pass default `removeAfterSettlement: true` — behavior unchanged.

**Dependencies:** None.

---

### Step 3: Add settings properties and periodic timer to `ProviderEngine`

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift`

Add published settings (so UI can bind):

```swift
@Published var settlementIntervalSeconds: Int = 300  // 5 minutes default
@Published var settlementThreshold: Int = 50          // 50 credits default
```

Add timer task handle:

```swift
private var settlementTimerTask: Task<Void, Never>?
```

Add method to start periodic settlement:

```swift
func startPeriodicSettlement() {
    settlementTimerTask?.cancel()
    let interval = settlementIntervalSeconds
    guard interval > 0 else { return }  // 0 = disabled
    settlementTimerTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            } catch {
                break  // CancellationError — exit cleanly
            }
            guard let self else { return }
            let pending = self.pendingSettlementCredits
            guard pending > 0 else { continue }
            print("Periodic settlement triggered: \(pending) credits pending")
            await self.settleAllChannelsOnChain(isRetry: true, removeAfterSettlement: false)
        }
    }
}
```

Cancel in `deinit` alongside existing `networkMonitor?.cancel()`:

```swift
settlementTimerTask?.cancel()
```

**Note:** `isRetry: true` skips the redundant faucet call + 3s sleep. `removeAfterSettlement: false` keeps active channels alive.

**Dependencies:** Steps 1, 2.

---

### Step 4: Add threshold check after voucher acceptance

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift` — `handleVoucherAuthorization()`

After `channels[sessionID]?.acceptVoucher(...)` and `persistState()`, add:

```swift
// Check aggregate threshold for auto-settlement
if settlementThreshold > 0 && pendingSettlementCredits >= settlementThreshold {
    print("Threshold settlement triggered: \(pendingSettlementCredits) >= \(settlementThreshold)")
    Task { await settleAllChannelsOnChain(isRetry: true, removeAfterSettlement: false) }
}
```

The `isSettling` guard inside `settleAllChannelsOnChain()` prevents this from interfering with any in-progress settlement. The detached `Task` is intentional — don't block inference on settlement.

**Dependencies:** Steps 2, 3.

---

### Step 5: Persist and restore settings

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift`

In `persistState()` — pass settings to `PersistedProviderState`:

```swift
let state = PersistedProviderState(
    // ... existing params ...,
    settlementIntervalSeconds: settlementIntervalSeconds,
    settlementThreshold: settlementThreshold
)
```

In `init` (restore path, inside the existing `if let persisted = ...` block) — read settings:

```swift
if let interval = persisted.settlementIntervalSeconds {
    self.settlementIntervalSeconds = interval
}
if let threshold = persisted.settlementThreshold {
    self.settlementThreshold = threshold
}
```

**Note:** Settings restore is synchronous in `init`, which completes before `.onAppear` fires `startPeriodicSettlement()`. The timer always uses the restored (not default) interval.

**Dependencies:** Steps 1, 3.

---

### Step 6: Provider UI — settlement settings

**Modify:** `JanusApp/JanusProvider/ProviderStatusView.swift`

Add a settings section below the existing stats strip:

```swift
settlementSettingsSection
```

Implementation:

```swift
private var settlementSettingsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
        Text("Auto-Settlement")
            .font(.subheadline.bold())

        HStack {
            Text("Interval:")
                .font(.caption)
            Picker("", selection: $engine.settlementIntervalSeconds) {
                Text("Off").tag(0)
                Text("1 min").tag(60)
                Text("5 min").tag(300)
                Text("15 min").tag(900)
                Text("30 min").tag(1800)
            }
            .pickerStyle(.segmented)
        }

        HStack {
            Text("Threshold:")
                .font(.caption)
            Picker("", selection: $engine.settlementThreshold) {
                Text("Off").tag(0)
                Text("25").tag(25)
                Text("50").tag(50)
                Text("100").tag(100)
            }
            .pickerStyle(.segmented)
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.gray.opacity(0.05))
    .cornerRadius(10)
    .onChange(of: engine.settlementIntervalSeconds) { _, _ in
        engine.persistState()
        engine.startPeriodicSettlement()
    }
    .onChange(of: engine.settlementThreshold) { _, _ in
        engine.persistState()
    }
}
```

**Note:** `onChange` handlers are split — interval change restarts the timer and persists; threshold change only persists (threshold is checked at voucher-acceptance time, not on a timer). No `updateSettlementSettings()` method needed.

**Dependencies:** Steps 3, 5.

---

### Step 7: Wire startup in view layer

**Modify:** `JanusApp/JanusProvider/ProviderStatusView.swift` — `.onAppear`

Add:

```swift
engine.startPeriodicSettlement()
```

This is idempotent (cancels existing timer first). Settings are already restored by `ProviderEngine.init` (synchronous), so the timer uses the correct persisted interval.

**Dependencies:** Step 3.

---

## Files Summary

| File | Action | Changes |
|------|--------|---------|
| `Sources/JanusShared/Persistence/SessionStore.swift` | Modify | Add `settlementIntervalSeconds` + `settlementThreshold` to `PersistedProviderState` |
| `JanusApp/JanusProvider/ProviderEngine.swift` | Modify | (1) `removeAfterSettlement` param on `settleAllChannelsOnChain`, (2) settings properties, (3) periodic timer with `do/catch` cancellation, (4) threshold check in `handleVoucherAuthorization`, (5) persist/restore settings, (6) cancel timer in `deinit` |
| `JanusApp/JanusProvider/ProviderStatusView.swift` | Modify | Settlement settings section with split `onChange` handlers, wire `startPeriodicSettlement()` in `.onAppear` |

**Total:** ~80 lines across 3 files (all modifications).

---

## What Does NOT Change

- `ChannelSettler` — settlement logic unchanged
- Client-side code — unaffected
- Transport layer — unaffected
- Disconnect-triggered settlement — still works as before (passes default `removeAfterSettlement: true`)

---

## Verification

1. **Periodic timer:** Set interval to 1 min → connect client → send request → wait 1 min → check provider logs for "Periodic settlement triggered" → client session still works after settlement
2. **Threshold trigger:** Set threshold to 25 → send enough requests to reach 25 credits → check logs for "Threshold settlement triggered" → client can still send requests
3. **Active session survives:** Periodic/threshold settlement runs → channel stays in `channels` dict → next client voucher succeeds
4. **Settings persistence:** Change settings → restart provider → verify settings restored (check picker state)
5. **Timer restart:** Change interval from 5 min to 1 min → verify new interval takes effect immediately
6. **Disabled:** Set interval to "Off" → verify no periodic settlement fires. Set threshold to "Off" → verify no threshold settlement fires
7. **Race safety:** Trigger disconnect + periodic timer simultaneously → only one settlement runs (other skipped by `isSettling`)
8. **Coexistence:** All three triggers (disconnect, periodic, threshold) work independently
9. **Disconnect still removes:** Disconnect-triggered settlement still removes settled channels (default `removeAfterSettlement: true`)

---

## Review Findings Incorporated

Based on **systems-architect** and **architecture-reviewer** feedback:

| Severity | Finding | Resolution |
|----------|---------|------------|
| Critical | `settleAllChannelsOnChain` removes channels after settlement — breaks active sessions for periodic/threshold triggers | Added `removeAfterSettlement` parameter (Step 2). Periodic/threshold pass `false`; disconnect passes default `true` |
| Important | Redundant faucet call + 3s sleep on every periodic/threshold trigger | Use `isRetry: true` to skip faucet (Steps 3, 4) |
| Important | `try?` swallowing CancellationError is non-idiomatic | Changed to `do/catch` with `break` (Step 3) |
| Important | `onChange` double-fires via Picker binding + updateSettlementSettings | Split handlers: interval→restart+persist, threshold→persist only (Step 6) |
| Minor | Timer cancel location vague | Explicit: add to `deinit` alongside `networkMonitor?.cancel()` (Step 3) |
| Minor | Persistence init/decoder not shown explicitly | Full code shown (Step 1) |

---

## Risks

- **Low.** Adds new triggers for an existing idempotent operation. The critical review finding (channel removal) is addressed by the `removeAfterSettlement` parameter.
- **Gas costs on testnet:** More frequent settlement = more transactions. Irrelevant on testnet, but on mainnet the provider would want to balance settlement frequency against gas costs. The configurable interval/threshold handles this.
- **Timer drift:** `Task.sleep` is not a precise timer, but precision doesn't matter here — ±seconds on a 5-minute interval is fine.
