# Feature #13d: Tab-Based Postpaid Payment Model

## Context

The current Janus payment flow is prepaid quote-driven: client gets a price quote, signs a voucher for that amount, then inference runs. This breaks for per-token pricing because output token count is unknown before inference. Feature #13d replaces it with a postpaid tab model: provider serves inference immediately, accumulates a per-client token tab, and requests settlement when the tab crosses a threshold. The client signs a voucher for the exact accumulated amount reactively. Designed for rural/village social-trust networks where reputation replaces cryptographic upfront commitment.

**This plan incorporates a full critical review. Do not skip any section — the review caught 20+ specific compile errors and logic bugs.**

---

## What is Removed

| Item | File | Reason |
|------|------|--------|
| `QuoteResponse` struct | `Sources/JanusShared/Protocol/QuoteResponse.swift` | No upfront quote in tab model |
| `PricingTier` enum | `Sources/JanusShared/Models/PricingTier.swift` | Replaced by per-token rate |
| `PricingTierTests.swift` | `Tests/JanusSharedTests/PricingTierTests.swift` | Tests deleted type |
| `pendingQuotes: [String: QuoteResponse]` | `ProviderEngine.swift` | No quotes |
| `case waitingForQuote` | `ClientEngine.RequestState` | State eliminated |
| `@Published var currentQuote: QuoteResponse?` | `ClientEngine.swift` | No quote in flow |
| `func handleQuote(_:)` | `ClientEngine.swift` | Method eliminated |
| `priceBadge("Small/Medium/Large")` | `DiscoveryView.swift` | Replaced by token rate display |
| `Pricing.default` usage in ServiceAnnounce init | `ServiceAnnounce.swift` | Replaced by tokenRate/tabThreshold |

**Scale of removal:** ~424 lines deleted (104 full-file + ~320 cut from existing files), ~250 lines added → net −175 lines. The feature is a net simplification.

**Surgical risk — `handlePromptRequest()` in `ProviderEngine.swift`:** The ~127-line quote generation block is interleaved with session setup code that must be preserved (channel verify, SessionSync, top-up detect, sessionToSender/Identity). Do NOT delete the whole method — only replace everything from the `PricingTier.classify` line through `appendLog`. The session setup above that line stays intact.

**Before deleting `PricingTier.swift`, update ALL callers first:**
- `ClientEngine.swift` line ~499: `PricingTier.small.credits` → replace with `1`
- `ProviderEngine.swift` line ~656: `PricingTier.classify(promptLength:)` → remove (inference runs directly)
- `ProviderEngine.swift` line ~744: `PricingTier(rawValue: quote.priceTier)` → remove (in deleted method)
- `Sources/JanusProvider/App/Main.swift` lines ~50–51, ~68: all `PricingTier` references → update to use fixed `maxOutputTokens: 1024`

---

## Phase 1: Shared Protocol Types (JanusShared) — Do First

### 1A. New file: `Sources/JanusShared/Protocol/TabUpdate.swift`
```swift
public struct TabUpdate: Codable, Sendable {
    public let tokensUsed: UInt64
    public let cumulativeTabTokens: UInt64
    public let tabThreshold: UInt64
    public init(tokensUsed: UInt64, cumulativeTabTokens: UInt64, tabThreshold: UInt64) { ... }
}
```

### 1B. New file: `Sources/JanusShared/Protocol/TabSettlementRequest.swift`
```swift
public struct TabSettlementRequest: Codable, Sendable {
    public let requestID: String      // fresh UUID per settlement cycle — provider validates this
    public let tabCredits: UInt64     // exact credits owed (ceiling division)
    public let channelId: Data        // 32 bytes
    public init(requestID: String, tabCredits: UInt64, channelId: Data) { ... }
}
```

### 1C. `Sources/JanusShared/Protocol/MessageEnvelope.swift`
Add to `MessageType` enum:
```swift
case tabSettlementRequest   // Provider → Client: payment demand
```
Tab settlement vouchers reuse `.voucherAuthorization`. Discriminant is `auth.quoteID == nil` (see Phase 3C).

### 1D. `Sources/JanusShared/Protocol/InferenceResponse.swift`
Add optional `tabUpdate` with `nil` default — existing call sites compile unchanged:
```swift
public let tabUpdate: TabUpdate?
public init(..., tabUpdate: TabUpdate? = nil) { ... }
```

### 1E. `Sources/JanusShared/Protocol/VoucherAuthorization.swift`
Change `quoteID: String` to `quoteID: String?`, add custom Codable decoder:
```swift
public let quoteID: String?
public init(requestID: String, quoteID: String? = nil, signedVoucher: SignedVoucher) { ... }
public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    requestID = try c.decode(String.self, forKey: .requestID)
    quoteID = try c.decodeIfPresent(String.self, forKey: .quoteID)
    signedVoucher = try c.decode(SignedVoucher.self, forKey: .signedVoucher)
}
```

