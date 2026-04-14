# Feature #15: Provider settledAmount Persistence

## Problem

When a provider restarts after settling a client's channel, the `settledAmount` baseline for that channel is lost. On reconnect, if the RPC is unavailable (timeout, flaky testnet), the provider creates a fresh `Channel` with `settledAmount = 0`. The client's next voucher has a `cumulativeAmount` that includes all prior spend, so `unsettledAmount = cumulativeAmount - 0` is massively inflated.

**Example:**
1. Client sends 57 credits total across a session. Provider settles 57 on-chain.
2. Settlement uses `removeAfterSettlement: true` → channel removed from `channels` dict. `unsettledChannels` only persists channels where `unsettledAmount > 0`, so this settled channel is excluded.
3. Provider restarts. No record of `settledAmount = 57` for this channelId.
4. Client reconnects. `verifyChannelInfoOnChain()` times out → `.rpcUnavailable`.
5. Provider creates new Channel with `settledAmount = 0`. Client sends voucher for cumulative = 60 (3 new credits). Provider sees `unsettledAmount = 60` instead of `3`. Pending display shows 57 phantom credits.

Discovered during #14b manual testing: provider restart → client reconnect → RPC timeouts → pending credits wildly inflated.

## Root Cause

`ProviderEngine.persistState()` (line 859) filters to `latestVoucher != nil && unsettledAmount > 0`:

```swift
let unsettled = channels.filter { $0.value.latestVoucher != nil && $0.value.unsettledAmount > 0 }
```

Fully-settled channels (`unsettledAmount == 0`) are intentionally excluded — there's nothing to recover. But the `settledAmount` baseline they represent is discarded too. This is correct when RPC is available (on-chain state repopulates the baseline), but breaks when RPC is unavailable on reconnect.

### Three paths that lose `settledAmount` (all must be fixed)

| Path | Trigger | Code location |
|------|---------|---------------|
| Disconnect settlement | `settleAllChannelsOnChain(removeAfterSettlement: true)` → `removeChannelIfMatch` | `ProviderEngine.swift:394, 489` |
| TTL eviction | `retryPendingSettlements()` → `channels.removeValue(forKey:)` directly | `ProviderEngine.swift:289` |
| Periodic/threshold settlement | `removeAfterSettlement: false` → channel stays in `channels` but `unsettledAmount == 0` after settlement → filtered out of `persistState()` | `ProviderEngine.swift:393, 859` |
| Channel replacement | New channel with different channelId replaces existing one for same session | `ProviderEngine.swift:594` |

## Solution

Add `settledChannelAmounts: [String: UInt64]?` to `PersistedProviderState` — a lightweight dictionary of `channelId (hex) → settledAmount`. Updated on all four paths above. Consulted on reconnect when RPC is unavailable.

**Key principle:** `persistState()` is the single source of truth. Rather than updating the dict only at removal time (which misses the periodic settlement path), `persistState()` scans all in-memory channels and upserts their `settledAmount` into the dict before saving. Removal paths additionally update the dict before the channel leaves memory. This ensures the dict is always populated regardless of how a channel's settled balance was established.

The dict is write-on-persist/removal, read-on-reconnect. Zero behavior change when RPC is available (on-chain state is still authoritative).

---

## Implementation

### Step 1 — Add `settledChannelAmounts` to `PersistedProviderState`

**File:** `Sources/JanusShared/Persistence/SessionStore.swift`

Add field with `decodeIfPresent` for backward compatibility:

```swift
public struct PersistedProviderState: Codable, Sendable {
    // ... existing fields ...
    /// Settled amount per channelId (hex) — persisted for settledAmount recovery when RPC is
    /// unavailable on reconnect. Updated on every persist so periodic settlement is covered.
    public var settledChannelAmounts: [String: UInt64]?
}
```

Update `init` (add after `settlementThreshold`):
```swift
public init(
    providerID: String,
    privateKeyBase64: String,
    receiptsIssued: [Receipt] = [],
    totalRequestsServed: Int = 0,
    totalCreditsEarned: Int = 0,
    requestLog: [PersistedLogEntry] = [],
    ethPrivateKeyHex: String? = nil,
    unsettledChannels: [String: Channel]? = nil,
    sessionToIdentity: [String: String]? = nil,
    settlementIntervalSeconds: Int? = nil,
    settlementThreshold: Int? = nil,
    settledChannelAmounts: [String: UInt64]? = nil   // NEW
) {
    // ... existing assignments ...
    self.settledChannelAmounts = settledChannelAmounts
}
```

Custom decoder (add after `settlementThreshold` line):
```swift
settledChannelAmounts = try container.decodeIfPresent([String: UInt64].self, forKey: .settledChannelAmounts)
```

### Step 2 — In-memory dict and restore on init

