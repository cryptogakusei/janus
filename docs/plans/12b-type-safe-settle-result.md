# Feature: Type-Safe SettleResult Failure Reasons

## Context

`ChannelSettler.settle()` returns `SettleResult.failed(String)` — a bare string describing what went wrong. `ProviderEngine.settleAllChannelsOnChain()` then uses `reason.contains("does not exist on-chain")` and `reason.contains("finalized")` to decide whether the failure is permanent (remove channel) or transient (keep for retry).

This is fragile:
- Changing the error string in `ChannelSettler` silently breaks the branching logic in `ProviderEngine`
- No compiler help — a typo like `reason.contains("finalizd")` compiles fine, falls to the default case
- New failure modes automatically get treated as transient (may be wrong)
- The retry loop in `settleAllChannelsOnChain()` doesn't differentiate at all — treats all failures the same

**Goal:** Replace the `String` with a structured enum so the compiler enforces exhaustive handling and string matching is eliminated.

---

## Design Decisions

1. **`SettleFailureReason` enum in JanusShared** — lives next to `SettleResult` in `ChannelSettler.swift`. This is a shared type, so both `ChannelSettler` (library) and `ProviderEngine` (app) can use it without import gymnastics.

2. **Preserve human-readable context** — Some failure cases carry extra info (the underlying error message, the reverted tx hash). These become associated values on enum cases, not lost.

3. **`isPermanent` computed property** — Rather than forcing `ProviderEngine` to enumerate every case, provide a `isPermanent: Bool` helper. Permanent failures = remove channel. Transient = keep for retry. This reduces the matching surface in the consumer.

4. **`description` computed property** — For logging and UI display. Replaces the raw string that was previously used in `print()` and `os_log()` calls.

5. **Fix the retry loop gap** — The retry loop (pending channels after 20s wait) currently treats all failures uniformly. After this change, it should differentiate permanent vs transient, matching the first loop's behavior.

---

## Implementation Steps

### Step 1: Define `SettleFailureReason` enum

**Modify:** `Sources/JanusShared/Tempo/ChannelSettler.swift`

Add a new enum and update `SettleResult`:

```swift
/// Categorized failure reasons for on-chain settlement.
public enum SettleFailureReason: Sendable {
    /// Channel has not been opened on-chain (client may still be opening it).
    case channelNotOnChain
    /// Channel is closed or expired on-chain — permanent, cannot settle.
    case channelFinalized
    /// Failed to fetch gas price or transaction nonce.
    case gasInfoUnavailable(String)
    /// Settlement transaction was mined but reverted.
    case transactionReverted(txHash: String)
    /// Signing, submission, or receipt polling failed.
    case submissionFailed(String)
}

public enum SettleResult: Sendable {
    case settled(txHash: String, amount: UInt64)
    case noVoucher
    case alreadySettled
    case failed(SettleFailureReason)  // was: failed(String)
}
```

**Dependencies:** None.

---

### Step 2: Add `isPermanent` and `description` to `SettleFailureReason`

**Modify:** `Sources/JanusShared/Tempo/ChannelSettler.swift`

```swift
extension SettleFailureReason: CustomStringConvertible {
    /// Whether this failure is permanent (channel should be removed) or transient (keep for retry).
    public var isPermanent: Bool {
        switch self {
        case .channelFinalized, .transactionReverted: return true
        case .channelNotOnChain, .gasInfoUnavailable, .submissionFailed:
            return false
        }
    }

    /// Human-readable description for logging.
    public var description: String {
        switch self {
        case .channelNotOnChain:
            return "Channel does not exist on-chain"
        case .channelFinalized:
            return "Channel is finalized"
        case .gasInfoUnavailable(let detail):
            return "Failed to get gas info: \(detail)"
        case .transactionReverted(let txHash):
            return "Settle tx reverted: \(txHash)"
        case .submissionFailed(let detail):
            return "Settle failed: \(detail)"
        }
    }
}
```

**Design note on `isPermanent`:**

- `channelFinalized` → **permanent** (channel is closed on-chain, nothing to do)
- `transactionReverted` → **permanent** (mined but EVM rejected — invalid signature, bad state, etc. Retrying with same inputs will revert again, just burning gas. A nonce race causes submission failure, not a revert.)
- `channelNotOnChain` → **transient by default** (client may still be opening). `ProviderEngine` overrides this to permanent when `isRetry == true` (persisted channel from a previous session — client is long gone). Also treated as permanent in the 20s retry loop (grace period elapsed).
- `gasInfoUnavailable` → transient (network issue)
- `submissionFailed` → transient (RPC error, network timeout, the "failed to decode signed transaction" issue)

**Dependencies:** Step 1.

---

### Step 3: Update `ChannelSettler.settle()` to return typed reasons

**Modify:** `Sources/JanusShared/Tempo/ChannelSettler.swift` — `settle()` method

Replace each `return .failed("...")` with the corresponding enum case:

| Line | Current | New |
|------|---------|-----|
| 52 | `.failed("Channel does not exist on-chain")` | `.failed(.channelNotOnChain)` |
| 55 | `.failed("Channel is finalized")` | `.failed(.channelFinalized)` |
| 69 | `.failed("Failed to get gas info: \(error.localizedDescription)")` | `.failed(.gasInfoUnavailable(error.localizedDescription))` |
| 91 | `.failed("Settle tx reverted: \(txHash)")` | `.failed(.transactionReverted(txHash: txHash))` |
| 95 | `.failed("Settle failed: \(error.localizedDescription)")` | `.failed(.submissionFailed(error.localizedDescription))` |

**Dependencies:** Step 1.

---

### Step 4: Update `ProviderEngine.settleAllChannelsOnChain()` — first settlement loop

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift` — first `.failed` case in the for loop (~line 317)

Replace string matching with enum pattern matching:

```swift
case .failed(let reason):
    if case .channelNotOnChain = reason {
        if isRetry {
            // Persisted channel from previous session — client is gone
            removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId)
            print("Channel \(sessionID.prefix(8))... not on-chain (stale) — removed")
        } else {
            // Client may still be opening — queue for 20s retry
            pendingChannels.append((sessionID, channel))
            print("Channel \(sessionID.prefix(8))... not yet on-chain, will retry...")
        }
    } else if reason.isPermanent {
        removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId)
        print("Channel \(sessionID.prefix(8))... \(reason.description) — removed")
    } else {
        // Transient failure — keep for future retry via NWPathMonitor
        print("On-chain settlement failed for \(sessionID.prefix(8))...: \(reason.description)")
        os_log("SETTLEMENT_FAILED=%{public}@", log: smokeLog, type: .default, reason.description)
        appendLog(LogEntry(
            timestamp: Date(), taskType: "on-chain-settlement",
            promptPreview: "On-chain settlement failed: \(reason.description)",
            responsePreview: nil, credits: nil, isError: true, sessionID: sessionID
        ))
    }
```

**Key change:** `reason.contains("finalized")` becomes `reason.isPermanent`. If a new permanent failure case is added to `SettleFailureReason`, we just update `isPermanent` — `ProviderEngine` handles it automatically.

**Dependencies:** Steps 1, 2, 3.

---

### Step 5: Update retry loop — add permanent vs transient differentiation

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift` — retry loop `.failed` case (~line 369)

Currently the retry loop just logs all failures. Fix it to differentiate permanent vs transient.

**Context:** The retry loop only fires for `pendingChannels` — channels that returned `channelNotOnChain` in the first pass. This only happens when `isRetry == false` (disconnect path). After 20 seconds, if the channel still doesn't exist, the grace period has elapsed and it should be removed.

```swift
case .failed(let reason):
    // After 20s grace period, channelNotOnChain is effectively permanent
    var shouldRemove = reason.isPermanent
    if case .channelNotOnChain = reason { shouldRemove = true }

    if shouldRemove {
        removeChannelIfMatch(sessionID: sessionID, expectedChannelId: channel.channelId)
        print("On-chain settlement permanently failed (retry) for \(sessionID.prefix(8))...: \(reason.description)")
    } else {
        print("On-chain settlement failed (retry) for \(sessionID.prefix(8))...: \(reason.description)")
    }
    os_log("SETTLEMENT_FAILED=%{public}@", log: smokeLog, type: .default, reason.description)
    appendLog(LogEntry(
        timestamp: Date(), taskType: "on-chain-settlement",
        promptPreview: "On-chain settlement failed: \(reason.description)",
        responsePreview: nil, credits: nil, isError: true, sessionID: sessionID
    ))
```

**Deliberate behavioral improvement:** The current retry loop never removes channels — it just logs. This change adds removal for permanent failures and for `channelNotOnChain` after the 20s grace period. This prevents stale entries from accumulating in the `channels` dict. The channel remains persisted for NWPathMonitor retry only if the failure is transient (e.g., `submissionFailed`).

**Dependencies:** Step 4.

---

### Step 6: Update existing test

**Modify:** `Tests/JanusSharedTests/OnChainTests.swift` — `testFullSettlementOnTempo()`

Update the `.failed` pattern match from `case .failed(let reason)` using `reason` as a `String` to using it as a `SettleFailureReason`:

```swift
case .failed(let reason):
    XCTFail("Settlement failed: \(reason.description)")
```

**Dependencies:** Step 1.

---

### Step 7: Add unit tests for SettleFailureReason

**Modify:** `Tests/JanusSharedTests/OnChainTests.swift`

Add tests that verify the enum properties without needing a live blockchain:

```swift
func testSettleFailureReason_isPermanent() {
    XCTAssertTrue(SettleFailureReason.channelFinalized.isPermanent)
    XCTAssertFalse(SettleFailureReason.channelNotOnChain.isPermanent)
    XCTAssertFalse(SettleFailureReason.gasInfoUnavailable("timeout").isPermanent)
    XCTAssertFalse(SettleFailureReason.transactionReverted(txHash: "0xabc").isPermanent)
    XCTAssertFalse(SettleFailureReason.submissionFailed("decode error").isPermanent)
}

func testSettleFailureReason_description() {
    XCTAssertEqual(SettleFailureReason.channelNotOnChain.description, "Channel does not exist on-chain")
    XCTAssertEqual(SettleFailureReason.channelFinalized.description, "Channel is finalized")
    XCTAssertTrue(SettleFailureReason.gasInfoUnavailable("timeout").description.contains("timeout"))
    XCTAssertTrue(SettleFailureReason.transactionReverted(txHash: "0xabc").description.contains("0xabc"))
    XCTAssertTrue(SettleFailureReason.submissionFailed("RPC error").description.contains("RPC error"))
}
```

**Dependencies:** Steps 1, 2.

---

## Files Summary

| File | Action | Changes |
|------|--------|---------|
| `Sources/JanusShared/Tempo/ChannelSettler.swift` | Modify | Add `SettleFailureReason` enum with `isPermanent`/`description`, update `SettleResult.failed` type, update 5 return sites in `settle()` |
| `JanusApp/JanusProvider/ProviderEngine.swift` | Modify | Replace 2 string-matching blocks with enum pattern matching + `isPermanent` |
| `Tests/JanusSharedTests/OnChainTests.swift` | Modify | Update existing test's `.failed` handling, add 2 new unit tests |

**Total:** ~40 lines changed across 3 files (all modifications, no new files).

---

## What Does NOT Change

- `SettleResult.settled`, `.noVoucher`, `.alreadySettled` — unchanged
- `ChannelSettler.settle()` logic — same flow, just different return types
- `ProviderEngine` settlement flow — same behavior in the first loop; retry loop gains permanent-failure removal (deliberate improvement, see Step 5)
- Channel persistence / NWPathMonitor / `removeChannelIfMatch()` — unaffected
- Client-side code — unaffected (client never sees `SettleResult`)

---

## Backward Compatibility

- `SettleResult` is not persisted or serialized — it's a runtime return type
- No protocol changes, no wire format changes
- The only consumers are `ProviderEngine` and one test — both updated in this change

---

## Verification

1. **Build:** `swift test` passes, `xcodebuild` builds both targets
2. **Unit tests:** New `testSettleFailureReason_isPermanent` and `testSettleFailureReason_description` pass
3. **Existing test:** `testFullSettlementOnTempo` still compiles and passes (if live testnet available)
4. **Manual regression:** Connect client, send requests, disconnect — settlement flow works as before
5. **Exhaustiveness:** Add a hypothetical new case to `SettleFailureReason` — compiler should warn about unhandled cases in `isPermanent` and `description` (but NOT in `ProviderEngine`, which uses `isPermanent` instead of exhaustive matching)

---

## Risks

- **Low:** Mostly a pure refactor. One deliberate behavioral improvement: the retry loop now removes channels on permanent failures (previously it just logged). This prevents stale entries from accumulating.
- **`isPermanent` future maintenance:** When adding a new `SettleFailureReason` case, the developer must decide if it's permanent. The compiler enforces this via the `switch` in `isPermanent` — it won't compile until the new case is handled.

---

## Review Findings Incorporated

Based on **systems-architect review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| P1 | `transactionReverted` wrongly classified as transient — retrying burns gas for same revert | Changed to permanent in `isPermanent` (Step 2) |
| P1 | Step 5 pseudocode not valid Swift (`reason is channelNotOnChain pattern`) | Rewritten with proper `if case` pattern matching (Step 5) |
| P1 | Step 5 introduced behavioral change while claiming "no behavioral change" | Documented as deliberate improvement; updated Risks section |
| P2 | Missing `CustomStringConvertible` conformance | Added to enum declaration (Step 2) |

Based on **architecture-reviewer review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| P1 | `transactionReverted` wrongly classified as transient | Same fix as above (Step 2) |
| P2 | Retry loop `isRetry` check is dead code (pendingChannels only queued when `isRetry == false`) | Removed `isRetry` from retry loop; use `channelNotOnChain` pattern match directly (Step 5) |
| P2 | Missing `CustomStringConvertible` | Same fix as above (Step 2) |
| P3 | `isPermanent` vs exhaustive switch design trade-off | Confirmed sound — `isPermanent` is correct for this codebase |
| P3 | Test coverage gaps (no ProviderEngine branching unit test) | Accepted as follow-up — would require protocol extraction of ChannelSettler |

**Insight:** `ChannelOpener.OpenResult.failed(String)` has the same fragility. Not dangerous today (consumer just logs), but worth a follow-up if client needs to branch on opener failure modes.

**Confirmed sound:** Core design (enum + `isPermanent` + `CustomStringConvertible`), exhaustive handling in `isPermanent` with compiler enforcement, `channelNotOnChain` special-casing.