### 1F. `Sources/JanusShared/Protocol/ServiceAnnounce.swift`
Add new fields. Keep `pricing: Pricing` but make it `Pricing?` with `decodeIfPresent`. Add:
```swift
public let tokenRate: UInt64          // credits per 1000 tokens (default: 10)
public let tabThreshold: UInt64       // tokens before settlement required (default: 500)
public let maxOutputTokens: Int       // replaces PricingTier.maxOutputTokens (default: 1024)
public let paymentModel: String       // "tab" or "prepaid" (default: "prepaid" for old providers)
public let pricing: Pricing?          // optional — old providers send it, new ones omit it
```
Full custom `init(from decoder:)` with `decodeIfPresent` for all new fields (and existing fields for robustness). Update memberwise `init()` with defaults. All existing construction call sites compile because all new params have defaults.

### 1G. `Sources/JanusShared/Protocol/ErrorResponse.swift`
Add: `case tabSettlementRequired = "TAB_SETTLEMENT_REQUIRED"`

### 1H. `Sources/JanusShared/Persistence/SessionStore.swift`
Add to `PersistedProviderState`:
```swift
public var tabByChannelId: [String: UInt64]?
// channelId hex → requestID of outstanding TabSettlementRequest (for crash recovery + replay prevention)
public var pendingTabSettlementByChannelId: [String: String]?
```
Both `decodeIfPresent`, both `= nil` in memberwise init. No changes to `PersistedClientSession`.

### 1I. `Sources/JanusShared/Verification/VoucherVerifier.swift`
Keep existing `verify(authorization:channel:quote:)` unchanged. Add NEW method for tab settlements:
```swift
public func verifyTabSettlement(
    authorization auth: VoucherAuthorization,
    channel: Channel,
    tabCredits: UInt64
) throws -> Accepted {
    guard channel.state == .open else { throw VoucherVerificationError.channelNotOpen }
    guard channel.payee == providerAddress else { throw VoucherVerificationError.wrongProvider }
    guard auth.channelId == channel.channelId else { throw VoucherVerificationError.channelMismatch }
    guard auth.cumulativeAmount > channel.authorizedAmount else {
        throw VoucherVerificationError.nonMonotonicVoucher
    }
    let increment = auth.cumulativeAmount - channel.authorizedAmount
    guard increment >= tabCredits else { throw VoucherVerificationError.insufficientAmount }
    guard auth.cumulativeAmount <= channel.deposit else { throw VoucherVerificationError.exceedsDeposit }
    guard Voucher.verify(signedVoucher: auth.signedVoucher,
                         expectedSigner: channel.authorizedSigner, config: config) else {
        throw VoucherVerificationError.invalidSignature
    }
    return Accepted(creditsCharged: Int(tabCredits), newCumulativeAmount: auth.cumulativeAmount)
}
```

---

## Phase 2: MLXRunner Token Counting

### `Sources/JanusProvider/Inference/MLXRunner.swift`

Add struct:
```swift
public struct InferenceResult: Sendable {
    public let outputText: String
    public let outputTokenCount: Int
}
```

Change `generate()` return type to `InferenceResult`. After getting `cleanedText`, add:
```swift
let outputTokenCount = await container.perform { ctx in
    ctx.tokenizer.encode(text: cleanedText, addSpecialTokens: false).count
}
return InferenceResult(outputText: cleanedText, outputTokenCount: outputTokenCount)
```

Update call site in `Sources/JanusProvider/App/Main.swift`: `let result = try await mlxRunner.generate(...)`, use `result.outputText`.

---

## Phase 3: ProviderEngine Overhaul

### `JanusApp/JanusProvider/ProviderEngine.swift`

### 3A. Remove
- `private var pendingQuotes: [String: QuoteResponse]`
- `private var requestCache: [String: PromptRequest]` (request is in scope directly in handlePromptRequest)

### 3B. Add tab state
```swift
private var tabByChannelId: [String: UInt64] = [:]
private var pendingTabSettlementByChannelId: [String: String] = [:]
private let tokenRate: UInt64 = 10
private let tabThresholdTokens: UInt64 = 500   // named "Tokens" to distinguish from settlementThreshold (credits)
```