**File:** `JanusApp/JanusProvider/ProviderEngine.swift`

Add property alongside `channels`:
```swift
/// channelId (hex) → last known settledAmount. Persisted for RPC-unavailable reconnect recovery.
private var settledChannelAmounts: [String: UInt64] = [:]
```

Restore in `init` alongside `unsettledChannels`:
```swift
if let amounts = persisted.settledChannelAmounts {
    self.settledChannelAmounts = amounts
}
```

### Step 3 — Upsert in `persistState()` (covers periodic/threshold path)

**File:** `JanusApp/JanusProvider/ProviderEngine.swift`

In `persistState()`, before constructing `PersistedProviderState`, scan all channels:

```swift
// Upsert settledAmount for all in-memory channels into the cache.
// This covers periodic/threshold settlement (removeAfterSettlement: false) where
// channels stay in memory with unsettledAmount = 0 — they're filtered out of
// unsettledChannels but their settledAmount baseline must survive a restart.
for (_, channel) in channels where channel.settledAmount > 0 {
    let key = channel.channelId.ethHexPrefixed
    settledChannelAmounts[key] = max(settledChannelAmounts[key] ?? 0, channel.settledAmount)
}
// Cap at 500 entries (far more than needed in practice — evict random entry if exceeded).
while settledChannelAmounts.count > 500 {
    if let randomKey = settledChannelAmounts.keys.randomElement() {
        settledChannelAmounts.removeValue(forKey: randomKey)
    }
}

let state = PersistedProviderState(
    // ... existing fields ...
    settledChannelAmounts: settledChannelAmounts.isEmpty ? nil : settledChannelAmounts
)
```

### Step 4 — Update dict at removal sites

**File:** `JanusApp/JanusProvider/ProviderEngine.swift`

Extract a helper to avoid duplication:

```swift
/// Record the settled amount for a channel before it leaves in-memory state.
/// Guards against the settled baseline being lost when the channel is removed
/// and RPC is unavailable on the next reconnect.
private func recordSettledBaseline(for channel: Channel) {
    guard channel.settledAmount > 0 else { return }
    let key = channel.channelId.ethHexPrefixed
    settledChannelAmounts[key] = max(settledChannelAmounts[key] ?? 0, channel.settledAmount)
}
```

Call it in **`removeChannelIfMatch`** before removal:
```swift
private func removeChannelIfMatch(sessionID: String, expectedChannelId: Data, onlyIfSettled: Bool = false) {
    guard channels[sessionID]?.channelId == expectedChannelId else { return }
    if onlyIfSettled {
        guard channels[sessionID]?.unsettledAmount == 0 else { return }
    }
    if let channel = channels[sessionID] { recordSettledBaseline(for: channel) }  // NEW
    channels.removeValue(forKey: sessionID)
    // ... rest unchanged ...
}
```

Call it in **`retryPendingSettlements`** TTL eviction loop (line 289):
```swift
for sessionID in staleIDs {
    if let channel = channels[sessionID] { recordSettledBaseline(for: channel) }  // NEW
    channels.removeValue(forKey: sessionID)
    sessionToIdentity.removeValue(forKey: sessionID)
    print("WARNING: Discarding stale channel ...")
}
```

Call it in **`handlePromptRequest`** channel-replacement path (line 594), before overwriting:
```swift
if existingChannel?.channelId != info.channelId {
    if let old = existingChannel { recordSettledBaseline(for: old) }  // NEW — record old channel's baseline
    var channel = Channel(...)
    // ... rest unchanged ...
}
```

### Step 5 — Apply cache on reconnect when RPC unavailable

**File:** `JanusApp/JanusProvider/ProviderEngine.swift`

In `handlePromptRequest`, inside the new-channel creation block:

```swift
if case .acceptedOnChain(_, let onChainSettled) = result, onChainSettled > 0 {
    channel.recordSettlement(amount: onChainSettled)
    // Keep cache in sync with authoritative on-chain value
    settledChannelAmounts[info.channelId.ethHexPrefixed] = onChainSettled   // NEW
    print("Initialized settledAmount=\(onChainSettled) from on-chain for session \(request.sessionID.prefix(8))...")
} else if case .rpcUnavailable = result {
    // RPC unavailable — fall back to locally persisted settled amount if known
    let key = info.channelId.ethHexPrefixed
    if let cached = settledChannelAmounts[key], cached > 0 {
        channel.recordSettlement(amount: cached)
        print("Initialized settledAmount=\(cached) from local cache (RPC unavailable) for session \(request.sessionID.prefix(8))...")
    }
}
```

---

## Files Changed

