# Janus V1 — Product Requirements Document

## One-line summary

A direct local AI hotspot: one Apple Silicon Mac runs a small OSS text model via MLX, one iPhone app connects over Multipeer Connectivity with no internet at request time, the phone spends from a provider-bound prepaid session using signed cumulative spend updates, and the Mac returns the inference result plus a signed receipt.

---

## 1. Goals

1. **Prove local AI utility** — Demonstrate that users will consume LLM inference from a nearby Mac when internet is unavailable.
2. **Prove offline payment authorization** — Demonstrate that provider-bound prepaid sessions with cumulative spend can gate usage locally without any network call at request time.
3. **Prove the transport** — Demonstrate that Multipeer Connectivity is viable for request/response inference payloads between iPhone and Mac.
4. **Preserve end-state alignment** — Every protocol message and data structure should map cleanly to the eventual MPP/Tempo-backed, relay-capable architecture.
5. **Ship a demo** — A working end-to-end flow: fund session online, go offline, discover provider, submit prompt, pay, get response, see receipt.

## 2. Non-goals

- Multi-hop relay routing or phone-to-phone forwarding
- Provider marketplace or cross-provider sessions
- Real money settlement (Stripe/Tempo integration)
- Streaming token delivery
- Multimodal (images, voice, audio)
- Long-context or multi-turn chat
- Android support
- Background iPhone operation
- Automatic fraud arbitration or dispute resolution
- Production-grade security hardening

---

## 3. Actors

| Actor | Device | Role |
|-------|--------|------|
| **Provider** | Mac mini / MacBook (Apple Silicon) | Runs model, verifies payments, serves inference, signs receipts |
| **Client** | iPhone | Discovers provider, holds session, signs spend updates, displays results |
| **Backend** | Cloud server | Issues session grants, registers providers, tops up credits (online only) |

---

## 4. Use cases (v1 scope)

Pick exactly three task types:

1. **Translation** — "Translate this text into [language]."
2. **Rewrite** — "Rewrite this message professionally / simply / formally."
3. **Summarization** — "Summarize this paragraph."

All are short-input, short-output, obvious-value tasks that work well with small local models.

---

## 5. Protocol schema

### 5.1 Message types

All messages are JSON payloads exchanged over Multipeer Connectivity.

Every message has a common envelope:

```
MessageEnvelope {
  type:         String          // message type identifier
  message_id:   String (UUID)   // unique per message
  timestamp:    String (ISO8601)
  sender_id:    String          // provider_id or client_id
  payload:      <type-specific>
}
```

### 5.2 Discovery

**ServiceAnnounce** (Provider → Client, via MPC discovery/browse)

```
ServiceAnnounce {
  provider_id:        String
  provider_name:      String
  model_tier:         String          // e.g. "small-text-v1"
  supported_tasks:    [String]        // ["translate", "rewrite", "summarize"]
  pricing: {
    small:            Int             // credits
    medium:           Int
    large:            Int
  }
  available:          Bool
  queue_depth:        Int             // number of pending requests
  provider_pubkey:    String (base64) // for receipt verification
}
```

### 5.3 Request flow

**PromptRequest** (Client → Provider)

```
PromptRequest {
  request_id:         String (UUID)
  session_id:         String
  task_type:          String          // "translate" | "rewrite" | "summarize"
  prompt_text:        String
  parameters: {
    target_language:  String?         // for translation
    style:            String?         // for rewrite: "professional", "simple", "formal"
  }
  max_output_tokens:  Int?
}
```

**QuoteResponse** (Provider → Client)

```
QuoteResponse {
  request_id:         String (UUID)   // references the PromptRequest
  quote_id:           String (UUID)
  price_credits:      Int
  price_tier:         String          // "small" | "medium" | "large"
  expires_at:         String (ISO8601)
}
```

**SpendAuthorization** (Client → Provider)

