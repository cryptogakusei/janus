# Janus - End-State Design

## One-line concept

An **offline-first local AI utility network** where nearby Apple devices provide LLM inference over short-range transport, and users pay through **MPP-based machine-payment sessions** using **locally verifiable credentials** with **deferred settlement**.

---

## 1. Product shape

The system is a **local inference marketplace** for places with weak or intermittent internet:

* a **provider node** runs an OSS model on a MacBook or Mac mini
* **client nodes** are iPhones requesting inference
* **relay nodes** are nearby subscribed phones that can forward requests/responses opportunistically
* **payments** use MPP semantics and session-style spending rights
* **settlement** happens later when some party gets connectivity again

The main user promise is:

> "You can use useful AI nearby even when the internet is unreliable."

---

## 2. Core design principles

### Offline-first, not offline-forever

The serving path should work without internet at request time, but funding and reconciliation happen when connectivity exists again.

### Local utility, not personal local inference

Most users do not run the model on their own phone. A nearby stronger machine does.

### Delay-tolerant, not always-online RPC

The network should be built as **bundled messages** that can be stored, forwarded, retried, and acknowledged later.

### Provider-bound economic trust

For the first full design, payment sessions are tied to a specific provider to reduce double-spend and offline fraud risk.

---

## 3. Actors in the system

### A. Provider

A Mac mini or MacBook that:

* runs the model
* advertises service locally
* accepts requests
* meters usage
* verifies payment credentials
* returns responses and receipts
* reconciles later with the upstream payment system

### B. Client

An iPhone app that:

* discovers providers
* opens or syncs a payment session when online
* composes request bundles
* attaches payment credentials
* receives streamed or delayed responses
* stores receipts
* optionally participates as a relay

### C. Relay

A subscriber phone that:

* forwards opaque bundles
* stores them temporarily
* earns relay credits or discounted service
* never has authority to alter or redeem payment state

### D. Session/payment backend

This is the periodic online anchor that:

* creates or funds sessions
* defines the rules for valid credentials
* eventually reconciles accepted spend
* may use Tempo/Stripe-backed MPP methods when connectivity exists

---

## 4. Network architecture

Three serving modes:

### Mode 1: Direct

Client iPhone is in Bluetooth reach of provider Mac.

### Mode 2: Assisted relay

Client cannot reach provider directly, but one or more phones can forward bundles (store-and-forward, hop-limited, TTL-based).

### Mode 3: Mailbox/delayed pickup

Client drops a request into the local mesh and picks up the response later.

---

## 5. AI serving layer

### Provider hardware

* Apple Silicon MacBook or Mac mini
* quantized OSS model
* optimized inference runtime

### Best-fit tasks

* translation, drafting, summarization, tutoring
* local-language assistance, structured form help
* FAQ over preloaded content, merchant/business help

### Poor-fit tasks initially

* huge context windows, web search, heavy multimodal, image generation, always-on voice

---

## 6. Payment architecture

### Why MPP fits

MPP standardizes the control flow:

* server returns a `402 Payment Required` challenge
* client fulfills it and retries with a payment credential
* server verifies and returns the resource with a receipt
* MPP supports transports beyond plain HTTP, including MCP/JSON-RPC style transport bindings

### What MPP does not give you

MPP does not magically solve offline finality. Payment methods define their own rails, credential formats, and verification logic. The system uses MPP as the **local paywall and proof exchange protocol**, while accepting that **funding and final reconciliation may happen later**.

### Tempo session fit

Tempo is the strongest fit among the listed methods because the use case is repetitive, metered machine usage.

---

## 7. Session model

**Provider-bound cumulative-spend sessions.**

### Online preparation

* the user creates or funds a session
* the provider learns the session rules
* the client obtains the ability to generate valid payment credentials for that session

### Offline spending

For each request, the client presents the inference request + a payment credential proving an updated spend state.

### Cumulative spend model

Use cumulative state, not isolated coupons. Example: spend state 3 -> 7 -> 9.

The provider only accepts a state if it is valid, newer, supersedes the last accepted state, and is within allowed budget.

### Provider-bound sessions

A session is valid for one provider only. Session includes provider identity, credentials are only redeemable by that provider, provider stores the latest accepted state.

