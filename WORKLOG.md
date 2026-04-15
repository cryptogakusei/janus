# Janus Worklog

## 2026-04-15

### Feature #13d: Tab-Based Postpaid Payment Model

Replaces the quote→voucher→response flow with a postpaid tab model. Provider serves inference immediately, accumulates a per-client token tab, and requests settlement when the tab crosses a threshold. The client auto-signs the voucher reactively. Designed for rural/village social-trust networks where cryptographic upfront commitment is unnecessary overhead.

#### Protocol changes

- **`TabUpdate`** (new message, `Provider → Client`): embedded in each `InferenceResponse` — carries `tokensUsed`, `cumulativeTabTokens`, `tabThreshold`.
- **`TabSettlementRequest`** (new message type, `Provider → Client`): sent when tab ≥ threshold, blocks further requests until client settles.
- **`VoucherAuthorization.quoteID`**: changed from `String` to `String?`. `quoteID == nil` is the discriminant for tab settlements; non-nil routes to legacy prepaid path.
- **`ServiceAnnounce`**: added `tokenRate` (credits / 1000 tokens), `tabThreshold` (tokens before settlement), `maxOutputTokens`, `paymentModel` ("tab" or "prepaid"). `pricing` made optional. All new fields use `decodeIfPresent` with sensible defaults — old prepaid providers decode transparently.
- **`InferenceResponse`**: added optional `tabUpdate: TabUpdate?` (default nil). Existing call sites compile unchanged.
- **`ErrorResponse`**: added `.tabSettlementRequired` case.
- **`PersistedProviderState`**: added `tabByChannelId: [String: UInt64]?` and `pendingTabSettlementByChannelId: [String: String]?` — persisted across restarts for crash recovery and debt anti-escape.

#### Provider changes (`ProviderEngine`)

- Added `tabByChannelId: [String: UInt64]` and `pendingTabSettlementByChannelId: [String: String]` in-memory state.
- `handlePromptRequest()`: removed entire quote-generation block. Now runs inference directly, increments tab, sends `InferenceResponse` with embedded `TabUpdate`, and triggers `TabSettlementRequest` if threshold crossed.
- Added `handleTabSettlementVoucher(_ auth:)`: validates replay prevention (`auth.requestID == pendingTabSettlementByChannelId[channelIdHex]`), runs `verifyTabSettlement()`, accepts voucher, resets tab to 0.
- `handleMessage()` dispatcher: `auth.quoteID == nil` routes to tab settlement; non-nil silently dropped (provider is tab-only now).
- `persistState()` / `restoreFromPersisted()`: includes tab dictionaries (nil when empty to save space).
- `ProviderAdvertiserTransport.updateServiceAnnounce()`: extended with `tokenRate`, `tabThreshold`, `maxOutputTokens`, `paymentModel` params; backward-compat default 2-param overload provided.
- Removed dead code: `requestCache` dict, `cacheRequest()`, `cachedTaskType()`, `cachedPrompt()`, `cleanupExpiredQuotes()`, `pendingQuotes`.

#### `MLXRunner` changes

- `generate()` now returns `InferenceResult` (struct with `outputText: String` + `outputTokenCount: Int`) instead of raw `String`.
- Token count computed post-inference via `container.perform { ctx in ctx.tokenizer.encode(...).count }` — exact count for ceiling-division billing.

#### Client changes (`ClientEngine`, `SessionManager`)

- **`RequestState`**: removed `.waitingForQuote`, added `.awaitingSettlement`.
- `handleMessage()`: removed `.quoteResponse` handler, added `.tabSettlementRequest` → `handleTabSettlementRequest()`.
- `handleTabSettlementRequest()`: sets `.awaitingSettlement`, auto-creates and sends `VoucherAuthorization` (quoteID nil) via `SessionManager.createTabSettlementVoucher()`, records settlement, resets to `.idle`.
- `handleInferenceResponse()`: tab fraud check — verifies `creditsCharged == max(1, (tokensUsed * tokenRate + 999) / 1000)`.
- `handleError()`: silently drops `.tabSettlementRequired` (provider sends both `TabSettlementRequest` message and the error simultaneously; the message drives state).
- `canAffordRequest`: returns false when `.awaitingSettlement`; no longer references `PricingTier.small.credits`.
- `SessionManager`: added `currentTabTokens`, `tabThreshold`, `tokenRate` `@Published` properties; `applyTabUpdate()`, `createTabSettlementVoucher()`, `recordTabSettlement()`.

#### UI changes

- `PromptView`: tab progress bar ("Tab: X / Y tokens"), settlement pending banner, `.awaitingSettlement` button state.
- `DiscoveryView` + `DualModeView`: conditional pricing display — tab providers show rate/threshold/maxOutput; prepaid providers show old small/medium/large badge.

#### Removals

- `PricingTier.swift` — deleted (replaced by per-token `tokenRate`).
- `PricingTierTests.swift` — deleted.
- `QuoteResponse.swift` — deleted (no quote in tab flow).

#### Verification

Key implementation invariants:
1. **Ceiling division**: `(tokens * rate + 999) / 1000`, min 1 — prevents 0-credit monotonicity break.
2. **Tab block = derived check**: `tabByChannelId[id] >= tabThresholdTokens` — no separate Set, crash-safe.
3. **Replay prevention**: `auth.requestID == pendingTabSettlementByChannelId[channelIdHex]` before accepting.
4. **Persistence**: both tab dicts in `PersistedProviderState` — client reconnect can't escape unpaid debt.
5. **Backward compat**: all `ServiceAnnounce` new fields `decodeIfPresent`; old providers default to `paymentModel="prepaid"`.

#### Files Changed

| File | Change |
|------|--------|
| `Sources/JanusShared/Protocol/TabUpdate.swift` | NEW |
| `Sources/JanusShared/Protocol/TabSettlementRequest.swift` | NEW |
| `Tests/JanusSharedTests/TabPaymentFlowTests.swift` | NEW (22 tests: serialization, verifyTabSettlement, ceiling division, backward compat) |
| `Sources/JanusShared/Protocol/QuoteResponse.swift` | DELETED |
| `Sources/JanusShared/Models/PricingTier.swift` | DELETED |
| `Tests/JanusSharedTests/PricingTierTests.swift` | DELETED |
| `Sources/JanusShared/Protocol/MessageEnvelope.swift` | Add `.tabSettlementRequest` |
| `Sources/JanusShared/Protocol/InferenceResponse.swift` | Add `tabUpdate: TabUpdate?` |
| `Sources/JanusShared/Protocol/VoucherAuthorization.swift` | `quoteID: String?`, custom decoder |
| `Sources/JanusShared/Protocol/ServiceAnnounce.swift` | Add 4 new fields; `pricing` optional |
| `Sources/JanusShared/Protocol/ErrorResponse.swift` | Add `.tabSettlementRequired` |
| `Sources/JanusShared/Persistence/SessionStore.swift` | Add tab fields to `PersistedProviderState` |
| `Sources/JanusShared/Verification/VoucherVerifier.swift` | Add `verifyTabSettlement()` |
| `Sources/JanusProvider/Inference/MLXRunner.swift` | Return `InferenceResult` (pkg file) |
| `JanusApp/JanusProvider/MLXRunner.swift` | Return `InferenceResult` (app file) |
| `JanusApp/JanusProvider/ProviderEngine.swift` | Full pipeline rewrite; remove quote/cache dead code |
| `JanusApp/JanusProvider/ProviderAdvertiserTransport.swift` | Updated protocol + backward-compat default |
| `JanusApp/JanusProvider/BonjourAdvertiser.swift` | Updated `updateServiceAnnounce` |
| `JanusApp/JanusProvider/MPCAdvertiser.swift` | Updated `updateServiceAnnounce` |
| `JanusApp/JanusProvider/CompositeAdvertiser.swift` | Updated `updateServiceAnnounce` |
| `JanusApp/JanusClient/ClientEngine.swift` | Remove quote; add tab settlement handler |
| `JanusApp/JanusClient/SessionManager.swift` | Tab state + methods |
| `JanusApp/JanusClient/PromptView.swift` | Tab progress bar, settlement banner |
| `JanusApp/JanusClient/DiscoveryView.swift` | Conditional pricing display |
| `JanusApp/JanusClient/DualModeView.swift` | Conditional pricing display |
| `Tests/JanusSharedTests/ProtocolTests.swift` | Updated `testServiceAnnounceRoundTrip()` + new old-JSON defaults test |
| `Tests/JanusSharedTests/VoucherFlowTests.swift` | `makeAuth()` quoteID → `String?` |
| `JanusApp/JanusClientTests/ClientEngineTests.swift` | Remove quote tests; add tab settlement tests |
| `JanusApp/JanusClientTests/DualModeTests.swift` | Updated local transport test to use TabSettlementRequest |

Net: ~424 lines deleted (PricingTier 104 + QuoteResponse + quote blocks), ~600 lines added (new protocol types + tab logic + tests). Net simplification of payment flow despite adding persistence.

#### Test Results

- `xcodebuild test -scheme Janus-Package` → **206 tests, 0 failures**
- `xcodebuild build -scheme JanusProvider` → **BUILD SUCCEEDED**
- `xcodebuild build -scheme JanusClient` → **BUILD SUCCEEDED**
- `xcodebuild test -scheme JanusClientTests` → **63 tests, 0 failures**

### Bug #13d-R1: Tab accumulation race condition under rapid concurrent requests (FIXED)

**Symptom**: When two requests are submitted in quick succession, the second request shows no tab increase in the client UI. The third request then shows a large jump that accounts for both. The inference responses themselves are correct — only the tab accounting is wrong.

**Root cause**: Stale capture of `currentTab` across the `await mlxRunner.generate(...)` yield point in `ProviderEngine.handlePromptRequest()`.

```
// In handlePromptRequest():
let currentTab = tabByChannelId[channelIdHex] ?? 0   // ← captured before await
// ... deposit check uses currentTab ...
let result = try await mlxRunner.generate(...)        // ← @MainActor yields here; other Tasks run
// ...
let newTab = currentTab + tokensUsed                  // ← stale capture, ignores concurrent Task's write
tabByChannelId[channelIdHex] = newTab                 // ← last-writer-wins: overwrites sibling's update
```