```
SpendAuthorization {
  session_id:         String
  request_id:         String (UUID)
  quote_id:           String (UUID)
  cumulative_spend:   Int             // new total, monotonically increasing
  sequence_number:    Int             // monotonically increasing
  client_signature:   String (base64) // sign(session_id | request_id | quote_id | cumulative_spend | sequence_number)
}
```

**InferenceResponse** (Provider → Client)

```
InferenceResponse {
  request_id:         String (UUID)
  output_text:        String
  credits_charged:    Int
  cumulative_spend:   Int             // accepted cumulative total
  receipt: {
    receipt_id:       String (UUID)
    session_id:       String
    request_id:       String (UUID)
    provider_id:      String
    credits_charged:  Int
    cumulative_spend: Int
    timestamp:        String (ISO8601)
    provider_signature: String (base64)
  }
}
```

**ErrorResponse** (Provider → Client)

```
ErrorResponse {
  request_id:         String (UUID)?
  error_code:         String          // "INVALID_SESSION", "EXPIRED_QUOTE", "INSUFFICIENT_CREDITS",
                                      // "INVALID_SIGNATURE", "SESSION_EXPIRED", "PROVIDER_BUSY",
                                      // "SEQUENCE_MISMATCH", "INFERENCE_FAILED"
  error_message:      String
}
```

### 5.4 Full request sequence

```
Client                                Provider
  |                                      |
  |  ---- [discover via MPC browse] ---> |
  |  <--- ServiceAnnounce -------------- |
  |                                      |
  |  ---- PromptRequest ---------------> |
  |  <--- QuoteResponse ---------------- |
  |                                      |
  |  ---- SpendAuthorization ----------> |
  |       [verify signature, session,    |
  |        cumulative spend, budget]     |
  |       [run MLX inference]            |
  |  <--- InferenceResponse ------------ |
  |       (includes signed receipt)      |
  |                                      |
```

---

## 6. Data model

### 6.1 Backend database

**providers**

| Field | Type | Description |
|-------|------|-------------|
| provider_id | String (UUID) | Primary key |
| provider_name | String | Display name |
| provider_pubkey | String (base64) | Provider's public key |
| registered_at | Timestamp | Registration time |
| active | Bool | Whether provider is active |

**sessions**

| Field | Type | Description |
|-------|------|-------------|
| session_id | String (UUID) | Primary key |
| user_id | String (UUID) | FK to users |
| provider_id | String (UUID) | FK to providers — session is bound to this provider |
| user_pubkey | String (base64) | Client's public key for this session |
| max_credits | Int | Total credits authorized |
| expires_at | Timestamp | Session expiry |
| created_at | Timestamp | Creation time |
| backend_signature | String (base64) | Backend signs the grant |

**users**

| Field | Type | Description |
|-------|------|-------------|
| user_id | String (UUID) | Primary key |
| created_at | Timestamp | Registration time |

### 6.2 Provider local state (SQLite)

**known_sessions**

| Field | Type | Description |
|-------|------|-------------|
| session_id | String | Primary key |
| user_pubkey | String | Client's public key |
| provider_id | String | Must match this provider |
| max_credits | Int | Budget cap |
| expires_at | Timestamp | Session expiry |
| backend_signature | String | Proof of valid issuance |

**spend_ledger**

| Field | Type | Description |
|-------|------|-------------|
| session_id | String | FK to known_sessions |
| last_cumulative_spend | Int | Latest accepted cumulative spend |
| last_sequence_number | Int | Latest accepted sequence number |
| updated_at | Timestamp | Last update time |

**request_log**

| Field | Type | Description |
|-------|------|-------------|
| request_id | String (UUID) | Primary key |
| session_id | String | FK to known_sessions |
| quote_id | String (UUID) | Quote that was accepted |
| prompt_text | String | Input |
| output_text | String | Response |
| credits_charged | Int | Actual cost |
| cumulative_spend | Int | Accepted cumulative at this request |
| sequence_number | Int | Sequence at this request |
| receipt_signature | String | Provider's receipt signature |
| created_at | Timestamp | Request time |