### 3C. Update `handleMessage()` dispatcher
```swift
case .voucherAuthorization:
    guard let auth = try? envelope.unwrap(as: VoucherAuthorization.self) else { return }
    if auth.quoteID == nil {
        Task { await handleTabSettlementVoucher(auth) }  // tab settlement
    }
    // Prepaid-style vouchers (quoteID non-nil) silently dropped — provider is tab-only
```
Add: `case .tabSettlementRequest: break  // Provider sends, never receives`

### 3D. Rewrite `handlePromptRequest()` ending (replace quote generation block)

Keep all existing session setup (channel verify, SessionSync, top-up detect, sessionToSender/Identity). Replace quote block with:

```swift
let channelIdHex = channel.channelId.hexString  // helper extension or map { String(format:"%02x",$0) }.joined()

// 1. Check deposit sufficiency (ceiling of one full tab cycle)
let maxSettlementCredits = (tabThresholdTokens * tokenRate + 999) / 1000
guard channel.remainingDeposit >= maxSettlementCredits else {
    sendError(.insufficientCredits, "Channel deposit too small. Top up required.", request)
    return
}

// 2. Block + re-send if tab still at threshold (handles lost settlement request + post-restart recovery)
let currentTab = tabByChannelId[channelIdHex] ?? 0
if currentTab >= tabThresholdTokens {
    let tabCredits = (currentTab * tokenRate + 999) / 1000
    let settleRequestID = pendingTabSettlementByChannelId[channelIdHex] ?? UUID().uuidString
    pendingTabSettlementByChannelId[channelIdHex] = settleRequestID
    sendSettlementRequest(tabCredits: tabCredits, requestID: settleRequestID, channel: channel, sessionID: request.sessionID)
    sendError(.tabSettlementRequired, "Tab threshold reached. Settle balance to continue.", request)
    persistState()
    return
}

// 3. Run inference
let result: InferenceResult = try await mlxRunner.generate(
    prompt: request.promptText,
    taskType: request.taskType,
    maxOutputTokens: request.maxOutputTokens ?? Int(serviceAnnounce?.maxOutputTokens ?? 1024)
)

// 4. Update tab
let tokensUsed = UInt64(max(1, result.outputTokenCount))
let newTab = currentTab + tokensUsed
tabByChannelId[channelIdHex] = newTab

// 5. Compute credits (ceiling division, min 1)
let creditsCharged = Int(max(1, (tokensUsed * tokenRate + 999) / 1000))
let cumulativeForReceipt = Int(channel.authorizedAmount) + creditsCharged

// 6. Sign receipt + send response with embedded TabUpdate
let receipt = signReceipt(sessionID: ..., requestID: ..., creditsCharged: creditsCharged, cumulativeSpend: cumulativeForReceipt)
let response = InferenceResponse(
    requestID: request.requestID,
    outputText: result.outputText,
    creditsCharged: creditsCharged,
    cumulativeSpend: cumulativeForReceipt,
    receipt: receipt,
    tabUpdate: TabUpdate(tokensUsed: tokensUsed, cumulativeTabTokens: newTab, tabThreshold: tabThresholdTokens)
)
lastResponses[request.sessionID] = response
sendEnvelope(type: .inferenceResponse, payload: response, toSession: request.sessionID)

// 7. Check threshold and send settlement request if crossed
if newTab >= tabThresholdTokens {
    let tabCredits = (newTab * tokenRate + 999) / 1000
    let settleRequestID = UUID().uuidString
    pendingTabSettlementByChannelId[channelIdHex] = settleRequestID
    sendSettlementRequest(tabCredits: tabCredits, requestID: settleRequestID, channel: channel, sessionID: request.sessionID)
}

totalCreditsEarned += creditsCharged
totalRequestsServed += 1
appendLog(...)
persistState()
```

### 3E. Add `handleTabSettlementVoucher()`
```swift
private func handleTabSettlementVoucher(_ auth: VoucherAuthorization) async {
    guard let (sessionID, var channel) = channels.first(where: { $0.value.channelId == auth.channelId }) else { return }
    let channelIdHex = channel.channelId.hexString

    // Replay prevention: requestID must match outstanding settlement request
    guard let expectedRequestID = pendingTabSettlementByChannelId[channelIdHex],
          auth.requestID == expectedRequestID else { return }

    guard let vv = voucherVerifier else { return }
    let tabTokens = tabByChannelId[channelIdHex] ?? 0
    let tabCredits = (tabTokens * tokenRate + 999) / 1000

    do {
        _ = try vv.verifyTabSettlement(authorization: auth, channel: channel, tabCredits: tabCredits)
        try channel.acceptVoucher(auth.signedVoucher)
        channels[sessionID] = channel
    } catch {
        print("Tab settlement rejected: \(error)")
        return
    }

    tabByChannelId[channelIdHex] = 0
    pendingTabSettlementByChannelId.removeValue(forKey: channelIdHex)
    persistState()

    let pending = pendingSettlementCredits
    if settlementThreshold > 0 && pending >= settlementThreshold {
        Task { await settleAllChannelsOnChain(isRetry: true, removeAfterSettlement: false) }
    }
}
```

