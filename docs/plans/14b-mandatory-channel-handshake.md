# Feature #14b: Mandatory On-Chain Channel Handshake

## Context

Currently the client opens its payment channel on-chain **in the background** while already sending inference requests. The provider accepts `acceptedOffChainOnly` and serves inference optimistically. This means:

- A malicious client can get unlimited free inference by never opening a channel
- The provider has no on-chain escrow backing the vouchers it accepts
- Settlement will fail when the provider eventually tries to claim payment

The original #14b proposal ("cap off-chain exposure") would serve one request optimistically and require on-chain confirmation for subsequent requests. But there's a cleaner design: **make channel opening a prerequisite for inference, not a background task.**

This aligns with the offline-first architecture: the initial handshake requires internet (on-chain transactions), but once the channel is verified, all subsequent inference can happen fully offline.

## Design Decisions

1. **Client gates `sessionReady` on channel confirmation** — The submit button stays disabled until `channelOpenedOnChain == true`. The user sees a progress indicator during channel setup. This is honest UX: the user is waiting for a real financial transaction.

2. **Provider rejects `channelNotFoundOnChain` as defense-in-depth** — Even if a modified client bypasses the UI gate, the provider sends back an error. The client can retry after channel opens. Belt-and-suspenders: client-side UX gate + provider-side enforcement.