### 6.3 iPhone local state (Keychain + local storage)

**keychain**

| Item | Description |
|------|-------------|
| user_private_key | Ed25519 private key for signing spend updates |
| user_public_key | Corresponding public key |

**local storage (UserDefaults / SQLite)**

| Data | Description |
|------|-------------|
| session_grants | Array of `SessionGrant` objects (session_id, provider_id, max_credits, expires_at, backend_signature) |
| current_spend_state | Per session: latest cumulative_spend and sequence_number |
| receipt_history | Array of signed receipts from provider |

---

## 7. Cryptographic scheme (v1)

### Key types

- **Backend signing key**: Ed25519 keypair. Signs session grants.
- **Client signing key**: Ed25519 keypair per user. Signs spend authorizations.
- **Provider signing key**: Ed25519 keypair per provider. Signs receipts.

### What is signed and verified

| Artifact | Signer | Verifier | Signed fields |
|----------|--------|----------|---------------|
| Session grant | Backend | Provider (at sync time) | session_id, user_pubkey, provider_id, max_credits, expires_at |
| Spend authorization | Client | Provider (at request time) | session_id, request_id, quote_id, cumulative_spend, sequence_number |
| Receipt | Provider | Client (at response time) | receipt_id, session_id, request_id, provider_id, credits_charged, cumulative_spend, timestamp |

### Signature format

`sign(field1 || field2 || ... || fieldN)` where `||` is concatenation of UTF-8 encoded fields with a delimiter (e.g. `\n`).

All signatures are Ed25519, encoded as base64.

### Key distribution

- Backend public key is hardcoded in both the provider and client apps (v1 simplification).
- Provider public key is advertised in `ServiceAnnounce` and registered in the backend.
- Client public key is embedded in the session grant.

---

## 8. Provider verification logic

When a `SpendAuthorization` arrives, the provider executes these checks **in order**:

1. **Session exists** — `session_id` is in `known_sessions`
2. **Session not expired** — `expires_at > now`
3. **Provider match** — session's `provider_id` matches this provider
4. **Quote valid** — `quote_id` references a recently issued quote that hasn't expired
5. **Sequence monotonic** — `sequence_number > last_sequence_number` for this session
6. **Spend monotonic** — `cumulative_spend > last_cumulative_spend` for this session
7. **Spend increment matches quote** — `cumulative_spend - last_cumulative_spend >= price_credits` from the quote
8. **Budget sufficient** — `cumulative_spend <= max_credits`
9. **Signature valid** — verify `client_signature` against `user_pubkey` from the session grant

If any check fails, return `ErrorResponse` with the appropriate error code. Do not run inference.

If all pass: update `spend_ledger`, run inference, sign receipt, return `InferenceResponse`.

---

## 9. Pricing rules (v1)

| Tier | Prompt length | Max output tokens | Credits |
|------|--------------|-------------------|---------|
| small | < 200 chars | 256 | 3 |
| medium | 200–800 chars | 512 | 5 |
| large | > 800 chars | 1024 | 8 |

Provider determines tier from `prompt_text` length in the `PromptRequest`. Tier is returned in `QuoteResponse`.

---

## 10. Session lifecycle

```
[Online]                                  [Offline]

User opens app                            User approaches provider
    |                                         |
    v                                         v
Backend issues session grant         MPC discovery finds provider
    |                                         |
    v                                         v
Phone stores grant locally           Phone sends PromptRequest
    |                                         |
    v                                         v
Phone stores grant locally           Phone sends PromptRequest + grant
    |                                         |
    v                                         v
(internet no longer needed)          Provider verifies backend sig,
                                     caches grant, returns QuoteResponse
                                              |
                                              v
                                     Phone signs SpendAuthorization
                                              |
                                              v
                                     Provider verifies + runs inference
                                              |
                                              v
                                     Phone receives response + receipt
                                              |
                                              v
                                     Phone updates local spend state
```

### Session grant delivery