### 3F. Update `persistState()` + `restoreFromPersisted()`
Include `tabByChannelId` and `pendingTabSettlementByChannelId` in `PersistedProviderState` construction and restoration.

### 3G. Update `ProviderAdvertiserTransport` protocol + all 4 implementations
`updateServiceAnnounce(providerPubkey:providerEthAddress:)` → add `tokenRate:tabThreshold:maxOutputTokens:paymentModel:` parameters. Update:
- `ProviderAdvertiserTransport.swift` (protocol)
- `BonjourAdvertiser.swift`
- `MPCAdvertiser.swift`
- `CompositeAdvertiser.swift`

---

## Phase 4: ClientEngine Overhaul

### `JanusApp/JanusClient/ClientEngine.swift`

### 4A. Update `RequestState` — remove `.waitingForQuote`, add `.awaitingSettlement`
**All 7 `.waitingForQuote` reference sites:**
| Site | Change |
|------|--------|
| Enum case definition (~line 44) | Delete |
| Disconnect detection (~line 86) | `== .waitingForResponse` only |
| After `submitRequest()` (~line 280) | `requestState = .waitingForResponse` |
| Timeout check (~line 473) | Remove `== .waitingForQuote \|\|` |
| `isWaitingForResponse` property (~line 488) | Remove `.waitingForQuote` from OR |
| `PromptView` button label | Delete `.waitingForQuote` case |
| `PromptView` canSubmit check | Remove `.waitingForQuote` from allowed states |

### 4B. Remove
- `@Published var currentQuote: QuoteResponse?`
- `func handleQuote(_ quote: QuoteResponse)`
- `case .quoteResponse` in `handleMessage()` (or leave as silent `break`)

### 4C. Add
- `@Published var pendingSettlement: TabSettlementRequest? = nil`
- `case .tabSettlementRequest` in `handleMessage()` → `handleTabSettlementRequest(req)`

### 4D. Update `handleInferenceResponse()`
Replace quote fraud check with tab-model check:
```swift
// Tab model: verify creditsCharged matches tokenRate × tokensUsed
if let tabUpdate = response.tabUpdate, let provider = connectedProvider, provider.paymentModel == "tab" {
    let expected = Int(max(1, (tabUpdate.tokensUsed * provider.tokenRate + 999) / 1000))
    guard response.creditsCharged == expected else {
        errorMessage = "Provider charged \(response.creditsCharged) but token count implies \(expected)"
        requestState = .error; return
    }
    sessionManager?.applyTabUpdate(tabUpdate, tokenRate: provider.tokenRate)
}
```

### 4E. Add `handleTabSettlementRequest()` — auto-approves
```swift
private func handleTabSettlementRequest(_ req: TabSettlementRequest) {
    pendingSettlement = req
    requestState = .awaitingSettlement
    guard let session = sessionManager else { return }
    Task {
        do {
            let auth = try await session.createTabSettlementVoucher(
                requestID: req.requestID, tabCredits: req.tabCredits, channelId: req.channelId)
            let envelope = try MessageEnvelope.wrap(type: .voucherAuthorization,
                senderID: session.sessionGrant.sessionID, payload: auth)
            try transport.send(envelope)
            session.recordTabSettlement(tabCredits: req.tabCredits)
            pendingSettlement = nil
            requestState = .idle
        } catch {
            errorMessage = "Tab settlement failed: \(error.localizedDescription)"
            requestState = .error
        }
    }
}
```

### 4F. Update `canAffordRequest`
Remove `PricingTier.small.credits` reference:
```swift
var canAffordRequest: Bool {
    guard requestState != .awaitingSettlement else { return false }
    return (sessionManager?.remainingCredits ?? 0) > 0
}
```

---

## Phase 5: SessionManager Additions

### `JanusApp/JanusClient/SessionManager.swift`

Add `@Published` tab state properties: `currentTabTokens: UInt64`, `tabThreshold: UInt64`, `tokenRate: UInt64`