3. **Split `acceptedOffChainOnly` into two cases** — The current `ChannelVerificationResult` conflates "channel doesn't exist on-chain" with "RPC call failed". These require opposite trust decisions:
   - `.channelNotFoundOnChain` → reject (channel was never opened)
   - `.rpcUnavailable` → accept (provider can't reach chain, but may have verified earlier; needed for offline inference after handshake)

   Without this split, any RPC failure would reject legitimate clients who already completed the handshake — breaking the offline-first architecture.

4. **No separate `channelReady` property** — `sessionReady` already gates the submit button. We just delay setting `sessionReady = true` until channel confirmation. Adding a redundant `channelReady` flag creates sync bugs.

5. **Persist `channelOpenedOnChain` in `PersistedClientSession`** — Currently `channelOpenedOnChain` is a plain `var` on `SessionManager` (not persisted). If the client restarts after opening, the restored session won't know the channel is open → user stuck at spinner. Must persist it.

6. **Progress UI with three stages** — "Funding wallet...", "Approving token...", "Opening channel..." so the user sees forward progress during the ~15s wait. Maps directly to the three `ChannelOpener` steps.

7. **Channel open failure shows retry** — If `openChannelOnChain()` fails (e.g., faucet down, contract error), show the error with a "Retry" button. No inference is served until the channel opens.

8. **Typed error codes, not string matching** — The provider uses a specific `ErrorResponse.ErrorCode` for channel-not-ready, and the client matches on the code, not error message text. Avoids fragile string matching.

---

## Current Flow (Before)

```
Client connects → setupTempoChannel() → [openChannelOnChain() in background]
                                        ↓ (immediately, without waiting)
                                   sessionReady = true
                                        ↓
                              User can submit requests
                                        ↓
                        Provider: acceptedOffChainOnly → serve anyway
```

## Proposed Flow (After)

```
Client connects → setupTempoChannel() → openChannelOnChain()
                                        ↓
                              UI: "Opening payment channel..."
                              Submit button disabled
                                        ↓ (channel confirmed on-chain)
                              channelOpenedOnChain = true (persisted)
                              sessionReady = true
                                        ↓
                              User can submit requests
                                        ↓
                        Provider: acceptedOnChain → serve
                                  channelNotFoundOnChain → reject
                                  rpcUnavailable → accept (offline-safe)
```

---

## Implementation Steps

### Step 1: Split `acceptedOffChainOnly` in `ChannelVerificationResult`

**Modify:** `Sources/JanusShared/Verification/VoucherVerifier.swift`

Replace the single `acceptedOffChainOnly` case with two distinct cases:

```swift
public enum ChannelVerificationResult: Sendable {
    /// Channel verified against on-chain state.
    case acceptedOnChain(onChainDeposit: UInt64, onChainSettled: UInt64)
    /// Channel queried on-chain but does not exist yet.
    case channelNotFoundOnChain
    /// Off-chain checks passed, but RPC was unavailable (no URL configured, or call failed).
    case rpcUnavailable
    /// Verification failed.
    case rejected(reason: String)

    public var isAccepted: Bool {
        switch self {
        case .acceptedOnChain, .rpcUnavailable: return true
        case .channelNotFoundOnChain, .rejected: return false
        }
    }
}
```

Update `verifyChannelInfoOnChain()` to use the new cases:

```swift
// No RPC URL configured:
guard config.rpcURL != nil else {
    return .rpcUnavailable
}

// Channel queried but doesn't exist:
guard onChain.exists else {
    return .channelNotFoundOnChain
}

// RPC call failed:
} catch {
    return .rpcUnavailable
}
```

**Note:** `isAccepted` now returns `false` for `channelNotFoundOnChain` — this is the key behavioral change. Existing call sites using `result.isAccepted` will automatically reject unverified channels.

**Dependencies:** None.

---

### Step 2: Persist `channelOpenedOnChain` in `PersistedClientSession`

**Modify:** `Sources/JanusShared/Persistence/SessionStore.swift`

Add to `PersistedClientSession`:

```swift
/// Whether the on-chain channel was successfully opened (survives app restart).
public var channelOpenedOnChain: Bool
```

Add to `init` with default `false`:

```swift
channelOpenedOnChain: Bool = false
```

Add backward-compatible decoding:

```swift
channelOpenedOnChain = try container.decodeIfPresent(Bool.self, forKey: .channelOpenedOnChain) ?? false
```

**Modify:** `JanusApp/JanusClient/SessionManager.swift` — `persist()`

Add `channelOpenedOnChain` to the `PersistedClientSession(...)` constructor call.

**Dependencies:** None.

---

### Step 3: Gate `sessionReady` on channel confirmation

**Modify:** `JanusApp/JanusClient/ClientEngine.swift`

In `createSession()` — for new sessions, don't set `sessionReady = true` immediately. Instead, observe the channel opening via `SessionManager`'s `$channelOpenedOnChain`:

```swift
// After setupTempoChannel():
manager.$channelOpenedOnChain
    .filter { $0 }
    .first()
    .receive(on: RunLoop.main)
    .sink { [weak self] _ in
        self?.sessionReady = true
    }
    .store(in: &cancellables)
```

For restored sessions where `channelOpenedOnChain` is already `true`:

```swift
if restored.channelOpenedOnChain {
    sessionReady = true
} else {
    // Channel wasn't opened last time — retry
    restored.retryChannelOpenIfNeeded()
    restored.$channelOpenedOnChain
        .filter { $0 }
        .first()
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.sessionReady = true
        }
        .store(in: &cancellables)
}
```

**Note:** `SessionManager` IS an `ObservableObject` with `@Published` properties, so Combine sinks work directly. No callback mechanism needed.

**Dependencies:** Step 2 (persistence), Step 4 (Combine `cancellables`).

---

### Step 4: Add Combine cancellables to ClientEngine

**Modify:** `JanusApp/JanusClient/ClientEngine.swift`

Add a cancellable set if one doesn't already exist:

```swift
import Combine
private var cancellables = Set<AnyCancellable>()
```

Also forward `channelOnChainStatus` for the progress UI:

```swift
manager.$channelOnChainStatus
    .receive(on: RunLoop.main)
    .assign(to: &$channelStatus)
```

Add the published property:

```swift
@Published var channelStatus: String = ""
```

Reset `channelStatus` and cancel subscriptions on disconnect.

**Dependencies:** None.

---

### Step 5: Granular channel opening progress

**Modify:** `JanusApp/JanusClient/SessionManager.swift` — `openChannelOnChain()`

Update `channelOnChainStatus` at each stage:

```swift
channelOnChainStatus = "Funding wallet..."
// faucet call
channelOnChainStatus = "Approving token spend..."
// approve tx
channelOnChainStatus = "Opening payment channel..."
// open tx
channelOnChainStatus = "Channel open on-chain"
channelOpenedOnChain = true
persist()  // <-- persist the flag immediately
```

Also persist `channelOpenedOnChain = true` on the `.alreadyOpen` path.

**Dependencies:** Step 2 (persistence of `channelOpenedOnChain`).

---

### Step 6: Show channel progress in PromptView

**Modify:** `JanusApp/JanusClient/PromptView.swift`

Show a progress banner when connected but session not ready:

```swift
if engine.connectedProvider != nil && !engine.sessionReady {
    HStack(spacing: 8) {
        ProgressView().scaleEffect(0.8)
        VStack(alignment: .leading, spacing: 2) {
            Text("Setting up payment channel...")
                .font(.caption.bold())
            if !engine.channelStatus.isEmpty {
                Text(engine.channelStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(.blue.opacity(0.08))
    .cornerRadius(8)
}
```

If channel opening fails, show the error with a retry button:

```swift
if let channelError = engine.channelOpenError {
    VStack(spacing: 8) {
        Text("Channel setup failed: \(channelError)")
            .font(.caption)
            .foregroundStyle(.red)
        Button("Retry") { engine.retryChannelOpen() }
    }
}
```

`canSubmit` already gates on `sessionReady`, so no other changes needed.

**Dependencies:** Steps 4, 5.

---

### Step 7: Provider rejects unverified channels (defense-in-depth)

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift` — `handlePromptRequest()`

Replace the current `guard result.isAccepted` with an explicit switch:

```swift
let result = await vv.verifyChannelInfoOnChain(info)
switch result {
case .acceptedOnChain:
    break  // proceed — channel confirmed on-chain
case .rpcUnavailable:
    break  // proceed — can't reach chain, trust off-chain checks (supports offline inference)
case .channelNotFoundOnChain:
    sendError(requestID: request.requestID, sessionID: request.sessionID,
              code: .channelNotReady, message: "Channel not yet opened on-chain.")
    return
case .rejected(let reason):
    sendError(requestID: request.requestID, sessionID: request.sessionID,
              code: .invalidSession, message: "Channel rejected: \(reason)")
    return
}
```

**Note:** `.rpcUnavailable` is accepted because the provider may have already verified this channel on-chain during the handshake. Rejecting here would break offline inference. The client-side gate (Step 3) is the primary defense; the provider rejection of `.channelNotFoundOnChain` is defense-in-depth.

**Dependencies:** Step 1 (new enum cases), Step 8 (new error code).

---

### Step 8: Add `channelNotReady` error code

**Modify:** `Sources/JanusShared/Protocol/Messages.swift` (or wherever `ErrorResponse.ErrorCode` is defined)

Add a new error code:

```swift
case channelNotReady
```

This gives the client a typed code to match on, rather than fragile string matching.

**Dependencies:** None.

---

### Step 9: Handle `channelNotReady` error on client

**Modify:** `JanusApp/JanusClient/ClientEngine.swift` — error handling

If the provider returns `.channelNotReady`, handle it gracefully rather than showing a raw error:

```swift
case .channelNotReady:
    // Channel still opening — don't show as a hard error
    requestState = .idle
    // sessionReady will flip to true soon via the Combine subscription, re-enabling submit
```

This shouldn't normally happen (Step 3 gates submission), but handles the race window where the client sends a request just as the channel opens.

**Dependencies:** Steps 7, 8.

---

### Step 10: Update ProviderEngine's existing `acceptedOffChainOnly` references

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift`

Update the diagnostic logging that currently references `acceptedOffChainOnly`:

```swift
// Line ~593 (current): case .acceptedOffChainOnly: verifyStatus = "off-chain only"
// Replace with:
case .channelNotFoundOnChain: verifyStatus = "not found on-chain"
case .rpcUnavailable: verifyStatus = "RPC unavailable (off-chain only)"
```

**Dependencies:** Step 1.

---

### Step 11: Update tests

**Modify:** `Tests/JanusSharedTests/OnChainTests.swift`

Update any tests referencing `acceptedOffChainOnly` to use the new cases. The existing test that creates `ChannelVerificationResult.acceptedOnChain(onChainDeposit: 1000, onChainSettled: 0)` is fine. Add a test for `channelNotFoundOnChain` being rejected by `isAccepted`.

**Modify:** `Tests/JanusSharedTests/PersistenceTests.swift`

Add a test for round-tripping `channelOpenedOnChain` through `PersistedClientSession` encode/decode.

**Dependencies:** Steps 1, 2.

---

## Files Summary

| File | Action | Changes |
|------|--------|---------|
| `Sources/JanusShared/Verification/VoucherVerifier.swift` | Modify | Split `acceptedOffChainOnly` → `channelNotFoundOnChain` + `rpcUnavailable`; update `isAccepted` |
| `Sources/JanusShared/Persistence/SessionStore.swift` | Modify | Add `channelOpenedOnChain: Bool` to `PersistedClientSession` |
| `Sources/JanusShared/Protocol/Messages.swift` | Modify | Add `.channelNotReady` error code |
| `JanusApp/JanusClient/SessionManager.swift` | Modify | Granular status updates in `openChannelOnChain()`, persist `channelOpenedOnChain` |
| `JanusApp/JanusClient/ClientEngine.swift` | Modify | Gate `sessionReady` on channel confirmation via Combine, forward `channelStatus`, handle `.channelNotReady` error |
| `JanusApp/JanusClient/PromptView.swift` | Modify | Show channel progress banner + retry button on failure |
| `JanusApp/JanusProvider/ProviderEngine.swift` | Modify | Explicit switch on verification result, reject `channelNotFoundOnChain`, accept `rpcUnavailable` |
| `Tests/JanusSharedTests/OnChainTests.swift` | Modify | Update for new enum cases |
| `Tests/JanusSharedTests/PersistenceTests.swift` | Modify | Add `channelOpenedOnChain` round-trip test |

**Total:** ~80 lines across 9 files (all modifications).

---

## What Does NOT Change

- `ChannelOpener` — opening logic unchanged
- `Channel.swift` — no changes
- `ChannelSettler` — settlement unchanged
- Transport layer — unaffected
- Existing voucher verification in `VoucherVerifier.verify()` — unchanged

---

## Verification

1. **New session flow:** Connect to provider → see "Funding wallet..." → "Approving token..." → "Opening channel..." → submit button enables → inference works
2. **Restored session (channel already open):** App restart → session restored → `channelOpenedOnChain == true` from persistence → submit button immediately enabled
3. **Restored session (channel NOT opened):** App killed during opening → restart → `channelOpenedOnChain == false` → retry runs → progress shows → button enables
4. **Channel open failure:** Disable WiFi during opening → error + retry button shown → re-enable WiFi → tap retry → succeeds
5. **Provider defense-in-depth:** Modified client that skips wait → sends request → provider returns `.channelNotReady`
6. **Offline inference after handshake:** Open channel → disable WiFi → send requests → all work (provider gets `.rpcUnavailable` → accepts, channel was verified earlier)
7. **Settlement after offline session:** Re-enable WiFi → disconnect → provider settles on-chain
8. **Provider with no RPC URL:** Returns `.rpcUnavailable` → accepts (backward compatible for setups without RPC)

---

## Risks

- **Faucet downtime:** Client can't fund → stuck at progress. Mitigation: retry button + clear error message. On mainnet, user funds their own wallet.
- **15-second wait on every new session:** One-time cost, skipped on restore. Granular progress makes it feel shorter.
- **Race window on submit:** Client submits right as channel opens → provider might see `channelNotFoundOnChain` (block propagation). Client gets `.channelNotReady`, silently retries when `sessionReady` flips.
- **RPC-unavailable acceptance:** Provider accepts `.rpcUnavailable` even if the channel was never opened (e.g., RPC was down during the entire session). Mitigation: client-side gate is the primary defense; this is defense-in-depth. A future enhancement could cache the last successful on-chain verification per channel.

---

## Review Findings Incorporated

Based on **systems-architect review**:

| Severity | Finding | Resolution |
|----------|---------|------------|
| HIGH | `channelOpenedOnChain` not persisted — breaks offline restore | Added to `PersistedClientSession` with backward-compat decoding (Step 2) |
| HIGH | RPC failure returns `acceptedOffChainOnly` → rejects legit clients offline | Split into `channelNotFoundOnChain` (reject) vs `rpcUnavailable` (accept) (Step 1) |
| MEDIUM | Error string matching fragile | Added typed `.channelNotReady` error code (Step 8) |
| MEDIUM | No retry button on channel failure | Added retry UI (Step 6) |

Based on **architecture-reviewer review**:

| Severity | Finding | Resolution |
|----------|---------|------------|
| P0 | RPC failure conflated with "channel not opened" | Split `acceptedOffChainOnly` → two cases (Step 1) |
| P1 | `channelOpenedOnChain` NOT in `PersistedClientSession` | Added with backward compat (Step 2) |
| P2 | Plan uncertain about SessionManager being ObservableObject | Confirmed it IS; use Combine sinks directly (Step 3) |
| P3 | `channelReady` redundant with `sessionReady` | Dropped — just gate `sessionReady` on channel (Step 3) |