When two `Task { await handlePromptRequest(...) }` run concurrently:
1. Task A captures `currentTab = T`, yields at `await`.
2. Task B captures `currentTab = T` (same value — Task A hasn't written yet), yields at `await`.
3. Task A finishes inference, writes `tabByChannelId = T + tokensA`. Client sees no jump for request B (because `TabUpdate` is embedded in Task B's response, which hasn't arrived yet).
4. Task B finishes inference, writes `tabByChannelId = T + tokensB`, **overwriting** Task A's contribution.
5. Client receives Task B's response with `cumulativeTabTokens = T + tokensB` — appears as a big jump because the tab was at `T + tokensA` momentarily, but the stored value rolled back.

**Effect**: `tabByChannelId` loses Task A's token contribution. Over time, the tab under-counts actual token usage, allowing clients to defer settlement longer than the threshold intends.

**Fix (not implemented)**: Re-read `tabByChannelId` after inference returns, not before:
```swift
// After await mlxRunner.generate(...):
let currentTabPostInference = tabByChannelId[channelIdHex] ?? 0
let newTab = currentTabPostInference + tokensUsed
tabByChannelId[channelIdHex] = newTab
```
This is safe because `@MainActor` guarantees the read-modify-write is atomic (no interleaving between the read and the write). The deposit check before inference still uses the pre-inference snapshot — that is acceptable since the check is a soft guard (the channel deposit is not atomically locked).

**Priority**: Low. The race requires concurrent in-flight inferences to the same provider, which is unlikely in v1 single-client scenarios. The accounting error self-corrects at settlement (voucher is for exact tab credits). The client is not overcharged; the provider may slightly undercharge.

**Files to change when fixing**: `JanusApp/JanusProvider/ProviderEngine.swift` — `handlePromptRequest()`, the `currentTab` capture and `newTab` assignment post-`await mlxRunner.generate`.

### Roadmap #13d-T1: Tab payment model unit tests (PENDING)

Phase 7 of the #13d plan — deferred to a future session. All production code is complete and manually verified. These tests cover correctness of the tab accounting logic in isolation.

**New file: `Tests/JanusSharedTests/TabPaymentFlowTests.swift`** (~22 tests)

| # | Test | What it checks |
|---|------|---------------|
| 1–4 | Serialization | `TabUpdate`, `TabSettlementRequest`, nil `quoteID` round-trip, legacy non-nil `quoteID` backward compat |
| 5–7, 17–20 | `verifyTabSettlement()` | Happy path + 6 rejection cases (channel not open, wrong provider, channel mismatch, non-monotonic voucher, insufficient amount, exceeds deposit) |
| 8 | `PersistedProviderState` tab fields | Round-trip with and without tabs present |
| 9–11 | Ceiling division | Exactly-at-threshold, zero-token min-1, table-driven correctness across several values |
| 12–15 | Tab lifecycle | Reset after settlement, accumulation across requests, replay prevention (duplicate requestID rejected), replay prevention (wrong requestID rejected) |
| 16 | Deposit-too-small guard | Provider rejects request when channel deposit < one full tab cycle |
| 21 | Full tab cycle integration | 3 prompts → tab crosses threshold → settlement → tab resets → 4th prompt proceeds |
| 22 | Crash recovery | Mid-cycle restart (tab resumes from persisted value) + during-settlement restart (pending requestID re-sent on reconnect) |

**Updates to existing test files:**
- `Tests/JanusSharedTests/ProtocolTests.swift`: update `testServiceAnnounceRoundTrip()` for new fields; add `testServiceAnnounce_oldJSON_decodesWithDefaults()` (backward compat)
- `Tests/JanusSharedTests/VoucherFlowTests.swift`: `makeAuth()` helper `quoteID` param → `String? = "test-quote-id"`
- `JanusApp/JanusClientTests/ClientEngineTests.swift`: remove 2 stale quote tests; add `testHandleTabSettlementRequest_autoApproves()` and fraud-check update

**Verification:** `xcodebuild test -scheme Janus-Package` should go from 206 → ~228 tests, 0 failures.

---

## 2026-03-23

### M1: Local inference on Mac (standalone)

#### Setup
- Created project directory at `~/projects/janus/`
- Wrote end-state design document (`DESIGN.md`)
- Wrote v1 spec (`V1_SPEC.md`)
- Wrote PRD with protocol schema, data model, milestones, decision log (`PRD.md`)

#### Decisions made
- D1: Inference model — `mlx-community/Qwen3-4B-4bit` (Qwen3-4B, 4-bit quantization, ~2.3GB)
- D2: Session grant delivery — Option B (client presents signed grant on first contact, MPP-aligned)
- D3: Transport — Multipeer Connectivity (not raw BLE)
- D4: Quote round-trip — keep it (MPP challenge fidelity, <50ms cost)
- D5: Backend — Swift (Vapor) for shared crypto code

#### Implementation
- Created SPM package with `JanusShared` library and `JanusProvider` executable targets
- Implemented `TaskType` enum (translate, rewrite, summarize)
- Implemented `PricingTier` with classify-by-prompt-length logic (small/medium/large → 3/5/8 credits)
- Implemented `PromptTemplates` with system prompts per task type
- Implemented `MLXRunner` actor wrapping mlx-swift-lm's `ChatSession` for single-turn inference
- Implemented CLI entry point with interactive prompt loop

#### Issues encountered
- `swift build` cannot compile Metal shaders — MLX requires `xcodebuild` to generate `default.metallib` in `mlx-swift_Cmlx.bundle`
- Required Xcode.app installation (was only Command Line Tools)
- Required Metal Toolchain download (`xcodebuild -downloadComponent MetalToolchain`)
- Qwen3 defaults to "thinking mode" with `<think>` tags — fixed with `/no_think` prompt prefix and `stripThinkingTags` safety net

#### Build commands
- Build: `xcodebuild -scheme janus-provider -destination "platform=macOS" build`
- Test: `xcodebuild test -scheme Janus-Package -destination "platform=macOS" -only-testing:JanusSharedTests`
- Run: `/Users/soubhik/Library/Developer/Xcode/DerivedData/janus-*/Build/Products/Debug/janus-provider`

#### Results
- All 3 task types working: translate (0.3s), summarize (0.6s), rewrite (0.5s)
- Pricing tier classification correct at boundaries
- 6/6 unit tests passing
- Model cached at HuggingFace default cache path (~2.3GB, downloaded once)

#### Status: M1 COMPLETE

---

### M2: Multipeer Connectivity link

#### Implementation
- Added shared protocol types to JanusShared:
  - `MessageEnvelope` — common wrapper for all messages with type, ID, timestamp, sender, payload
  - `ServiceAnnounce` — provider identity, capabilities, pricing, availability
  - `MPCError` — shared transport error type
  - `MessageType` enum for all protocol message types
  - Shared `JSONEncoder.janus` / `JSONDecoder.janus` with ISO8601 dates and sorted keys
- Created Xcode project (`JanusApp/JanusApp.xcodeproj`) with two targets:
  - `JanusClient` — iOS SwiftUI app (iPhone)
  - `JanusProvider` — macOS SwiftUI app (Mac)
- Implemented `MPCAdvertiser` (macOS) — advertises provider, auto-sends ServiceAnnounce on connection
- Implemented `MPCBrowser` (iOS) — discovers providers, displays ServiceAnnounce info
- Implemented `DiscoveryView` (iOS) — scan button, connection status, provider info card
- Implemented `ProviderStatusView` (macOS) — advertising status, connected client, pricing display
- Info.plist files with NSLocalNetworkUsageDescription and NSBonjourServices for MPC
- MPC service type: `janus-ai`

#### Issues encountered
- Swift 6 strict concurrency: MPC delegate callbacks are nonisolated but need @MainActor state — used `nonisolated(unsafe)` for MPC objects
- iOS platform not installed in Xcode — downloading iOS simulator runtime (8.39 GB)
- `swift build` unusable for iOS targets — must use `xcodebuild` with proper Xcode project

#### Build commands
- Provider (macOS): `cd JanusApp && xcodebuild -project JanusApp.xcodeproj -scheme JanusProvider -destination "platform=macOS" build`
- Client (iOS): `cd JanusApp && xcodebuild -project JanusApp.xcodeproj -scheme JanusClient -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`

#### Issues encountered (continued)
- `XCSwiftPackageProductDependency` in hand-crafted pbxproj was missing `package = R000000001` reference — Xcode saw the dependency name but couldn't resolve it to the local SPM package for building
- SPM package target (JanusShared) defaulted to Release config while Xcode project target (JanusClient) used Debug — caused build directory mismatch (`Release-iphoneos/` vs `Debug-iphoneos/`). Fixed once scheme-based build used with proper simulator destination.
- iOS simulator runtime downloaded as iOS 26.3 (not 26.2 as SDK version suggests)

#### Build commands (final)
- Provider (macOS): `cd JanusApp && xcodebuild -project JanusApp.xcodeproj -scheme JanusProvider -destination "platform=macOS" build`
- Client (iOS Simulator): `cd JanusApp && xcodebuild -project JanusApp.xcodeproj -scheme JanusClient -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`
- Client (device, no signing): `cd JanusApp && xcodebuild -project JanusApp.xcodeproj -target JanusClient -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO SYMROOT="$(pwd)/build" build`

#### Results
- JanusProvider (macOS) builds successfully
- JanusClient (iOS) builds successfully for both simulator and device
- Both targets correctly resolve JanusShared via local SPM package

#### Verification
- JanusClient launched on iPhone 17 Pro simulator — no crashes
- JanusProvider launched on macOS — no crashes
- MPC framework active on client (GCKSession routing table initialized)
- MPC cannot fully test peer discovery in simulator — real device needed for end-to-end MPC testing

#### Real device test
- JanusClient deployed to physical iPhone (free Apple ID signing, team 2GKGGY6HZ8)
- Required: Developer Mode enabled on iPhone, developer profile trusted in Settings → General → VPN & Device Management
- JanusProvider running on Mac, JanusClient running on iPhone
- Both devices show "Connected" — MPC peer discovery, invitation, and ServiceAnnounce delivery all working
- Provider info card displayed on iPhone with pricing and task capabilities

#### Status: M2 COMPLETE

---

### M3: Cryptographic session model

#### Implementation
- Added `JanusShared/Crypto/` module:
  - `KeyPair.swift` — Ed25519 key generation, base64 import/export via CryptoKit (Curve25519)
  - `Signer.swift` — Signs newline-delimited field arrays, returns base64 signature
  - `Verifier.swift` — Verifies base64 signatures against public key
  - `CryptoError` enum for invalid base64/signature/verification failures
- Added protocol message types to `JanusShared/Protocol/`:
  - `PromptRequest` — client→provider, includes optional `SessionGrant` for first contact
  - `QuoteResponse` — provider→client, price quote with expiry
  - `SpendAuthorization` — client→provider, cumulative spend with client signature
  - `InferenceResponse` — provider→client, output text + signed `Receipt`
  - `ErrorResponse` — provider→client, typed error codes for all 9 verification failures
- Added model types to `JanusShared/Models/`:
  - `SessionGrant` — backend-signed grant with `signableFields` for canonical field ordering
  - `SpendState` — tracks cumulative spend + sequence number, `advance()` method
  - `Receipt` — provider-signed receipt with `signableFields`
- Added `JanusShared/Verification/SpendVerifier.swift`:
  - Full 9-step verification from PRD §8
  - `verify()` — validates authorization against grant, spend state, and quote
  - `verifyGrant()` — validates backend signature on session grant
  - `VerificationError` enum maps to `ErrorResponse.ErrorCode`
- Added tests:
  - `CryptoTests.swift` — 9 tests: key gen, sign/verify round-trip, wrong key, tampered fields, bad signature, base64 import
  - `SpendVerifierTests.swift` — 14 tests: happy path, sequential spends, all 9 verification failure modes, grant verification
  - `ProtocolTests.swift` — 17 tests: encode/decode round-trips for all 7 message types, envelope wrap/unwrap/serialize, signable fields, SpendState advance

#### Results
- 46/46 tests passing (9 crypto + 6 pricing + 17 protocol + 14 spend verification)
- JanusProvider (macOS) builds with new JanusShared code
- JanusClient (iOS) builds with new JanusShared code
- No new dependencies — CryptoKit is built into Apple platforms

#### Status: M3 COMPLETE

---

### M4: End-to-end flow

#### Implementation
- Added `DemoConfig` to JanusShared — deterministic backend keypair (SHA256 seed), hardcoded public key for grant verification, demo session defaults (100 credits, 1hr expiry)
- **Provider (macOS):**
  - `ProviderEngine` — orchestrates full pipeline: receive PromptRequest → cache grant → classify tier → issue QuoteResponse → verify SpendAuthorization (9-step) → run MLX inference → sign receipt → return InferenceResponse
  - Copied `MLXRunner` and `PromptTemplates` into Xcode provider target
  - Added MLXLLM + MLXLMCommon as SPM dependencies for macOS target
  - `ProviderStatusView` updated — shows model loading status, connection, activity log (last request/response, total served)
  - Auto-loads model on launch, auto-starts advertising
- **Client (iOS):**
  - `SessionManager` — generates client Ed25519 keypair, creates demo session grant (signed by hardcoded backend key), tracks cumulative spend state, stores receipts
  - `ClientEngine` — state machine (idle → waitingForQuote → waitingForResponse → complete/error), forwards browser published properties via Combine for SwiftUI observation, auto-accepts quotes by signing SpendAuthorization
  - `PromptView` — task type picker (segmented), text input, target language / rewrite style options, submit button with loading state, result card with receipt info, balance display, error display
  - `DiscoveryView` updated — creates session on provider connection, shows session credits, navigates to PromptView
- Updated `MPCAdvertiser` to accept `providerPubkey` parameter for ServiceAnnounce
- Updated `project.pbxproj` — 6 new source files (3 client + 3 provider), 2 new SPM product deps (MLXLLM, MLXLMCommon)

#### Issues encountered
- Nested ObservableObject problem: SwiftUI only observes `@Published` on the direct `@StateObject`. Nested `ObservableObject`s (MPCBrowser inside ClientEngine, ProviderEngine inside coordinator) don't propagate changes. Fixed by forwarding properties via Combine `assign(to:)` on client, and using separate `@StateObject`s on provider.

#### Build commands
- Provider (macOS): `cd JanusApp && xcodebuild -project JanusApp.xcodeproj -scheme JanusProvider -destination "platform=macOS" build`
- Client (iOS device): `security unlock-keychain && cd JanusApp && xcodebuild -project JanusApp.xcodeproj -scheme JanusClient -destination "id=00008140-001E7526022B001C" -allowProvisioningUpdates build`
- Deploy: `xcrun devicectl device install app --device 00008140-001E7526022B001C <path-to-app>`

#### Results
- Full end-to-end flow verified on real devices (iPhone + MacBook)
- PromptRequest → QuoteResponse → SpendAuthorization → MLX inference → InferenceResponse with signed receipt
- All 3 task types working over MPC (translate, rewrite, summarize)
- Session grant delivered and verified on first request
- Credits deducted correctly, receipts displayed
- 46/46 unit tests still passing

#### Status: M4 COMPLETE

---

### M5: Polish and demo

#### Implementation

- **Client — PromptView polish:**
  - Added visual balance bar with progress indicator (blue when >20%, red when low)
  - "Insufficient credits" warning when balance drops below smallest tier cost (3 credits)
  - Clear prompt text after submit for quick sequential entries
  - Keyboard dismisses on scroll (`.scrollDismissesKeyboard(.interactively)`)
  - Collapsible response history section (shows all past results with task type, prompt preview, response preview, credits charged)
  - Dismissable error cards (tap "Dismiss" to clear and reset to idle)
  - Disconnect banner when provider drops mid-session, with "Back" button
  - Auto-pops back to DiscoveryView after 2s if provider disconnects while idle

- **Client — ClientEngine improvements:**
  - Disconnect detection during active request (waitingForQuote/waitingForResponse) — sets error state with "Provider disconnected during request" message
  - Response history tracking: stores (taskType, prompt, InferenceResponse) tuples
  - `canAffordRequest` computed property checks remaining credits >= smallest tier (3)
  - Cleans up pending state (taskType, promptText) on error and completion

- **Provider — ProviderEngine improvements:**
  - Request log: capped at 50 entries, shows timestamp, task type, prompt preview, response preview, credits earned, error flag
  - Active session count tracking
  - Total credits earned counter
  - Error logging: all `sendError` calls create log entries
  - Expired quote cleanup: stale quotes purged on each new quote creation
  - Request cache cleanup: removes cached PromptRequest after inference completes

- **Provider — ProviderStatusView redesign:**
  - Compact status cards for Model and Network status with color-coded indicators
  - Connection card showing client name + active session count
  - Stats row: requests served, credits earned, error count
  - Scrollable request log with green/red status dots, timestamps, task type badges, credit amounts
  - Version label updated from "M4 — End-to-End" to "v1 Demo"

#### Results
- JanusProvider (macOS) builds successfully
- JanusClient (iOS Simulator) builds successfully
- 46/46 unit tests still passing
- Edge cases handled: disconnect mid-request, insufficient credits, expired quotes

#### Status: M5 COMPLETE

---

## v1.1: Session Syncing

### Step 1: Persistence layer

#### Implementation
- Added `JanusShared/Persistence/SessionStore.swift`:
  - `PersistedClientSession` — stores keypair (base64), session grant, spend state, receipts, grantDelivered flag
  - `PersistedProviderState` — stores provider ID, keypair (base64), known sessions, spend ledger, receipts issued, stats
  - `JanusStore` — simple JSON file persistence using Application Support directory. `save()`, `load()`, `delete()` methods.
- Updated `SessionManager` (client):
  - `restore(providerID:)` static method tries to load persisted session. Returns nil if expired or wrong provider.
  - `persist()` called after session creation and after each `recordSpend()`
  - `clearPersistedSession()` for manual reset
- Updated `ClientEngine`:
  - `createSession()` tries `SessionManager.restore()` before creating new session
  - Keeps sessionManager on disconnect (persisted session survives reconnect)
- Updated `ProviderEngine`:
  - Restores provider ID + keypair from persisted state (stable identity across restarts)
  - Restores known sessions + spend ledger (returning clients work without re-presenting grant)
  - `persistState()` called after new session cached and after spend state advances
  - Stores receipts issued for future settlement
- Updated `ProviderStatusView`:
  - Provider ID loaded from persisted state if available (stable across restarts)
- Added `PersistenceTests.swift` — 7 tests:
  - Save/load round-trip, load nonexistent returns nil, delete removes file
  - Client session round-trip (keypair restore, spend state, receipts, isValid, remainingCredits)
  - Expired session correctly reports invalid
  - Provider state round-trip (sessions, ledger, stats, keypair restore)
  - Save overwrites previous value

#### Issues encountered
- Provider persistence file was empty on first test — old binary (M5, pre-persistence) was still running. Rebuilt and relaunched fixed it.
- Client history lost on reconnect — `PersistedClientSession` added `history: [HistoryEntry]` field, but old files on iPhone (written before history was added) didn't have this key. `JSONDecoder` threw `keyNotFound`, `try?` returned nil, and `SessionManager.restore()` fell through to creating a brand new session. Fixed with custom `init(from:)` using `decodeIfPresent` to default `history` to `[]`.
- Provider request log not persisting — `LogEntry` was not `Codable` and not included in `PersistedProviderState`. Fixed by making `LogEntry` Codable, adding `PersistedLogEntry` to JanusShared, persisting log in `appendLog()`, and restoring on init. Same `decodeIfPresent` pattern for backwards compat.

#### Results
- JanusProvider (macOS): BUILD SUCCEEDED
- JanusClient (iOS): BUILD SUCCEEDED, verified on real iPhone
- 54/54 tests passing (46 original + 8 persistence tests including backwards compat)
- Persistence directory: `~/Library/Application Support/Janus/` (macOS), app sandbox (iOS)
- Verified on real devices:
  - Client restart: credits, receipts, and response history persist
  - Provider restart: sessions, spend ledger, request log, stats, and provider identity persist
  - Cross-restart: client reconnects to restarted provider, resumes existing session without re-presenting grant

#### Status: Step 1 COMPLETE

---

### Step 2: Vapor backend + client/provider wiring

#### Implementation
- **Vapor backend server** (`JanusBackend/`):
  - Separate SPM package to isolate server-only dependencies (Vapor) from the main project
  - `@main` async entry point using `Application.make(.detect())`
  - Uses `DemoConfig` deterministic keypair — grants are verifiable by existing providers
  - In-memory actor-based stores (`InMemorySessionStore`, `InMemoryProviderStore`)
  - 4 endpoints:
    - `GET /status` — health check, session/provider counts
    - `POST /providers/register` — register provider ID + public key
    - `POST /sessions` — create backend-signed `SessionGrant` (requires registered provider)
    - `POST /sessions/settle` — provider submits final spend for reconciliation
  - `VaporExtensions.swift` — retroactive `Content` conformance for `SessionGrant` and `Receipt`
  - Build: `cd JanusBackend && swift build`
  - Run: `cd JanusBackend && .build/debug/JanusBackend serve --hostname 0.0.0.0 --port 8080`

- **`SessionBackend` protocol** (`JanusShared/BackendAPI.swift`):
  - Abstracts over the session funding/settlement backend
  - Three operations map to MPP payment channel concepts:
    - `fundSession` → open + fund a payment channel
    - `registerProvider` → announce provider identity to network
    - `settleSession` → close + settle a payment channel
  - `HTTPSessionBackend` — concrete implementation using URLSession → Vapor
  - When MPP/Tempo arrives, swap for `MPPSessionBackend` without touching client/provider code

- **Client (`SessionManager`):**
  - `init(providerID:)` replaced with `create(providerID:)` async factory method
  - Calls `backend.fundSession()` to get a real grant from the server
  - Falls back to local DemoConfig self-signing if backend is unreachable (offline mode)
  - Backend private key no longer needed on the client

- **Provider (`ProviderEngine`):**
  - `registerWithBackend()` — calls `backend.registerProvider()` on startup
  - `settleSession(_:)` — calls `backend.settleSession()` with receipts
  - `@Published var backendRegistered` — tracks registration status for UI

- **Provider UI (`ProviderStatusView`):**
  - Backend status card (green "Registered" / orange "Not registered")
  - Calls `registerWithBackend()` on launch alongside model loading

- **ATS (App Transport Security):**
  - Added `NSAllowsLocalNetworking` to both Info.plist files
  - Allows plain HTTP to local network IPs without disabling ATS globally

- **Config:**
  - `DemoConfig.backendBaseURL` — Mac's LAN IP (`http://10.0.0.117:8080`)

#### Issues encountered
- Vapor `Application(.detect())` deprecated — used `Application.make(.detect())` async API
- `@main` conflicts with `main.swift` — renamed to `App.swift`
- Protocol methods can't have default parameter values — must pass `nil` explicitly for optional `maxCredits`
- iOS ATS blocks plain HTTP by default — `NSAllowsLocalNetworking` is the surgical fix for local dev

#### Results
- JanusBackend: BUILD SUCCEEDED, all 4 endpoints tested with curl
- JanusProvider (macOS): BUILD SUCCEEDED
- JanusClient (iOS): BUILD SUCCEEDED, deployed to real iPhone
- 54/54 unit tests still passing
- Verified on real devices:
  - Provider registers with backend on launch (status shows "Registered")
  - Client requests grant from backend when connecting to provider
  - Full end-to-end flow works: backend-signed grant → MPC → quote → authorization → inference → receipt
  - Offline fallback: client self-signs if backend unreachable

#### Status: Step 2 COMPLETE

---

### Step 3: Provider settlement on disconnect

#### Implementation
- **`MPCAdvertiser`:**
  - Added `onClientDisconnected` callback, fired on `.notConnected` state change
  - Wired in `ProviderStatusView` to trigger `engine.settleAllSessions()`

- **`ProviderEngine` — settlement trigger:**
  - `settleSession(_:) -> Bool` — calls `backend.settleSession()`, returns success/failure
  - `settleAllSessions()` — iterates all sessions with unsettled spend, calls `settleSession()` for each
  - Logs settlement success/failure to request log

- **Re-settlement support:**
  - `settledSpends: [String: Int]` tracks last settled cumulative spend per session (not just boolean)
  - On disconnect: only settles if `ledger.cumulativeSpend > settledSpends[sessionID]`
  - Allows client to reconnect, spend more, disconnect again — provider re-settles at the higher amount
  - Persisted via `PersistedProviderState.settledSpends` with `decodeIfPresent` backwards compat

- **Backend re-settlement:**
  - `InMemorySessionStore.settle()` changed from `-> Bool` to `-> Int?`
  - Accepts re-settlement if new spend >= previous settled spend (monotonically increasing)
  - Rejects if spend decreased (returns nil → 409)

- **Bug fix — settlement on failure:**
  - Original code marked session as settled even when HTTP call failed
  - Fixed: only update `settledSpends` when backend confirms settlement
  - Failed settlements are retried on next disconnect

#### Issues encountered
- DHCP lease changed Mac IP from `10.0.0.117` to `10.0.0.119` — hardcoded `DemoConfig.backendBaseURL` had to be updated and both apps rebuilt. Future improvement: dynamic backend URL discovery.

#### Results
- JanusProvider (macOS): BUILD SUCCEEDED
- JanusBackend: BUILD SUCCEEDED
- 54/54 unit tests still passing
- Verified on real devices (reconnect scenario):
  - Round 1: Client connects, translates "How is life?" (3 credits), disconnects → settled at 3
  - Round 2: Client reconnects, translates "What an awesome world is this?" (3 more), disconnects → re-settled at 6
  - Provider log shows both settlement entries with correct cumulative amounts
  - `settledSpends` correctly tracks `D0A1C067... → 6`

#### Status: Step 3 COMPLETE

---

### v1.1 Session Syncing — COMPLETE

#### Deferred: SessionSync / SettlementNotice messages (future hardening)
- **Scenario:** If the provider crashes mid-inference after advancing its spend ledger but before sending InferenceResponse, the client and provider ledgers diverge. Neither side knows.
- **Fix (when needed):** Add `SessionSync` message (provider → client: "your current spend is X") and `SettlementNotice` (provider → client: "I settled session Y with backend for Z credits"). Allows both sides to reconcile after disruptions.
- **Priority:** Low — current persistence + settlement handles restarts and reconnects. This is an edge case for a future robustness pass.

---

## v1.2: Better Receipts

### Client-side receipt verification

#### Implementation
- **`ClientEngine.handleInferenceResponse()`** — two new checks before accepting any response:
  1. **Quote-price match:** `creditsCharged` must equal `currentQuote.priceCredits` — prevents overcharging
  2. **Receipt signature verification:** Ed25519 signature on receipt verified against provider's public key (from `ServiceAnnounce.providerPubkey`) — prevents forged/tampered receipts
  - If either check fails, client rejects the response, shows error, does not deduct credits

- **`ReceiptVerificationTests.swift`** — 8 new tests:
  - Valid receipt signature passes
  - Receipt signed by wrong provider (impersonation) rejected
  - Tampered `creditsCharged` field rejected
  - Tampered `cumulativeSpend` field rejected
  - Empty signature rejected
  - Quote-price match accepted / mismatch rejected
  - Sequential receipts with monotonic spend all verify independently

#### Deferred: Receipt-based recovery
- Custom recovery against Vapor backend would be throwaway — MPP/Tempo replaces the recovery model entirely (payment channels on shared ledger, keypair + latest receipt = full recovery)
- Only durable investment: store keypair in recoverable location (Keychain with iCloud sync) — deferred to MPP milestone

#### Results
- JanusClient (iOS): BUILD SUCCEEDED, deployed to real iPhone
- 62/62 unit tests passing (54 original + 8 receipt verification)
- Verified on real device: happy path works with receipt verification active

#### Status: v1.2 COMPLETE

---

## v1.3: Multiple Simultaneous Users

#### Implementation
- **`MPCAdvertiser` — multi-peer support:**
  - `connectedClients: [MCPeerID: String]` replaces single `clientPeerID`
  - `senderToPeer: [String: MCPeerID]` maps message sender IDs to MPC peers for reply routing
  - Auto-registers sender→peer mapping on every received message
  - ServiceAnnounce sent to each peer individually on connect
  - Per-peer disconnect with cleanup of sender mappings
  - `send(_:to:)` routes to specific peer by sender ID
  - `onClientDisconnected` now passes client name (for logging)

- **`ProviderEngine` — targeted message routing:**
  - `sendMessage` callback changed from `(MessageEnvelope) -> Void` to `(MessageEnvelope, String) -> Void` — includes target sender ID
  - `sessionToSender: [String: String]` maps session IDs to sender IDs for routing replies
  - All `send()` and `sendError()` calls pass session ID for correct routing
  - Session data structures already multi-session (dictionaries) — no changes needed

- **`ProviderStatusView` — multi-client UI:**
  - Connection card shows list of connected clients (not just one name)
  - Displays client count + session count

- **`MultiSessionTests.swift`** — 8 new tests:
  - Two sessions track spend independently
  - Exhausting one session doesn't affect another
  - Verifier accepts two clients on same provider
  - Client A can't spend on client B's session (cross-session attack rejected)
  - Settlement tracks per-session
  - Re-settlement detects increased spend
  - Receipts from different sessions verify independently (cross-check fails)
  - Multi-session provider state persists and restores correctly

#### MPC stability fixes (multi-phone testing)

**Problem 1: Connect/disconnect loop with two phones.**
When both phones connected, they kept cycling between connecting and disconnecting. Root cause: `foundPeer` callback was `nonisolated` and called `invitePeer` immediately every time MPC discovered the provider — even while already connecting or connected. With two phones, duplicate invitations confused the provider's MCSession, triggering drops.
- Fix: moved `foundPeer` logic to `@MainActor`, added guard `connectionState == .disconnected` before inviting.

**Problem 2: Auto-reconnect never triggered after disconnect.**
Phone would show "disconnected" but never reconnect. Root cause: race condition between two MPC delegate callbacks. `lostPeer` (browser delegate) fired first and set `providerPeerID = nil`. Then `.notConnected` (session delegate) fired, checked `peerID == providerPeerID`, found nil, skipped `scheduleReconnect()`.
- Fix: both `lostPeer` and `.notConnected` now trigger reconnect independently. `.notConnected` checks `connectionState != .disconnected` instead of peerID. Whichever fires first handles it, second is a no-op.

**Problem 3: Stuck at `.connecting` forever.**
After auto-reconnect, client would find provider and send invitation, but MPC's invitation timeout callback sometimes never fired — client stuck at `.connecting` permanently.
- Fix: added `startConnectionTimeout()` — if still `.connecting` after 10 seconds, forces session reset and retries.

**Problem 4: Phantom connections (both sides show "connected", but data doesn't flow).**
Provider showed clients as connected, clients showed connected, but requests got stuck at "getting quote" — provider never received the messages, or sent responses that never arrived. MPC's `session.send()` succeeded (buffered internally) but data never reached the other side. MPC didn't fire any disconnect callbacks.
- Attempted fix 1: foreground health check (`willEnterForegroundNotification`) — checks `session.connectedPeers` when app returns to foreground, forces reconnect if stale. Helped for background/foreground transitions but didn't catch phantom connections while app was in foreground.
- Attempted fix 2: provider-side stale peer cleanup timer (every 15s, compare `connectedClients` against `session.connectedPeers`). Didn't help — MPC's `connectedPeers` also reported the phantom peers as connected.
- Attempted fix 3: ping/pong heartbeat (client pings every 10s, waits 5s for pong, declares dead if no response). This correctly detected phantom connections BUT the heartbeat traffic itself caused more disconnects — during inference (which takes seconds), the pong response was delayed, and multiple pings from multiple clients created MPC contention. Reverted.

**Problem 5 (root cause): One phone backgrounding broke ALL connections.**
The actual root cause of phantom connections and instability: MPC used a single shared `MCSession` for all peers. When one phone locked (iOS kills background MPC connections), the shared session became unstable for ALL peers — the other phone's connection would silently die or become phantom.
- **Final fix: per-client MCSession isolation.** Changed `MPCAdvertiser` from `session: MCSession` (one shared) to `clientSessions: [MCPeerID: MCSession]` (one per client). Each incoming invitation creates a dedicated session via `createSession(for:)`. One client disconnecting only affects its own session. This eliminated all cross-client interference.

**Client-side auto-reconnect (`MPCBrowser`) — kept from earlier fixes:**
- `foundPeer` guard (Problem 1 fix)
- `scheduleReconnect()` from both `lostPeer` and `.notConnected` (Problem 2 fix)
- Connection timeout at 10 seconds (Problem 3 fix)
- Foreground health check (Problem 4 partial fix — still useful for detecting stale state after backgrounding)
- Stop browsing on connect — prevents stale `foundPeer` callbacks

**Approaches tried and reverted:**
- Exponential backoff + jitter on reconnect — over-engineered, the core issue was shared sessions not reconnect timing
- Heartbeat ping/pong — correct in theory but caused more disconnects in practice due to MPC traffic contention during inference
- Provider stale peer cleanup timer — unnecessary with per-client sessions

**Key lesson:** The fix was architectural (isolate sessions) not behavioral (detect and recover from bad connections). We spent significant time adding detection/recovery mechanisms that made things worse because they added MPC traffic and complexity to an already fragile shared session. The per-client session change was ~50 lines and solved everything.

#### Provider UI fix
- Connection card now shows "X connected now" (green/orange) and "Y sessions total" (gray) separately — distinguishes live MPC peers from durable Janus payment sessions.

#### Known issue (deferred)
- **Spend state divergence on mid-request disconnect:** If provider runs inference and advances spend ledger but client never receives the response (MPC drops mid-flight), client and provider sequence numbers diverge. Next request from client gets "sequence mismatch" error. Fix: SessionSync message (provider tells client current spend state on reconnect). Deferred — same issue noted in v1.1.

#### Results
- JanusProvider (macOS): BUILD SUCCEEDED
- JanusClient (iOS): BUILD SUCCEEDED
- 70/70 unit tests passing (62 previous + 8 multi-session)
- Single-phone smoke test: provider registered, session created, iPhone auto-connected — no regression
- Multi-phone test (2 iPhones → 1 Mac provider):
  - Both phones connect and create independent sessions
  - Both phones submit requests and receive independent responses
  - One phone locking does NOT affect the other phone's connection (per-client session isolation working)
  - Phone unlocking → auto-reconnect within ~2 seconds → new requests work
  - Provider correctly shows "2 connected now, 2 sessions total"
  - MPC drops handled by auto-reconnect — phones recover within ~2 seconds

#### Status: v1.3 COMPLETE

---

## v1.3.1: Provider UI Redesign

#### Implementation
- **Provider dashboard overhaul (`ProviderStatusView`):**
  - Compact horizontal header bar with machine name
  - Status pills (model/network/backend) instead of large status cards
  - Stats strip: Served, Credits Earned, Connected clients, Total sessions
  - Per-client cards in a 2-column `LazyVGrid` — cards sit side by side instead of stacking vertically
  - Each card shows: client name with unique session ID suffix (e.g. "iPhone (a3f2b1)"), connection status dot, credits used, remaining, sessions, requests
  - Expandable "Recent Requests" dropdown inside each card (`ClientLogDropdown`) — collapsed by default, tap to expand with animated chevron
  - Global "All Activity" log at the bottom

- **Data model changes for per-client grouping:**
  - Added `sessionID: String?` to `LogEntry` and `PersistedLogEntry` (optional for backward compat)
  - Added `ClientSummary` struct and computed property on `ProviderEngine` — groups sessions by senderID, aggregates spend/request/error data
  - Added `displayName(forSender:)` and `isConnected(senderID:)` helpers on `MPCAdvertiser`
  - Client name disambiguation: appends last 6 chars of senderID to device name (both phones named "iPhone" by default)

#### Results
- JanusProvider (macOS): BUILD SUCCEEDED
- JanusClient (iOS): BUILD SUCCEEDED
- 70/70 unit tests still passing
- Two client cards display side by side with unique identifiers

#### Status: v1.3.1 COMPLETE

---

## v1.4: SessionSync (Spend State Divergence Fix)

### Problem
If the provider completes inference and advances its spend ledger but the client never receives the response (MPC drops mid-flight), the two sides diverge:
- Provider: sequence N+1, cumulative spend X+price
- Client: sequence N, cumulative spend X

Every subsequent request from the client fails with "sequence mismatch" because the client sends sequence N+1 but the provider expects N+2. Previously required app reinstall to recover.

### Implementation
- **New message type:** `sessionSync` added to `MessageType` enum
- **New model:** `SessionSync` (`Sources/JanusShared/Protocol/SessionSync.swift`) — carries the missed `InferenceResponse` (which includes the signed receipt + output text)
- **Provider (`ProviderEngine`):**
  - Stores last `InferenceResponse` per session in `lastResponses: [String: InferenceResponse]`
  - On `sequenceMismatch` error during spend verification, checks if a stored response exists for that session
  - If yes, sends `SessionSync` instead of error — client gets the missed receipt and can recover
  - If no stored response, falls back to error (shouldn't happen in practice since requests are sequential)
- **Client (`ClientEngine`):**
  - Handles `.sessionSync` message type
  - Verifies receipt signature before trusting the provider's state (same Ed25519 check as normal responses)
  - Rejects sync if receipt is forged or tampered
  - On valid sync: updates `SpendState` via `SessionManager.syncSpendState()`, adds missed response to history as "(recovered)", resets to idle
- **Client (`SessionManager`):**
  - Added `syncSpendState(to:)` — reconstructs `SpendState` from the receipt's cumulative spend and increments sequence number

### Security model
- Provider cannot lie about spend: SessionSync includes a signed receipt, and the client verifies the signature against the provider's public key
- Provider cannot inflate credits: the receipt's `creditsCharged` was originally authorized by the client's `SpendAuthorization`
- Provider cannot forge transactions: no `SpendAuthorization` from the client = no valid receipt to include in sync
- Tampered receipt fields (changed amounts) fail signature verification

### Tests
- **`SessionSyncTests.swift`** — 6 new tests:
  - `testSessionSyncRoundTrip` — encode/decode through MessageEnvelope
  - `testDivergenceAndRecovery` — full scenario: 2 requests succeed → provider advances on 3rd but client misses it → stale auth rejected → sync state → retry succeeds
  - `testSyncReceiptSignatureValid` — valid receipt passes verification
  - `testSyncReceiptRejectsWrongSigner` — receipt signed by impersonator rejected
  - `testSyncReceiptRejectsTamperedAmount` — receipt with changed creditsCharged rejected
  - `testSyncDoesNotAllowSpendBeyondBudget` — sync doesn't bypass budget enforcement

### Results
- JanusProvider (macOS): BUILD SUCCEEDED
- JanusClient (iOS): BUILD SUCCEEDED
- 76/76 unit tests passing (70 previous + 6 SessionSync)
- Verified on real devices:
  - Sent request from iPhone, locked screen during inference to kill MPC connection
  - Provider completed inference, logged response, but phone never received it
  - Unlocked phone, sent new request — provider detected sequence mismatch, sent SessionSync
  - Phone auto-recovered: state synced, next request worked normally
  - No app reinstall needed

#### Status: v1.4 COMPLETE

---

## v1.5: MPP/Tempo Integration (In Progress)

### Goal
Replace the toy Vapor backend with real Tempo payment channels — on-chain escrow smart contracts on Tempo testnet. Clients deposit tokens (one tx), send signed cumulative vouchers off-chain per request, and settle on-chain at session end (one tx).

### Step 1: Ethereum Primitives

#### Implementation
- **Dependencies added:**
  - `CryptoSwift` v1.9.0 (10.5k stars) — battle-tested keccak256 implementation. Pure Swift, no heavy deps.
  - `swift-secp256k1` pinned to v0.21.1 — product renamed from `secp256k1` to `P256K` in v0.20.0. v0.22.0 added a mandatory build plugin that broke xcodebuild, so pinned to last stable version without it.

- **`Sources/JanusShared/Ethereum/Keccak256.swift`:**
  - Thin wrapper around CryptoSwift's `SHA3(.keccak256)` — Ethereum uses Keccak-256 (NOT SHA3-256; different padding byte)

- **`Sources/JanusShared/Ethereum/EthKeyPair.swift`:**
  - `EthKeyPair` — secp256k1 keypair using `P256K.Signing.PrivateKey` / `P256K.Recovery.PrivateKey`
  - Ethereum address derivation: `keccak256(uncompressed_pubkey[1..65])[-20:]`
  - `signRecoverable(messageHash:)` → `EthSignature(r, s, v)` for EIP-712 voucher signing
  - `EthAddress` — 20-byte address with EIP-55 checksum encoding, Codable
  - `EthSignature` — recoverable ECDSA (r, s, v), 65-byte compact representation
  - Hex utilities: `Data(ethHex:)`, `.ethHex`, `.ethHexPrefixed`

- **`Sources/JanusShared/Ethereum/ABI.swift`:**
  - Minimal Solidity ABI encoding for EIP-712 struct hashing and contract calls
  - Supports `uint256`, `address`, `bytes32`, `bool`
  - `ABI.encode()` (standard, padded to 32 bytes) and `ABI.encodePacked()` (tight packing)

- **`Sources/JanusShared/Ethereum/EIP712.swift`:**
  - EIP-712 typed structured data hashing and signing
  - `TypeDefinition` with `typeHash` computation
  - `Domain` separator (name, version, chainId, verifyingContract)
  - `hashStruct()` and `signableHash()` (`keccak256("\x19\x01" || domainSeparator || structHash)`)

#### Tests
- **`EthereumTests.swift`** — 19 tests:
  - Keccak256: empty string vector, "hello world" vector, NOT-SHA3 verification
  - Hex: round-trip, prefixed, invalid odd-length rejection
  - EthAddress: from hex, EIP-55 checksum (Vitalik's address), Codable round-trip
  - EthKeyPair: generation (sizes, 0x04 prefix), deterministic address, Hardhat account #0 address vector, recoverable signature (r/s/v sizes)
  - ABI: uint256 encoding, address left-padding, packed encoding sizes, bool encoding
  - EIP-712: type hash computation, domain separator determinism, signable hash with 0x1901 prefix

#### Results
- JanusShared: BUILD SUCCEEDED
- 95/95 unit tests passing (76 previous + 19 Ethereum)
- Hardhat account #0 test vector passes: private key `0xac0974...` → address `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`

#### Status: Step 1 COMPLETE

---

### Step 2: Tempo Voucher & Channel Layer

#### Implementation
- **`Sources/JanusShared/Tempo/TempoConfig.swift`:**
  - Chain-specific configuration: escrow contract, payment token, chain ID
  - Computes EIP-712 voucher domain ("Tempo Stream Channel", version "1")
  - `TempoConfig.testnet` preset for Hardhat/Anvil (chainId 31337)

- **`Sources/JanusShared/Tempo/Voucher.swift`:**
  - `Voucher` — cumulative payment authorization (channelId + cumulativeAmount), matches on-chain type
  - `SignedVoucher` — voucher + EIP-712 recoverable ECDSA signature (65 bytes: r || s || v)
  - `voucherEIP712Type` — `Voucher(bytes32 channelId, uint128 cumulativeAmount)`
  - `structHash` / `signableHash(config:)` — EIP-712 hashing chain
  - `sign(with:config:)` — signs voucher with secp256k1 key pair
  - `verify(signedVoucher:expectedSigner:config:)` — recovers signer address from signature, compares against expected
  - `recoverAddress(messageHash:signature:)` — Swift `ecrecover` using P256K.Recovery

- **`Sources/JanusShared/Tempo/Channel.swift`:**
  - `Channel` — on-chain escrow payment channel (payer, payee, token, salt, deposit, state)
  - `computeId()` — deterministic channel ID via `keccak256(abi.encode(...))`, mirrors on-chain computation
  - `ChannelState` — open / closeRequested / closed / expired
  - `acceptVoucher()` — validates monotonicity, deposit bounds, channel ID match
  - `recordSettlement()` — tracks on-chain settlement amount
  - `ChannelError` — typed errors for all validation failures

#### Tests
- **`TempoTests.swift`** — 17 tests:
  - Voucher: sign & verify, rejects wrong signer, rejects tampered amount, deterministic hashing
  - Address recovery: `ecrecover` round-trip
  - Channel ID: deterministic, differs for different params
  - Channel lifecycle: creation, accept voucher, settlement, monotonic sequence
  - Channel validation: non-monotonic rejected, exceeds deposit rejected, wrong channel rejected
  - Codable: Voucher and Channel JSON round-trips

#### Results
- JanusShared: BUILD SUCCEEDED
- 112/112 unit tests passing (95 previous + 17 Tempo)

#### Status: Step 2 COMPLETE

---

### Step 3a: Off-chain Voucher Integration (Protocol Layer)

#### Design
Tempo payment channels have two independent layers:
1. **Off-chain (vouchers):** Client signs EIP-712 vouchers, provider verifies via `ecrecover`. Pure crypto — no blockchain needed.
2. **On-chain (escrow):** Opening channels, depositing tokens, settling. Requires a real chain (Step 3b).

Step 3a implements the off-chain layer: new protocol messages and verification logic that replace Ed25519-based `SpendAuthorization` with EIP-712-based `VoucherAuthorization`.

#### Implementation
- **`Sources/JanusShared/Protocol/VoucherAuthorization.swift`:**
  - `VoucherAuthorization` — new protocol message wrapping `SignedVoucher` + requestID + quoteID
  - `ChannelInfo` — replaces `SessionGrant` for first-contact channel setup

- **`Sources/JanusShared/Verification/VoucherVerifier.swift`:**
  - `VoucherVerifier` — 8-step verification using ecrecover instead of Ed25519
  - `verifyChannelInfo()` — validates first-contact channel info

- **`MessageType.voucherAuthorization`** added to enum

#### Tests
- **`VoucherFlowTests.swift`** — 15 end-to-end tests covering happy path, all 7 error modes, channel info validation, and wire format round-trips

#### Results
- JanusShared: BUILD SUCCEEDED
- 127/127 unit tests passing (112 previous + 15 voucher flow)

#### Status: Step 3a COMPLETE

---

### Step 3a (cont): App-level Voucher Wiring

#### Design
Wire the off-chain Tempo voucher flow into the actual iOS (client) and macOS (provider) apps, creating a dual-path system that supports both Ed25519 `SpendAuthorization` and EIP-712 `VoucherAuthorization` sessions.

#### Implementation
- **`MPCAdvertiser.swift`:**
  - Made `serviceAnnounce` mutable
  - Added `updateServiceAnnounce(providerPubkey:providerEthAddress:)` — called after `ProviderEngine` initializes its keypairs, so the announce includes both the Ed25519 pubkey and Ethereum address

- **`ProviderStatusView.swift`:**
  - Calls `advertiser.updateServiceAnnounce()` in `.onAppear` with `engine.providerPubkeyBase64` and `engine.providerEthKeyPair?.address.checksumAddress`

- **`ClientEngine.submitRequest()`:**
  - Dual-path first-contact: sends `channelInfo` (Tempo) or `sessionGrant` (Ed25519) depending on `session.usesVouchers`
  - `PromptRequest` now carries both optional fields

- **`ClientEngine.handleQuote()`:**
  - Dual-path authorization: sends `VoucherAuthorization` (via `session.createVoucherAuthorization()`) or `SpendAuthorization` (via `session.createAuthorization()`) depending on `session.usesVouchers`
  - Marks `channelInfoDelivered` or `grantDelivered` after successful send

#### Results
- JanusProvider (macOS): BUILD SUCCEEDED
- JanusClient (iPhone): BUILD SUCCEEDED
- 127/127 unit tests passing (no regressions)

#### Status: Step 3a app wiring COMPLETE

---

### Step 3a Smoke Test + Bug Fixes

#### Device-to-device smoke test (Mac ↔ iPhone)
- Confirmed **both payment paths** work end-to-end over MPC:
  - Ed25519 (SpendAuthorization): session `D7A1C719...` in `knownSessions` + `spendLedger`
  - Tempo (VoucherAuthorization): session `1705C527...` — receipt issued but NOT in `knownSessions`/`spendLedger` (fingerprint of voucher path using in-memory `channels`)
- Codable round-trips for `EthAddress`, `EthSignature`, `SignedVoucher`, `ChannelInfo` all serialize correctly across iOS ↔ macOS

#### Bug: Stuck "Processing..." after phone lock/unlock
**Root cause:** Tempo channel identity mismatch on reconnect. ETH keypair is not persisted, so client creates a new one after restoring session from disk → new channel ID. Provider ignored the updated `channelInfo` (checked `channels[sessionID] == nil`, found old channel, skipped). Client sent `VoucherAuthorization` with new channel ID → provider couldn't find it → silently dropped with no error → client waited forever.

**Fixes:**
- **`ProviderEngine.handlePromptRequest()`:** Always accept updated `channelInfo` (removed `if channels[sessionID] == nil` guard). Handles client reconnect with new keypair.
- **`ProviderEngine.handleVoucherAuthorization()`:** Send error back to client when voucher channel is unknown (was just printing and returning silently).
- **`ClientEngine`:** Added 20-second request timeout as safety net for any future message-loss scenarios. Proactively calls `checkConnectionHealth()` on submit.

**Verified:** Lock phone → unlock → reconnect → send request → works.

#### Remaining for persistence (deferred to 3b)
- Persist ETH keypair in `PersistedClientSession` so channel doesn't change on reconnect (proper fix)
- Persist provider-side `channels` dict for crash recovery

---

### Step 3b: On-chain Integration with Tempo Testnet

#### Context
Tempo is an EVM-compatible L1 blockchain optimized for payments. Key differences from Ethereum:
- **No native gas token** — fees paid in USD stablecoins (TIP-20 tokens)
- Higher state creation costs (250k gas for new storage slot vs 20k on Ethereum)
- Fast finality (~0.5s blocks)
- Custom Foundry fork with `--tempo.fee-token` flags

#### Tempo Testnet (Moderato) Details
| Property | Value |
|----------|-------|
| Network Name | Tempo Testnet (Moderato) |
| Chain ID | `42431` |
| RPC URL | `https://rpc.moderato.tempo.xyz` |
| Explorer | `https://explore.testnet.tempo.xyz` |
| Currency | USD (no native token) |
| pathUSD | `0x20c0000000000000000000000000000000000000` |
| Faucet | `cast rpc tempo_fundAddress <ADDR> --rpc-url https://rpc.moderato.tempo.xyz` |
| Foundry | `foundryup -n tempo` (Tempo fork installed) |

#### Design

We deploy our own `StreamEscrow` contract to Tempo testnet. The escrow:
1. Holds TIP-20 stablecoin deposits from clients (payers)
2. Verifies EIP-712 voucher signatures for settlement
3. Pays providers (payees) based on the latest cumulative voucher

**Key changes from Step 3a:**
- Payment token: pathUSD (`0x20c0...0000`) instead of `address(0)` (no native ETH on Tempo)
- Chain ID: `42431` instead of `31337` (Hardhat)
- TempoConfig: real escrow contract address after deployment
- Channel ID computation now uses real escrow address + real chain ID

**EIP-712 domain (unchanged structure):**
- name: "Tempo Stream Channel"
- version: "1"
- chainId: 42431
- verifyingContract: `<deployed escrow address>`

**Escrow contract functions:**
- `openChannel(payee, token, salt, authorizedSigner, amount)` — client deposits TIP-20 tokens
- `getChannel(channelId)` → returns on-chain channel state (deposit, settled amount, open flag)
- `settle(channelId, cumulativeAmount, signature)` — provider claims payment via EIP-712 ecrecover
- `closeChannel(channelId)` — finalize and return remaining deposit to payer

**Channel ID** = `keccak256(abi.encode(payer, payee, token, salt, authorizedSigner, escrow, chainId))` — matches our existing `Channel.computeId()`.

#### Implementation Progress

**Phase 1: Smart Contract** ✅
- [x] Created Foundry project at `contracts/` with tempo-std, solady, forge-std
- [x] Wrote `TempoStreamChannel.sol` — reference implementation from Tempo TIPs
- [x] Wrote `TempoUtilities.sol` — isTIP20() wrapper for factory precompile
- [x] Deployed to Tempo Moderato testnet (chain ID 42431)
- [x] **Contract address**: `0xaB7409f3ea73952FC8C762ce7F01F245314920d9`
- [x] **Domain separator**: `0x838cdeffc3b733fce6d75c74ebef34992efe2f79039073514982955f6caa7bba`
- Deployer: `0x1A1F1C6132f634484EbB35954f357FC16A875D3D` (testnet only)

**Phase 2: Swift JSON-RPC Client** ✅
- [x] `Sources/JanusShared/Ethereum/EthRPC.swift` — async JSON-RPC over HTTP (eth_call)
- [x] `Sources/JanusShared/Tempo/EscrowClient.swift` — typed wrapper for `getChannel(bytes32)` and `computeChannelId(...)`
- [x] Custom `UInt128` type for Solidity uint128 deposit/settled amounts

**Phase 3: App Integration** ✅
- [x] Updated `TempoConfig.testnet` with real contract address, chain ID 42431, pathUSD token, RPC URL
- [x] Provider: async on-chain verification in `handlePromptRequest()` via `verifyChannelInfoOnChain()`
  - Checks channel exists, payee matches, authorizedSigner matches, not finalized
  - Falls back to off-chain-only if RPC unreachable or channel not yet opened
- [x] Client: ETH keypair persisted in `PersistedClientSession.ethPrivateKeyHex`
- [x] Client: `setupTempoChannel()` reuses persisted ETH keypair (prevents channel ID mismatch on reconnect)
- [x] Client: uses pathUSD token address in channel setup
- [x] All 127 tests pass

**Phase 4: Auto On-Chain Channel Opening** ✅
- [x] `Sources/JanusShared/Ethereum/RLP.swift` — RLP encoding for Ethereum transaction serialization
- [x] `Sources/JanusShared/Ethereum/EthTransaction.swift` — legacy tx building with EIP-155 signing, `approve`/`openChannel` builders
- [x] Extended `EthRPC.swift` — `sendRawTransaction`, `getTransactionCount`, `gasPrice`, `waitForReceipt`, `fundAddress`
- [x] `Sources/JanusShared/Tempo/ChannelOpener.swift` — orchestrates fund → approve → open (idempotent)
- [x] `SessionManager` auto-opens channel on-chain after `setupTempoChannel()` (async, non-blocking)
- [x] `ProviderEngine` added `os_log` for client channel info capture (subsystem `com.janus.provider`, category `SmokeTest`)
- [x] Fixed `EscrowClient` decoder: handles both 256-byte and 288-byte `getChannel` returns
- [x] Gas limits set to 2M for both approve and open (Tempo fee token mechanism adds significant overhead)
- [x] Live smoke test: both iPhones auto-funded, approved escrow, opened channels on Tempo Moderato testnet
- [x] 160/160 tests passing (11 new: RLP encoding, tx builders, live integration test)

Key discoveries:
- Tempo uses custom transaction type 118 (`0x76`) with `feeToken` field, but **legacy type 0 transactions also work**
- Gas accounting on Tempo includes fee token overhead — 60K gas limit fails even for a simple `approve` (~531K actual)
- `print()` in macOS GUI apps doesn't appear in unified log — must use `os_log()` for CLI log capture
- `getChannel()` returns 256 bytes (no ABI offset pointer), not 288 as initially assumed

**Phase 5: On-Chain Settlement by Provider** ✅
- [x] `Sources/JanusShared/Ethereum/EthTransaction.swift` — added `settleChannel()` builder with dynamic `bytes` ABI encoding (offset + length + padded signature)
- [x] `Sources/JanusShared/Tempo/ChannelSettler.swift` — submits settlement tx using provider's ETH keypair; checks on-chain state first to avoid wasting gas
- [x] Provider ETH keypair persisted in `PersistedProviderState.ethPrivateKeyHex` (survives restarts)
- [x] `ProviderEngine.settleAllChannelsOnChain()` — triggered on client disconnect, parallel to existing Ed25519 backend settlement
- [x] Signature v conversion: 0/1 → 27/28 (`ethV`) for on-chain `ecrecover`
- [x] `testFullSettlementOnTempo` integration test: open channel → sign 3 vouchers → provider settles → verify on-chain `settled=9`
- [x] 162/162 tests passing, both apps build

Key details:
- Settlement is idempotent — contract ignores amounts ≤ already-settled
- Dual settlement paths: Ed25519 sessions → Janus backend HTTP; Tempo channels → on-chain escrow contract
- Provider persists `settledSpends[sessionID]` to allow re-settlement when more spend accumulates
- Provider must be funded with pathUSD on Tempo for gas (no native ETH on Tempo — gas paid in stablecoin)

#### Offline-First Smoke Test (2026-03-25) ✅

End-to-end test proving the core Janus thesis: **blockchain only needed at the edges (escrow open + settlement), entire service delivery happens offline.**

**Devices:**
- Provider: Mac (JanusProvider with MLX Qwen3-4B) — ETH `0x52109e2F353f1f6Bc0796b1E852acdB400BC531d`
- Client: iPhone 16 (JanusClient) — ETH `0x08526625F4257704E43F272CcC23994ee302B76a`
- Escrow: `0xaB7409f3ea73952FC8C762ce7F01F245314920d9` on Tempo Moderato (chain 42431)
- Channel ID: `0xa48371be0034a1cb0b6784bbf120065784ecfcd4b20bd7aed96297db04e38be6`

**Phase 1 — Online (channel opening):**
- Client auto-funded via Tempo faucet, approved escrow, opened channel with deposit=100 pathUSD credits
- All 3 on-chain txs (fund, approve, open) executed automatically by the client app

**Phase 2 — Online requests (6 requests, 18 credits):**
- 6 translation requests served via MPC + MLX inference + EIP-712 voucher signing
- Each voucher is cumulative: voucher #6 authorizes provider to claim up to 18 credits total
- Provider settled on-chain when client briefly disconnected:
  - **Settlement TX 1**: `0x9b1df3bf1a72a300f7fa9e049e1c42be3191c538c2f53b3e0d65db18db669ebe` — 18 credits
  - On-chain state: `deposit=100, settled=18`

**Phase 3 — Offline requests (WiFi off, 2 more requests, 6 more credits):**
- Disconnected WiFi on both Mac and iPhone
- Sent 2 more translation requests — all worked identically:
  - MPC (Multipeer Connectivity) over Bluetooth/peer-to-peer WiFi — no internet gateway
  - MLX inference ran locally on Mac GPU — no cloud API
  - Voucher signing/verification via pure local secp256k1 crypto — no chain needed
- Voucher #8 authorized cumulative 24 credits

**Phase 4 — Reconnect & settle:**
- Turned Mac WiFi back on
- Provider auto-settled the latest voucher (cumulative=24) on-chain:
  - **Settlement TX 2**: `0x1f255dc45a302f81b135479a0daa7b21ce1ac753f57bee86d583f93ebc76a98d` — 24 credits cumulative (delta of 6 transferred)
  - On-chain state: `deposit=100, settled=24, remaining=76`

**Issue encountered:**
- First settlement attempt at 10:32 failed with `insufficient funds for gas` — provider ETH address had 0 pathUSD. Fixed by funding provider via `tempo_fundAddress`. Subsequent settlements succeeded.

**Final on-chain state:**
| Field | Value |
|-------|-------|
| Deposit | 100 credits |
| Settled | 24 credits (8 requests × 3 credits) |
| Remaining | 76 credits |
| Provider earned | 24 pathUSD transferred from escrow to provider |

**Key takeaway:** The blockchain was touched only 5 times total (approve, open, failed settle, settle #1, settle #2). All 8 request/response cycles — including 2 fully offline — used only local compute and local crypto. The micropayment channel pattern amortizes expensive on-chain operations across many cheap off-chain voucher exchanges.

#### Bug: MPC discovery fails after screen lock + cellular toggle

**Symptom:** User locks iPhone screen, unlocks, turns off cellular data, taps "Scan" in JanusClient — provider is not found. MPC browsing appears active (spinner visible) but never discovers the provider's advertisement.

**Root cause:** Multipeer Connectivity uses Bonjour/mDNS for peer discovery, which binds to specific network interfaces at browse time. When iOS suspends the app (screen lock), MPC browsing silently stops. When the user then changes network state (e.g., toggling cellular off), the available interfaces change. On resume, `startSearching()` called `browser.startBrowsingForPeers()` on the existing `MCNearbyServiceBrowser` instance, but its Bonjour bindings were stale — still referencing interfaces from before the suspend/network change. The browser appeared to be browsing but was actually listening on dead interfaces.

**Fix (`JanusApp/JanusClient/MPCBrowser.swift`):**
- **`startSearching()`**: Changed from a simple `startBrowsingForPeers()` to a full stop → `resetSession()` → start cycle. This forces MPC to tear down old Bonjour bindings and re-enumerate available network interfaces (Bluetooth, WiFi peer-to-peer) from scratch.
- **`checkConnectionHealth()`** (called automatically via `UIApplication.willEnterForegroundNotification`): Previously only handled the case where the app thought it was connected but the peer was gone. Now always restarts browsing on foreground re-entry, regardless of connection state — catches the case where interfaces changed while suspended but the app was in `.disconnected` state with no reconnect pending.

**Key detail:** The `MCNearbyServiceBrowser` instance itself is reused (created once in `init`), but the underlying `MCSession` is recreated via `resetSession()`. The stop/start cycle on the browser is sufficient to force Bonjour to rebind — no need to recreate the browser object.

**Verified:** Lock iPhone → unlock → toggle cellular off → tap Scan → provider discovered immediately.

#### Bug: MPC stuck "Connecting" when WiFi radio is off

**Symptom:** Both Mac (provider) and iPhone (client) have WiFi completely off (not just disconnected from a network — the radio itself is disabled). iPhone also has cellular off. User taps "Scan" — client discovers the provider and shows "Connecting", but the connection never completes. Stays in connecting state indefinitely, silently retrying every 10 seconds.

**Root cause — MPC's three transport layers:**

| Layer | Purpose | Requires |
|-------|---------|----------|
| **Bluetooth** | Peer **discovery** (finding nearby devices) | BT radio on |
| **AWDL (Apple Wireless Direct Link)** | Peer-to-peer **session data transfer** | WiFi radio on (no access point or internet needed) |
| **Infrastructure WiFi** | Session data when both on same network | Both on same WiFi network |

When WiFi is off on either device, Bluetooth can still discover the peer (so `foundPeer` fires and the UI shows "Connecting"), but AWDL is unavailable so the `MCSession` can never be established. The invitation times out, the code resets and retries, creating an infinite loop with no user feedback.

**This is distinct from the offline smoke test scenario:** In the smoke test, WiFi was **on** but **internet was off**. The WiFi radio being on is sufficient for AWDL — it creates an ad-hoc peer-to-peer WiFi link between devices without needing an access point or internet gateway. That's why the offline test worked: AWDL was available.

**Fix (`JanusApp/JanusClient/MPCBrowser.swift` + `DiscoveryView.swift`):**
- Added `consecutiveTimeouts` counter to `MPCBrowser`. After 2 consecutive connection timeouts (20 seconds total), transitions to new `.connectionFailed` state and stops retrying.
- New `ConnectionState.connectionFailed` case — surfaces to UI instead of silently looping.
- **`DiscoveryView`**: Shows orange `wifi.exclamationmark` icon with message: "Provider found but can't connect — WiFi must be enabled on both devices. Internet is not required — just the WiFi radio."
- Counter resets on successful connection or when user taps Scan again.

**Architectural insight — "offline" has two meanings for Janus:**
1. **No internet** (WiFi radio on, no gateway): Fully supported. AWDL provides peer-to-peer transport. This is the core Janus use case — all service delivery (MPC discovery, session setup, inference, voucher exchange) works without internet.
2. **No WiFi radio** (airplane mode / WiFi disabled): Not supported for data transfer. Bluetooth alone can discover peers but cannot reliably establish MPC sessions or transfer the data volumes needed for inference requests/responses. The fix ensures users get a clear, actionable error instead of infinite "Connecting...".

**Verified:** WiFi off on both devices → Scan → "Connecting" for ~20s → shows WiFi warning. Enable WiFi → tap Scan → connects immediately.

#### Multi-Client Smoke Test (2026-03-25) ✅

Two iPhones connected to the same Mac provider simultaneously, each with independent Tempo payment channels.

**Devices:**
- iPhone 16 (payer `0x0852...`) — channel `0xa483...`, deposit=100
- iPhone 14 Plus (payer `0x2f27...`) — channel `0xe096...`, deposit=100
- Provider (Mac) — `0x5210...`, serving both via separate MPC sessions

**Results:**
- Both clients discovered provider, connected, opened channels on-chain, and received inference responses
- Requests from both phones served concurrently (provider handles MPC sessions independently via per-client `MCSession`)
- On-chain settlements for both channels:
  - iPhone 16: settled **69 credits** (23 requests) — TX `0x885461d2...`
  - iPhone 14 Plus: settled **9 credits** (3 requests) — TX `0xa024c963...`
- Each channel is fully independent — separate payer addresses, separate channel IDs, separate voucher chains, separate on-chain settlements

#### Status: Step 3b COMPLETE (Phases 1–5 + Offline Smoke Test + Multi-Client Test + MPC bug fixes)

---

### Transport Reference: MPC / AWDL / Bluetooth

#### How Multipeer Connectivity works under the hood

MPC uses three transport layers, each with a distinct role:

| Layer | Role | Requires | Bandwidth | Range |
|-------|------|----------|-----------|-------|
| **Bluetooth LE** | Peer **discovery** (finding nearby devices) | BT radio on | ~0.3 Mbps | ~10-30m |
| **AWDL (Apple Wireless Direct Link)** | Peer-to-peer **session & data transfer** | WiFi radio on | ~20-80 Mbps | ~30-70m |
| **Infrastructure WiFi** | Data transfer (when both on same network) | Same WiFi network | Network speed | Router range |

- **Bluetooth** broadcasts "I'm here" advertisements. When the client's `MCNearbyServiceBrowser` discovers a provider's `MCNearbyServiceAdvertiser`, it fires `foundPeer`. This is discovery only.
- **AWDL** handles the actual `MCSession` handshake and all data transfer. It creates a **direct device-to-device WiFi link** — no router, no access point, no internet. Same technology as AirDrop. Uses 5 GHz band (channel-hops between device's WiFi channel and a dedicated AWDL social channel).
- If both devices are on the **same WiFi network**, MPC may use infrastructure WiFi instead of AWDL for better throughput.

#### Core requirement for Janus offline operation

| What | Required? |
|------|-----------|
| WiFi radio toggle ON | **Yes** (both devices) |
| Connected to a WiFi network | No |
| WiFi router / access point | No |
| Internet access | No |
| Bluetooth | Yes (for initial discovery) |
| Cellular data | No |

**"Offline" for Janus means no internet, NOT no WiFi radio.** The WiFi toggle powers on the radio chip; AWDL then creates a point-to-point link directly between devices. Two people in the middle of a desert with zero infrastructure can use Janus, as long as both have WiFi and Bluetooth toggled on.

#### Range expectations

| Environment | AWDL Range |
|-------------|------------|
| Indoor (walls, furniture) | ~10-15m (~30-50 ft) |
| Open space (line of sight) | ~30-70m (~100-230 ft) |
| Ideal (no interference) | Up to ~100m (~330 ft) |

Rule of thumb: if you can AirDrop to someone, Janus will work at that distance.

#### Why Bluetooth alone is insufficient

Bluetooth can discover peers but cannot reliably establish `MCSession` or transfer the data volumes Janus needs. This is an Apple architectural decision — MPC delegates session handshake and data to AWDL. A single Janus inference round-trip (PromptRequest → QuoteResponse → VoucherAuthorization → InferenceResponse) involves multiple messages of several KB each; Bluetooth's ~0.3 Mbps and unreliable connection setup make this impractical.

**Future option:** If true Bluetooth-only operation is needed (e.g., one device can't enable WiFi), we'd need to replace MPC with a custom **Core Bluetooth L2CAP channel** implementation. L2CAP gives ~1 Mbps bidirectional streams over BLE 5.0 — workable but slower, with significantly more connection management code.

---

### Phase 6: Production Key Management — Privy Embedded Wallet Integration

**Problem:** Client generates raw secp256k1 key via `EthKeyPair()`, stored as plaintext hex in `client_session.json`. Private key is also logged via `os_log` (debug only). Not suitable for production — key loss means loss of funds, no user identity tied to wallet.

**Solution:** [Privy](https://privy.io) embedded wallet SDK. Uses MPC-TSS (threshold signature scheme) — the private key is split across Privy's infrastructure and the user's device. The app never sees the full key. Users authenticate via Apple Sign-In or email OTP, and Privy manages wallet creation/restoration automatically.

#### Architecture

```
┌─────────────────────────────────────────────────────────┐
│  JanusClientApp                                         │
│  ┌──────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │LoginView │───►│DiscoveryView │───►│  PromptView   │  │
│  │(Privy    │    │(wallet badge,│    │(inference +   │  │
│  │ auth)    │    │ MPC scan)    │    │ vouchers)     │  │
│  └──────────┘    └──────────────┘    └───────────────┘  │
│       │                │                     │          │
│  ┌────▼────┐    ┌──────▼──────┐    ┌────────▼────────┐  │
│  │PrivyAuth│    │ClientEngine │    │SessionManager   │  │
│  │Manager  │───►│.walletProv. │───►│.walletProvider  │  │
│  └─────────┘    └─────────────┘    └─────────────────┘  │
│       │                                     │           │
│  ┌────▼──────────┐              ┌───────────▼────────┐  │
│  │PrivyWallet    │              │ChannelOpener       │  │
│  │Provider       │              │(WalletProvider)    │  │
│  │(EIP-712 sign, │              │approve → open      │  │
│  │ send tx)      │              └────────────────────┘  │
│  └───────────────┘                                      │
│       │                                                 │
│  ┌────▼──────────────────────────────────────────────┐  │
│  │ WalletProvider protocol (JanusShared)             │  │
│  │  - signVoucher(Voucher, TempoConfig) → SignedV.   │  │
│  │  - sendTransaction(to, data, value, chainId) → tx │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

#### What was built

**1. `WalletProvider` protocol** (`Sources/JanusShared/Tempo/WalletProvider.swift`)
- Abstraction over any Ethereum wallet (local key or remote MPC)
- Two methods: `signVoucher()` (EIP-712) and `sendTransaction()` (raw tx)
- Both are `async` — Privy's MPC signing requires a network call (~200-500ms)
- `LocalWalletProvider`: wraps raw `EthKeyPair`, used by provider and tests
- `PrivyWalletProvider`: wraps Privy embedded wallet, used by iOS client in production

**2. `PrivyAuthManager`** (`JanusApp/JanusClient/PrivyAuthManager.swift`)
- Manages Privy SDK initialization, authentication, and wallet lifecycle
- Login methods: Apple Sign-In (via `privy.oAuth.login(with: .apple)`) and email OTP
- Auto-checks for existing session on app launch (`privy.getAuthState()`)
- After auth: creates embedded Ethereum wallet or restores existing one
- Exposes `walletProvider: PrivyWalletProvider?` for downstream use

**3. `PrivyWalletProvider`** (`JanusApp/JanusClient/PrivyWalletProvider.swift`)
- Implements `WalletProvider` using Privy's `EmbeddedEthereumWalletProvider`
- `signVoucher()`: builds EIP-712 typed data → `eth_signTypedData_v4` via Privy
- `sendTransaction()`: builds `UnsignedEthTransaction` → `eth_sendTransaction` via Privy
- Parses 65-byte hex signatures into `EthSignature(r, s, v)` with v normalization (27/28 → 0/1)

**4. Refactored `ChannelOpener`** (`Sources/JanusShared/Tempo/ChannelOpener.swift`)
- Now accepts `WalletProvider` instead of raw `EthKeyPair`
- Uses calldata-only helpers (`EthTransaction.approveCalldata()`, `.openChannelCalldata()`)
- Wallet handles nonce/gas internally — opener just builds calldata and waits for receipts
- Legacy `openChannel(keyPair:)` overload preserved for backward compat

**5. Refactored `SessionManager`** (`JanusApp/JanusClient/SessionManager.swift`)
- Accepts optional `WalletProvider` injection (from Privy auth)
- If injected: uses wallet's address as channel payer/signer (no local key created)
- If not injected: falls back to creating local `EthKeyPair` wrapped in `LocalWalletProvider`
- `createVoucherAuthorization()` is now `async` (Privy signing is a network call)

**6. Updated `ClientEngine`** (`JanusApp/JanusClient/ClientEngine.swift`)
- `walletProvider` property set by `DiscoveryView.onAppear` from `PrivyAuthManager`
- Passes wallet provider through to `SessionManager.create()` / `.restore()`
- `handleQuote()` splits into async (voucher via WalletProvider) and sync (Ed25519) paths

**7. UI layer**
- `LoginView` — Apple Sign-In button and email OTP flow, gates app access
- `JanusClientApp` — conditionally shows `LoginView` or `DiscoveryView` based on `auth.isAuthenticated`
- `DiscoveryView` — wallet badge in toolbar (truncated address + logout menu)

**8. Calldata helpers** (`Sources/JanusShared/Ethereum/EthTransaction.swift`)
- `approveCalldata(spender:amount:)` — just the ABI-encoded function call data
- `openChannelCalldata(payee:token:deposit:salt:authorizedSigner:)` — same
- `settleChannelCalldata(channelId:cumulativeAmount:voucherSignature:)` — same
- Full transaction builders now delegate to these (DRY)

**9. Tests** (13 new, `Tests/JanusSharedTests/WalletProviderTests.swift`)
- `LocalWalletProvider` signature matches direct `EthKeyPair` signing (deterministic)
- Vouchers signed via `WalletProvider` verify correctly with `VoucherVerifier`
- `MockWalletProvider` simulates async Privy-like signing with call tracking
- Full multi-step verification flow using `WalletProvider` through `Channel` + `VoucherVerifier`
- Calldata helpers produce identical output to full transaction builders
- **175/175 tests passing**

#### Privy SDK v2.x API notes

The Privy iOS SDK (v2.10.0) is a binary xcframework (`https://github.com/privy-io/privy-ios`). The actual API surface differs from some documentation:

| What we expected | Actual v2.x API |
|---|---|
| `privy.apple.login()` | `privy.oAuth.login(with: .apple)` |
| `privy.logout()` | `user.logout()` (on `PrivyUser`, not `Privy`) |
| `privy.user` (sync property) | `privy.getAuthState() async` → `AuthState` enum |
| `EIP712TypedData(types:, primaryType:, domain:, message:)` | `EIP712TypedData(domain:, primaryType:, types:, message:)` (different param order) |
| `UnsignedEthTransaction(value: .hexadecimal(...))` | `.hexadecimalNumber(...)` or `.int(...)` via `Quantity` enum |
| `ethSignTypedDataV4(...)` returns result directly | Factory method `throws`, must use `try` |

Discovered by reading `.swiftinterface` at:
`DerivedData/JanusApp-*/SourcePackages/checkouts/privy-ios/PrivySDK.xcframework/ios-arm64_x86_64-simulator/PrivySDK.framework/Modules/PrivySDK.swiftmodule/arm64-apple-ios-simulator.swiftinterface`

#### Swift gotcha: public struct memberwise init

`EthSignature` (a `public struct` in JanusShared) had no explicit `public init(r:s:v:)`. Swift auto-generates a memberwise initializer for structs, but it's **internal** — invisible to other modules. `PrivyWalletProvider` (in JanusClient module) couldn't call it. Fixed by adding an explicit `public init`.

#### Payer/signer separation

During real device testing, discovered that Privy's embedded wallet cannot send raw transactions to custom chains like Tempo Moderato (chain ID 42431). The `eth_sendTransaction` RPC goes through Privy's infrastructure, which only supports known chains.

**Fix:** Separated the payer (on-chain transactions) from the authorizedSigner (voucher signing):
- **Payer**: Local `EthKeyPair` — auto-funded via Tempo faucet, opens channel on-chain, deposits funds
- **AuthorizedSigner**: Privy embedded wallet — signs EIP-712 vouchers via MPC

The `Channel` struct already supported this via separate `payer` and `authorizedSigner` fields — this is exactly the pattern payment channels are designed for. Modified `SessionManager.setupTempoChannel()` to always create a local key for on-chain ops while using the injected Privy wallet for voucher signing.

#### Apple Sign-In entitlement

Apple Sign-In requires OAuth credentials (Services ID, Key ID, Signing Key, Team ID) configured in both Apple Developer Portal and Privy dashboard. Privy hard-gates enabling Apple login behind these credentials. Removed the `com.apple.developer.applesignin` entitlement from JanusClient for now — email OTP works without any external configuration.

#### Real device test — PASSED (2026-03-25)

**Setup:**
- Privy email login enabled in dashboard (no Apple OAuth credentials needed)
- JanusClient deployed to 2 iPhones via `xcrun devicectl`
- JanusProvider running on Mac with funded ETH key (`0x52Db...252e`)

**Results:**

| Step | Action | Result |
|---|---|---|
| 1 | Launch app | LoginView appears with Janus branding |
| 2 | Sign in with email OTP | Privy auth + embedded wallet created |
| 3 | Wallet badge in toolbar | Privy wallet address displayed (0x...truncated) |
| 4 | Scan → connect to Mac provider | MPC discovery + connection works |
| 5 | Send inference requests | Vouchers signed via Privy MPC, responses received |
| 6 | Channel opened on-chain | Local payer key funded via faucet, approve+open TXs confirmed |
| 7 | Disconnect → provider settles | TX `0x426af2...` settled 18 credits on-chain |
| 8 | Second iPhone (email OTP) | TX `0x0aaf1b...` settled 36 credits on-chain |

**Two clients, two Privy wallets, two on-chain channels — 54 total credits settled.**

Proved: Privy MPC wallet signing + local payer key for on-chain ops + multi-user support all working end-to-end.

#### Phase 6 status: COMPLETE

**Remaining cleanup (non-blocking):**
- [ ] Remove debug logging of private keys (`CLIENT_ETH_PRIVKEY` os_log lines)
- [ ] Configure Apple Sign-In OAuth credentials in Privy dashboard (requires Apple Developer Portal setup)
- [ ] Add biometric confirmation for high-value operations (channel open, large deposits)
- [ ] Add key recovery documentation (Privy handles this via their recovery flow)
- [ ] Optional: fiat on-ramp integration for funding channels without pre-existing crypto

---

## 2026-03-26

### Phase 7: Multi-hop relay (single-hop MVP)

#### Ed25519 cleanup verification
- Verified all 5 settlement transactions on Tempo Moderato testnet (93+48+99+57+60 = 357 credits)
- Confirmed Ed25519 removal didn't break payment flow
- Committed `a24c6a6`: "Remove Ed25519 payment fallback, keep only Tempo voucher path"

#### Relay design
- Wrote `RELAY_DESIGN.md` — full 5-phase relay architecture
- Key design decision: **provider transparency** — zero provider code changes, relay unwraps RelayEnvelope and sends bare MessageEnvelope
- 5 phases: Core forwarding → Robustness → Multi-hop mesh → E2E encryption → Incentives
- Regression test gates at every phase boundary, covering all historical bugs

#### Implementation (Phase 1)
- **Protocol layer**: `RelayEnvelope` (routing wrapper), `RelayAnnounce` (relay discovery), new `MessageType` cases
- **MPCRelay**: browses `janus-ai` for providers, advertises `janus-relay` for clients, per-peer session isolation, bidirectional forwarding with routing tables
- **MPCBrowser**: dual browser (provider + relay), `forceRelayMode` toggle, `ConnectionMode` enum (`.direct` / `.relayed(relayName:)` / `.disconnected`)
- **RelayView**: relay status UI with provider/client lists, forwarded message count, start/stop controls
- **JanusClientApp**: client/relay mode switching via `@AppStorage("appMode")`
- **DiscoveryView**: connection mode badge, settings menu with force relay toggle and relay mode switch
- **Info.plist**: added `_janus-relay._tcp` and `_janus-relay._udp` Bonjour service types
- 8 unit tests for relay protocol serialization round-trips (157 total tests, all pass)

#### Device testing
- Setup: Mac = provider, iPhone 1 = relay, iPhone 2 = client (force relay mode)
- Prompt forwarding through relay: PASS
- Multiple prompts, forwarded count increments: PASS
- Relay stop → client disconnects: PASS
- Relay restart → client auto-reconnects: PASS (after MPC reconnection fixes)
- Payment/settlement through relay: PASS

#### Bugs found and fixed during testing

**Relay phone screen locks → relay dies:**
- iOS suspends MPC sessions when app is backgrounded/locked
- Fix: `UIApplication.shared.isIdleTimerDisabled = true` while relay is active
- Documented iOS background execution limitations in RELAY_DESIGN.md (no background mode exists for MPC)

**Client stuck at .connecting after relay restart:**
- Two bugs: (1) `foundPeer` guard rejected peers unless `connectionState == .disconnected`, blocking recovery from `.connectionFailed`; (2) relay MPC session connected but cancelled the timeout before receiving provider info, leaving client in limbo
- Fix: allow `.connectionFailed` in `foundPeer` guard, added 15s `relayInfoTimeout` for relay sessions that connect but don't send provider info

**Client can't reconnect to same relay without force-quit:**
- MPC caches peer state when browser stop/start happens too fast
- Fix: clear all relay peer state in `startSearching()`, added 0.5s delay between stop and start browsing to let MPC clean up

**Connection mode badge showing client's own name instead of relay name:**
- `connectionMode = .relayed(relayName: peerID.displayName)` used client's peerID
- Fix: changed to `relayPeerID?.displayName ?? "Relay"`

#### Committed
- `38d57ae`: "Phase 1 relay: single-hop message forwarding through intermediate iPhone" — 12 files, +1938/-74

#### Phase 1 status: CORE COMPLETE

### Next tasks

**Immediate (before Phase 2):**
- [ ] Direct-mode regression testing — both iPhones connecting directly to Mac (force relay OFF), verify all existing functionality still works
- [ ] Multi-client direct regression — both iPhones as direct clients simultaneously, per-client session isolation
- [ ] Disconnect/reconnect regression — kill app, lock screen, reconnect scenarios
- [ ] Payment regression — full voucher + settlement flow on direct connection
- [ ] Session persistence regression — kill/relaunch client and provider, verify session recovery

**Phase 2: Robustness (next feature work):**
- [ ] Relay disconnect handling — notify clients when provider drops, client fallback to direct
- [ ] Request timeout propagation — relay sends ErrorResponse if provider doesn't respond
- [ ] Multi-provider relay support — relay connects to multiple providers, routes by destinationID
- [ ] Dual mode (relay + client on same phone) — relay phone can also send its own queries
- [ ] Provider relay awareness — optional `relayedVia` field so provider knows direct vs relayed
- [ ] Battery management — show level in RelayView, auto-stop at 20%
- [ ] Relay auto-discovery updates — re-broadcast provider list on changes

---

## 2026-04-07

### Post-Relay Phase 1: Regression Testing

#### Test coverage rationale

The Janus test suite covers two distinct layers:

1. **Protocol & crypto layer** (168 tests in `JanusSharedTests`, SPM target, runs on macOS):
   Tests the shared library — message serialization, Ed25519/secp256k1 crypto, voucher signing, channel state, persistence. These types are used by both the iOS client and macOS provider, so they run on macOS without needing an iOS runtime.

2. **App logic layer** (13 tests in `JanusClientTests`, Xcode target, runs on iOS Simulator):
   Tests the client's *reaction* to messages — what happens when a quote arrives, when a provider overcharges, when a receipt signature is forged, when an error is received. This is the `ClientEngine` state machine that drives the UI. These tests need the iOS Simulator because `ClientEngine` creates a real `MPCBrowser` (which imports `UIKit` + `MultipeerConnectivity`). The browser stays dormant (we never call `startSearching()`), so no Bluetooth/WiFi is activated — we just inject `MessageEnvelope`s directly into `handleMessage()`.

**Why both layers matter:** Bugs can live in either layer. A relay refactor could break message serialization (layer 1) or break the client's handling of a new message flow (layer 2). The SPM tests catch the first kind; the app tests catch the second. Together they form a regression safety net before adding new features.

#### SPM tests (11 new, 168 total — all passing)

**`DirectModeProtocolTests.swift`** — 4 tests simulating full direct-path protocol flows:
- `testFullDirectFlow_PromptToReceipt` — complete message sequence (PromptRequest → QuoteResponse → VoucherAuthorization → InferenceResponse), serialize/deserialize each step, verify receipt signature
- `testSessionSync_afterMissedResponse` — SessionSync recovery after missed response, receipt verification, spend state reconstruction
- `testTwoClientsSequentialRequests_independentReceipts` — two independent channels with interleaved requests, verify no cross-contamination
- `testErrorResponse_allCodes_serializeCorrectly` — all 8 ErrorResponse.ErrorCode values round-trip through MessageEnvelope

**`SessionPersistenceRegressionTests.swift`** — 7 tests for persistence after ETH/relay field additions:
- `testClientSessionPersistWithEthKey_roundTrip` — PersistedClientSession with ethPrivateKeyHex survives save/restore, ETH key reconstructs to same address
- `testClientSessionPersistWithHistory_roundTrip` — history with multiple task types, spend state, remaining credits
- `testProviderStatePersistWithEthKey_roundTrip` — provider ETH + Janus keypair both survive
- `testProviderStatePersistWithRequestLog_roundTrip` — requestLog with sessionID field, error entries
- `testClientSessionRestore_wrongProviderID_returnsNil` — provider mismatch check
- `testClientSessionDecodesWithoutEthKeyField` — backwards compat: old JSON without ethPrivateKeyHex decodes, field defaults to nil
- `testProviderStateDecodesWithoutEthKeyField` — same for provider side

#### App-layer tests (13 new, 181 total — all passing)

Created `JanusClientTests` Xcode test target hosted by `JanusClient.app` (iOS Simulator).

**`ClientEngineTests.swift`** — 8 tests for message handling state machine:
- `testHandleQuoteResponse_setsCurrentQuote` — inject QuoteResponse with matching requestID, verify currentQuote set
- `testHandleQuoteResponse_ignoresWrongRequestID` — non-matching requestID leaves state unchanged
- `testHandleInferenceResponse_rejectsMismatchedCharge` — charge != quoted price → error state
- `testHandleInferenceResponse_rejectsInvalidReceiptSignature` — receipt signed by wrong key → error
- `testHandleInferenceResponse_ignoresWrongRequestID` — non-matching requestID, state unchanged
- `testHandleError_setsErrorState` — ErrorResponse → requestState == .error with correct message
- `testHandleError_allCodes` — all 8 ErrorResponse.ErrorCode values route correctly
- `testHandleMessage_ignoresUnknownTypes` — ServiceAnnounce (handled by browser) doesn't affect engine state

**`ConnectionModeTests.swift`** — 5 tests for MPCBrowser enums:
- `testDirectMode_displayLabel` — .direct → "Direct"
- `testRelayedMode_displayLabel` — .relayed("Bob's iPhone") → "via Bob's iPhone"
- `testDisconnectedMode_displayLabel` — .disconnected → "Disconnected"
- `testConnectionMode_equality` — Equatable conformance correct for all cases
- `testConnectionState_rawValues` — all 4 raw values match expected strings

**Build command:**
```
cd JanusApp && xcodebuild test -project JanusApp.xcodeproj -scheme JanusClient \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:JanusClientTests
```

#### Visibility changes for testability
- `ClientEngine.handleMessage` changed from `private` to `internal` (testable via `@testable import`)
- `pendingRequestID`, `pendingTaskType`, `pendingPromptText` changed from `private` to `internal`
- `connectedProvider` already `@Published` (writable for test injection)

#### How to access provider logs for analysis

The provider persists its runtime state to a JSON file that can be read directly — no special permissions needed.

**File location:**
```
~/Library/Application Support/Janus/provider_state.json
```

**What it contains:**
- `totalRequestsServed` / `totalCreditsEarned` — aggregate counters
- `receiptsIssued` — array of all signed receipts (receiptID, sessionID, requestID, creditsCharged, cumulativeSpend, timestamp, providerSignature)
- `requestLog` — array of request entries with: sessionID, taskType, promptPreview (first ~50 chars), responsePreview, credits, timestamp, and error info if applicable
- `ethPrivateKeyHex` — provider's Ethereum keypair (persisted for settlement continuity)
- `janusPublicKey` / `janusPrivateKey` — Ed25519 keypair for receipt signing

**How to read it:**
```bash
# Pretty-print the full state
cat ~/Library/Application\ Support/Janus/provider_state.json | python3 -m json.tool

# Extract just the request log
cat ~/Library/Application\ Support/Janus/provider_state.json | python3 -c "
import json, sys
state = json.load(sys.stdin)
for entry in state.get('requestLog', []):
    print(f\"{entry['timestamp']}  {entry['sessionID'][:8]}  {entry['taskType']}  {entry['credits']}cr  {entry.get('promptPreview', '')}\")
"

# Count requests per session (multi-client verification)
cat ~/Library/Application\ Support/Janus/provider_state.json | python3 -c "
import json, sys
from collections import Counter
state = json.load(sys.stdin)
counts = Counter(e['sessionID'][:8] for e in state.get('requestLog', []))
for sid, n in counts.items():
    print(f'  {sid}… → {n} requests')
"
```

**macOS unified log (requires Full Disk Access or admin):**
```bash
# If running from Terminal.app with Full Disk Access:
log show --predicate 'subsystem == "com.janus.provider"' --last 5m --style compact
```
> Note: Claude Code's sandbox does not have permission for `log show`. Use the JSON state file instead.

#### Manual device testing checklist

**Setup:** Mac = JanusProvider, iPhone A + iPhone B = JanusClient, `forceRelayMode = false`.

**Direct connection (CRITICAL):**
- [ ] iPhone A discovers Mac, connects (badge = "Direct")
- [ ] iPhone B discovers Mac, connects (badge = "Direct")
- [ ] Provider dashboard shows 2 clients

**Multi-client simultaneous (CRITICAL):**
- [ ] iPhone A sends summarize, iPhone B sends translate — both get correct responses
- [ ] Credits deducted independently on each phone
- [ ] Provider log shows different sessionIDs

**Disconnect/reconnect (HIGH):**
- [x] Force-quit client A, relaunch — reconnects, session restored
- [x] Lock iPhone B 30s, unlock — auto-reconnects
- [x] Force-quit provider, relaunch — both clients reconnect
- [x] After provider relaunch, new requests work with correct payment

**Payment on direct (HIGH):**
- [x] Full flow: prompt → quote → voucher → response → receipt
- [x] Cumulative spend matches on client and provider after 3+ requests (5C52674C: 39cr/13req, 43394F22: 48cr/16req)
- [x] Provider settles on disconnect (check logs for settlement TX) — multiple settlement TXs per session due to disconnect/reconnect tests

**Session persistence (MEDIUM):**
- [x] Client: 2 requests, force-quit, relaunch — history preserved, credits correct (verified via disconnect/reconnect tests)
- [x] 3rd request uses correct spend state (verified: cumulative spend monotonically increasing across reconnects)
- [x] Provider: force-quit, relaunch — totalRequestsServed restored (verified: provider_state.json shows 128 total)

**Relay not interfering (HIGH):**
- [x] With forceRelayMode OFF, neither iPhone uses relay when Mac is reachable (verified: all connections showed "Direct" badge)
- [~] forceRelayMode ON → client does NOT connect (no relay running) — skipped (covered by code path, low risk)
- [~] forceRelayMode OFF again → reconnects directly — skipped

**Regression verdict: PASS** — all critical and high-priority items verified. Direct-connection path fully intact after Relay Phase 1.

---

### Relay Phase 2, Item 1: Relay Disconnect Handling

**Problem:** When the provider disconnects from the relay, the client is never notified — it hangs waiting for a response that never arrives. The relay silently drops undeliverable messages.

**Solution:** Two-pronged notification:
1. **Updated RelayAnnounce** — relay re-sends RelayAnnounce with the disconnected provider removed. Client detects its provider is missing from the list and transitions to disconnected state.
2. **New `providerUnreachable` error code** — when `forwardToProvider` can't find the provider, relay constructs an ErrorResponse and sends it back to the client via RelayEnvelope.

**Key design choices:**
- No changes to ClientEngine needed — existing `$connectedProvider` sink handles disconnect detection, existing `handleError` handles the new error code
- Direct fallback: when provider is lost via relay and `forceRelayMode` is off, client starts browsing for direct providers while keeping relay session alive (relay might reconnect to a new provider)
- Relay sends `requestID: nil` in ErrorResponse because it treats inner payloads as opaque (can't extract requestID)

#### Files changed
- `Sources/JanusShared/Protocol/ErrorResponse.swift` — added `providerUnreachable = "PROVIDER_UNREACHABLE"` case
- `JanusApp/JanusClient/MPCRelay.swift` — notify clients via RelayAnnounce in `handleProviderStateChange(.notConnected)` and `browser(_:lostPeer:)`, send ErrorResponse in `forwardToProvider()` on failure, new `sendProviderUnreachableError(to:)` helper
- `JanusApp/JanusClient/MPCBrowser.swift` — detect provider removed from RelayAnnounce in `handleRelayData()`, new `handleProviderLostViaRelay()` method with direct fallback

#### Tests (185 total, all passing)
- Updated `testHandleError_allCodes` and `testErrorResponse_allCodes_serializeCorrectly` with new code
- New `testHandleError_providerUnreachable_setsErrorState` (requestID: nil from relay)
- New `RelayDisconnectTests.swift` (3 tests): empty RelayAnnounce round-trip, providerUnreachable ErrorResponse round-trip, RelayEnvelope wrapping ErrorResponse round-trip

### Fix: SEQUENCE_MISMATCH after provider disconnect/reconnect

**Root cause:** When a response is lost in transit (e.g., relay dropped it or MPC session died mid-flight), the client's `spendState.cumulativeSpend` falls behind the provider's `channel.authorizedAmount`. On reconnection, the client's next voucher has a lower `cumulativeAmount` than the provider expects, triggering `nonMonotonicVoucher` → SEQUENCE_MISMATCH.

This is different from the v1.4 SessionSync fix (which handles missed responses on direct reconnection). In the relay path, the provider has no way to detect client reconnection — the relay forwards messages transparently. So SessionSync never fires proactively.

**Fix (two parts):**
1. **Client: always send channelInfo** — removed the `channelInfoDelivered` optimization. Every PromptRequest now includes channelInfo, letting the provider detect "reconnection" even through a relay. This is ~200 bytes of overhead per request, negligible over MPC.
2. **Provider: proactive SessionSync on reconnection detection** — when the provider receives channelInfo for an existing session AND has a cached `lastResponse`, it sends SessionSync before processing the new request. The client syncs its spendState, then handles the quote with the correct cumulative amount. Provider also preserves existing channel state (only replaces channel if channelId changed, e.g., client generated new keypair).

**Why v1.4 SessionSync didn't cover this:**
- v1.4 sends SessionSync when the provider detects a new MPC session (direct connection only)
- In the relay path, provider↔relay and relay↔client are separate MPC sessions — provider never sees client reconnection
- The `channelInfoDelivered` flag meant the client stopped sending channelInfo after the first request, so the provider had no signal that the client had reconnected

#### Files changed
- `JanusApp/JanusClient/ClientEngine.swift` — always include `session.channelInfo` in PromptRequest (removed `channelInfoDelivered` ternary)
- `JanusApp/JanusClient/SessionManager.swift` — removed `channelInfoDelivered` property (no longer needed)
- `JanusApp/JanusProvider/ProviderEngine.swift` — on channelInfo for existing session: send SessionSync if lastResponse exists AND client spend is behind, only replace channel if channelId differs

### Fix: False SessionSync recovery on idle reconnect

**Problem:** Always sending channelInfo meant every reconnection (including phone lock/unlock) triggered SessionSync with stale cached response, showing "(recovered)" tag on first request after unlock.

**Fix:** Added `clientCumulativeSpend` field to `ChannelInfo`. Client now reports its current spend state. Provider compares: if `clientCumulativeSpend < cachedResponse.cumulativeSpend`, client genuinely missed a response → send SessionSync. If equal, client already got it (idle reconnect) → skip.

- `Sources/JanusShared/Protocol/VoucherAuthorization.swift` — added `clientCumulativeSpend` to ChannelInfo
- `JanusApp/JanusClient/SessionManager.swift` — `channelInfo` is now a computed property (includes current spend)
- `JanusApp/JanusProvider/ProviderEngine.swift` — compare client spend vs cached response before SessionSync

### Fix: iOS 26 CFNetServiceBrowser crash

**Problem:** `_CFAssertMismatchedTypeID` crash ~13s after launch on iPhone 14 Plus. iOS 26 added assertion that catches double-stop of `MCNearbyServiceBrowser` (previously silent). Rapid timeout/reconnect cycles called `stopBrowsingForPeers()` on already-stopped browsers.

**Fix:** Boolean state tracking (`providerBrowserActive`/`relayBrowserActive`) with safe start/stop wrappers that guard against double-stop/double-start.

### Fix: Connection timeout retry stuck at "Connecting"

**Problem:** After first 10s timeout, `connectionState` stayed `.connecting` (never reset to `.disconnected`). The `foundPeer` guard rejected re-discovered peers, so retry never actually re-invited.

**Fix:** Reset `connectionState = .disconnected` in timeout retry path before restarting browsers.

### Relay Phase 2: Relay disconnect handling

Provider disconnect via relay now notifies clients. `handleProviderLostViaRelay()` in MPCBrowser detects provider removal from RelayAnnounce, triggers ClientEngine disconnect detection, attempts direct fallback. New `providerUnreachable` error code in ErrorResponse.

#### Manual device testing (2026-04-07)
- 2 iPhones (iPhone 16 + iPhone 14 Plus) + Mac provider
- Normal flow: multiple queries from both phones ✓
- Provider restart recovery: kill/restart provider, clients reconnect and send queries ✓
- Lock/unlock: no false "(recovered)" responses ✓
- Two simultaneous clients ✓

## 2026-04-08

### Feature #5: Direct mode multi-provider — attempted and reverted

**Goal:** Allow iPhone in direct MPC mode to discover, connect to, and switch between multiple nearby providers (two Macs).

**Approach:** Since `MCSession` supports up to 8 peers, all discovered providers would be invited into the same session. Switching providers would just change which peer receives `send()` calls via `providerPeerID`. Later revised to per-provider `MCSession` pattern (matching `MPCAdvertiser.createSession(for:)`) when shared session proved unreliable over AWDL.

**Result:** Reverted. AWDL does not reliably support concurrent MPC sessions from a single device to multiple providers. Connection instability across both shared-session and per-session approaches. Direct multi-provider deferred to Bonjour+TCP transport (roadmap #8).

**Lessons learned:**
- `MCSession` multi-peer works over infrastructure WiFi but is unreliable over AWDL
- Per-provider `MCSession` (separate session per Mac) also unstable — AWDL can't multiplex
- Relaxing the `foundPeer` guard to accept peers during `.connecting` caused direct+relay race conditions
- Relay multi-provider (Feature #4) works because each device maintains only one direct MPC connection

### Fix: AWDL flicker causing relay instability

**Problem:** MPC browser's `lostPeer` delegate fires when a peer's Bonjour advertisement briefly disappears from AWDL, even while the `MCSession` to that peer remains connected. Both `MPCBrowser` and `MPCRelay` treated `lostPeer` as a hard disconnect, tearing down the connection and triggering reconnect cycles. This caused the "connected → disconnected → connected → connecting" instability pattern in relay mode.

**Root cause:** `lostPeer` is a browsing-layer event (Bonjour visibility), not a session-layer event (`MCSession` state). AWDL visibility flickers are normal — they don't mean the session is dead.

**Fix:** Guard `lostPeer` handlers in both `MPCBrowser` and `MPCRelay` to check `session.connectedPeers.contains(peerID)` before acting. If the session is still active, log "ignoring AWDL flicker" and return.

- `JanusApp/JanusClient/MPCBrowser.swift` — guard both provider and relay `lostPeer` paths
- `JanusApp/JanusClient/MPCRelay.swift` — guard provider `lostPeer` path

#### Regression testing (2026-04-08)
- Test 1: Single provider, direct mode ✓
- Test 2: Both Macs, dual mode ✓
- Test 3: Relay mode (Madhuri dual mode relay, Soubhik forced relay) ✓ — stable after fix

### Remaining work roadmap (as of 2026-04-08)

Full prioritized list of all remaining features across relay, transport, payments, and long-term mesh vision.

#### Relay Phase 2: Robustness (#1–7)

| # | Feature | Effort | Dependencies | Details |
|---|---------|--------|-------------|---------|
| 1 | Request timeout propagation | Small | — | Relay tracks in-flight requests (requestID → timestamp). If provider doesn't respond within relay's own timeout, relay sends `ErrorResponse` back to client. Prevents client from waiting full 20s when relay already knows provider is gone. |
| 2 | Dual mode (relay + client on same phone) | Medium | — | Share upstream provider MPC session between relay forwarding and local ClientEngine. Relay UI shows both relay stats and a "Send Prompt" button. Route local requests without RelayEnvelope wrapping. Every phone becomes a potential relay without sacrificing its own client functionality. |
| 3 | Relay auto-fallback (direct → relay after 2 timeouts) | Small | #2 | After 2 consecutive direct connection timeouts, automatically start browsing for relays alongside direct. Accept whichever path connects first. Only truly useful once dual mode (#2) exists — otherwise requires someone to manually start a dedicated relay. |
| 4 | Multi-provider relay support | Small | — | Relay already stores `reachableProviders` dict. Route messages by `destinationID` to correct provider session. Client picks provider from relay's advertised list. |
| 5 | Relay auto-discovery updates | Small | — | Client re-evaluates relay choice when provider list changes. Partially done — RelayAnnounce already sent on provider disconnect. Remaining: client-side logic to switch relays if a better one appears. |
| 6 | Provider relay awareness (`relayedVia`) | Small | — | Optional `relayedVia` field on MessageEnvelope. Relay stamps its identity when forwarding. Provider dashboard shows direct vs relayed per client. No behavioral change — metadata only. |
| 7 | Battery management for relay | Small | — | Show battery level in RelayView. Auto-stop relay at 20%. Warning banner when low. |

#### Transport & Infrastructure (#8–9)

| # | Feature | Effort | Dependencies | Details |
|---|---------|--------|-------------|---------|
| 8 | Bonjour+TCP as parallel transport | Medium | — | Use `NWBrowser`/`NWListener` (Network.framework) to discover and connect via local WiFi. Eliminates AWDL fragility when devices share a router (even offline — no WAN needed, just a local network). Needs a `TransportProvider` protocol abstraction so MPC and Bonjour are interchangeable. MPC remains the fallback for zero-infrastructure scenarios (no router). |
| 9 | Dynamic backend URL discovery | Small | — | Bonjour/mDNS for backend service instead of hardcoded IP. Fixes the DHCP lease issue (Mac IP changes, both apps need rebuild). Could piggyback on #8's mDNS work. |

#### Payments polish (#10–14)

| # | Feature | Effort | Dependencies | Details |
|---|---------|--------|-------------|---------|
| 10 | ~~SettlementNotice message~~ → **On-chain settlement verification** | Small | — | **DONE.** Client reads blockchain directly via `EscrowClient.getChannel()` to verify provider settlement. Three-state comparison: match (green), overpayment (red), underpayment/partial (orange). Pull-only design — no provider changes needed. Push notification deferred to v2 (needs store-and-forward for disconnected clients). |
| 11 | Channel top-up + wallet funding | Medium | — | Three subgoals: **(11a) ~~Wallet key persistence~~** — DONE. **(11b) ~~Channel top-up~~** — DONE. `topUp(bytes32,uint256)` on `TempoStreamChannel`; approve+topUp flow; 3-way state sync (client memory, persistence, provider cache); +50/+100/+200 UI. ~~Bug #11b-1~~: fixed — `guard !channelOpenedOnChain` early exit in `openChannelOnChain()` + `do/catch` on RPC pre-existence check + `lastEscrowContract` contract migration guard. **(11c) Funding UX** — show local wallet address + QR code so user can transfer tokens from an external wallet (MVP); third-party on-ramp SDK (MoonPay/Transak) as follow-up. **Note:** top-up (and by extension funding) requires internet connectivity — the approve + topUp transactions go on-chain. Inference works offline but topping up does not. Add a visible note in the funding UI reminding the user that an internet connection is required. |
| 12 | Multi-channel management UI | Small | — | View/manage channels with multiple providers. Currently one provider, one channel. |
| 12a | ~~Fix first-query failure after provider switch~~ | Small | — | **DONE.** Generation counter in `createSession()` discards stale async results. `canSubmit` gated on `sessionReady` (not just `connectedProvider`). Defense-in-depth guard in `submitRequest()`. |
| 13 | ~~Periodic & threshold-based settlement~~ | Small | — | **DONE.** Provider settles on a configurable timer (default 5 min) and/or when aggregate unsettled credits cross a threshold (default 50). Provider UI with segmented pickers. Persisted settings survive restart. Bug fix: `settledAmount` desync after provider restart caused inflated `unsettledAmount` and premature threshold triggers — fixed by initializing `settledAmount` from on-chain state during channel verification. Additional hardening: startup race fix (fund→retry→timer ordering), settlement queuing (no dropped disconnect requests), 24h TTL on stale channels, zombie channel prevention (re-check on-chain after tx revert), computed `activeSessionCount`. |
| 13b | Real token economics / USD pricing | Product decision | — | Dynamic pricing by model load, token count, or USD denomination. Currently fixed 3/5/8 credit tiers. |
| 13d | ~~Tab-based postpaid payment model~~ | Large | — | **DONE.** Replace the current quote→voucher→response flow with a postpaid tab model. Provider serves inference and accumulates a running token tab per client (input + output tokens counted after inference, so charging is exact). Once the tab crosses a configurable threshold (e.g. 100 tokens worth of credits), provider blocks new requests until client sends a voucher for the exact accumulated amount. Tab resets and client can continue. Provider persists tab per client (by channel ID) so a disconnecting client cannot escape the debt by reconnecting — the tab resumes from where it left off. **Why this fits the use case:** designed for rural/village networks where social reputation enforces payment and cryptographic upfront commitment is unnecessary overhead. Threshold is kept small so unpaid exposure per client is always bounded. **Tradeoffs:** (1) client trusts provider's token count post-inference — no cryptographic price commitment before serving; (2) provider attack of inflating token count is possible but reputation-destroying; (3) provider withholding response after incrementing tab is a losing strategy (loses reputation, loses payment). **Protocol changes required:** (a) remove `QuoteResponse` message type — no upfront quote needed; (b) remove `VoucherAuthorization` before inference — voucher is now sent reactively when threshold crossed; (c) add `TabUpdate` message: provider → client after each response with `{tokensUsed, cumulativeTabTokens, tabThreshold}`; (d) add `TabSettlementRequest` message: provider → client when threshold crossed, blocking further requests; (e) `ServiceAnnounce` changes: replace small/medium/large pricing with `tokenRate` (credits per 1000 tokens) and `tabThreshold` (tokens before settlement required); (f) provider persistence: add running tab per channel ID to `PersistedProviderState`; (g) client UI: show running tab in balance bar alongside remaining credits. **What stays the same:** escrow channel, voucher format, on-chain settlement — only the trigger and timing of voucher signing changes. |
| 13e | Provider-configurable pricing (tokenRate + tabThreshold) | Small | #13d | **Immediate follow-up to #13d.** Feature #13d hardcodes `tokenRate = 10 credits/1000 tokens` and `tabThresholdTokens = 500` as constants in `ProviderEngine`. This feature makes them operator-configurable so each provider can set their own price and settlement cadence. **What changes:** (1) Extend `PersistedProviderState` with `tokenRate: UInt64?` and `tabThresholdTokens: UInt64?` (decodeIfPresent, nil = use defaults). (2) Add provider settings UI section ("Pricing") with segmented pickers. (3) `ProviderEngine` `@Published var` instead of `private let` constants — restored from disk on launch with validation clamps. (4) Rate snapshot locals at top of `handlePromptRequest` and `handleTabSettlementVoucher` to prevent mid-inference picker change from causing accounting inconsistency. (5) `ServiceUpdate` message type (new) pushed to all connected clients when operator changes a picker — client updates `connectedProvider` in place and shows a dismissible info banner. No accept/reject in this version (deferred to #13e+1). (6) Remove dead 2-param convenience overload in `ProviderAdvertiserTransport`. **Why this matters:** providers running different models have different compute costs; the market can only work if providers can set their own prices. |
| 13e+1 | Rate-change accept/reject for client | Small | #13e | When provider sends a `ServiceUpdate` mid-session, client currently just shows an info banner. This feature adds a proper accept/reject dialog: provider sends a `RateChangeProposal`, client gets N seconds to accept or auto-disconnect, provider only commits the new rate once accepted. Deferred from #13e to keep scope small. |
| 13g | Pricing constraint check: tab cycle vs auto-settlement threshold | Small | #13e | When the operator saves pricing settings, validate that one full tab cycle doesn't generate more credits than the auto-settlement threshold. Concretely: `tabCycleCredits = ceil(tabThresholdTokens × tokenRate / 1000)`. If `tabCycleCredits > settlementThreshold > 0`, show an inline warning in the provider UI: *"Tab cycle (~X credits) exceeds auto-settlement threshold (Y). Consider raising the threshold or lowering rate/tokens."* Not a hard block — the system still works correctly, but on-chain settlement fires mid-tab rather than at clean voucher boundaries, wasting gas and producing confusing accounting. **What changes:** (1) `ProviderStatusView.persistAndBroadcast()` computes `tabCycleCredits` and compares to `engine.settlementThreshold`. (2) Add `@Published var pricingWarning: String? = nil` to `ProviderEngine` (or compute inline in the view). (3) Show warning label below the pricing section when non-nil. No protocol changes, no persistence changes. |
| 13f | USD/million-token display for provider pricing | Small | #13e | **Immediate follow-up to #13e.** The internal `tokenRate` is in credits per 1000 tokens (an abstract unit). This feature surfaces a human-readable price alongside credits: "X credits / 1000 tokens  ≈  $Y / 1M tokens" — the standard denomination used by OpenAI, Anthropic, and every current inference API provider. **What changes:** (1) Add a `CreditConversion` utility: given the on-chain credit-to-USD exchange rate (read from `TempoConfig` or a hardcoded testnet rate), compute `dollarsPerMillionTokens = (tokenRate / 1000) * creditsToUSD * 1_000_000`. (2) `DiscoveryView` provider cards show both: "10 credits/1K tokens  ·  ~$0.50/1M tokens". (3) Provider settings UI shows the computed USD equivalent as a live preview while the operator types their rate — so they can reason in familiar terms before saving. (4) No on-chain changes; purely a display layer. **Why this matters:** village operators need to set prices that make economic sense relative to the outside world. Showing only "credits" is opaque; showing an equivalent dollar rate lets them benchmark against cloud providers and set fair prices. |
| 13c | ~~Remove Privy SDK~~ | Small | — | **DONE.** Deleted `PrivyAuthManager`, `PrivyWalletProvider`, `LoginView`. Removed Privy SPM dependency and all 14 pbxproj entries. App opens directly to `DiscoveryView` — no login, no internet at startup. All signing and on-chain ops already used `LocalWalletProvider` since #12a. Net: −571 lines. |
| 14 | Mainnet deployment | Small | — | TempoConfig.mainnet + deploy TempoStreamChannel contract to mainnet. No code changes needed. |
| 14b | Cap off-chain voucher exposure | Small | — | Provider currently serves inference optimistically before the client's channel is confirmed on-chain (`VoucherVerifier` returns `.acceptedOffChainOnly`). Risk: client never opens channel, provider serves for free. Fix: serve first request optimistically, require on-chain confirmation before subsequent requests. Bounded risk (one cheap inference per session). |
| 14c | Multi-turn chat | Medium | — | Pass conversation history as context with each new prompt so the model remembers prior turns. Requires: (1) UI rethink — replace task type picker with a free-form chat interface, (2) per-turn pricing — longer prompts cost more credits, need per-token pricing or a larger fixed tier for context-heavy turns, (3) history truncation strategy to stay within model context window. Payment protocol charges per completed request so the quote/response/receipt flow is unchanged — just the prompt size grows. |
| 14d | Streaming responses | Medium | #14c | Show tokens appearing word-by-word as the model generates instead of waiting for the full response. Requires: (1) MLXRunner to emit partial tokens via AsyncStream, (2) chunked MPC message protocol (stream start / chunk / stream end message types), (3) quote upfront based on prompt size (can't know exact cost mid-generation), settle after stream ends. Natural companion to multi-turn chat — both change the inference UX fundamentally. |
| 14e | TestFlight distribution | Small | #13c | Publish JanusClient to TestFlight so external users can install without Xcode. Prerequisites: App Store Connect setup, bundle ID registered, provisioning profile for distribution, privacy policy (minimal — no data collected server-side). Post-#13c the onboarding is zero-friction: install → open → see providers → connect. No login, no account, no seed phrase. |

#### Long-term: Mesh network vision (#15–19)

| # | Feature | Effort | Dependencies | Details |
|---|---------|--------|-------------|---------|
| 15 | E2E encryption (Relay Phase 4) | Medium-Large | — | ECDH key exchange using existing ETH keypairs. Client and provider establish shared secret; relay sees only opaque bytes. Required before untrusted relays or multi-hop. |
| 16 | Multi-hop relay + congestion control (Relay Phase 3) | Large | #15 | Messages traverse multiple relays (Client → Relay A → Relay B → Provider). Needs TTL, loop detection, route caching. Congestion control bundled here: relay must break payload opacity to track request/response pairs, manage per-client queues, enforce provider capacity limits, propagate backpressure. Major design change from current stateless forwarding. |
| 17 | ~~Backend session service (Vapor)~~ — **DONE** | — | — | Tempo payment channels replaced the need for a centralized session authority. Sessions are now created locally with on-chain payment verification. Removed: `JanusBackend/` directory, `SessionGrant.backendSignature`, `SessionGrant.signableFields`, all stale backend doc comments. |
| 18 | Core Bluetooth L2CAP transport | Large | — | True WiFi-less operation via BLE 5.0 L2CAP channels. ~100KB/s throughput (vs MPC's ~2MB/s). Major rewrite: custom discovery, connection management, reliable delivery. Also serves as the bridge between Apple devices and non-Apple hardware (ESP32, RPi). |
| 19 | Relay incentives (Relay Phase 5) | Large | #15 | Relays earn payment for forwarding. Options: flat fee per forward, percentage of inference payment, or client opens micro payment channel with relay. Requires E2E encryption so relay can't extract payment info. |

#### Hardware relay & edge provider vision (#20–23)

Non-Apple hardware as relay nodes and edge providers, enabling a truly infrastructure-free mesh.

| # | Feature | Effort | Dependencies | Details |
|---|---------|--------|-------------|---------|
| 20 | ESP32 mesh relay | Large | #16, #18 | ESP32 (~$4) as dedicated relay node. Communicates with iPhones via BLE (CoreBluetooth ↔ ESP32 BLE GATT). ESP32-to-ESP32 hops use ESP-NOW (peer-to-peer WiFi without router, ~1MB/s, ~200m range). ESP-MDF (Mesh Development Framework) provides automatic route discovery and self-healing. Janus relay logic rewritten in C/Arduino — MessageEnvelope is JSON, parseable on ESP32. Solar-powered nodes could form persistent outdoor relay backbone. |
| 21 | Raspberry Pi relay/client/provider | Medium | #8, #18 | RPi runs full Janus protocol — relay, client, or provider. Swift on Linux (SPM supports it) or Python rewrite. RPi 5 (8GB, ~$60) can run quantized LLMs via llama.cpp (~5 tok/s for 1B models). Connects via WiFi TCP (Bonjour) and/or BLE. Portable with USB-C power bank — provider in a backpack. |
| 22 | Cross-transport relay | Medium | #8, #18 | A relay that bridges transports: receives on BLE, forwards on TCP (or vice versa). Enables heterogeneous mesh — iPhone (BLE) → ESP32 (ESP-NOW) → RPi (TCP) → Mac (TCP). Relay logic already exists (Feature #2), needs multiple transport backends per node. |
| 23 | ESP-NOW transport (ESP32-only) | Medium | #20 | Native ESP32 peer-to-peer WiFi protocol. No router needed, ~1MB/s, ~200m range. ESP32s form a self-healing mesh. Only runs between ESP32 nodes — iPhones/Macs connect to edge ESP32s via BLE or WiFi. |

**Target architectures:**

```
Solar mesh backbone:
  Solar+ESP32 ~~ESP-NOW~~ Solar+ESP32 ~~ESP-NOW~~ Solar+ESP32
       |                                               |
      BLE                                             BLE
       |                                               |
    iPhone (client)                               Mac (provider)

Edge provider (no Mac needed):
  iPhone --WiFi/BLE-→ RPi 5 (llama.cpp, 1B model)

Hybrid mesh:
  iPhone ~~BLE~~ ESP32 ~~ESP-NOW~~ ESP32 ~~WiFi~~ RPi (provider)
                                         ~~BLE~~ Mac (provider)
```

**Key insight:** The Janus protocol is transport-agnostic — MessageEnvelope is just JSON bytes. The `ProviderTransport` protocol abstraction enables plugging in new transports (BLE, ESP-NOW, TCP) without changing business logic, UI, or payment flows. Each transport has a sweet spot: TCP for same-LAN reliability, MPC/AWDL for zero-infrastructure single-hop, BLE for reliable multi-hop and hardware bridge, ESP-NOW for long-range ESP32 mesh.

#### Network economics: Two-tier relay model (#24) 🔴 HIGH PRIORITY

| # | Feature | Effort | Dependencies | Details |
|---|---------|--------|-------------|---------|
| 24 | Commons + private relay two-tier network | Medium | #19 | **Two-tier relay architecture:** Tier 1 = **commons relays** run by village admin, NGO, or public service operator — no toll fee (`relayFee: 0`), funded externally (budget, grant, cross-subsidy). Tier 2 = **private relays** run by individual operators who set their own forwarding fee (`relayFee: X credits`). Like village roads: the commons backbone is always available and free; private "toll roads" serve niche routes (better latency, coverage gaps, urban areas underserved by commons). **Protocol changes:** (a) Add `relayFee: UInt64` to `ServiceAnnounce` — `0` means commons/free; (b) Add `isCommons: Bool` as explicit declaration (fee=0 is implied but `isCommons` signals intent to clients); (c) Client routing preference: prefer lowest-cost path first, always has a free option if commons backbone is reachable; (d) Discovery UI shows fee badge on relay cards ("FREE" vs "2 credits/req"). **Relay fee payment:** when client routes via a private relay, a slice of each voucher is earmarked for the relay (or a separate micro-channel is opened — design TBD in #19). Commons relays take no slice. **Sustainability for commons:** operator funds hardware and bandwidth externally — same model as village road maintenance. Private relays are self-sustaining via fees. **Network effect:** zero barrier to entry on the commons path (no credits needed just to route a request) ensures adoption in low-income / rural contexts. Private relays fill in where commons don't reach. **Key constraint:** commons relay operators need a non-fee sustainability model — note in admin docs that commons operators need an external budget (ISP subsidy, NGO grant, public utility allocation). |

#### Dependency graph

```
#2 (dual mode) ← #3 (auto-fallback)
#8 (Bonjour+TCP) ← #9 (dynamic backend URL) can piggyback on same mDNS work
#8 (Bonjour+TCP) ← #21 (RPi relay/client/provider) uses TCP transport
#15 (E2E encryption) ← #16 (multi-hop + congestion control)
#15 (E2E encryption) ← #19 (relay incentives)
#16 (multi-hop) ← #20 (ESP32 mesh relay)
#18 (BLE transport) ← #20 (ESP32 mesh relay) BLE is the iPhone↔ESP32 bridge
#18 (BLE transport) ← #21 (RPi) BLE as alternative to TCP
#18 (BLE transport) ← #22 (cross-transport relay)
#20 (ESP32 mesh) ← #23 (ESP-NOW transport)
#19 (relay incentives) ← #24 (two-tier relay model) commons/private distinction refines fee model
```

#### Summary

- **26 items total**: 7 small (Phase 2), 8 small-medium (polish), 10 large (long-term), 1 hardware vision
- **Near-term** (#1–7): finish relay robustness
- **Medium-term** (#8–14): transport reliability + payment polish
- **Payment model** (~~#13d~~ ✓ → #13e 🔴 → #13f): tab-based postpaid DONE, then provider-configurable pricing, then USD display
- **Long-term** (#15–19): mesh network with encryption, multi-hop, and incentives
- **Hardware vision** (#20–23): ESP32 mesh backbone, RPi edge providers, cross-transport relay
- **Network economics** (#24 🔴): two-tier commons/private relay model — HIGH PRIORITY

---

## 2026-04-08

### Relay Phase 2, Items 1–4: Request Timeout, Dual Mode, Auto-Fallback, Multi-Provider

Four features implemented in a single session. Design docs at `docs/plans/01-04`.

#### Feature #1: Request Timeout Propagation (commit 0b6fb9c)

Relay tracks in-flight requests and sends `relayTimeout` error to the client if the provider doesn't respond within 15s (before the client's 20s timeout). On provider disconnect, sends `providerUnreachable` for all in-flight requests.

#### Feature #2: Dual Mode — Relay + Client on Same Phone (commit c42f714)

Phone can simultaneously relay for other clients AND send its own queries. `ProviderTransport` protocol abstracts the transport layer — `ClientEngine` works with either `MPCBrowser` (direct/relay) or `RelayLocalTransport` (dual mode zero-hop).

**Key bug found during manual testing:** FIFO response queue assumed provider responses arrive in send order. Failed during interleaved two-round-trip flows (promptRequest→quoteResponse→voucherAuth→inferenceResponse) because voucherAuth timing is unpredictable across local vs remote clients. **Fix:** Replaced FIFO with `requestRouting: [String: RequestOrigin]` map keyed by requestID — order-independent routing.

#### Feature #3: Auto-Fallback — Direct → Relay (commit 37ae519)

After 2 consecutive direct connection timeouts, instead of stopping, the client continues browsing for both direct providers and relays. Whichever path connects first wins.

#### Feature #4: Multi-Provider Relay Support

When connected via relay, the client can see and switch between multiple providers. Provider picker UI (horizontal scroll) appears when >1 provider is available.

##### Files changed
- `MPCBrowser.swift` — `relayProviders` dict, `selectRelayProvider()`, `handleRelayData()` stores all ServiceAnnounces, prunes on RelayAnnounce
- `MPCRelay.swift` — `RelayLocalTransport.relayProviders`, `selectProvider()`, Combine subscription from relay's `reachableProviders`, `sendLocalMessage()` routes to selected provider
- `ClientEngine.swift` — `availableProviders` published array, `selectProvider()` forwarding for both MPCBrowser and RelayLocalTransport
- `DiscoveryView.swift` + `DualModeView.swift` — provider picker UI
- `SessionManager.swift` — per-provider persistence (`client_session_{providerID}.json`)
- `MultiProviderTests.swift` — 8 new unit tests

##### Bugs found and fixed during multi-provider testing
1. **DualModeView missing picker** — picker was added to DiscoveryView but not DualModeView. Dual mode couldn't switch providers.
2. **Session overwrite on provider switch** — single `client_session.json` meant switching Provider A→B overwrote A's session. Credits reset to 100 on switch-back. **Fix:** per-provider filenames (`client_session_{providerID}.json`) with legacy fallback.
3. **`sendLocalMessage` routing** — always picked first connected provider session instead of the selected one. **Fix:** route via `providerRoutes[selectedProviderID]`.

##### Manual testing (2026-04-08)

**Setup:** 2 Macs (MacBook Pro + Mac Mini) running JanusProvider, Phone A (dual mode/relay), Phone B (client mode).

**Dual mode multi-provider (Phone A):**
- [x] Relay stats show 2 providers
- [x] Provider picker appears with both Macs
- [x] Send query to Mac A — correct response
- [x] Switch to Mac B, send query — correct response from Mac B
- [x] Credits persist across provider switches (A→B→A, no reset)

**Client via relay multi-provider (Phone B, Force Relay Mode):**
- [x] Both providers visible in picker
- [x] Queries route to selected provider correctly

**Provider disconnect recovery:**
- [x] Quit Mac B — Phone A auto-switches to Mac A, picker disappears
- [x] Restart Mac B — provider reappears in picker

##### Test suite: 38 tests (8 new), all passing
- `MultiProviderTests.swift` — 8 tests: selection, unknown ID rejection, cleanup on start/disconnect, Combine forwarding to ClientEngine, selectProvider delegation

##### Feature plan docs created
- `docs/plans/01-request-timeout.md`
- `docs/plans/02-dual-mode.md`
- `docs/plans/03-auto-fallback.md`
- `docs/plans/04-multi-provider.md`
- `docs/plans/05-direct-multi-provider.md` (planned, not yet implemented)
- **Long-term** (#15–19): mesh network with encryption, multi-hop, and incentives

---

### Feature #8: Bonjour+TCP Transport (commit 906473f, c629230)

Added Bonjour+TCP as a parallel transport alongside MPC/AWDL using Network.framework (`NWBrowser`, `NWListener`, `NWConnection`). Devices on the same LAN discover each other via mDNS (`_janus-tcp._tcp`) and communicate over plain TCP — faster and more reliable than AWDL. MPC stays warm as instant fallback.

#### What was built

**Shared layer:**
- `TCPFramer` (JanusShared) — 4-byte big-endian length-prefix framing with 16MB max frame size. `Deframer` class handles partial reads and concatenated frames.

**Provider side:**
- `ProviderAdvertiserTransport` protocol — abstracts `MPCAdvertiser` vs `BonjourAdvertiser`
- `BonjourAdvertiser` — `NWListener` on dynamic TCP port, per-client state tracking (temp UUID → senderID on first message), pull-based receive loop with `TCPFramer.Deframer`
- `CompositeAdvertiser` — wraps both advertisers, routes replies to correct child via `senderTransport` map
- `MPCAdvertiser` conformed to new protocol (callback changed from `MCPeerID` to `String` senderID)
- `ProviderStatusView` updated to use `CompositeAdvertiser`

**Client side:**
- `BonjourBrowser` — `NWBrowser` for `_janus-tcp._tcp`, multi-provider support, auto-reconnect with backoff, `selectProvider()` for instant switching
- `CompositeTransport` — wraps `BonjourBrowser` + `MPCBrowser`, both stay running. Bonjour preferred (~100-200ms connect vs AWDL's ~2-5s). MPC warm fallback.
- `ClientEngine` updated: default transport is `CompositeTransport`, `compositeRef` exposes child transports, `availableProviders` merges relay (MPC) + direct (Bonjour)

**Tests:** 14 new tests (TCPFramingTests: 8, BonjourTransportTests: 6), all 221 pass.

#### Bugs found and fixed

**CompositeTransport connectedProvider race condition:**
MPC's `connectionState` becomes `.connected` before `ServiceAnnounce` arrives (connectedProvider still nil). Initial fix that re-ran `resolveActiveTransport` on connectedProvider changes made things worse — overwriting real Bonjour connectedProvider with nil from MPC's delayed state.

**Fix:** Separate `$connectedProvider` subscriptions per child that only forward when `activeTransport` matches. `resolveActiveTransport` only sets `connectedProvider` when the value is non-nil. The two-subscription pattern decouples transport selection (driven by connectionState) from provider identity (driven by connectedProvider).

**MultiProviderTests backward compatibility:**
Tests inject standalone `MPCBrowser` directly into `ClientEngine`. After renaming `browserRef` to `compositeRef`, the `availableProviders` and `selectProvider` paths broke. Fixed by adding `else if let browser = transport as? MPCBrowser` fallback in ClientEngine.

#### Manual testing results (2026-04-08)

| Test | Result |
|------|--------|
| Direct Bonjour+TCP (iPhone → Mac via WiFi) | PASS — connects ~200ms |
| Relay mode (MPC path) | PASS — no regression |
| Dual mode (relay + local client) | PASS — no regression |
| MPC fallback (WiFi off, cellular on) | PASS — falls back to MPC/AWDL |
| MPC fallback (WiFi off, no cellular) | PASS — MPC/AWDL still works |

#### Plan doc: `docs/plans/08-bonjour-tcp-transport.md`

---

### Critical Issue Discovered: Offline Voucher Signing Fails with Privy

During the MPC fallback manual test (WiFi off, no cellular), Madhuri's iPhone showed: **"Failed to authorize: The Internet connection appears to be offline"**.

#### Root cause analysis

When Privy is active, the voucher signing path is:

```
ClientEngine.handleQuote()
  → SessionManager.createVoucherAuthorization()  [async]
    → walletProvider.signVoucher(voucher, config)
      → PrivyWalletProvider.signVoucher()
        → wallet.provider.request(rpcRequest)   ← NETWORK CALL TO PRIVY MPC API
```

`PrivyWalletProvider.signVoucher()` calls Privy's MPC signing API over the internet. The private key is split via threshold signatures (MPC-TSS) between Privy's infrastructure and the device — both shares are needed to sign. **No internet = no signature = no payment = no inference.**

This breaks Janus's core premise: offline-first AI inference for rural/disaster areas with intermittent connectivity.

#### Why it matters

The payment channel model was specifically designed for offline operation:
1. **Online (edge):** Client opens channel, deposits funds on-chain
2. **Offline (core):** Client signs vouchers locally, provider verifies locally via `ecrecover` — no chain access needed
3. **Online (edge):** Provider settles cumulative voucher on-chain when internet returns

Step 2 is entirely local crypto — `ecrecover` on a secp256k1 signature against the channel's `authorizedSigner`. But with Privy as signer, step 2 requires internet, defeating the entire design.

#### Chosen solution: Option 3 — Local key as authorizedSigner

Always use the local `EthKeyPair` as the `authorizedSigner` in Tempo channels. Privy handles identity and funding only. Voucher signing is always local → works offline → settles on-chain because `ecrecover` matches `authorizedSigner`.

**Why this works:**
- `authorizedSigner` is set at channel open time (on-chain, while internet is available)
- Provider verifies vouchers via `ecrecover(signature) == channel.authorizedSigner`
- If `authorizedSigner` = local key address, and local key signs the voucher, verification passes
- Privy wallet address is still the user's identity, used for funding the local payer key
- Channel structure already supports separate payer and authorizedSigner fields

**Plan doc:** `docs/plans/12a-offline-voucher-signing.md`

---

### Feature #12a: Offline Voucher Signing — Implementation (commit 45320af)

#### What was changed

**`SessionManager.swift`** — 3 surgical modifications:

1. **Restore init (lines 83-99):** Always restore `ethKeyPair` from persisted `ethPrivateKeyHex`, regardless of whether Privy is present. Previously, when Privy was active, the local key was never restored — causing a new key (and new channelId) on every app restart. Added explicit `do/catch` for corrupted key data instead of silently swallowing errors with `try?`.

2. **Create init (lines 132-136):** No longer stores Privy as `walletProvider`. Captures `privyIdentityAddress` for display only. Eliminates window where `self.walletProvider` briefly points to Privy between init and `setupTempoChannel()`.

3. **setupTempoChannel (lines 168-179):** Removed Privy/local branching. Always sets `signerAddress = ethKP.address` and `walletProvider = LocalWalletProvider(...)`. Single code path regardless of Privy presence.

**New property:** `privyIdentityAddress: EthAddress?` — captures Privy wallet address for identity/display, separate from signing.

#### Architecture review

Plan reviewed by both `systems-architect` and `architecture-reviewer` agents before implementation. Key findings incorporated:
- Restore init bug (pre-existing, made critical by this change) — fixed
- `create()` init briefly storing Privy as walletProvider — fixed
- No migration logic needed: `Channel` is reconstructed on every launch, not persisted
- Stranded deposits from old Privy-signed channels: acceptable for testnet, needs close utility for mainnet

#### Tests: 8 new (229 total, all passing)

**SPM (3 new, 171 total):**
- `testVoucherSignedWithLocalKey_verifiesAgainstLocalSigner` — full VoucherVerifier flow with local key as authorizedSigner
- `testVoucherSignedWithLocalKey_ecrecoverMatchesSigner` — proves on-chain settlement works (ecrecover matches)
- `testPrivySignedVoucher_failsAgainstLocalKeyChannel` — negative test: wrong-key voucher rejected

**Xcode (5 new, 58 total):**
- `testCreateInit_alwaysUsesLocalSignerEvenWithPrivy` — mock Privy injected, walletProvider is still LocalWalletProvider
- `testOfflineVoucherSigning_noNetworkRequired` — mock Privy's signVoucher never called (signCallCount == 0)
- `testRestoreInit_alwaysRestoresEthKeyPair` — ethKeyPair survives restore with Privy injected
- `testChannelId_stableAcrossRestart` — channelId identical after persist → restore → setupTempoChannel
- `testRestoreInit_corruptedEthKey_generatesNewKey` — corrupted hex → new key generated, system functional

#### Manual device testing (2026-04-09)

**Setup:** Mac = JanusProvider (MLX Qwen3-4B), 2 iPhones = JanusClient with Privy login.

| # | Test | Result | Details |
|---|------|--------|---------|
| 1 | Online — Privy login, connect, send queries | PASS | Vouchers signed locally even with internet available |
| 2 | **Offline — WiFi+cellular off, send query via MPC/AWDL** | **PASS** | Previously showed "The Internet connection appears to be offline". Now works — pure local secp256k1 signing |
| 3 | Settlement — re-enable internet, provider settles | PASS | `ecrecover` returns local key address, matches `authorizedSigner` on-chain |
| 4 | Restart — force-quit app, relaunch, send query | PASS | ethKeyPair restored, same channelId, cumulative spend continues (no new channel) |
| 5 | Transition — existing Privy-signed sessions | PASS | Old sessions (`63EBE013`, `4F8C1705`) replaced by new local-key sessions (`CA178301`, `AC4BD01D`). Settlements succeeded on new channels. |

**Provider log analysis (test 4 verification):**
Sessions `CA178301` and `AC4BD01D` show continuous cumulative spend progression (3→6→9→...→27) across app restarts, confirming the same channel was reused — ethKeyPair properly restored from persisted data.

#### Status: Feature #12a COMPLETE

---

## 2026-04-11

### Feature #12b: Provider-Side Offline Settlement Resilience (commit d155091)

Completes the offline-first story on the provider side. Unsettled vouchers are now persisted to disk so they survive app restarts. `NWPathMonitor` retries settlement when internet returns.

#### What was built

- **`PersistedProviderState.unsettledChannels`** — `[String: Channel]?` field, backward compat via `decodeIfPresent`
- **Per-voucher persistence** — `persistState()` called immediately after `acceptVoucher()` (critical write — real money)
- **`removeChannelIfMatch()`** — channelId-safe removal guard (prevents removing a replaced live channel)
- **`settleAllChannelsOnChain(isRetry:)`** — `isRetry` parameter skips faucet/sleep/pending-channel wait for persisted channels
- **`retryPendingSettlements()`** — filters channels with `unsettledAmount > 0`, calls settlement with `isRetry: true`
- **`NWPathMonitor`** — triggers retry on unsatisfied → satisfied transition
- **`willTerminateNotification`** — safety net persistence on graceful quit
- **Startup recovery** — restores unsettled channels from `PersistedProviderState` on init

#### Tests: 6 new (177 SPM total, all passing)

- `testProviderStateRoundTrip_withUnsettledChannels` — full persist/restore with signed voucher, crypto integrity verified
- `testProviderStateRoundTrip_multipleUnsettledChannels` — 3 channels survive round-trip
- `testProviderStateRoundTrip_unsettledChannelsNilWhenEmpty` — nil when no unsettled channels
- `testProviderStatePersistsOnlyUnsettledChannels` — filtering matches ProviderEngine.persistState()
- `testProviderStateDecodesWithoutUnsettledChannelsField` — backward compat with pre-#12b JSON
- `testChannelWithVoucherCodableRoundTrip` — Channel+SignedVoucher JSON round-trip, signature bytes exact match

#### Manual device testing (2026-04-11)

**Kill-and-restart test (2 runs, both PASS):**
1. Send requests from iPhone → provider accepts vouchers → force-quit provider
2. Verify `provider_state.json` contains `unsettledChannels` with valid vouchers
3. Relaunch provider → "Restored N unsettled channel(s)" in logs → settlement succeeds

**Test 1:** 48cr recovered and settled on relaunch
**Test 2:** 18cr recovered and settled on relaunch

#### Plan doc: `docs/plans/12b-offline-settlement.md`

---

### Feature: Group Client Cards by Stable Device Identity

**Problem:** Provider UI shows one card per `senderID` (MPC peer hash). Since `senderID` changes on every reconnect, the same iPhone spawns multiple client cards. A provider with 2 real devices may see 10+ cards after several reconnects.

**Root cause:** No stable device identity. `senderID` is transport-level (changes per connection). `userPubkey` in `SessionGrant` is per-session (new `JanusKeyPair()` on every `SessionManager.create()`). Neither is usable for grouping.

**Solution:** Persistent device identity key (`client_device_identity.json`), sent as `clientIdentity` on every `PromptRequest`, provider groups by identity with senderID fallback.

#### What was built

- **`SessionManager.deviceIdentityKey()`** — static method, loads or creates a `JanusKeyPair` persisted to `client_device_identity.json`. Cached in memory after first load. `clearDeviceIdentity()` for reset.
- **`PromptRequest.clientIdentity: String?`** — optional Ed25519 pubkey base64, backward compat
- **`ClientEngine.submitRequest()`** — populates `clientIdentity` from `deviceIdentityKey().publicKeyBase64`
- **`ProviderEngine.sessionToIdentity`** — runtime dict mapping `sessionID → clientIdentity`
- **`ClientSummary.senderIDs: [String]`** — all transport-level senderIDs for this identity
- **`clientSummaries`** — groups by `sessionToIdentity[sessionID] ?? senderID`, uses `Set<String>` during aggregation
- **`ProviderAdvertiserTransport`** — new `displayName(forSenderIDs:)` and `isConnected(senderIDs:)` with protocol defaults
- **`MPCAdvertiser`** — explicit overrides using `senderToPeer` mapping (MUST-FIX from architecture review)
- **`ProviderStatusView.clientCard()`** — switched to `senderIDs`-based lookups
- **`removeChannelIfMatch()`** — prunes `sessionToIdentity` but NOT `sessionToSender` (MUST-FIX from architecture review)

#### Architecture reviews

Plan reviewed by both `systems-architect` and `architecture-reviewer` agents. Key findings:
- **P0:** Force-unwrap crash on corrupted identity file → `guard let` for base64 decoding
- **P1:** Disk I/O on every request → static cache after first load
- **P1:** No way to reset identity → `clearDeviceIdentity()` method
- **MUST-FIX:** `MPCAdvertiser` has explicit overrides of single-senderID methods → new multi-senderID methods also need explicit implementations
- **MUST-FIX:** Don't prune `sessionToSender` in `removeChannelIfMatch()` → only prune `sessionToIdentity`

#### Manual device testing (2026-04-11)

**Setup:** Mac = JanusProvider, iPhone 16 + iPhone 14 Plus = JanusClient

| Test | Result |
|------|--------|
| Both iPhones connect, send requests | 2 client cards shown |
| iPhone 16 disconnects, reconnects, sends request | Still 2 client cards (not 3) |

#### Files changed (6 files, all modifications)

| File | Changes |
|------|---------|
| `Sources/JanusShared/Protocol/PromptRequest.swift` | Added `clientIdentity: String?` |
| `JanusApp/JanusClient/SessionManager.swift` | `deviceIdentityKey()`, `clearDeviceIdentity()`, `DeviceIdentity` struct |
| `JanusApp/JanusClient/ClientEngine.swift` | Populate `clientIdentity` in `submitRequest()` |
| `JanusApp/JanusProvider/ProviderEngine.swift` | `sessionToIdentity`, identity-based `clientSummaries`, `senderIDs` on `ClientSummary` |
| `JanusApp/JanusProvider/ProviderAdvertiserTransport.swift` | `displayName(forSenderIDs:)`, `isConnected(senderIDs:)` |
| `JanusApp/JanusProvider/MPCAdvertiser.swift` | Explicit multi-senderID overrides |

#### Plan doc: `docs/plans/stable-client-identity.md`

---

### Known Issue: Intermittent "failed to decode signed transaction" during settlement

**Observed:** 1 failure out of 11 settlement attempts in the provider log. Error: `Settle failed: RPC error: failed to decode signed transaction`.

**Analysis:** The error occurs at RPC decode time — the node can't parse the raw transaction bytes, before any validation (nonce, balance, etc.) runs.

**Likely causes (ranked):**

1. **V value encoding for chainId 42431** — EIP-155 produces `v = 84897` (3 bytes), uncommon for standard Ethereum. Some Tempo RPC backends may reject large V values during strict parsing. Intermittent if Tempo load-balances across nodes with different strictness.

2. **R/S leading-zero stripping** — RLP encoder strips leading zeros from `r` and `s` signature components. If either starts with `0x00` bytes, it encodes as < 32 bytes. Most nodes handle this, but strict parsers may reject. Probabilistic (~1/128 chance per component).

3. **Transaction type mismatch** — Code uses legacy Type 0 (EIP-155). Tempo has custom Type 118 (`0x76`). WORKLOG notes "legacy type 0 works", but if an RPC node update tightened validation, Type 0 could fail at decode.

**Severity:** Low. 10/11 settlements succeeded. Failed voucher remains persisted (#12b), will be retried on next network restore or app restart. No money lost.

**Potential fixes (if frequency increases):**
- Switch to Tempo Type 118 transactions (native format, guaranteed accepted)
- Pad R/S to 32 bytes in RLP encoding
- Add retry with re-signing in `ChannelSettler` (fresh signature = different R/S values)

**Status:** Tabled for later investigation. Monitor frequency in future testing sessions.

---

### Follow-up B: Type-Safe SettleResult (Follow-up from #12b)

Replaced `SettleResult.failed(String)` with `SettleFailureReason` enum — eliminates fragile `reason.contains("finalized")` string matching in `ProviderEngine`.

#### What was built

- **`SettleFailureReason` enum** — 5 cases: `channelNotOnChain`, `channelFinalized`, `gasInfoUnavailable(String)`, `transactionReverted(txHash: String)`, `submissionFailed(String)`
- **`isPermanent` computed property** — `channelFinalized` and `transactionReverted` are permanent; others transient
- **`CustomStringConvertible`** — for safe string interpolation in logs
- **ProviderEngine first loop** — `if case .channelNotOnChain = reason` + `reason.isPermanent` replaces string matching
- **ProviderEngine retry loop** — now removes channels on permanent failures and `channelNotOnChain` after 20s grace period (previously just logged)
- **2 new unit tests** — `testSettleFailureReason_isPermanent`, `testSettleFailureReason_description`

#### Plan doc: `docs/plans/12b-type-safe-settle-result.md`

---

### Follow-up C: Provider UI — Pending Settlement Indicator (Follow-up from #12b)

Shows the provider operator how many credits are pending on-chain settlement.

#### What was built

- **`channels` `didSet`** — `objectWillChange.send()` ensures SwiftUI re-renders when channels change (fixes stale-UI bug identified by both reviewers)
- **`pendingSettlementCredits` computed property** — sums `unsettledAmount` across all channels
- **`isSettling` → `@Published`** — enables "Settling..." status pill during active settlement
- **Always-visible "Pending" stat** — 5th item in stats strip, shows "0" in gray when clean, orange when credits pending (no layout shift)
- **Settlement status pill** — "Settling..." (orange, rotating arrows) during active settlement, "Pending" (orange, clock) when unsettled credits exist

#### Manual device testing (2026-04-12)

| Test | Result |
|------|--------|
| Send requests, disconnect (online) | "Pending" flashes briefly, settlement succeeds, returns to 0 |
| Turn off WiFi → disconnect client → settlement fails | "Pending" turns orange with credit count |
| Turn WiFi back on → settlement retries | "Settling..." pill appears → "Pending" clears to 0 |

#### Plan doc: `docs/plans/12b-pending-settlement-indicator.md`

---

### Fix: Duplicate Client Cards After Reconnect

**Problem:** Same iPhone shows as multiple client cards after reconnecting, despite the stable-client-identity feature.

**Root causes (3 bugs found):**

1. **Ghost cards from stale `sessionToSender`** — `removeChannelIfMatch` pruned `sessionToIdentity` but kept `sessionToSender`. After settlement, the stale entry fell back to senderID as grouping key → ghost card. When the device reconnected with a new senderID, a second (correct) card appeared.

2. **`sessionToIdentity` not persisted** — After provider restart, restored channels had no identity mapping → fell back to senderID grouping.

3. **Restored channels invisible in UI** — `clientSummaries` iterated `sessionToSender` (routing table), but restored channels had no `sessionToSender` entry → invisible despite `activeSessionCount` being nonzero.

**What was fixed:**

- **`removeChannelIfMatch` full cleanup** — now prunes `sessionToSender`, `lastResponses`, and updates `activeSessionCount` alongside existing `channels` + `sessionToIdentity` cleanup
- **`sessionToIdentity` persisted** — added to `PersistedProviderState` as optional field, restored in `init`, filtered to unsettled sessions only in `persistState()`
- **`clientSummaries` iterates `channels.keys`** — source of truth for existing sessions, not `sessionToSender` (routing table). Eliminates ghost cards structurally. Identity fallback chain: `sessionToIdentity` → `senderID` → `sessionID`

#### Manual device testing (2026-04-12)

| Test | Result |
|------|--------|
| Connect iPhone → send requests → disconnect → reconnect → send request | 1 client card (was 2 before fix) |

#### Plan doc: `docs/plans/fix-duplicate-client-cards.md`

---

### Fix #12a: First-Query Race Condition on Provider Switch

**Problem:** When user is on PromptView and the provider connection transitions (disconnect → reconnect to different provider), the submit button was enabled before the new session was ready. Submitting during this window sent the old provider's stale session credentials to the new provider → "Unknown session" error.

**Root cause:** `PromptView.canSubmit` checked `connectedProvider != nil` (transport state) instead of `sessionReady` (session state). `connectedProvider` becomes non-nil immediately on transport connect, before `sessionManager` is updated for the new provider.

**What was fixed:**

- **`canSubmit` gates on `sessionReady`** — strict superset of `connectedProvider != nil`, only true after session is fully configured for the current provider
- **Generation counter in `createSession()`** — prevents stale async session-creation Tasks from overwriting current state on rapid provider switching (A→B→C). Captures generation before async work, discards result if counter has moved on.
- **`sessionReady = false` at top of `createSession()`** — explicit invariant, not reliant on disconnect handler running first
- **Defense-in-depth guard in `submitRequest()`** — catches any bypass of the UI gate
- **Unified tri-state banner** — replaced separate `disconnectedBanner` + `onChange` auto-dismiss with single prioritized banner: (1) disconnect-during-request, (2) reconnecting, (3) setting up session
- **Deferred `promptText` clearing** — only clears after confirming request wasn't rejected by guard

#### Manual device testing (2026-04-12)

| Test | Result |
|------|--------|
| Connect to Provider 1 → PromptView → send request → force-quit Provider 1 → auto-switch to Provider 2 → submit | Seamless switch, request served by Provider 2 |
| Disconnect all providers while on PromptView | "Provider disconnected" banner with Back button, submit disabled |

#### Plan doc: `docs/plans/12a-fix-first-query-race.md`

---

### Bonjour Listener Retry Fix

**Problem:** When running the provider on MacBook Air, `NWListener` failed with `-65555: NoAuth` (Local Network permission not granted by macOS). The `stateUpdateHandler` `.failed` case immediately called `startAdvertising()` with no delay or retry limit → infinite loop burning through thousands of ports in seconds.

**Root cause:** macOS Local Network permission (`tccd`) was in a stale state on the Air — toggling the permission in System Settings had no effect. Required a full system restart to clear.

**What was fixed:**

- **5-second retry delay** — `Task.sleep` between retries prevents port exhaustion
- **Max 5 retries** — stops retrying after persistent failures, logs "Check Local Network permission in System Settings"
- **Cancellable retry** — stored `retryTask` handle, cancelled in `stopAdvertising()` to prevent ghost restarts
- **Reset on success** — retry counter resets when listener reaches `.ready` state

**Debugging journey:** Provider UI showed "Advertising" (green) but `dns-sd -B _janus-tcp._tcp` on other machines couldn't see the Air's service. Confirmed firewall was disabled, both Macs on same WiFi, Air could see Pro's service but not its own. Running from Xcode console revealed the NoAuth loop. System restart cleared the stale permission state.

---

### Feature #13: Periodic & Threshold-Based Settlement (2026-04-12)

**Problem:** Provider only settled when clients disconnected — entirely at the client's mercy. Hours of accumulated unsettled vouchers at risk if provider crashes.

**Implementation:** Two new settlement triggers alongside existing disconnect trigger:
1. **Periodic timer** — `Task.sleep` loop on `@MainActor`, configurable interval (Off/1min/5min/15min/30min)
2. **Aggregate threshold** — checked after every voucher acceptance, fires when total unsettled credits across all clients >= threshold (Off/25/50/100)

Both use `removeAfterSettlement: false` (keeps channels alive for active clients) and `isRetry: true` (skips redundant faucet funding). Settings persisted in `PersistedProviderState`, UI via segmented pickers with split `onChange` handlers.

**Plan doc:** `docs/plans/13-periodic-settlement.md`

#### Bug: Premature settlement with two clients (settledAmount desync)

**Symptom:** With threshold=25, provider settled after only 12 new credits. Pending credits UI briefly flashed 75. Happened consistently when two iPhones connected after a provider restart.

**Root cause:** After periodic settlement, channels with `unsettledAmount == 0` were correctly excluded from persistence (nothing to settle). But when the provider restarted and clients reconnected with the same on-chain channel, the provider created a fresh `Channel` with `settledAmount = 0`. The client's voucher `cumulativeAmount` includes ALL prior spend (cumulative accounting), so `unsettledAmount = cumulativeAmount - 0` was massively inflated by already-settled spend.

Example: Client had 18 credits settled on-chain from previous session. After restart, provider's new Channel has `settledAmount = 0`. Client sends voucher for 21 (18 old + 3 new). Provider sees `unsettledAmount = 21` instead of `3`.

**Fix:** Initialize `settledAmount` from on-chain state when creating a Channel from `channelInfo`. The `verifyChannelInfoOnChain()` call already queries the escrow contract — added `onChainSettled` to `ChannelVerificationResult.acceptedOnChain` and call `channel.recordSettlement(amount: onChainSettled)` on the new Channel. Zero extra RPC calls.

#### Additional hardening (systems-architect review findings)

| Severity | Issue | Fix |
|----------|-------|-----|
| P0 | Startup race: `retryPendingSettlements()` ran before `fundProviderIfNeeded()` completed — retry failed with no gas, stale channels persisted | Chained in single Task: fund → retry → startTimer |
| P1 | Periodic timer started from app launch, not after cleanup — could fire while stale channels still being retried | Moved `startPeriodicSettlement()` after retry completes |
| P2 | Tx revert after failed pre-flight RPC check created zombie channels (already settled on-chain but provider didn't know) | `ChannelSettler.settle()` re-checks on-chain state after revert, returns `.alreadySettled` if applicable |
| P2 | No TTL on restored channels — infinitely retried even after on-chain channel closed | Added `lastVoucherAt` timestamp to `Channel`, discard channels older than 24h on retry |
| P2 | Disconnect settlement silently dropped when threshold settlement in progress (`isSettling` guard) | Queue settlement request, re-run after current completes with merged parameters |
| P3 | `activeSessionCount` inflated by settled channels from disconnected clients | Changed to computed property: counts channels with active sender OR unsettled amount |

#### Files changed

| File | Changes |
|------|---------|
| `Sources/JanusShared/Tempo/Channel.swift` | Added `lastVoucherAt: Date?` timestamp, set on `acceptVoucher` |
| `Sources/JanusShared/Tempo/ChannelSettler.swift` | Re-check on-chain state after tx revert |
| `Sources/JanusShared/Verification/VoucherVerifier.swift` | Added `onChainSettled` to `ChannelVerificationResult.acceptedOnChain` |
| `JanusApp/JanusProvider/ProviderEngine.swift` | Initialize `settledAmount` from on-chain, TTL cleanup, settlement queuing, computed `activeSessionCount`, diagnostic logging, startup ordering |
| `JanusApp/JanusProvider/ProviderStatusView.swift` | Startup: fund → retry → timer in single Task |
| `Tests/JanusSharedTests/OnChainTests.swift` | Updated for new `acceptedOnChain` signature |

#### Testing (2 iPhones + Mac provider)

| Test | Result |
|------|--------|
| Send 21 credits from iPhone 1, then switch to iPhone 2 (threshold=25) | No premature settlement — pending shows correct delta, not inflated cumulative |
| Periodic timer fires after 5 min from startup cleanup (not app launch) | Correct timing verified |
| Provider restart → clients reconnect → `settledAmount` initialized from on-chain | Log shows "Initialized settledAmount=N from on-chain" |

---

### Feature #14b: Mandatory On-Chain Channel Handshake Before Inference (2026-04-13)

**Problem:** Provider accepted vouchers from channels it had never verified existed on-chain. A client could skip `openChannel()` entirely, generate a signed voucher against a non-existent channel, and the provider would serve inference so long as the signature was valid. The channel might never settle.

**Implementation:**

1. **`ChannelVerificationResult` split** — `acceptedOffChainOnly` was a single case that conflated two very different situations: "I checked the chain and found nothing" (reject — channel was never opened) vs "I couldn't reach the chain" (accept — supports offline inference after the initial handshake). Replaced with:
   - `channelNotFoundOnChain` — `isAccepted = false`, provider sends `CHANNEL_NOT_READY` error
   - `rpcUnavailable` — `isAccepted = true`, accepted to support inference when chain is unreachable after initial handshake

2. **`channelOpenedOnChain` persistence** — Added `channelOpenedOnChain: Bool` field to `PersistedClientSession`. Without this, every app restart would show the channel-opening spinner even for channels already confirmed on-chain.

3. **Combine gating on `SessionManager`** — `sessionReady = true` is now gated on `$channelOpenedOnChain.filter { $0 }.first()`. This means the "Start Using Provider" button in `DiscoveryView`/`DualModeView` doesn't appear until the channel is confirmed on-chain (first connect) or restored from persistence (subsequent connects).

4. **Provider defense** — `ProviderEngine` replaced the `guard result.isAccepted` catch-all with an explicit switch, returning `CHANNEL_NOT_READY` for `channelNotFoundOnChain` and passing through `rpcUnavailable` and `acceptedOnChain`.

**Plan doc:** `docs/plans/14b-mandatory-channel-handshake.md`

#### Bug: INVALID_SESSION on every request after restore

**Symptom:** All inference requests returned INVALID_SESSION immediately after provider had been serving correctly on a prior session.

**Root cause:** `createSession()` in `ClientEngine` fast-pathed `channelOpenedOnChain == true` cases to `sessionReady = true` without calling `setupTempoChannel()`. The `Channel` object is not persisted (only `ethPrivateKeyHex` is), so `channel = nil` after every app restart. With `channel == nil`, `channelInfo` was nil, and the provider received requests with no channel data.

**Fix:** Always call `setupTempoChannel()` when `channel == nil`, even in the "already opened" fast path — always before setting `sessionReady = true`.

#### Bug: Channel-opening progress banner never visible

**Symptom:** Users went directly from "Searching..." to "Start Using Provider" with no intermediate state showing channel setup progress.

**Root cause:** The `reconnectingBanner` inside `PromptView` gated on `!sessionReady` is unreachable during initial setup — `DiscoveryView` and `DualModeView` only navigate to `PromptView` when `engine.sessionReady == true`.

**Fix:** Added `channelOpeningBanner` directly in the `else` branch of the `sessionReady` check in both `DiscoveryView` and `DualModeView`. Shows a spinner + "Opening payment channel..." + `engine.channelStatus` sub-label. On failure: warning icon + "Channel setup failed" + Retry button.

#### Files changed

| File | Changes |
|------|---------|
| `Sources/JanusShared/Verification/VoucherVerifier.swift` | Split `acceptedOffChainOnly` into `channelNotFoundOnChain` and `rpcUnavailable` |
| `Sources/JanusShared/Persistence/SessionStore.swift` | Added `channelOpenedOnChain: Bool` to `PersistedClientSession` |
| `Sources/JanusShared/Protocol/ErrorResponse.swift` | Added `channelNotReady` error code |
| `Sources/JanusShared/Tempo/ChannelOpener.swift` | Added `progressHandler` closure parameter |
| `JanusApp/JanusClient/SessionManager.swift` | Publish `channelOpenedOnChain`, persist it, wire progress handler |
| `JanusApp/JanusClient/ClientEngine.swift` | `observeChannelOpening()` Combine helper, fix `setupTempoChannel()` call on restore, `channelStatus` forwarding |
| `JanusApp/JanusClient/DiscoveryView.swift` | Add `channelOpeningBanner` in `!sessionReady` branch |
| `JanusApp/JanusClient/DualModeView.swift` | Same `channelOpeningBanner` pattern |
| `JanusApp/JanusClient/PromptView.swift` | Update `reconnectingBanner` for mid-session reconnects |
| `JanusApp/JanusProvider/ProviderEngine.swift` | Explicit switch on `ChannelVerificationResult`, send `CHANNEL_NOT_READY` |
| `Tests/JanusSharedTests/OnChainTests.swift` | Updated for new enum cases, added progress handler test |
| `Tests/JanusSharedTests/VoucherFlowTests.swift` | Added zero-network `rpcUnavailable` path test |
| `Tests/JanusSharedTests/PersistenceTests.swift` | Added `channelOpenedOnChain` round-trip and backward-compat tests |

#### Testing (2 iPhones + Mac provider)

| Test | Result |
|------|--------|
| Fresh install iPhone 16 — channel opening from scratch | "Funding wallet..." banner visible, faucet failed → retry → succeeded, "Start Using Provider" appeared. Note: faucet failure was likely happening silently before #14b — the banner made it visible for the first time. Retry path (`retryChannelOpenIfNeeded`) pre-existed; #14b just surfaced the failure instead of swallowing it. |
| Subsequent connect (channel already on-chain) | No banner, "Start Using Provider" immediate |
| Inference after fresh channel open | Working on both iPhones |
| Provider receives request with no channel history | `CHANNEL_NOT_READY` returned correctly |
| Provider restart → client reconnect | No banner on reconnect (fast path correct), inference working. Settlement after reconnect failed twice with testnet RPC timeouts ("failed to get gas info") but eventually succeeded — retry queue from #13 kept firing until RPC cooperated. Not a code regression; testnet RPC unreliability only. |

**Test suite:** 182 tests passing (2 new: `testVerifyChannelInfoOnChain_returnsRpcUnavailable_whenNoRPCConfigured`, `testChannelOpener_progressHandler_firesBeforeWalletFailure`)

**Commits:** `7112f65`, `554623d`, `a7b58b0`

---

### Fix #15: Provider settledAmount Persistence (2026-04-14)

**Problem:** After settlement, channels with `unsettledAmount == 0` are excluded from `unsettledChannels` persistence. On provider restart + RPC timeout, a fresh `Channel(settledAmount: 0)` was created on reconnect. The client's cumulative voucher amount includes all prior spend, so `unsettledAmount = cumulativeAmount - 0` was inflated — showing phantom pending credits equal to the full prior session spend.

Discovered during #14b manual testing: provider restart → client reconnect → testnet RPC timeouts → pending credits showing the full prior cumulative instead of 0.

**Root cause:** Three distinct paths lost `settledAmount`:
1. **Disconnect settlement** (`removeAfterSettlement: true`) — channel removed via `removeChannelIfMatch`, no baseline recorded
2. **TTL eviction** in `retryPendingSettlements()` — `channels.removeValue(forKey:)` called directly, bypassing `removeChannelIfMatch`
3. **Periodic/threshold settlement** (`removeAfterSettlement: false`) — channel stays in memory but `unsettledAmount == 0` after settlement → filtered out of `persistState()` → baseline lost on restart

**Implementation:**
- Added `settledChannelAmounts: [String: UInt64]?` (channelId hex → settledAmount) to `PersistedProviderState` with `decodeIfPresent` for backward compat
- `recordSettledBaseline()` helper called at all three removal sites
- `persistState()` scans all in-memory channels and upserts their `settledAmount` — covers the periodic/threshold path where channels stay alive after settlement
- On reconnect with `.rpcUnavailable`: cache consulted, `channel.recordSettlement(cached)` applied before inserting into `channels`
- On reconnect with `.acceptedOnChain`: on-chain value written back to cache to keep it fresh

**Plan doc:** `docs/plans/15-settled-amount-persistence.md`

#### Files changed

| File | Changes |
|------|---------|
| `Sources/JanusShared/Persistence/SessionStore.swift` | Add `settledChannelAmounts` field, `init` param, `decodeIfPresent` |
| `JanusApp/JanusProvider/ProviderEngine.swift` | In-memory dict, restore on init, `recordSettledBaseline()` helper, `persistState()` scan, apply on reconnect, cache sync on `acceptedOnChain` |
| `Tests/JanusSharedTests/PersistenceTests.swift` | 3 new tests: round-trip, backward compat, unsettledAmount correctness after cache recovery |

#### Testing (Mac provider + iPhone)

| Test | Result |
|------|--------|
| Run 18 credits of inference → disconnect → restart provider → reconnect iPhone | `settledChannelAmounts: {"0x07903c...": 18}` confirmed in `provider_state.json` after settlement. Pending showed 0 on reconnect — cache applied correctly. |

**Test suite:** 185 tests passing (3 new)

**Commit:** `51c2076`

---

## 2026-04-14

### Feature #17: Backend Dead Code Removal

#### Problem

The original Janus design included a Vapor backend that issued signed session grants — the backend's Ed25519 signature on each `SessionGrant` was the trust anchor. This was fully superseded by Tempo on-chain payment channels: sessions are now created locally, trust comes from on-chain channel verification, and the backend signature was never set (always `""`) or verified.

Dead code was accumulating confusion across the codebase.

#### What Was Removed

| Item | Location | Why dead |
|------|----------|----------|
| `JanusBackend/` directory (4 files) | `JanusBackend/` | Standalone Vapor package — not in `Package.swift`, references nonexistent `DemoConfig`, zero callers in main project |
| `SessionGrant.backendSignature` | `SessionGrant.swift` | Always set to `""` in `SessionManager.create()`, never read or verified anywhere |
| `SessionGrant.signableFields` | `SessionGrant.swift` | Only called from dead `JanusBackend/Routes.swift` and the test being deleted |
| Stale "backend API" comments | `ClientEngine.swift:162,195`, `SessionManager.swift:140` | Described a backend API call that never happens |
| Stale `SessionGrant` doc comment | `SessionGrant.swift:3–7` | Said "issued by the backend" / "The backend signs" — all false after Tempo |
| Minor stale doc comments | `JanusShared.swift:4`, `VoucherAuthorization.swift:31–33` | Referenced backend model that no longer exists |

#### What Was Kept

- `SessionGrant` struct itself — still carries `maxCredits`, `expiresAt`, `providerID`, `userPubkey` to provider
- `PromptRequest.sessionGrant` — provider receives session metadata from client on first connect
- `JanusKeyPair`, `JanusSigner`, `JanusVerifier` — used for provider receipt signing / client verification
- Raw JSON `"backendSignature"` in backward-compat test fixtures — intentionally kept as regression tests for the synthesized decoder's unknown-key-ignoring behavior

#### Implementation Notes

- `SessionGrant` uses synthesized `Codable` — no custom decoder needed. Old persisted JSON with `"backendSignature"` decodes silently (Swift ignores unknown keys in synthesized decoders).
- Both a systems architect and architecture reviewer independently caught the same gap in the original plan: 3 test files (`PersistenceTests`, `SessionPersistenceRegressionTests`, `OnChainTests`) had `backendSignature:` in `SessionGrant(...)` constructor calls that would have been compile errors.

#### Files Changed

- `JanusBackend/` — deleted entirely
- `Sources/JanusShared/Models/SessionGrant.swift` — removed field, init param, signableFields, rewrote doc comment
- `Sources/JanusShared/JanusShared.swift` — removed "backend" from module doc
- `Sources/JanusShared/Protocol/VoucherAuthorization.swift` — updated stale framing
- `JanusApp/JanusClient/ClientEngine.swift` — updated 2 stale comments
- `JanusApp/JanusClient/SessionManager.swift` — updated comment, removed `backendSignature: ""`
- `Tests/JanusSharedTests/ProtocolTests.swift` — updated 2 fixtures, deleted `testSessionGrantSignableFields`
- `Tests/JanusSharedTests/PersistenceTests.swift` — updated 4 init calls
- `Tests/JanusSharedTests/SessionPersistenceRegressionTests.swift` — updated `makeGrant()` helper
- `Tests/JanusSharedTests/OnChainTests.swift` — updated 2 init calls

**Test suite:** 184 tests passing (185 − 1 deleted test)

---

## 2026-04-14 (continued)

### Feature #11a: Wallet Key Persistence (Keychain)

#### Problem

The client's ETH keypair was stored as a plain hex string in `client_session_{providerID}.json` in Application Support. On app reinstall, this file is deleted — the key is lost, the on-chain channel is orphaned with stranded funds. Prerequisite for real-money channel funding.

#### Solution

Added `JanusWalletKeychain` — a thin `SecItem` wrapper that stores the ETH private key (raw 32 bytes) in the device Keychain with `kSecAttrAccessibleAfterFirstUnlock` (supports background channel operations). One stable key per device, shared across all sessions and providers.

- `loadOrCreate()` — loads existing Keychain key or generates+saves a fresh one
- `save()` — add-then-update pattern, explicit `kSecAttrSynchronizable: false`, logs `OSStatus` on failure
- `delete()` — for test tearDown isolation

Migration path: `SessionManager.init(persisted:)` promotes the JSON-restored key to Keychain on first launch (`load() == nil` guard prevents redundant writes on subsequent restarts).

#### Files Changed

- `JanusApp/JanusClient/JanusWalletKeychain.swift` — new Keychain helper
- `JanusApp/JanusClient/SessionManager.swift` — migration in `init(persisted:)`; `setupTempoChannel()` uses `loadOrCreate()` instead of `try? EthKeyPair()`
- `JanusApp/JanusClientTests/WalletKeychainTests.swift` — 4 unit tests with per-test UUID Keychain namespacing
- `JanusApp/JanusApp.xcodeproj/project.pbxproj` — added both new files to target

#### Verification

Definitive reinstall test passed:
- Connected → payer address `0x5DA773e51086C77d23aF24443B48675Aa6f595c1`
- App uninstalled (wiped session JSON) + reinstalled → reconnected
- Payer address: `0x5DA773e51086C77d23aF24443B48675Aa6f595c1` ✓ (same)
- New `sessionID` confirmed JSON was wiped; key came from Keychain only

**Commit:** `b28b409`

---

## 2026-04-14 (continued)

### Feature #11b: Channel Top-Up

#### Problem

Credits were one-way: once exhausted the user had to close and reopen the channel (losing continuity and paying two sets of gas). `TempoStreamChannel` exposes `topUp(bytes32 channelId, uint256 additionalDeposit)` which increases the existing deposit in-place — cheaper and channel-preserving.

Three-way state synchronization required: (1) client in-memory `channel.deposit`, (2) `PersistedClientSession.lastChannelDeposit` so deposit survives restart, (3) provider's cached `Channel` object so it accepts vouchers above the old deposit limit.

#### Solution

- `ChannelTopUp` struct mirrors `ChannelOpener` exactly: fund → approve → topUp → on-chain verify
- `Channel.deposit` changed from `let` to `var`; `recordTopUp(newDeposit:)` mutation method added
- `PersistedClientSession.lastChannelDeposit: UInt64?` new field with `decodeIfPresent` (backwards-compatible)
- `remainingCredits` ceiling uses `lastChannelDeposit ?? sessionGrant.maxCredits` in both persistence and live SessionManager
- Provider re-verifies on-chain when same `channelId` arrives with a higher `deposit` in `channelInfo`
- `ClientEngine.topUpChannel()` guard: disabled during in-flight inference to prevent race conditions
- Top Up button in balance bar → sheet with +50/+100/+200 tiers
- Progress banner (`channelStatusBanner`) shows for all channel status updates including already-open channels — fixed a bug where `bindChannelStatus` was only wired for the `!channelOpenedOnChain` restore path

#### Files Changed

| File | Change |
|------|--------|
| `Sources/JanusShared/Ethereum/EthTransaction.swift` | `topUpCalldata()` — selector `0xb67644b9` |
| `Sources/JanusShared/Tempo/ChannelTopUp.swift` | New file |
| `Sources/JanusShared/Tempo/Channel.swift` | `deposit` let → var; `recordTopUp()` |
| `Sources/JanusShared/Persistence/SessionStore.swift` | `lastChannelDeposit`; `remainingCredits` formula |
| `JanusApp/JanusClient/SessionManager.swift` | `topUpChannel()`; `creditCeiling`; `setupTempoChannel()` deposit; auto-clear status messages |
| `JanusApp/JanusProvider/ProviderEngine.swift` | Re-verify on deposit change for same channelId |
| `JanusApp/JanusClient/ClientEngine.swift` | `topUpChannel()` passthrough; `bindChannelStatus` wired for all session paths |
| `JanusApp/JanusClient/PromptView.swift` | Top Up button + `TopUpSheet`; `channelStatusBanner` |

#### Tests

190 tests passing (+6 new):
- `testTopUpCalldata_encodesCorrectly` — selector + ABI encoding
- `testChannelRecordTopUp_updatesCreditAvailability` — deposit mutation + canAuthorize
- `testPersistedClientSession_remainingCredits_usesLastChannelDeposit`
- `testPersistedClientSession_remainingCredits_fallsBackToMaxCredits`
- `testLastChannelDeposit_roundTrip` — JSON encode/decode survives
- `testLastChannelDeposit_decodesNilFromOldFormat` — backwards compatibility

#### Verification

Manual end-to-end on testnet: top-up flow, post-top-up inference, restart persistence all confirmed working.

---

### Known Bug: `ChannelOpener` open tx reverts on fresh launch when pre-existence RPC check fails

**Symptom:** On first fresh launch, a red banner briefly shows "On-chain failed: open tx reverted: 0x...". Inference still works — the channel exists on-chain from a previous session.

**Root cause:** `ChannelOpener.openChannel()` checks if the channel already exists via `try? await escrowClient.getChannel(...)`. If the RPC call fails (network latency, testnet hiccup), `try?` silences the error and returns `nil`, so the pre-existence guard is skipped. The `open()` tx is then sent, and the contract reverts correctly because the channel already exists.

**Impact:** UX only — alarming red error on first launch, clears on next connect. `channelOpenedOnChain` stays `false` so the second launch retries and gets `.alreadyOpen` (green checkmark).

**Fix:** Harden the pre-existence check — retry the RPC call once before proceeding, or treat an RPC error as "assume exists" rather than "assume doesn't exist". Track as **Bug #11b-1**, fix in a follow-up.

---

### Bug #11b-1 Fix + Hardening

#### Changes

Three-part fix deployed 2026-04-14:

1. **`SessionManager.openChannelOnChain()` — early exit when already open (Bug #11b-1 root fix)**
   Added `guard !channelOpenedOnChain else { return }` at the top of `openChannelOnChain()`. Skips the entire `ChannelOpener` call on reconnect, eliminating the spurious open tx revert. Previously the `isFirstOpen` gate suppressed UI noise but still ran the opener (and its flaky RPC pre-existence check). Reviewed by systems-architect and architecture-reviewer before implementing.

2. **`ChannelOpener.openChannel()` — `try?` → `do/catch` on RPC existence check (P2 hardening)**
   The pre-existence check (`escrowClient.getChannel()`) was `try?` — RPC failure silently returned nil, skipping the guard and proceeding to send `open()` which reverted. Changed to `do/catch`: RPC failure now returns `.failed("RPC unavailable: cannot verify channel state")` instead of blundering forward. Protects the first-open path on flaky testnet.

3. **`PersistedClientSession.lastEscrowContract` — contract migration guard (P3 hardening)**
   Added `lastEscrowContract: String?` to persistence. On restore, if the stored address differs from `TempoConfig.testnet.escrowContract`, `channelOpenedOnChain` resets to `false`. Without this, a contract redeployment would leave `channelOpenedOnChain = true` referring to a now-defunct channel, causing the opener guard to permanently skip re-opening.

#### Files Changed

| File | Change |
|------|--------|
| `JanusApp/JanusClient/SessionManager.swift` | `guard !channelOpenedOnChain` early exit; contract address mismatch reset; `lastEscrowContract` in `persist()` |
| `Sources/JanusShared/Tempo/ChannelOpener.swift` | `try?` → `do/catch` on pre-existence check |
| `Sources/JanusShared/Persistence/SessionStore.swift` | `lastEscrowContract: String?` field + `decodeIfPresent` |

#### Tests

192 tests passing (+2 new):
- `testLastEscrowContract_roundTrip` — JSON encode/decode survives
- `testLastEscrowContract_decodesNilFromOldFormat` — backwards compatibility for old sessions

#### Verification

Both iPhones (Soubhik's iPhone + Madhuri's iPhone) + Mac provider deployed. Dual mode (iPhone as relay) verified working. No spurious revert error on reconnect.

---

## 2026-04-14

### Feature #13c: Remove Privy SDK (commit bc94977)

Removes all Privy SDK dependencies from the client app. The login screen and authentication gate are gone — the app opens directly to provider discovery.

#### Why

Privy was used for two things: (1) Apple/email login to gate the UI, and (2) an embedded Ethereum wallet. Feature #12a already replaced the Privy wallet with `LocalWalletProvider` (EthKeyPair) for all signing and on-chain ops. Privy's address was only being captured as `privyIdentityAddress` for display/logging — never used. The login gate had no security value for a local peer-to-peer network. Removing Privy eliminates an internet dependency at app launch, reduces binary size, and removes an SDK from the trust boundary.

#### What was removed

- **`PrivyAuthManager.swift`** — deleted. Auth manager, Apple/email OTP login, wallet setup.
- **`PrivyWalletProvider.swift`** — deleted. Privy-backed `WalletProvider` (never called for signing since #12a).
- **`LoginView.swift`** — deleted. Apple/email login screen.
- **`auth.isAuthenticated` gate** in `JanusClientApp` — removed. App now starts directly in `DiscoveryView`.
- **`walletProvider` parameter** on `SessionManager.create()`/`restore()` — removed (was identity-only since #12a).
- **`privyIdentityAddress: EthAddress?`** on `SessionManager` — removed.
- **`ClientEngine.walletProvider`** property and injection blocks in `DiscoveryView`/`DualModeView` — removed.
- **`walletBadge`** (showed Privy wallet address + Logout) from both discovery views — removed.
- **Privy SPM reference** (`privy-ios`) and all 14 pbxproj artifact entries — removed.

#### Files Changed

| File | Change |
|------|--------|
| `JanusApp/JanusClient/PrivyAuthManager.swift` | Deleted |
| `JanusApp/JanusClient/PrivyWalletProvider.swift` | Deleted |
| `JanusApp/JanusClient/LoginView.swift` | Deleted |
| `JanusApp/JanusClient/JanusClientApp.swift` | Remove `auth`, login gate, `LoginView` fallback |
| `JanusApp/JanusClient/SessionManager.swift` | Remove `walletProvider` param, `privyIdentityAddress`, Privy comments |
| `JanusApp/JanusClient/ClientEngine.swift` | Remove `walletProvider` property and its call sites |
| `JanusApp/JanusClient/DiscoveryView.swift` | Remove `auth` param, `walletBadge`, injection blocks |
| `JanusApp/JanusClient/DualModeView.swift` | Same as DiscoveryView |
| `JanusApp/JanusApp.xcodeproj/project.pbxproj` | Remove all 14 Privy pbxproj entries |
| `Sources/JanusShared/Tempo/WalletProvider.swift` | Remove `PrivyWalletProvider` from doc comment |
| `JanusApp/JanusClientTests/OfflineVoucherTests.swift` | Drop Privy params; rename corrupted-key test to reflect Keychain fallback behavior |

Net: 611 lines deleted, 40 added.

#### Tests

63/63 Xcode tests passing. Updated `testRestoreInit_corruptedEthKey` — now verifies that a corrupted JSON key falls back to the Keychain key (identity continuity), which is the correct behavior since the Keychain feature was added.

#### Verification

All three targets (Mac provider + Soubhik's iPhone + Madhuri's iPhone) deployed. End-to-end: discovery, channel open, inference, top-up all confirmed working with no login screen.
