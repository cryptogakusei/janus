# Feature #10: On-Chain Settlement Verification

## Context

After the provider settles a payment channel on-chain, the client has **zero visibility** into what happened. The provider extracts money from escrow, but the client never learns whether settlement occurred, how much was settled, or whether it matches what was owed. This is a trust gap — especially relevant for the dispute case where a provider takes payment without delivering a response.

This feature adds **client-side on-chain verification**: the client reads the blockchain directly to check settlement status. No provider cooperation needed — fully trustless.

## Current State

- Provider settles via `ChannelSettler.settle()` → gets `(txHash, amount)` → logs it → done
- Client tracks `spendState.cumulativeSpend` and `receipts` but nothing about settlement
- `EscrowClient.getChannel(channelId)` already exists and returns on-chain state including `settled` amount (`UInt128`)
- Client already makes RPC calls (channel opening), so infrastructure exists
- `Channel` is `Codable` and has a public `channelId: Data` (32 bytes)

---

## Design Decisions

1. **Pull-only, no push notification** — Settlement happens after the client disconnects (the normal flow), so a provider-sent notice would never arrive. Instead, the client reads the blockchain directly via `EscrowClient.getChannel()`. This is simpler and more trustworthy — the provider can't fake on-chain state.

2. **Persist `channelId` in `PersistedClientSession`** — The `Channel` object is reconstructed on reconnect via `setupTempoChannel()`, which creates a *new* channel. If we rely on `self.channel`, we'd verify the new channel, not the old one that was settled. Persisting `lastChannelId` captures the settled channel's identity.

3. **On-chain verification is on-demand** — Client calls `EscrowClient.getChannel()` when user taps "Verify On-Chain." Not automatic — avoids unnecessary RPC calls and works offline (the user can verify later).

4. **Three-state correctness check** — Compare on-chain `settled` against client's `cumulativeSpend`:
   - **Match** (settled == spend): green — provider settled exactly what was owed
   - **Overpayment** (settled > spend): red — provider over-claimed (possible if client missed a response)
   - **Underpayment** (settled < spend): yellow — partial settlement (could be in-progress or provider error)

5. **Show settlement section when `cumulativeSpend > 0`** — Not gated on receiving a notice. Any session that spent credits can verify settlement status.

6. **Forward verification state through `ClientEngine`** — Nested `@Published` on `SessionManager` won't trigger SwiftUI updates on `PromptView` (which observes `engine`). Forward `settlementStatus` as a `@Published` property on `ClientEngine`, matching the existing pattern for `responseHistory`.

7. **Future enhancement (v2):** Provider-side push notification with store-and-forward for reconnect delivery. Deferred — on-chain verification is the trustless foundation.

---

## Implementation Steps

### Step 1: Persist `lastChannelId` in `PersistedClientSession`

**Modify:** `Sources/JanusShared/Persistence/SessionStore.swift` — `PersistedClientSession`

Add fields:

```swift
/// Channel ID from the last active Tempo channel (for post-settlement verification).
public var lastChannelId: Data?
/// On-chain verified settlement amount (nil = not yet verified).
public var lastVerifiedSettlement: UInt64?
```

Add to `init` with defaults:

```swift
public init(
    // ... existing params ...,
    lastChannelId: Data? = nil,
    lastVerifiedSettlement: UInt64? = nil
) {
    // ... existing assignments ...
    self.lastChannelId = lastChannelId
    self.lastVerifiedSettlement = lastVerifiedSettlement
}
```

Add `decodeIfPresent` lines in custom decoder:

```swift
lastChannelId = try container.decodeIfPresent(Data.self, forKey: .lastChannelId)
lastVerifiedSettlement = try container.decodeIfPresent(UInt64.self, forKey: .lastVerifiedSettlement)
```

**Dependencies:** None.

---

### Step 2: SessionManager — persist channelId and add verification method

**Modify:** `JanusApp/JanusClient/SessionManager.swift`

Add published properties:

```swift
@Published var lastChannelId: Data?
@Published var lastVerifiedSettlement: UInt64?
```

Update `setupTempoChannel()` — after creating the channel, snapshot its ID:

```swift
// After: self.channel = channel
self.lastChannelId = channel.channelId
persist()
```

Update `persist()` — pass new fields to `PersistedClientSession`:

```swift
let state = PersistedClientSession(
    privateKeyBase64: clientKeyPair.privateKeyBase64,
    sessionGrant: sessionGrant,
    spendState: spendState,
    receipts: receipts,
    history: history,
    ethPrivateKeyHex: ethKeyPair?.privateKeyData.ethHexPrefixed,
    lastChannelId: lastChannelId,
    lastVerifiedSettlement: lastVerifiedSettlement
)
```

Update `init(persisted:walletProvider:store:)` — restore new fields:

```swift
self.lastChannelId = persisted.lastChannelId
self.lastVerifiedSettlement = persisted.lastVerifiedSettlement
```

Add on-chain verification method:

```swift
/// Verify settlement on-chain by reading the escrow contract directly.
/// Compares on-chain settled amount against client's cumulative spend.
func verifySettlementOnChain() async -> SettlementStatus? {
    guard let channelId = lastChannelId else { return nil }
    let escrow = EscrowClient(config: tempoConfig)
    do {
        let onChain = try await escrow.getChannel(channelId: channelId)
        guard let settled = onChain.settled.toUInt64 else {
            print("WARNING: settled amount exceeds UInt64 range")
            return nil
        }
        lastVerifiedSettlement = settled
        persist()

        let expected = spendState.cumulativeSpend
        if settled == expected {
            return .match(settled: settled)
        } else if settled > expected {
            return .overpayment(settled: settled, expected: expected)
        } else {
            return .underpayment(settled: settled, expected: expected)
        }
    } catch {
        print("On-chain verification failed: \(error)")
        return nil
    }
}
```

**Dependencies:** Step 1.

---

### Step 3: Define `SettlementStatus` enum

**Create:** `Sources/JanusShared/Protocol/SettlementStatus.swift`

```swift
/// Result of comparing on-chain settlement against client's expected spend.
public enum SettlementStatus: Equatable, Sendable {
    /// Settled amount matches cumulative spend exactly.
    case match(settled: UInt64)
    /// Provider settled more than client authorized.
    case overpayment(settled: UInt64, expected: UInt64)
    /// Provider settled less than client authorized (partial or in-progress).
    case underpayment(settled: UInt64, expected: UInt64)
    /// Verification not yet attempted.
    case unverified

    public var settled: UInt64 {
        switch self {
        case .match(let s): return s
        case .overpayment(let s, _): return s
        case .underpayment(let s, _): return s
        case .unverified: return 0
        }
    }
}
```

**Dependencies:** None.

---

### Step 4: Forward verification state through `ClientEngine`

**Modify:** `JanusApp/JanusClient/ClientEngine.swift`

Add published property (matches pattern used for `responseHistory`):

```swift
@Published var settlementStatus: SettlementStatus = .unverified
```

Add method to trigger verification and update the published state:

```swift
func verifySettlement() {
    Task {
        if let status = await sessionManager?.verifySettlementOnChain() {
            settlementStatus = status
        }
    }
}
```

Update `createSession()` — restore verification state from session:

```swift
// After restoring or creating sessionManager:
if let verified = sessionManager?.lastVerifiedSettlement {
    let expected = sessionManager?.spendState.cumulativeSpend ?? 0
    if verified == expected {
        settlementStatus = .match(settled: verified)
    } else if verified > expected {
        settlementStatus = .overpayment(settled: verified, expected: expected)
    } else {
        settlementStatus = .underpayment(settled: verified, expected: expected)
    }
} else {
    settlementStatus = .unverified
}
```

**Dependencies:** Steps 2, 3.

---

### Step 5: Client UI — settlement verification section

**Modify:** `JanusApp/JanusClient/PromptView.swift`

Add settlement section below the balance bar (shown when session has spent credits):

```swift
if let session = engine.sessionManager, session.spendState.cumulativeSpend > 0 {
    settlementSection
}
```

Settlement section implementation:

```swift
private var settlementSection: some View {
    let spent = engine.sessionManager?.spendState.cumulativeSpend ?? 0
    let status = engine.settlementStatus

    return VStack(alignment: .leading, spacing: 6) {
        HStack {
            Image(systemName: "checkmark.shield")
            Text("Settlement")
                .font(.subheadline.bold())
            Spacer()
            statusBadge(status)
        }
        HStack {
            Text("\(spent) credits spent")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if case .unverified = status {
                // nothing
            } else {
                Text("\(status.settled) settled on-chain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if case .unverified = status {
            Button("Verify On-Chain") {
                engine.verifySettlement()
            }
            .font(.caption.bold())
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(statusBackground(status))
    .cornerRadius(10)
}

@ViewBuilder
private func statusBadge(_ status: SettlementStatus) -> some View {
    switch status {
    case .match:
        Text("Verified")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.green.opacity(0.1))
            .cornerRadius(4)
    case .overpayment:
        Text("Overpayment")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red.opacity(0.1))
            .cornerRadius(4)
    case .underpayment:
        Text("Partial")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.1))
            .cornerRadius(4)
    case .unverified:
        EmptyView()
    }
}

private func statusBackground(_ status: SettlementStatus) -> Color {
    switch status {
    case .match: return .green.opacity(0.05)
    case .overpayment: return .red.opacity(0.05)
    case .underpayment: return .orange.opacity(0.05)
    case .unverified: return .gray.opacity(0.05)
    }
}
```