Add methods:
```swift
func applyTabUpdate(_ tabUpdate: TabUpdate, tokenRate: UInt64) {
    currentTabTokens = tabUpdate.cumulativeTabTokens
    tabThreshold = tabUpdate.tabThreshold
    self.tokenRate = tokenRate
}

func createTabSettlementVoucher(requestID: String, tabCredits: UInt64, channelId: Data) async throws -> VoucherAuthorization {
    guard let wp = walletProvider, let ch = channel else { throw CryptoError.verificationFailed }
    // Cumulative = existing authorized + this tab's credits
    let newCumulative = ch.authorizedAmount + tabCredits
    guard newCumulative <= ch.deposit else { throw ChannelError.exceedsDeposit }
    let voucher = Voucher(channelId: ch.channelId, cumulativeAmount: newCumulative)
    let signed = try await wp.signVoucher(voucher, config: tempoConfig)
    return VoucherAuthorization(requestID: requestID, quoteID: nil, signedVoucher: signed)
}

func recordTabSettlement(tabCredits: UInt64) {
    spendState.advance(creditsCharged: Int(min(tabCredits, UInt64(Int.max))))
    remainingCredits = max(0, Int(channel?.deposit ?? 0) - spendState.cumulativeSpend)
    currentTabTokens = 0
    persist()
}
```

Update channel deposit sizing in `SessionManager.create()` or `setupTempoChannel()`:
```swift
// Set deposit = enough for min 5 tab cycles, based on provider's announced tab economics
// Read from connectedProvider.tabThreshold * tokenRate / 1000 * 5, floor at 100
```

---

## Phase 6: UI Updates

### `PromptView.swift`
- Remove `.waitingForQuote` button label case
- Remove quote badge from status section
- Add tab progress line: `"Tab: \(session.currentTabTokens) / \(session.tabThreshold) tokens"`
- Add settlement pending banner when `requestState == .awaitingSettlement`

### `DiscoveryView.swift` + `DualModeView.swift`
Replace `priceBadge` trio with conditional display:
- `paymentModel == "tab"` → show token rate, tab threshold, max output
- else → show old `pricing.small/medium/large` (backward compat for old prepaid providers)

---

## Phase 7: Test Updates

**Delete:** `Tests/JanusSharedTests/PricingTierTests.swift`

### 7A. New file: `Tests/JanusSharedTests/TabPaymentFlowTests.swift`
**Target:** `Janus-Package` (macOS, fast) — all 22 tests are pure unit tests, no network/simulator needed.

**Shared fixtures** (in `setUp()`):
```swift
private var clientKP: EthKeyPair!
private var providerKP: EthKeyPair!
private var config: TempoConfig!
private var channel: Channel!       // deposit = 100
private var verifier: VoucherVerifier!
private let tokenRate: UInt64 = 10
private let tabThresholdTokens: UInt64 = 500
```
Mirror `VoucherFlowTests.setUp()`: create keypairs, `config = .testnet`, `Channel(deposit: 100)`, `VoucherVerifier(providerAddress: providerKP.address, config: config)`.

**Shared helper:**
```swift
private func makeTabAuth(requestID: String, cumulativeAmount: UInt64) throws -> VoucherAuthorization {
    let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: cumulativeAmount)
    let signed = try voucher.sign(with: clientKP, config: config)
    return VoucherAuthorization(requestID: requestID, quoteID: nil, signedVoucher: signed)
}
```

---

#### Serialization tests (1–4)

**1. `testTabUpdateRoundTrip()`**
Create `TabUpdate(tokensUsed: 42, cumulativeTabTokens: 350, tabThreshold: 500)`, encode/decode.
Assert: all three fields survive round-trip exactly.

**2. `testTabSettlementRequestRoundTrip()`**
Create `TabSettlementRequest(requestID: "settle-001", tabCredits: 5, channelId: Keccak256.hash(Data("test-channel".utf8)))`, encode/decode.
Assert: `requestID`, `tabCredits`, `channelId` (byte-for-byte), `channelId.count == 32`. *(`Data` round-trips via base64 — easy failure point.)*

**3. `testVoucherAuthorizationNilQuoteID_roundTrip()`**
`makeTabAuth(requestID: "req-tab-1", cumulativeAmount: 10)`, encode/decode.
Assert: `decoded.quoteID == nil` (not `"null"`, not crash), `requestID` preserved. *This is the tab discriminant — if nil fails to round-trip, every settlement voucher is misrouted.*

**4. `testVoucherAuthorizationLegacyStringQuoteID_decodesCorrectly()`**
Encode a `VoucherAuthorization(quoteID: "quote-abc", ...)` with the new encoder, decode with the new decoder.
Assert: `decoded.quoteID == "quote-abc"` (non-nil, exact match). *Backward compat for old prepaid clients.*

---

#### VoucherVerifier.verifyTabSettlement() tests (5–7, 17–20)

