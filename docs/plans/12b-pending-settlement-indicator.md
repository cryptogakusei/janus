# Feature: Provider UI — Pending Settlement Indicator

## Context

After #12b, the provider persists unsettled vouchers and retries settlement when internet returns. But the provider operator has **no visibility** into this:

- If the provider is offline and a client disconnects, settlement fails silently (just a log line)
- If the provider restarts with unsettled channels, there's no UI showing "you have money waiting to be claimed"
- The only way to know is to read the terminal logs or inspect `provider_state.json` manually

**Goal:** Show the provider operator how many credits are pending settlement, so they know money is waiting and can see when it gets claimed.

---

## Design Decisions

1. **Computed property + `didSet` on `channels`** — `pendingSettlementCredits` is derived from `channels`. To ensure SwiftUI re-renders when channels change (even without a co-occurring `@Published` mutation), add `didSet { objectWillChange.send() }` on `channels`. This is 1 line and eliminates an entire class of stale-UI bugs. (Both reviewers flagged `.alreadySettled` and permanent `.failed` paths as broken without this.)

2. **Stats strip, not a separate section** — Add a "Pending" stat to the existing stats strip (Served | Credits Earned | Connected | Sessions). This is the natural place — it's always visible, compact, and follows the existing pattern.

3. **Always-visible "Pending" stat** — Always show the "Pending" stat (with "0" in `.secondary` color when nothing pending, orange when non-zero). This avoids layout shift from the 5th item appearing/disappearing — each stat would jump ~20% in width otherwise. The operator also learns where to look.

4. **Orange color accent** — Orange signals "attention needed but not an error." The pending count uses orange text to distinguish it from the blue credits-earned counter.

5. **Settlement status pill** — Add a status pill in the status strip when settlement is in progress ("Settling...") or when there are pending credits ("Pending"). This gives at-a-glance status without reading the stats. The "Settling..." state works because `@MainActor` + `await` yields back to the run loop, allowing SwiftUI to render during the 20+ second settlement process.

---

## Implementation Steps

### Step 1: Add `didSet` on `channels` for SwiftUI reactivity

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift`

Add `didSet` to the `channels` property so SwiftUI re-renders when channels change:

```swift
private var channels: [String: Channel] = [:] {
    didSet { objectWillChange.send() }
}
```

Without this, `.alreadySettled` and permanent `.failed` paths in settlement remove channels via `removeChannelIfMatch` without any `@Published` mutation — the "Pending" indicator would show stale values. This also fixes the pre-existing reactivity gap for `clientSummaries`.

**Dependencies:** None.

---

### Step 2: Add `pendingSettlementCredits` computed property to `ProviderEngine`

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift`

```swift
/// Total credits pending on-chain settlement (unsettled vouchers across all channels).
var pendingSettlementCredits: Int {
    channels.values.reduce(0) { $0 + Int($1.unsettledAmount) }
}
```

Derived from `channels` — reactivity guaranteed by Step 1's `didSet`.

**Dependencies:** Step 1.

---

### Step 3: Expose `isSettling` as `@Published` for UI binding

**Modify:** `JanusApp/JanusProvider/ProviderEngine.swift`

Change `private var isSettling = false` to `@Published private(set) var isSettling = false`.

This lets the view show "Settling..." while settlement is in progress. The pill shows for the full duration because `@MainActor` + `await` yields back to the run loop at each suspension point.

**Dependencies:** None.

---

### Step 4: Add `valueColor` parameter to `statItem()`

**Modify:** `JanusApp/JanusProvider/ProviderStatusView.swift` — `statItem()`

```swift
private func statItem(value: String, label: String, valueColor: Color = .primary) -> some View {
    VStack(spacing: 2) {
        Text(value)
            .font(.title3.bold().monospacedDigit())
            .foregroundStyle(valueColor)
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
}
```

Existing callers keep the default `.primary`. The "Pending" stat will pass `.orange`.

**Dependencies:** None.

---

### Step 5: Add always-visible "Pending" stat to `statsStrip`

**Modify:** `JanusApp/JanusProvider/ProviderStatusView.swift` — `statsStrip`

Always show the "Pending" stat (avoids layout shift from conditional 5th item):

