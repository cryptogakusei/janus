# Fix #12a: First-Query Failure After Provider Switch

## Context

When a user is already on `PromptView` and the provider connection transitions (disconnect → reconnect to same or different provider), the user can submit a request during the transition window. The request uses the **old** provider's session state and gets sent to the **new** provider, which rejects it with "Unknown session."

## Root Cause Analysis

### What ISN'T the problem

The originally suspected race — "channel not opened on-chain when first query sent" — is **not** a real issue:

- `setupTempoChannel()` creates the `Channel` object **synchronously** (`SessionManager.swift` line ~223). The on-chain `Task { await openChannelOnChain() }` is fire-and-forget.
- `VoucherVerifier.verifyChannelInfoOnChain()` returns `.acceptedOffChainOnly` when the channel isn't on-chain yet (line ~145), which **is accepted**. The provider tolerates pre-on-chain channels.
- `Channel.init` sets `state = .open` immediately, so the separate `VoucherVerifier.verify()` check (`channel.state == .open`) also passes for provider-created channels.
- The `DiscoveryView` navigation gate (`sessionReady`) prevents users from reaching `PromptView` before the session is fully set up.

### What IS the problem

`PromptView.canSubmit` (line ~184) checks:
1. Non-empty prompt text
2. Request state is idle/complete/error
3. `canAffordRequest` (session has credits)
4. `connectedProvider != nil`

**Missing check: `sessionReady`.** This allows submission during the stale-session window because `connectedProvider` is set immediately on transport connect, before `sessionManager` is updated.

The `guard let session = sessionManager` in `submitRequest()` is also insufficient — `sessionManager` is never nil'd on disconnect (by design, for persistence), so it always passes but may reference the **wrong provider's** session.

**Race timeline:**
```
T+0ms    Provider A disconnects
         → connectedProvider = nil → canSubmit = false (good)
         → sessionReady = false
T+5ms    Provider B connects
         → connectedProvider = ProviderB → canSubmit = true (BAD!)
         → createSession(providerB.providerID) called
T+6ms    [New session path] Task { await SessionManager.create(...) } starts
         sessionManager STILL points to Provider A's session
T+6-50ms User taps Submit
         → submitRequest() uses Provider A's sessionID + channelInfo
         → Transport sends to Provider B
         → Provider B: "Unknown session. Include channelInfo on first request."
T+200ms  SessionManager.create() completes
         → sessionManager = new session for Provider B
         → sessionReady = true
```

For **restored sessions** (same or previously-seen provider), `createSession()` is synchronous — `sessionManager = restored` and `sessionReady = true` happen in the same MainActor turn. The race window is effectively zero. The bug only manifests with **new** sessions (first time connecting to a provider).

### Secondary issues

1. **No connection feedback in PromptView:** When the connection drops, the button disables but re-enables immediately when a new provider connects (before session is ready). No visual indicator of the transition.

2. **Stale async Task on rapid switching:** If user switches A→B→C quickly, the async Task from B's `createSession()` can complete after C is connected, overwriting `sessionManager` with B's session and setting `sessionReady = true` for the wrong provider.

3. **Existing `disconnectedBanner` and auto-dismiss:** PromptView already has a disconnect banner (line 23-25) and a 2-second auto-dismiss `onChange` (line 52-61). The banner would conflict with a new reconnection indicator, and the auto-dismiss contradicts graceful reconnection handling.

---

## Design Decisions

1. **Add `sessionReady` to `canSubmit`** — Replaces the weaker `connectedProvider != nil` check. `sessionReady` is `false` during disconnect and only becomes `true` after `sessionManager` is set to the correct session. Strict superset: implies both connected AND session-ready.

2. **Add `sessionReady` guard in `submitRequest()` as defense-in-depth** — Even if `canSubmit` is bypassed (programmatic call, race in SwiftUI rendering), `submitRequest()` should refuse to send with a stale session.

3. **Generation counter for `createSession()`** — Prevents stale async session-creation Tasks from overwriting current state on rapid provider switching. Classic concurrency pattern: increment counter before async work, discard result if counter has moved on.

4. **Set `sessionReady = false` at top of `createSession()`** — Makes the invariant explicit rather than relying on the disconnect handler having run first. One line, zero risk.

5. **Unify status banner in PromptView** — Replace the existing `disconnectedBanner` + `onChange` auto-dismiss with a single tri-state indicator. Prioritized: (1) disconnect-during-request error, (2) disconnected/reconnecting, (3) session-setting-up.

6. **Remove auto-dismiss on disconnect** — The 2-second `onChange` auto-dismiss is too aggressive for reconnection scenarios. Users may be composing a prompt and just need to wait. The unified banner provides a manual "Back" button for intentional navigation.