**Dependencies:** Steps 3, 4.

---

## Files Summary

| File | Action | Changes |
|------|--------|---------|
| `Sources/JanusShared/Persistence/SessionStore.swift` | Modify | Add `lastChannelId` + `lastVerifiedSettlement` to `PersistedClientSession` |
| `Sources/JanusShared/Protocol/SettlementStatus.swift` | Create | New `SettlementStatus` enum |
| `JanusApp/JanusClient/SessionManager.swift` | Modify | Persist channelId, `verifySettlementOnChain()` method, restore on init |
| `JanusApp/JanusClient/ClientEngine.swift` | Modify | Forward `settlementStatus`, `verifySettlement()` method |
| `JanusApp/JanusClient/PromptView.swift` | Modify | Settlement verification section with three-state badge |

**Total:** ~100 lines across 5 files (1 new file, 4 modifications).

---

## What Does NOT Change

- `ChannelSettler` — settlement logic unchanged
- `EscrowClient` — already has `getChannel()`, no modifications needed
- `Channel` — client-side channel unchanged
- `MessageEnvelope` / `MessageType` — no new message types needed
- Transport layer — no send infrastructure needed
- Provider-side code — **zero provider changes**

---

## Verification

1. **Normal flow:** Connect → send requests → disconnect → provider settles → client reopens app → sees "Verify On-Chain" button → taps → sees "Verified" badge with matching amount
2. **Overpayment detection:** Provider settles more than client's `cumulativeSpend` → red "Overpayment" badge
3. **Partial settlement:** Provider settles less than `cumulativeSpend` → orange "Partial" badge (could be in-progress)
4. **Not yet settled:** Client verifies before provider settles → `settled == 0` → "Partial" badge (underpayment case)
5. **Backward compat:** Existing `client_session.json` without `lastChannelId` field loads correctly (nil)
6. **Channel replacement:** Client reconnects, new channel created → `lastChannelId` still points to old channel → verification checks the right channel
7. **Persisted verification:** Verify once → kill app → reopen → "Verified" badge restored from persistence (no re-fetch needed)

---

## Risks

- **Low.** Adds a read-only on-chain query and UI section. No changes to settlement logic, transport, or payment flow. Zero provider-side changes.
- **RPC dependency:** Verification requires internet access to the Tempo testnet RPC. If RPC is down, verification fails gracefully (returns nil, button stays available).
- **`toUInt64` overflow:** If on-chain `settled` exceeds `UInt64.max`, verification returns nil with a warning log. Practically impossible for this application.

---

## Review Findings Incorporated

Based on **systems-architect** and **architecture-reviewer** feedback on the original push-based plan:

| Severity | Finding | Resolution |
|----------|---------|------------|
| Critical | SettlementNotice never delivered (client disconnected during settlement) | Dropped push model entirely — pull-only from blockchain |
| Important | UI gated on non-empty notices — verify button hidden when most needed | Show section whenever `cumulativeSpend > 0` |
| Important | No correctness comparison against client spend | Three-state comparison: match / overpayment / underpayment |
| Important | Persistence round-trip incomplete | Fully specified: init, persist(), restore all shown |
| Should-fix | `verifySettlementOnChain()` used current channel (could be replaced) | Persist `lastChannelId` separately — survives channel replacement |
| Nice-to-have | Nested `@Published` won't trigger SwiftUI update | Forward `settlementStatus` through `ClientEngine` |

---

## Future Enhancements (v2)

- **Provider push notification with store-and-forward:** Provider persists unsent notices keyed by `clientIdentity`, re-sends on reconnect. Layer on top of pull verification as an optimization for instant UX.
- **Automatic verification on session restore:** When app launches and a session has `cumulativeSpend > 0` and `lastVerifiedSettlement == nil`, auto-verify in background.
- **Settlement history view:** Show all past sessions with their verification status across providers.