**5. `testVerifyTabSettlement_acceptsValidVoucher()`**
`tabCredits = (500 * 10 + 999) / 1000 = 5`. `makeTabAuth(cumulativeAmount: 5)`.
Assert: no throw, `result.creditsCharged == 5`, `result.newCumulativeAmount == 5`. Then `channel.acceptVoucher(...)`, assert `channel.authorizedAmount == 5`.

**6. `testVerifyTabSettlement_rejectsNonMonotonicVoucher()`**
Accept voucher at 5 (per test 5 setup). Attempt second with `cumulativeAmount: 3`.
Assert: throws `VoucherVerificationError.nonMonotonicVoucher`.

**7. `testVerifyTabSettlement_rejectsInsufficientAmount()`**
`tabCredits = 10`, voucher `cumulativeAmount = 5` (increment 5 < 10).
Assert: throws `VoucherVerificationError.insufficientAmount`.

**17. `testVerifyTabSettlement_rejectsExceedingDeposit()`**
Channel `deposit = 100`. `makeTabAuth(cumulativeAmount: 150)`.
Assert: throws `VoucherVerificationError.exceedsDeposit`.

**18. `testVerifyTabSettlement_rejectsWrongSigner()`**
Sign with `wrongKP = try EthKeyPair()` (not `clientKP`). `quoteID: nil`.
Assert: throws `VoucherVerificationError.invalidSignature`.

**19. `testVerifyTabSettlement_rejectsWrongChannelId()`**
`Voucher(channelId: Keccak256.hash(Data("wrong-channel".utf8)), cumulativeAmount: 5)`.
Assert: throws `VoucherVerificationError.channelMismatch`.

**20. `testVerifyTabSettlement_channelNotOpen_rejected()`**
Set `closedChannel.state = .closed`.
Assert: throws `VoucherVerificationError.channelNotOpen`.

---

#### Persistence test (8)

**8. `testTabByChannelId_persistenceRoundTrip()`**
Create `PersistedProviderState` with `tabByChannelId: [hex: 350]` and `pendingTabSettlementByChannelId: [hex: "settle-req-001"]`, encode/decode.
Assert: both fields survive with correct values. Also test with `nil` tab fields: assert `decoded.tabByChannelId == nil`, `decoded.pendingTabSettlementByChannelId == nil` (handles old provider state files).

---

#### Edge case tests (9–16)

**9. `testTabBlock_exactlyAtThreshold()`**
```swift
XCTAssertTrue(UInt64(500) >= UInt64(500))   // blocked at ==
XCTAssertFalse(UInt64(499) >= UInt64(500))  // not blocked below
```
*Invariant 1 specifies `>=` not `>`. Off-by-one costs one free inference or one lost request.*

**10. `testCeilingDivision_zeroTokenOutput_minimumOneCredit()`**
```swift
let credits = max(1, (UInt64(0) * 10 + 999) / 1000)
XCTAssertEqual(credits, 1)
```
*0-credit charge breaks voucher monotonicity — `max(1,...)` guard must hold.*

**11. `testCeilingDivision_correctnessAcrossRange()`**
Table-driven at `tokenRate = 10`:

| tokens | expected credits |
|--------|-----------------|
| 1 | 1 |
| 99 | 1 |
| 100 | 1 |
| 101 | 2 |
| 500 | 5 |
| 1000 | 10 |
| 1001 | 11 |

Assert each: `max(1, (tokens * 10 + 999) / 1000) == expected`.

**12. `testTabReset_afterSuccessfulSettlement()`**
Accept voucher at 5 (tab was 500). Reset `tabByChannelId[hex] = 0`.
Assert: tab == 0, not blocked, second voucher at `cumulativeAmount: 10` (monotonic above 5) succeeds.

**13. `testReplayPrevention_sameRequestID_rejected()`**
Accept settlement, clear `pendingTabSettlementByChannelId`.
Replay same auth: assert `pendingTabSettlementByChannelId[hex] == nil` (guard fails) AND `verifyTabSettlement` throws `.nonMonotonicVoucher` (both defenses independently block it).

**14. `testReplayPrevention_wrongRequestID_rejected()`**
Pending = `"settle-req-001"`. Auth `requestID = "settle-req-999"`.
Assert: `auth.requestID != pendingTabSettlementByChannelId[hex]`.

**15. `testTabAccumulation_acrossMultipleRequests()`**
Simulate 3×100-token requests → tab = 300, not blocked. Add 2×100 → tab = 500, blocked.
Assert credits: `max(1, (500 * 10 + 999) / 1000) == 5`.

**16. `testDepositTooSmall_insufficientForOneTabCycle()`**
`deposit = 4`. `maxSettlementCredits = (500 * 10 + 999) / 1000 = 5`.
Assert: `deposit < maxSettlementCredits`. Boundary: `deposit = 5` → sufficient.

