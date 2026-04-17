# Feature #16: Extend Close Grace Period to 24 Hours

## Problem

`TempoStreamChannel.sol` currently has `CLOSE_GRACE_PERIOD = 15 minutes` (line 16). This is the window the provider has to call `settle()` with the latest voucher before a client can drain the escrow via `requestClose` + `withdraw`.

**The attack:**
1. Client uses inference, accumulating signed vouchers held by the provider (not yet settled on-chain)
2. Provider goes offline (sleep, power loss, network loss)
3. Client calls `requestClose(channelId)` — no provider signature needed
4. 15 minutes pass — provider still offline
5. Client calls `withdraw(channelId)` — entire unsettled deposit returned to client
6. Channel is `finalized = true`
7. Provider comes back online, tries to `settle()` — reverts with `ChannelFinalized`
8. Provider served inference and gets paid nothing

**Why the pre-serve check doesn't help:** An offline provider can't call `getChannel()` to detect the pending close — the RPC call fails. The provider has no way to know the attack is happening.

**Why 15 minutes is too short:** Janus is designed for offline-first use on local hardware (Macs, iPhones). These devices sleep, lose power, or lose connectivity routinely. A 15-minute window makes the attack trivially easy against any provider that steps away from their device.

## Solution

Increase `CLOSE_GRACE_PERIOD` from `15 minutes` to `24 hours` in `TempoStreamChannel.sol`. This aligns the attack window with "provider was unreachable for more than a full day" — a much higher bar that covers normal offline usage patterns.

The contract's challenge-response design is already correct:
- `settle()` cancels any pending close request (lines 84-87)
- The provider just needs to be online within the grace period

## Changes Required

### `contracts/src/TempoStreamChannel.sol`

Line 16 — change:
```solidity
uint64 public constant CLOSE_GRACE_PERIOD = 15 minutes;
```
to:
```solidity
uint64 public constant CLOSE_GRACE_PERIOD = 24 hours;
```

### Contract Redeployment

Since `CLOSE_GRACE_PERIOD` is a `constant` (compiled into the bytecode, not a storage variable), changing it requires redeploying the contract. Steps:
1. Update the constant
2. Run tests: `forge test`
3. Deploy to testnet: `forge script` deploy script
4. Update `TempoConfig.testnet.escrowContract` in Swift with new address
5. All clients and providers need to reopen channels against the new contract (existing channels on the old contract are unaffected)

## Trade-off

The client's deposit is locked for up to 24 hours after calling `requestClose` before they can withdraw. This is the legitimate cost of the protection — the client must wait a day to reclaim funds from a channel they want to close. For the Janus use case (long-running inference relationships between known devices), this is an acceptable trade-off.

## Future Work (not in scope for this feature)

- **Watchtower**: A third-party service holding the latest voucher that calls `settle()` on the provider's behalf when a `CloseRequested` event is detected — the proper long-term solution for providers that may be offline for days.
- **Close-request poller**: Background task in `ProviderEngine` that periodically checks `closeRequestedAt` on all active channels when online, and auto-settles + blacklists the client if a close is detected.
- **UI exposure**: Add `requestClose`/`withdraw` to `EthTransaction.swift` and surface cooperative close in the client UI, so the legitimate close path doesn't require external tooling.

## Review Notes

Identified during offline inference scenario review (2026-04-17). Both systems-architect and architecture-reviewer independently flagged this as P1. The contract design is sound — the fix is purely a parameter change + redeployment.