7. **Defer `promptText` clearing** — Move `promptText = ""` from immediately after `submitRequest()` to after confirming the request wasn't rejected by the defense-in-depth guard.

---

## Implementation Steps

### Step 1: Add generation counter to `createSession()`

**Modify:** `JanusApp/JanusClient/ClientEngine.swift`

Add a generation counter to discard stale async completions:

```swift
// New property:
private var sessionCreationGeneration = 0

func createSession(providerID: String) {
    sessionReady = false  // Explicit reset — don't rely on disconnect handler
    sessionCreationGeneration += 1
    let expectedGeneration = sessionCreationGeneration

    if let restored = SessionManager.restore(providerID: providerID, walletProvider: walletProvider) {
        sessionManager = restored
        responseHistory = restored.history
        if restored.channel == nil, let ethAddr = connectedProvider?.providerEthAddress, !ethAddr.isEmpty {
            restored.setupTempoChannel(providerEthAddress: ethAddr)
        } else {
            restored.retryChannelOpenIfNeeded()
        }
        sessionReady = true
        // ... existing log
    } else {
        Task {
            let manager = await SessionManager.create(providerID: providerID, walletProvider: walletProvider)
            // Discard if a newer createSession() has been called
            guard sessionCreationGeneration == expectedGeneration else {
                print("Discarding stale session creation for \(providerID.prefix(8))...")
                return
            }
            if let ethAddr = connectedProvider?.providerEthAddress, !ethAddr.isEmpty {
                manager.setupTempoChannel(providerEthAddress: ethAddr)
            }
            sessionManager = manager
            responseHistory = []
            sessionReady = true
        }
    }
}
```

**Why:** Without this, rapid A→B→C switching causes B's stale Task to set `sessionManager` to B's session after C is already connected — the exact same class of bug we're fixing.

**Dependencies:** None.

---

### Step 2: Gate `canSubmit` on `sessionReady`

**Modify:** `JanusApp/JanusClient/PromptView.swift` — `canSubmit`

Replace `engine.connectedProvider != nil` with `engine.sessionReady`:

```swift
private var canSubmit: Bool {
    !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    && (engine.requestState == .idle || engine.requestState == .complete || engine.requestState == .error)
    && engine.canAffordRequest
    && engine.sessionReady
}
```

**Dependencies:** None.

---

### Step 3: Add defense-in-depth guard in `submitRequest()`

**Modify:** `JanusApp/JanusClient/ClientEngine.swift` — `submitRequest()`

Add a `sessionReady` check after the existing `sessionManager` guard:

```swift
func submitRequest(taskType: TaskType, promptText: String, parameters: PromptRequest.Parameters) {
    guard let session = sessionManager else {
        errorMessage = "No active session"
        requestState = .error
        return
    }

    guard sessionReady else {
        errorMessage = "Session is being set up. Please wait."
        requestState = .error
        return
    }

    // ... rest unchanged
}
```

**Dependencies:** None.

---

### Step 4: Defer `promptText` clearing in PromptView

**Modify:** `JanusApp/JanusClient/PromptView.swift` — `submit()`

Only clear prompt text if the request was accepted (not rejected by defense-in-depth guard):

```swift
private func submit() {
    let params: PromptRequest.Parameters
    var fullPrompt = promptText
    // ... existing task-specific setup ...

    let savedPrompt = promptText
    engine.submitRequest(taskType: selectedTask, promptText: fullPrompt, parameters: params)

    // Only clear if request was accepted (not rejected by guard)
    if engine.requestState != .error {
        promptText = ""
    }
}
```

**Why:** Currently `promptText = ""` runs unconditionally. If the defense-in-depth guard rejects (setting `requestState = .error`), the user's text is destroyed.

**Dependencies:** Step 3.

---

### Step 5: Unify status banner and remove auto-dismiss

**Modify:** `JanusApp/JanusClient/PromptView.swift`

**5a. Replace the existing banner condition** (line 23-25):

```swift
// Replace:
if engine.disconnectedDuringRequest || engine.connectedProvider == nil {
    disconnectedBanner
}

// With unified tri-state banner:
if engine.disconnectedDuringRequest {
    // Disconnect happened during an active request — show error with Back button
    disconnectedBanner
} else if !engine.sessionReady {
    // Disconnected or reconnecting — show status
    reconnectingBanner
}
```

**5b. Add `reconnectingBanner` view:**