---

#### Integration test (21)

**21. `testFullTabCycle_connectThreePromptsSettlementThenFourthPrompt()`**

Full domain-level simulation — no MLX, no transport, no UI:

1. 3 prompts: 200 + 150 + 200 = 550 tokens → tab crosses 500 threshold
2. `tabCredits = max(1, (550 * 10 + 999) / 1000) = 6`
3. Provider generates `TabSettlementRequest(requestID: uuid, tabCredits: 6, channelId: ...)`
4. Client signs: `makeTabAuth(requestID: uuid, cumulativeAmount: 0 + 6 = 6)`, assert `quoteID == nil`
5. Replay check passes: `auth.requestID == pendingTabSettlementByChannelId[hex]`
6. `verifyTabSettlement` → accept → `channel.authorizedAmount == 6`
7. Tab reset to 0, pending cleared
8. 4th prompt: 100 tokens, not blocked, `channel.remainingDeposit = 94 >= 5` (room for more cycles)

Assert each step. *If this test passes, the tab model works correctly end-to-end at the protocol layer.*

---

#### Crash recovery test (22)

**22. `testCrashRecovery_persistedTabState_restoredCorrectly()`**

Scenario A — crash mid-cycle (no pending settlement):
`PersistedProviderState(tabByChannelId: [hex: 350], pendingTabSettlementByChannelId: nil)`, encode/decode.
Assert: tab = 350 restored, not blocked (350 < 500), no pending settlement.

Scenario B — crash during settlement:
`PersistedProviderState(tabByChannelId: [hex: 550], pendingTabSettlementByChannelId: [hex: "settle-req-crash"])`, encode/decode.
Assert: tab = 550 (still blocked), pending requestID = `"settle-req-crash"` (provider re-sends on reconnect).

---

### 7B. Updates to existing test files

**`VoucherFlowTests.swift`** — update `makeAuth()`:
```swift
// Before:
private func makeAuth(requestID: String, quoteID: String, cumulativeAmount: UInt64) throws -> VoucherAuthorization
// After:
private func makeAuth(requestID: String, quoteID: String? = "test-quote-id", cumulativeAmount: UInt64) throws -> VoucherAuthorization
```

**`ProtocolTests.swift`** — update `testServiceAnnounceRoundTrip()`:
Add `tokenRate: 15, tabThreshold: 1000, maxOutputTokens: 2048, paymentModel: "tab"` to the constructed `ServiceAnnounce`.
Assert: all 4 new fields, `XCTAssertNotNil(decoded.pricing)` (pricing is now `Pricing?`).

Add new test `testServiceAnnounce_oldJSON_decodesWithDefaults()`:
Feed raw old-schema JSON (no new fields, `pricing` present), decode, assert:
`tokenRate == 10`, `tabThreshold == 500`, `maxOutputTokens == 1024`, `paymentModel == "prepaid"`, `pricing?.small == 3`.

**`ClientEngineTests.swift`** — three changes (implement after Phases 4–5):
- **Remove**: `testHandleQuoteResponse_setsCurrentQuote()`, `testHandleQuoteResponse_ignoresWrongRequestID()`
- **Update** `testHandleInferenceResponse_rejectsMismatchedCharge()`: set `connectedProvider.paymentModel = "tab"`, `tokenRate = 10`; inject response with `tabUpdate.tokensUsed = 100`, `creditsCharged = 5` (correct is 1); assert `requestState == .error`
- **Add** `testHandleTabSettlementRequest_autoSignsVoucher()`: inject `TabSettlementRequest`, assert state transitions `.awaitingSettlement` → `.idle`, `pendingSettlement` set then cleared

---

### Priority order for test implementation

Implement in this order if time is constrained:
1. **Test 21** (full cycle integration) — exercises all 8 invariants at once
2. **Tests 9–11** (arithmetic) — pure logic, writable before any Phase 1 code exists
3. **Tests 3, 5–7** (nil discriminant + verifyTabSettlement core) — most likely failure points
4. **Test 22** (crash recovery) — persistence correctness
5. **Tests 13–14** (replay prevention) — security invariant
6. Everything else

---

## Execution Order

1. Phase 1 (JanusShared) — all in one commit
2. Phase 2 (MLXRunner) — update Main.swift PricingTier refs here too
3. Phase 3 (ProviderEngine)
4. Phase 4+5 (ClientEngine + SessionManager)
5. Phase 6 (UI)
6. Delete QuoteResponse.swift + PricingTier.swift (only after all callers removed)
7. Phase 7 (Tests)

