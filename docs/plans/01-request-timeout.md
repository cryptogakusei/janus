# Feature #1: Request Timeout Propagation

**Status:** Implemented (2026-04-07)
**Commit:** 0b6fb9c

## Context

When a provider doesn't respond to a forwarded request, the relay had no way to notify the client. The client would wait its full 20s timeout before giving up. The relay, being closer to the failure, can detect this faster and send a meaningful error.

**Goal:** Relay tracks in-flight requests and sends `relayTimeout` error to the client if the provider doesn't respond within 15s (before the client's 20s timeout).

## Design

- Added `InFlightRequest` struct tracking `clientPeer`, `providerID`, `messageType`, `forwardedAt`, `timeoutTask`
- `forwardToProvider()` peeks at inner envelope — if `promptRequest` or `voucherAuthorization`, starts a 15s timeout
- `forwardToClient()` clears the in-flight tracker when a response arrives
- On timeout: sends `ErrorResponse` with `.relayTimeout` code back to the client
- On provider disconnect: sends `providerUnreachable` for all in-flight requests targeting that provider
- On client disconnect: cancels in-flight timeouts for that client

## Files Changed

| File | Change |
|------|--------|
| `MPCRelay.swift` | Added `InFlightRequest`, tracking/timeout/cleanup methods |
| `ErrorResponse.swift` | Added `relayTimeout` error code |
| `RelayDisconnectTests.swift` | 2 new tests for relay timeout error round-trips |
| `DirectModeProtocolTests.swift` | Added `.relayTimeout` to allCodes test |