---

## 8. End-to-end payment flow

1. **Discovery** - Client discovers local providers
2. **Capability exchange** - Provider advertises model tier, pricing, queue depth, payment methods, provider ID
3. **Challenge** - Provider responds with MPP-style 402 challenge (amount, session requirements, nonce, expiry)
4. **Credential** - Client sends session ID, cumulative spend state, sequence number, cryptographic proof, challenge reference, request payload
5. **Verification** - Provider verifies session, credential, signature, freshness, bounds, budget
6. **Inference** - Provider executes model request
7. **Receipt** - Provider returns response, usage metering, signed receipt, accepted cumulative spend, residual balance
8. **Later reconciliation** - When online, provider submits latest accepted session state for settlement

---

## 9. Local protocol design

### Bundle types

* `ServiceAnnounce`
* `QuoteRequest`
* `PaymentChallenge`
* `InferenceRequest`
* `PaymentCredential`
* `InferenceResponse`
* `PaymentReceipt`
* `Ack`
* `SessionSync`
* `SettlementNotice`

### Required IDs in every economic message

* provider ID, client pseudonymous ID, session ID, request ID
* challenge ID, sequence number, cumulative spend amount, expiry/TTL

---

## 10. Relay model

Relays forward bundles only. They cannot generate credentials, alter amounts, redeem value, or acknowledge settlement.

Relay incentives: relay credits, discounted inference, social/cooperative participation, operator-sponsored rewards.

Architecture should not depend on always-on relaying to be useful (iPhone background execution limits, BLE constraints, battery sensitivity).

---

## 11. Trust and fraud model

### Threats

* replay of old credentials, reuse at multiple providers, forged responses
* lost receipts, relay tampering, queue griefing/spam
* provider overcharging, client repudiation

### Controls

* provider-bound sessions, cumulative spend states, monotonic sequence numbers
* request/challenge expiration, provider-signed receipts, per-session caps
* local rate limits, bounded queue reservations
* encrypted payloads end-to-end, relays only forward opaque bundles

---

## 12. Pricing model

Per request class, per response size band, per reserved session minute, per daily/weekly pass, priority surcharge. Provider advertises a price curve, client selects maximum spend, provider returns actual usage plus signed receipt.

---

## 13. UX model

### User journey

1. Install app, create account/wallet/session when connected
2. Pre-fund or authorize local spending rights
3. App scans for nearby providers
4. See provider name, model class, estimated wait, cost range
5. Submit request
6. App handles payment challenge locally
7. Response appears immediately or later
8. App stores receipt and updated remaining balance

### Provider journey

1. Install provider app on Mac
2. Select model and pricing
3. Sync session verification state when online
4. Advertise locally
5. Accept and serve requests
6. Reconcile later

---

## 14. Governance / marketplace layer

Provider metadata: reliability score, average response latency, supported languages, model quality tier, pricing reputation, uptime history.

Community deployment shapes: school node, clinic node, shopkeeper merchant node, cooperative/community node, roaming provider.

---

## 15. Future vision

The deeper design is a **local machine-services economy**. LLM inference is the first workload, but the same platform could later support: translation, OCR, speech-to-text, local search over cached corpora, education content lookup, form completion, private knowledge pack assistants.

The protocol should be **service-generic**.

---

## 16. End-state technical stack

### On Mac provider

* local service daemon, model runtime, queue manager
* payment verifier, receipt signer, settlement sync agent
* local service advertisement

### On iPhone client

* discovery + session wallet, request composer, credential generator
* receipt store, delayed delivery inbox, optional relay engine

### Shared protocol

* MPP-inspired payment state machine
* bundle transport
* cryptographic identities
* cumulative-spend session model

---

## 17. Architectural planes

* **Compute plane** - Mac provider runs OSS model locally
* **Transport plane** - direct Bluetooth first, relay/store-and-forward second, delay-tolerant message bundles
* **Payment plane** - MPP semantics for challenge/credential/receipt, Tempo-style session spending rights, provider-bound cumulative-spend states, deferred reconciliation
* **Trust plane** - signed credentials, signed receipts, sequence numbers, TTLs, replay protection, provider-specific redemption