The client presents the full signed session grant with its first `PromptRequest` to a provider. The provider verifies the backend's signature (using the hardcoded backend public key), caches the grant in `known_sessions`, and proceeds with verification. Subsequent requests for the same session skip grant delivery — the provider already has it cached.

This mirrors MPP's client-presents-credential pattern and requires no provider-side polling or sync infrastructure.

---

## 11. Tech stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| iPhone app | SwiftUI + Swift | Foreground only |
| iPhone transport | MultipeerConnectivity framework | Browse + advertise |
| iPhone crypto | CryptoKit (Curve25519) | Ed25519 signing |
| iPhone storage | Keychain (keys) + SwiftData or UserDefaults (sessions, receipts) | |
| Mac provider app | Swift | Menu bar app or daemon |
| Mac transport | MultipeerConnectivity framework | Advertise + browse |
| Mac inference | MLX + mlx-swift | `mlx-community/Qwen3-4B-4bit` (dev), consider 6-bit for demo |
| Mac storage | SQLite (via swift-sqlite or similar) | Spend ledger, request log |
| Mac crypto | CryptoKit (Curve25519) | Ed25519 signing + verification |
| Backend | Swift (Vapor) | Shared crypto code via Swift package, 3–4 endpoints |
| Backend DB | SQLite or Postgres | Minimal schema |

---

## 12. Code module structure

Monorepo with SPM for shared libraries + backend, Xcode workspace for Apple app targets.

```
janus/
├── Package.swift                       # SPM manifest (shared libs + backend)
├── JanusApp/                           # Xcode workspace for Apple targets
│   ├── JanusApp.xcworkspace
│   ├── JanusClient/                    # iOS app target
│   └── JanusProvider/                  # macOS app target
│
├── Sources/
│   ├── JanusShared/                    # Shared package — NO platform dependencies
│   │   ├── Protocol/                   # Wire format message types
│   │   │   ├── MessageEnvelope.swift
│   │   │   ├── ServiceAnnounce.swift
│   │   │   ├── PromptRequest.swift
│   │   │   ├── QuoteResponse.swift
│   │   │   ├── SpendAuthorization.swift
│   │   │   ├── InferenceResponse.swift
│   │   │   └── ErrorResponse.swift
│   │   ├── Crypto/                     # Ed25519 signing & verification
│   │   │   ├── KeyPair.swift
│   │   │   ├── Signer.swift
│   │   │   └── Verifier.swift
│   │   └── Models/                     # Domain types
│   │       ├── SessionGrant.swift
│   │       ├── SpendState.swift
│   │       ├── Receipt.swift
│   │       ├── PricingTier.swift
│   │       └── TaskType.swift
│   │
│   └── JanusBackend/                   # Vapor server
│       ├── main.swift
│       ├── Routes/
│       │   ├── ProviderRoutes.swift     # POST /providers/register
│       │   ├── SessionRoutes.swift      # POST /sessions, POST /sessions/:id/topup
│       │   └── HealthRoutes.swift       # GET /health
│       ├── Services/
│       │   ├── GrantSigner.swift        # Signs grants using JanusShared/Crypto
│       │   └── SessionService.swift
│       └── Storage/
│           └── BackendDB.swift
│
├── JanusClient/                        # iOS app source
│   ├── Transport/
│   │   └── MPCBrowser.swift             # MPC discovery + message I/O
│   ├── Session/
│   │   ├── SessionManager.swift         # Grant storage, spend state tracking
│   │   └── SpendSigner.swift            # Signs spend authorizations
│   ├── Storage/
│   │   ├── KeychainStore.swift          # Ed25519 keys in Keychain
│   │   └── ReceiptStore.swift           # Local receipt history
│   └── UI/
│       ├── DiscoveryView.swift          # Find nearby providers
│       ├── PromptView.swift             # Enter prompt, select task type
│       ├── ResponseView.swift           # Display inference result
│       ├── BalanceView.swift            # Remaining credits
│       └── ReceiptListView.swift        # Receipt history
│
├── JanusProvider/                      # macOS app source
│   ├── Transport/
│   │   └── MPCAdvertiser.swift          # MPC advertising + message I/O
│   ├── Verification/
│   │   └── SpendVerifier.swift          # 9-step verification logic
│   ├── Inference/
│   │   ├── MLXRunner.swift              # Model loading + generation
│   │   └── PromptTemplates.swift        # System prompts per task type
│   ├── Storage/
│   │   ├── SessionLedger.swift          # known_sessions + spend_ledger (SQLite)
│   │   └── RequestLog.swift             # Request + receipt log
│   └── App/
│       └── ProviderStatusView.swift     # Status UI
│
└── Tests/
    ├── JanusSharedTests/
    │   ├── CryptoTests.swift            # Sign/verify round-trip
    │   ├── ProtocolTests.swift          # Encode/decode all message types
    │   └── SpendStateTests.swift        # Cumulative spend logic
    └── JanusBackendTests/
        └── SessionTests.swift           # Grant issuance + signature validity
```

