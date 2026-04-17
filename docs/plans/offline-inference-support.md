# Offline Inference Support: Analysis & Implementation Plan

## Scenario

Both client (iPhone) and provider (Mac) have no internet. A payment channel was previously opened on-chain when internet was available. The provider serves inference requests offline. The provider settles the channel once internet returns.

## Review Summary (2026-04-17)

Reviewed independently by systems-architect and architecture-reviewer. Both confirmed the scenario is **SUPPORTED** for normal usage with the following gaps identified.

---

## Full Inference Path (Confirmed Offline-Safe)

| Step | Component | Offline? | Notes |
|------|-----------|----------|-------|
| Discovery | BonjourBrowser (mDNS) | ✅ | Local multicast, AWDL works without AP |
| Session restore | SessionManager.restore() | ✅ | Reads from disk, TTL guard removed in #15b |
| Channel open guard | `channelOpenedOnChain` | ✅ | Persisted boolean, skips re-open |
| Inference request | ClientEngine.submitRequest() | ✅ | Local state + TCP send |
| Voucher signing | LocalWalletProvider.signVoucher() | ✅ | Pure secp256k1 |
| Channel verification | ProviderEngine ~line 591 | ✅ | Known channels skip RPC; unknown → `.rpcUnavailable` (accepted) |
| Voucher verification | VoucherVerifier.verifyTabSettlement() | ✅ | Pure local ecrecover |
| Inference | MLXRunner.generate() | ✅ | Local MLX model |
| Receipt signing | ProviderEngine.signReceipt() | ✅ | Local Ed25519 |
| Response handling | ClientEngine.handleInferenceResponse() | ✅ | Local crypto + state |
| Tab voucher at threshold | SessionManager.createTabSettlementVoucher() | ✅ | Local secp256k1 |
| On-chain settlement | ChannelSettler.settle() | ❌ | Needs RPC — deferred, retried when internet returns |

### Settlement Retry (Three Independent Paths)
1. **NWPathMonitor** — fires the moment connectivity is restored (`ProviderEngine.swift:327-335`)
2. **Periodic timer** — every 5 minutes (`ProviderEngine.swift:357-370`)
3. **Threshold trigger** — when 50+ credits are unsettled (`ProviderEngine.swift:847-853`)

---

## Gaps Found

### GAP 1 (P1): 15-Second Latency on First Request After Provider Restart

**File:** `JanusApp/JanusProvider/ProviderEngine.swift` lines 591-596

**Root cause:** After a provider restart, `channels` is only repopulated with *unsettled* channels from persistence (channels with `latestVoucher != nil && unsettledAmount > 0`). Fully-settled channels are excluded from the persistence filter at line 938:

```swift
let unsettled = channels.filter { $0.value.latestVoucher != nil && $0.value.unsettledAmount > 0 }
```

When a client reconnects post-restart, `existingChannel` is nil, so `channelChanged = true`, and the code calls `await vv.verifyChannelInfoOnChain(info)` (line 596) — an RPC call. With no internet, the `URLSessionTransport` times out after 15 seconds (HTTPTransport.swift line 29), then returns `.rpcUnavailable`, which is accepted (line 602-603). Inference proceeds but only after the 15-second penalty.

This only affects the **first request per session after provider restart**. All subsequent requests for the same session are fast (channel is now cached in `channels`).

**Architecture-reviewer note:** This is latency only, not a correctness issue. The request ultimately succeeds.

---

### GAP 2 (P3): Wasted RPC Timeout Attempts During Offline Settlement

**File:** `JanusApp/JanusProvider/ProviderEngine.swift` line 847-853

**Root cause:** When the tab settlement threshold is crossed while offline, `settleAllChannelsOnChain` is fired anyway. Each channel burns up to 45 seconds of async RPC timeouts (3x `URLSessionTransport` calls: `getChannel`, `gasPrice`, `getTransactionCount`) before queuing for retry. The `@MainActor` `await` yields during each timeout so inference is not blocked, but it wastes background resources and may cause multiple redundant settlement attempts as the `isSettling` guard cycles.

**No user-visible impact.** P3 only.

---

## Implementation Plan

### Fix 1 (P1): Eliminate 15-Second Delay — Short-Circuit Known Channels After Restart

**Goal:** When a client reconnects after provider restart, skip the RPC call if we can determine the channel is legitimate from local state.

