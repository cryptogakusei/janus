# Janus V1 Spec

## V1 thesis

A user with an iPhone can get useful LLM inference from a nearby MacBook/Mac mini **without Wi-Fi or cellular at request time**, and the Mac can **gate usage on a locally verifiable prepaid session balance**.

---

## 1. What v1 is

### Topology

* 1 provider Mac
* 1 iPhone client
* direct local connection only
* no relay nodes, no mesh, no live settlement during inference

### Core product

**iPhone app**: discovers Mac nearby, sends text prompt, receives text response, spends from previously synced session balance.

**Mac app**: runs small OSS model locally, advertises over local transport, verifies local payment state, executes inference, returns output and signed receipt.

---

## 2. What v1 is NOT

* multi-hop relay routing
* phone-to-phone forwarding
* generalized MPP over arbitrary transports
* provider marketplace
* cross-provider portable sessions
* dynamic online settlement
* images, voice, or multimodal
* streaming tokens
* sophisticated pricing
* background iPhone relay participation
* automatic fraud arbitration

---

## 3. V1 user experience

1. **Fund session while online** - app fetches signed session grant from backend (stand-in for eventual Tempo/MPP)
2. **Go offline** - user loses internet entirely
3. **Find provider** - app discovers nearby Mac via Bluetooth/Multipeer Connectivity
4. **Enter prompt** - translate, summarize, rewrite, explain
5. **Provider quotes price** - e.g. "this request costs 5 credits max"
6. **Phone authorizes spend** - signs cumulative spend update
7. **Mac runs inference** - verifies spend update and runs model
8. **Result comes back** - user sees response and updated remaining credits

---

## 4. Exact scope

### Device support

* Provider: Mac mini or MacBook, Apple Silicon only
* Client: iPhone app, foreground usage only
* No Android, no background relay

### Transport

**Multipeer Connectivity** (not custom BLE protocol). Easier discovery and messaging, much better dev velocity for v1.

### Inference

Small quantized text model only. Tasks: translate, summarize, rewrite, answer short questions. Avoid: long chats, tool use, large context, agents.

### Payments

Fake-but-structurally-correct local session model:
* session created online ahead of time
* phone stores provider-bound session credentials locally
* phone sends monotonic cumulative spend updates
* Mac verifies with known public key / signed grant
* Mac tracks latest accepted spend

---

## 5. V1 architecture

### A. Provider Mac app

Responsibilities: advertise service, request/response protocol, hold provider keypair, pricing table, session validation, spend verification, accepted spend ledger, local inference, sign receipts.

Persistent state: provider ID, provider private key, pricing config, known valid session grants, latest accepted cumulative spend per session, request log, receipt log.

### B. iPhone app

Responsibilities: discover provider, show provider status, hold session grant, hold user signing key, compose prompt, receive quote, sign spend update, display response, store receipt history.

Persistent state: session ID, provider ID, user keypair, session grant, latest signed cumulative spend, receipt history.

### C. Optional thin backend (setup only)

Only used when online: issuing session grants, registering provider IDs, topping up credits, simple admin tools. Not used during offline inference.

---

## 6. V1 payment model

### Provider-bound prepaid sessions

Each session bound to: one user, one provider, one max credit amount, one expiry time.

Example grant:
```
session_id: sess_123
user_pubkey: U
provider_id: prov_abc
max_credits: 500
expires_at: ...
backend_signature: sig(...)
```

### Spend update format

Cumulative state (not per-request coupons):
* first request: cumulative spend = 5
* second request: cumulative spend = 9
* third request: cumulative spend = 14

Each update includes: session ID, request ID, cumulative spend, sequence number, quote ID, user signature.

Mac accepts only if: signature valid, session bound to this provider, not expired, cumulative spend > last accepted, cumulative spend <= max credits.

---

## 7. Request protocol

1. **Discovery** - provider name, provider ID, model tier, availability
2. **Prompt request** - request ID, session ID, prompt text, task type, optional max output tokens
3. **Quote response** - quote ID, price in credits, expiry timestamp
4. **Spend authorization** - session ID, request ID, quote ID, cumulative spend, sequence number, signature
5. **Verification + inference** - Mac checks payment, runs model
6. **Response + receipt** - request ID, output text, credits charged, accepted cumulative spend, provider-signed receipt

---

## 8. Pricing

Three request classes:
* small: 3 credits
* medium: 5 credits
* large: 8 credits

Mapped to prompt length / max output length. No token-level pricing.

---

## 9. Model choice

Requirements: small, fast on Apple Silicon, decent for utility tasks, easy to run locally. Design around one model, one runtime, one prompt format.

---

## 10. V1 use cases (pick 2-3)

1. **Translation assistant** - "Translate this text into X."
2. **Rewrite assistant** - "Rewrite this message professionally / simply."
3. **Summarization assistant** - "Summarize this paragraph or note."

Short input, short output, obvious value, easy to demo and price.

---

## 11. Security model

### Required
* signed session grants
* signed spend updates
* provider-bound sessions
* monotonic cumulative spend
* sequence numbers
* quote expiry
* request IDs
* signed receipts

### Acceptable v1 limitations
* clunky recovery if phone loses local state
* manual disputes
* one phone per session
* no cross-device sync
* no relay tampering model

---

## 12. Suggested stack

### iPhone app
* SwiftUI
* Multipeer Connectivity
* local secure key storage (Keychain)
* simple receipt/session storage

### Mac provider app
* Swift or lightweight local service wrapper
* Multipeer Connectivity peer
* local inference runner
* SQLite or flat-file ledger

### Backend
* tiny service for session issuance
* provider registration
* test credit top-ups

---

## 13. Success criteria

A successful v1 demo:
1. User briefly goes online and gets a prepaid session
2. User turns off Wi-Fi and cellular
3. User approaches the Mac provider
4. iPhone discovers provider locally
5. User submits "translate this" or "summarize this"
6. Mac returns quote
7. Phone signs spend authorization
8. Mac verifies and returns answer
9. App shows reduced balance and receipt

---

## 14. Post-v1 roadmap (in order)

1. better session syncing
2. better receipts/recovery
3. multiple simultaneous users
4. richer pricing
5. actual MPP/Tempo-compatible session plumbing
6. delayed pickup/mailbox mode
7. relays