```swift
private var reconnectingBanner: some View {
    HStack(spacing: 6) {
        if engine.connectedProvider != nil {
            ProgressView().scaleEffect(0.7)
            Text("Setting up session...")
                .font(.subheadline)
        } else {
            Image(systemName: "wifi.slash")
            Text("Reconnecting to provider...")
                .font(.subheadline)
            Spacer()
            Button("Back") { dismiss() }
                .font(.subheadline.bold())
        }
    }
    .padding()
    .background(.orange.opacity(0.15))
    .cornerRadius(10)
}
```

**5c. Remove the `onChange` auto-dismiss** (line 52-61):

Delete the entire `onChange(of: engine.connectedProvider == nil)` block. The unified banner provides a manual "Back" button when disconnected, giving users control. Auto-dismiss is too aggressive — it can fire during a legitimate reconnection and discard the user's in-progress prompt.

**Dependencies:** None (but logically after Steps 1-3).

---

## Files Summary

| File | Action | Changes |
|------|--------|---------|
| `JanusApp/JanusClient/ClientEngine.swift` | Modify | (1) `sessionCreationGeneration` counter in `createSession()`, (2) `sessionReady = false` at top of `createSession()`, (3) `sessionReady` guard in `submitRequest()` |
| `JanusApp/JanusClient/PromptView.swift` | Modify | (1) Replace `connectedProvider != nil` with `sessionReady` in `canSubmit`, (2) Unify banner into tri-state, (3) Remove `onChange` auto-dismiss, (4) Defer `promptText` clearing |

**Total:** ~25 lines changed across 2 files (all modifications, no new files).

---

## What Does NOT Change

- `SessionManager` — session creation flow is correct, just needs UI gating and staleness protection
- `ProviderEngine` — provider-side validation is correct (rejects unknown sessions properly)
- `VoucherVerifier` — off-chain acceptance is the right behavior; `Channel.init` sets `state = .open` so voucher verification also works
- `DiscoveryView` / `DualModeView` — navigation gates already use `sessionReady`
- Transport layer — Bonjour/MPC unchanged
- Tempo channel flow — on-chain opening continues to be non-blocking

---

## Verification

1. **Provider switch test:** On PromptView with Provider A → Provider A disconnects → Provider B connects → verify Submit button is disabled and "Setting up session..." banner shows → button enables after session creation → first submit succeeds
2. **Same-provider reconnect test:** On PromptView → brief disconnect → reconnect → "Reconnecting..." banner shows briefly → button re-enables → submit works
3. **Rapid switching test (A→B→C):** Switch providers quickly → verify only the final provider's session is installed → no stale session from intermediate providers
4. **Normal flow regression:** Navigate from DiscoveryView → PromptView → first submit succeeds as before
5. **Defense-in-depth test:** If `sessionReady` guard rejects, verify prompt text is preserved and error message shows
6. **Disconnect-during-request:** Existing `disconnectedDuringRequest` banner still appears correctly, takes priority over reconnecting banner

---

## Risks

- **Very low.** Core changes are a UI gate, a generation counter, and a defense-in-depth guard. No changes to session creation, transport, or payment logic.
- The `onChange` removal changes existing behavior (no auto-dismiss on disconnect). Users must now tap "Back" manually. This is intentional — auto-dismiss was too aggressive for reconnection scenarios.
- If `sessionReady` gets stuck `false` due to a bug in session creation, the user would be unable to submit. But this is visible (banner stays) and the existing error handling in `createSession()` should surface the issue.

---

## Review Findings Incorporated

Based on **systems-architect review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| Critical | Stale async Task on rapid provider switching (A→B→C) | Added generation counter in Step 1 |
| Important | Banner conflicts with existing `disconnectedBanner` | Unified into tri-state banner in Step 5 |
| Important | `promptText` cleared before confirming success | Deferred clearing in Step 4 |
| Important | `channel.state == .open` concern on voucher path | Verified: `Channel.init` sets `.open` immediately — non-issue |
| Minor | Defense-in-depth error message wording | Changed to "Session is being set up. Please wait." |

Based on **architecture-reviewer review:**

| Priority | Issue | Resolution |
|----------|-------|------------|
| P1 | Banner conflicts with existing `disconnectedBanner` | Same — unified in Step 5 |
| P1 | `onChange` auto-dismiss contradicts Design Decision 4 | Removed in Step 5c |
| P2 | `sessionReady` not reset at `createSession()` entry | Added `sessionReady = false` at top of `createSession()` in Step 1 |
| P2 | Plan prose didn't clarify stale-manager mechanism | Clarified in Root Cause Analysis that `sessionManager` is never nil'd but may reference wrong provider |
| P3 | `canAffordRequest` transient inconsistency during transition | Non-issue — gated by `sessionReady` check in `canSubmit` |