### Module dependency graph

```
JanusBackend ──────┐
JanusClient  ──────┤──→ JanusShared (Protocol, Crypto, Models)
JanusProvider ─────┘
                         │
JanusProvider ──→ MLX    │  (provider-only)
JanusBackend  ──→ Vapor  │  (backend-only)
```

### Design principles

- **JanusShared** has zero platform dependencies (no UIKit, no AppKit, no Vapor). Pure Swift + CryptoKit.
- **Transport is isolated from protocol.** MPCBrowser and MPCAdvertiser deal only in `MessageEnvelope` bytes. Swappable for BLE later.
- **SpendVerifier is pure logic.** `(SpendAuthorization, SessionGrant, SpendState) → Result<Accepted, VerificationError>`. Testable without MPC, MLX, or any I/O.
- **No circular dependencies.** Each target pulls in only JanusShared plus its own platform deps.

---

## 13. Milestones

### M1: Local inference on Mac (standalone)

**Goal**: MLX model running on Mac, accepting a prompt and returning a response via CLI or simple UI.

Model: `mlx-community/Qwen3-4B-4bit`

Deliverables:
- Mac app scaffold
- MLX model loading and inference with Qwen3-4B-4bit
- Prompt → response working locally
- Pricing tier classification from prompt length

### M2: Multipeer Connectivity link

**Goal**: iPhone and Mac discover each other and exchange JSON messages over MPC.

Deliverables:
- MPC advertiser on Mac
- MPC browser on iPhone
- Bidirectional JSON message exchange
- ServiceAnnounce broadcast on connection
- iPhone displays provider info

### M3: Cryptographic session model

**Goal**: Session grants, spend authorizations, and receipts all work with real Ed25519 signatures.

Deliverables:
- Key generation on all three components (backend, client, provider)
- Backend signs session grants
- Client signs spend authorizations
- Provider verifies spend authorizations (full 9-step check)
- Provider signs receipts
- Client verifies receipts
- Spend ledger tracks cumulative state

### M4: End-to-end flow

**Goal**: Full demo flow — fund session online, go offline, discover, prompt, pay, receive, see receipt.

Deliverables:
- Backend API: create session, register provider
- iPhone: session funding flow (online), prompt entry UI, quote display, response display, receipt history, balance display
- Mac: quote generation, verification + inference pipeline, receipt generation
- All protocol messages wired together over MPC
- Error handling for all failure cases

### M5: Polish and demo

**Goal**: Reliable, demo-ready experience.

Deliverables:
- UI polish on iPhone (clean prompt entry, response display, balance indicator)
- Mac status UI (active sessions, request log, queue)
- Edge case handling (session expired, insufficient credits, provider disconnected mid-request)
- Demo script for the three use cases (translate, rewrite, summarize)

---

## 14. Decision log

Decisions are recorded with rationale so future contributors understand *why*, not just *what*.

### D1: Inference model — Qwen3-4B-4bit

