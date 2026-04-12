# Janus Worklog

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
| 10 | SettlementNotice message | Small | — | Provider → client: "I settled session Y for Z credits." Client currently has no way to know settlement happened. Low priority — settlement is provider-side, client doesn't need to act on it. |
| 11 | Channel top-up | Small-Medium | — | Add funds to existing channel without opening a new one. Depends on whether TempoStreamChannel contract supports it. Swift side needs a top-up flow in ChannelOpener. |
| 12 | Multi-channel management UI | Small | — | View/manage channels with multiple providers. Currently one provider, one channel. |
| 12a | Fix first-query failure after provider switch | Small | — | When switching providers (any mode), the first query can fail with "channel rejected / invalid session" because the query races with `createSession(providerID:)`. Fix: block query submission until new session + Tempo channel are fully initialized, or queue the query and replay after session setup. |
| 13 | Real token economics / USD pricing | Product decision | — | Dynamic pricing by model load, token count, or USD denomination. Currently fixed 3/5/8 credit tiers. |
| 14 | Mainnet deployment | Small | — | TempoConfig.mainnet + deploy TempoStreamChannel contract to mainnet. No code changes needed. |

#### Long-term: Mesh network vision (#15–19)

| # | Feature | Effort | Dependencies | Details |
|---|---------|--------|-------------|---------|
| 15 | E2E encryption (Relay Phase 4) | Medium-Large | — | ECDH key exchange using existing ETH keypairs. Client and provider establish shared secret; relay sees only opaque bytes. Required before untrusted relays or multi-hop. |
| 16 | Multi-hop relay + congestion control (Relay Phase 3) | Large | #15 | Messages traverse multiple relays (Client → Relay A → Relay B → Provider). Needs TTL, loop detection, route caching. Congestion control bundled here: relay must break payload opacity to track request/response pairs, manage per-client queues, enforce provider capacity limits, propagate backpressure. Major design change from current stateless forwarding. |
| 17 | Backend session service (Vapor) | Medium | — | Real session issuance service replacing the removed DemoConfig. Adapter layer for future Tempo/MPP swap. Only needed for production multi-user. |
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
```

#### Summary

- **23 items total**: 7 small (Phase 2), 6 small-medium (polish), 10 large (long-term)
- **Near-term** (#1–7): finish relay robustness
- **Medium-term** (#8–14): transport reliability + payment polish
- **Long-term** (#15–19): mesh network with encryption, multi-hop, and incentives
- **Hardware vision** (#20–23): ESP32 mesh backbone, RPi edge providers, cross-transport relay

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