| File | Change |
|------|--------|
| `Sources/JanusShared/Persistence/SessionStore.swift` | Add `settledChannelAmounts` with `decodeIfPresent`, update `init` |
| `JanusApp/JanusProvider/ProviderEngine.swift` | In-memory dict, restore, `recordSettledBaseline()` helper, `persistState()` scan, apply on reconnect, cache sync on `acceptedOnChain` |

No client-side changes. No protocol changes.

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| RPC available on reconnect | `acceptedOnChain` path used — on-chain state is authoritative, cache updated to stay fresh |
| Channel never settled (first connect) | No entry in dict → `settledAmount = 0` (correct) |
| Channel settled multiple times (periodic) | `persistState()` upserts on every persist — latest `max()` value always captured |
| Channel replaced with new channelId | Old channel's baseline recorded before overwrite; new channel starts fresh (correct) |
| Provider reinstall / app data wipe | Dict is empty → reverts to pre-fix behavior (RPC timeout shows inflated pending). Acceptable |
| Dict exceeds 500 entries | Random eviction. In practice never happens with 1-2 regular clients |

---

## Reviewer Findings Incorporated

| Original plan gap | Finding source | Fix applied |
|---|---|---|
| TTL eviction at line 289 bypasses `removeChannelIfMatch` | Both reviewers (P0/P1) | `recordSettledBaseline()` helper called at line 289 |
| Periodic settlement leaves no trace when `unsettledAmount == 0` | Architecture reviewer (INSIGHT/P1) | `persistState()` upserts all in-memory channels into dict |
| Channel replacement loses old channel's `settledAmount` | Systems architect (P1) | `recordSettledBaseline(for: old)` before overwrite at line 594 |
| Cache not updated when `acceptedOnChain` succeeds | Both reviewers (P1/P2) | `settledChannelAmounts[key] = onChainSettled` on `acceptedOnChain` path |
| Eviction by smallest value semantically wrong | Both reviewers (P1/P2) | Changed to random eviction, cap raised to 500 |
| Missing reconnect-path unit test | Architecture reviewer (P1) | Added `testCachedSettledAmountProducesCorrectUnsettledAmount` below |
| Missing complete `init` signature | Both reviewers (P2/P3) | Full updated `init` shown in Step 1 |

---

## Testing

### Unit tests (`Tests/JanusSharedTests/PersistenceTests.swift`)

```swift
func testSettledChannelAmountsPersistenceRoundTrip() throws {
    let state = PersistedProviderState(
        providerID: "test",
        privateKeyBase64: "dGVzdA==",
        settledChannelAmounts: ["0xabc": 42, "0xdef": 100]
    )
    let data = try JSONEncoder.janus.encode(state)
    let decoded = try JSONDecoder.janus.decode(PersistedProviderState.self, from: data)
    XCTAssertEqual(decoded.settledChannelAmounts?["0xabc"], 42)
    XCTAssertEqual(decoded.settledChannelAmounts?["0xdef"], 100)
}

func testSettledChannelAmounts_decodesNilFromOldFormat() throws {
    let json = """
    {"providerID":"test","privateKeyBase64":"dGVzdA==","totalRequestsServed":0,"totalCreditsEarned":0}
    """
    let decoded = try JSONDecoder.janus.decode(PersistedProviderState.self, from: Data(json.utf8))
    XCTAssertNil(decoded.settledChannelAmounts)
}

/// The key invariant: after recovering settledAmount from cache, subsequent vouchers
/// produce correct unsettledAmount (not inflated by prior settled spend).
func testCachedSettledAmountProducesCorrectUnsettledAmount() throws {
    let clientKP = try EthKeyPair()
    let providerKP = try EthKeyPair()
    let salt = Keccak256.hash(Data("test-cache-recovery".utf8))
    var channel = Channel(
        payer: clientKP.address,
        payee: providerKP.address,
        token: EthAddress(Data(repeating: 0, count: 20)),
        salt: salt,
        authorizedSigner: clientKP.address,
        deposit: 100,
        config: TempoConfig.testnet
    )

    // Simulate cache recovery: 57 credits were settled in a prior session
    channel.recordSettlement(amount: 57)
    XCTAssertEqual(channel.settledAmount, 57)
    XCTAssertEqual(channel.unsettledAmount, 0)

    // Client sends voucher for cumulative 60 (3 new credits above prior 57)
    let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 60)
    let signed = try voucher.sign(with: clientKP, config: TempoConfig.testnet)
    try channel.acceptVoucher(signed)

    // unsettledAmount must be 3, not 60 (which would be the inflated value without cache recovery)
    XCTAssertEqual(channel.unsettledAmount, 3)
    XCTAssertEqual(channel.authorizedAmount, 60)
}
```

---

## Verification

```
xcodebuild test -scheme Janus-Package -destination 'platform=macOS'
```

All existing tests + 3 new tests should pass.