**Decision**: Use `mlx-community/Qwen3-4B-4bit` for development. May upgrade to 6-bit or Instruct-2507 variant for demo quality.

**Why**: Qwen3-4B is the sweet spot in the MLX ecosystem for v1. The 0.6B and 1.7B variants produce noticeably worse output for translation/rewrite/summarization tasks. The 8B is viable but slower and uses more memory. 4-bit quantization (~2.3 GB RAM) keeps memory pressure low during development, leaving room for the rest of the provider app. The model can be swapped by changing a single model ID — no architectural impact.

**Alternatives rejected**: Llama 3.2 1B/3B (weaker on multilingual tasks), Phi-3 mini (less MLX community support), Qwen3-8B (unnecessary memory cost for v1).

### D2: Session grant delivery — Client presents on first contact

**Decision**: Client carries the full signed session grant and presents it to the provider on first contact. Provider verifies the backend signature and caches locally.

**Why**: This mirrors MPP's client-presents-credential pattern. In MPP, the server never fetches credentials from the payment authority — the client carries them. Building Option B now means the grant delivery code path (`client presents signed artifact → provider verifies authority signature → caches`) stays identical when swapping to Tempo. Option A (provider polls backend for sessions) would require building sync infrastructure that gets torn out during MPP migration. Option B also eliminates a timing dependency: with Option A, the provider must sync *after* session creation but *before* the client arrives — a gap that causes silent failures.

**Alternatives rejected**: Option A (provider polls backend) — adds sync infrastructure, creates timing dependency, doesn't match MPP's credential flow pattern.

### D3: Transport — Multipeer Connectivity

**Decision**: Use Apple's Multipeer Connectivity framework for v1, not a custom BLE-GATT protocol.

**Why**: MPC gives discovery, reliable bidirectional messaging, and larger payloads out of the box. A custom BLE protocol would mean writing GATT services, chunking payloads across 512-byte MTUs, and managing connection state machines — all complexity that doesn't prove the product thesis. MPC is Apple-to-Apple only, which is fine since v1 targets Mac + iPhone exclusively. When relay/mesh semantics are needed post-v1, we can drop to CoreBluetooth.

**Alternatives rejected**: Custom BLE-GATT (too much transport plumbing for v1), Wi-Fi Direct (requires network configuration, defeats "no Wi-Fi" premise).

### D4: Quote round-trip — Keep it

**Decision**: Keep the explicit QuoteResponse step in the protocol, even though the client could pre-compute the price from advertised pricing tiers.

**Why**: The quote step maps directly to MPP's `402 Payment Required` challenge. Removing it would mean adding it back during MPP migration. The latency cost is <50ms on a direct MPC link. Keeping it also lets the provider dynamically adjust pricing in the future (queue depth surcharges, model-specific costs) without protocol changes.

### D5: Backend tech — Swift (Vapor)

**Decision**: Use Swift with Vapor for the thin session-issuance backend.

**Why**: The backend signs session grants with Ed25519. The provider and client verify those signatures with CryptoKit. If the backend is also Swift, the signing code is the *same* CryptoKit calls — field ordering, delimiter, encoding are all shared via a Swift package. With Python (FastAPI), you'd maintain parallel Ed25519 implementations and risk subtle serialization mismatches on a security-critical path. The backend is tiny (3–4 endpoints: register provider, create session, top up credits, health check), so Vapor's slightly slower iteration speed vs FastAPI is negligible. The whole Janus stack being one language also means one set of tooling, one CI pipeline, and shared model types.

**Alternatives rejected**: Python (FastAPI) — faster to prototype but introduces a second language for crypto code, creating a subtle bug surface for signature serialization mismatches.

### D6: MPC reliability — pending

### D7: Prompt templates — pending

---

## 15. Open questions

6. **MPC reliability** — Need to test Multipeer Connectivity throughput and latency for inference-sized payloads (potentially several KB responses). May need chunking strategy.
7. **Model prompt templates** — How to structure system prompts for the three task types to get consistent quality from a small model.