**Approach:** Before calling `verifyChannelInfoOnChain`, check if the channel ID exists in `settledChannelAmounts` — the provider's local cache of previously settled channels. If it does, the channel was previously verified and settled on-chain. Short-circuit to `.rpcUnavailable` immediately without any network call.

**File:** `JanusApp/JanusProvider/ProviderEngine.swift`

**Change at lines 591-598:**

Current:
```swift
let existingChannel = channels[request.sessionID]
let depositChanged = existingChannel.map { $0.deposit != info.deposit } ?? false
let channelChanged = existingChannel?.channelId != info.channelId || depositChanged

let result: ChannelVerificationResult
if channelChanged {
    result = await vv.verifyChannelInfoOnChain(info)
} else {
    result = .rpcUnavailable
}
```

Proposed:
```swift
let existingChannel = channels[request.sessionID]
let depositChanged = existingChannel.map { $0.deposit != info.deposit } ?? false
let channelChanged = existingChannel?.channelId != info.channelId || depositChanged

let result: ChannelVerificationResult
if channelChanged {
    // Short-circuit: channel was previously settled on-chain — no need to re-verify
    let channelIdHex = info.channelId.lowercased()
    if settledChannelAmounts[channelIdHex] != nil {
        result = .rpcUnavailable  // previously verified; skip RPC
    } else {
        result = await vv.verifyChannelInfoOnChain(info)
    }
} else {
    result = .rpcUnavailable
}
```

**Key questions for reviewers:**
- Is `settledChannelAmounts` the right dict to check? Is it persisted across restarts?
- Are there cases where a channel is in `settledChannelAmounts` but should NOT be trusted (e.g. different deposit, different contract)?
- Should `info.deposit` also be checked against the cached settled amount for a sanity bound?

---

### Fix 2 (P3): Skip Settlement Attempts When Offline

**Goal:** Avoid burning RPC timeouts when we already know we're offline.

**Approach:** Gate `settleAllChannelsOnChain` with a reachability check. If `lastPathStatus != .satisfied`, skip the settlement attempt entirely and rely on the NWPathMonitor to trigger retry when internet returns.

**File:** `JanusApp/JanusProvider/ProviderEngine.swift`

**Change at the top of `settleAllChannelsOnChain`** (around line 378, after `isSettling` guard):

Current:
```swift
guard !isSettling else {
    pendingSettlementRequest = true
    return
}
isSettling = true
```

Proposed:
```swift
guard !isSettling else {
    pendingSettlementRequest = true
    return
}
// Skip settlement when offline — NWPathMonitor will trigger retry on network restore
guard lastPathStatus == .satisfied else {
    print("Settlement skipped: network unavailable")
    return
}
isSettling = true
```

**Note:** This only applies to threshold-triggered and timer-triggered settlement. The NWPathMonitor path already checks `wasUnsatisfied && path.status == .satisfied` so it won't be affected.

**Key questions for reviewers:**
- Is `lastPathStatus` the right flag to check here? Could it be stale?
- Should this guard also apply to the periodic timer path, or just the threshold trigger?
- Does skipping settlement here risk losing the `pendingSettlementRequest` signal?

---

## What Is NOT In Scope

- **Close-request watcher / watchtower**: Tracked separately in `docs/plans/16-close-grace-period-extension.md`
- **24-hour stale TTL**: Acknowledged limitation. No change planned — it is a reasonable safety valve.
- **First-ever connection RPC timeout** (new client, provider has never seen channel): Acceptable — this only affects brand-new channels and `.rpcUnavailable` is already the fallback.

---

## Implementation (2026-04-17)

Both fixes implemented in `JanusApp/JanusProvider/ProviderEngine.swift` after reviewer sign-off.

**Fix 1 corrections applied:**
- `info.channelId.ethHexPrefixed` used as dict key (not `.lowercased()` — `Data` has no such method)
- `vv.verifyChannelInfo(info)` added alongside the dict check to preserve off-chain payee + channelId integrity checks

**Fix 2 correction applied:**
- Guards placed at the two call sites (periodic timer line ~367, threshold trigger line ~863) rather than inside `settleAllChannelsOnChain`, preserving the `isSettling`/`pendingSettlementRequest` queueing semantics

Build verified: `xcodebuild build -scheme JanusProvider` passes with no errors.