```swift
Divider().frame(height: 28)
statItem(
    value: "\(engine.pendingSettlementCredits)",
    label: "Pending",
    valueColor: engine.pendingSettlementCredits > 0 ? .orange : .secondary
)
```

When nothing is pending, shows "0" in `.secondary` (gray). When credits are pending, shows the count in orange. No layout shift — always 5 stat items.

**Dependencies:** Steps 2, 4.

---

### Step 6: Add settlement status pill to `statusStrip`

**Modify:** `JanusApp/JanusProvider/ProviderStatusView.swift` — `statusStrip`

Add a conditional pill that shows settlement state:

```swift
if engine.isSettling {
    statusPill(icon: "arrow.triangle.2.circlepath", color: .orange, label: "Settling...")
} else if engine.pendingSettlementCredits > 0 {
    statusPill(icon: "clock.arrow.circlepath", color: .orange, label: "Pending")
}
```

- **"Settling..."** with rotating arrows icon — shown during active settlement attempt
- **"Pending"** with clock icon — shown when there are unsettled credits but no active settlement

Neither pill shows when everything is settled (clean state).

**Dependencies:** Steps 2, 3.

---

## Files Summary

| File | Action | Changes |
|------|--------|---------|
| `JanusApp/JanusProvider/ProviderEngine.swift` | Modify | `didSet` on `channels`, `pendingSettlementCredits` computed property, `isSettling` → `@Published private(set)` |
| `JanusApp/JanusProvider/ProviderStatusView.swift` | Modify | Always-visible "Pending" stat in `statsStrip`, settlement status pill in `statusStrip`, `valueColor` param on `statItem()` |

**Total:** ~20 lines changed across 2 files (all modifications, no new files).

---

## What Does NOT Change

- Settlement logic — no changes to `settleAllChannelsOnChain()`, `retryPendingSettlements()`, or `NWPathMonitor`
- Persistence — no new persisted fields
- Client-side code — unaffected
- Existing stats (Served, Credits Earned, Connected, Sessions) — unchanged
- Channel management — `removeChannelIfMatch()` unchanged (channels `didSet` is additive)

---

## Verification

1. **Build:** `xcodebuild` builds the provider target
2. **Visual — normal flow:** Connect client, send requests, disconnect → "Pending" appears in stats strip → settlement succeeds → "Pending" disappears
3. **Visual — offline:** Disable WiFi → disconnect client → "Pending" shows with credit count → re-enable WiFi → "Settling..." pill briefly appears → "Pending" clears
4. **Visual — restart:** Force-quit with unsettled channels → relaunch → "Pending" shows restored amount → settlement retries → clears
5. **Visual — clean state:** No unsettled channels → "Pending" shows "0" in gray, no settlement pill

---

## Risks

- **Low:** Pure UI addition. No logic changes, no persistence changes, no protocol changes.
- **`channels` `didSet` overhead:** `objectWillChange.send()` fires on every `channels` mutation, which triggers a SwiftUI diff. Negligible — channel count is bounded by active clients (< 100 realistically), and the dict is value-type so `didSet` fires exactly once per mutation.

---

## Review Findings Incorporated

Based on **systems-architect review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| P0 | `pendingSettlementCredits` has stale-UI paths (`.alreadySettled`, permanent `.failed`) | Added `didSet { objectWillChange.send() }` on `channels` (Step 1) |
| P1 | Conditional stat item causes ~20% layout shift | Changed to always-visible with "0" in `.secondary` (Step 5) |
| P1 | `isSettling` + `@MainActor` + `await` interaction undocumented | Documented in Step 3 |

Based on **architecture-reviewer review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| Must-fix | Same stale-UI bug via `.alreadySettled` and permanent `.failed` paths | Same fix — `didSet` on `channels` (Step 1) |
| Should-fix | Layout instability from conditional stat | Same fix — always-visible (Step 5) |
| Consider | Show pending channel count alongside aggregate credits | Deferred — aggregate amount sufficient for v1 |
| Consider | Step ordering (Step 5 prerequisite for Step 3) | Reordered: `statItem` change is now Step 4, before Step 5 |

**Confirmed sound:** Computed property approach (with `didSet`), `isSettling` as `@Published`, no persistence changes, existing `statusPill()` reuse.