---

## Key Invariants

1. **Tab block = derived check**: `(tabByChannelId[id] ?? 0) >= tabThresholdTokens` — no separate Set, crash-safe
2. **Pending settlement persisted**: `pendingTabSettlementByChannelId` in `PersistedProviderState` — provider re-sends on reconnect
3. **Replay prevention**: `auth.requestID == pendingTabSettlementByChannelId[channelIdHex]` before accepting
4. **Ceiling division**: `(tokens * rate + 999) / 1000`, min 1 — prevents 0-credit monotonicity break
5. **quoteID nil = discriminant**: Routes to `handleTabSettlementVoucher()` in provider
6. **Old `verify()` preserved**: Prepaid path still compiles; tab uses new `verifyTabSettlement()`
7. **`InferenceResponse` default nil**: All existing construction call sites compile unchanged
8. **ServiceAnnounce backward compat**: All new fields `decodeIfPresent` with sensible defaults

---

## Verification

```bash
cd /Users/soubhik/Projects/janus/JanusApp
xcodebuild -workspace JanusApp.xcworkspace -scheme JanusClient -destination 'generic/platform=iOS' build
xcodebuild -workspace JanusApp.xcworkspace -scheme JanusProvider -destination 'platform=macOS' build

cd /Users/soubhik/Projects/janus
xcodebuild test -scheme Janus-Package -destination 'platform=macOS'
xcodebuild test -workspace JanusApp/JanusApp.xcworkspace -scheme JanusClientTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

E2E test: Set `tabThresholdTokens = 20` (low for testing). Submit 3-4 prompts. Verify settlement banner appears, tab resets, inference continues. Restart provider. Reconnect client. Verify tab resumes from persisted value.

---

## Files Modified

| File | Change |
|------|--------|
| `Sources/JanusShared/Protocol/TabUpdate.swift` | NEW |
| `Sources/JanusShared/Protocol/TabSettlementRequest.swift` | NEW |
| `Tests/JanusSharedTests/TabPaymentFlowTests.swift` | NEW |
| `Sources/JanusShared/Protocol/QuoteResponse.swift` | DELETE (after callers removed) |
| `Sources/JanusShared/Models/PricingTier.swift` | DELETE (after callers removed) |
| `Tests/JanusSharedTests/PricingTierTests.swift` | DELETE |
| `Sources/JanusShared/Protocol/MessageEnvelope.swift` | Add `.tabSettlementRequest` |
| `Sources/JanusShared/Protocol/InferenceResponse.swift` | Add `tabUpdate: TabUpdate?` |
| `Sources/JanusShared/Protocol/VoucherAuthorization.swift` | `quoteID: String?`, custom decoder |
| `Sources/JanusShared/Protocol/ServiceAnnounce.swift` | Add 4 new fields, `pricing` optional |
| `Sources/JanusShared/Protocol/ErrorResponse.swift` | Add `.tabSettlementRequired` |
| `Sources/JanusShared/Persistence/SessionStore.swift` | Add tab fields to PersistedProviderState |
| `Sources/JanusShared/Verification/VoucherVerifier.swift` | Add `verifyTabSettlement()` |
| `Sources/JanusProvider/Inference/MLXRunner.swift` | Return `InferenceResult` |
| `Sources/JanusProvider/App/Main.swift` | Remove PricingTier refs |
| `JanusApp/JanusProvider/ProviderEngine.swift` | Full pipeline rewrite |
| `JanusApp/JanusProvider/BonjourAdvertiser.swift` | updateServiceAnnounce signature |
| `JanusApp/JanusProvider/MPCAdvertiser.swift` | updateServiceAnnounce signature |
| `JanusApp/JanusProvider/CompositeAdvertiser.swift` | updateServiceAnnounce signature |
| `JanusApp/JanusProvider/ProviderAdvertiserTransport.swift` | updateServiceAnnounce protocol |
| `JanusApp/JanusClient/ClientEngine.swift` | Remove quote; add tab settlement |
| `JanusApp/JanusClient/SessionManager.swift` | Add tab state + methods |
| `JanusApp/JanusClient/PromptView.swift` | Tab UI, settlement banner |
| `JanusApp/JanusClient/DiscoveryView.swift` | Provider pricing display |
| `JanusApp/JanusClient/DualModeView.swift` | Provider pricing display |
| `Tests/JanusSharedTests/ProtocolTests.swift` | Update ServiceAnnounce test |
| `Tests/JanusSharedTests/VoucherFlowTests.swift` | makeAuth() quoteID optional |
| `JanusApp/JanusClientTests/ClientEngineTests.swift` | Remove quote tests; add tab tests |
