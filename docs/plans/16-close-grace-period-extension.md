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

## Trade-off

The client's deposit is locked for up to 24 hours after calling `requestClose` before they can withdraw. This is the legitimate cost of the protection — the client must wait a day to reclaim funds from a channel they want to close. For the Janus use case (long-running inference relationships between known devices), this is an acceptable trade-off.

---

## Implementation Plan

### Step 1: Contract Change

**File:** `contracts/src/TempoStreamChannel.sol`, line 16

```solidity
// Before:
uint64 public constant CLOSE_GRACE_PERIOD = 15 minutes;

// After:
uint64 public constant CLOSE_GRACE_PERIOD = 24 hours;
```

This is the only change to the contract source. `CLOSE_GRACE_PERIOD` is used in exactly two places:
- `requestClose()` line 152: `uint256 graceEnd = block.timestamp + CLOSE_GRACE_PERIOD;`
- `withdraw()` line 161: `block.timestamp < ch.closeRequestedAt + CLOSE_GRACE_PERIOD`

The interface at `contracts/lib/tempo-std/src/interfaces/ITempoStreamChannel.sol` only declares the function signature — no value is baked in. No interface change needed.

**Note:** `ProviderStatusView.swift` has a settlement interval picker with `Text("15 min").tag(900)` — this is the provider's on-chain settlement cadence, an entirely separate concept from the close grace period. No change needed there.

---

### Step 2: New Test File

**File:** `contracts/test/TempoStreamChannel.t.sol` (NEW)

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ITIP20} from "tempo-std/interfaces/ITIP20.sol";
import {ITIP20RolesAuth} from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import {StdPrecompiles} from "tempo-std/StdPrecompiles.sol";
import {StdTokens} from "tempo-std/StdTokens.sol";
import {TempoStreamChannel} from "../src/TempoStreamChannel.sol";
import {ITempoStreamChannel} from "tempo-std/interfaces/ITempoStreamChannel.sol";

contract TempoStreamChannelTest is Test {
    TempoStreamChannel public channel;
    ITIP20 public token;

    address public constant PAYER = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    address public constant PAYEE = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);

    // Foundry default test key 0 — corresponds to PAYER address above
    uint256 public constant PAYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    uint128 public constant DEPOSIT = 1000 * 1e6;

    bytes32 public channelId;

    function setUp() public {
        address feeToken = vm.envOr("TEMPO_FEE_TOKEN", StdTokens.ALPHA_USD_ADDRESS);
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(feeToken);

        token = ITIP20(
            StdPrecompiles.TIP20_FACTORY
                .createToken("testUSD", "tUSD", "USD", StdTokens.PATH_USD, address(this), bytes32(0))
        );
        ITIP20RolesAuth(address(token)).grantRole(token.ISSUER_ROLE(), address(this));
        token.mint(PAYER, DEPOSIT);

        channel = new TempoStreamChannel();

        vm.startPrank(PAYER);
        token.approve(address(channel), DEPOSIT);
        channelId = channel.open(PAYEE, address(token), DEPOSIT, bytes32("salt1"), PAYER);
        vm.stopPrank();
    }

    // ─── Constant value ───────────────────────────────────────────────────────

    function test_GracePeriodIs24Hours() public view {
        assertEq(channel.CLOSE_GRACE_PERIOD(), 24 hours);
    }

    // ─── requestClose + withdraw timing ──────────────────────────────────────

    function test_Withdraw_RevertsBeforeGracePeriod() public {
        vm.prank(PAYER);
        channel.requestClose(channelId);

        // 1 second before grace ends — must revert
        vm.warp(block.timestamp + 24 hours - 1);
        vm.prank(PAYER);
        vm.expectRevert(ITempoStreamChannel.CloseNotReady.selector);
        channel.withdraw(channelId);
    }

    function test_Withdraw_SucceedsAfterGracePeriod() public {
        vm.prank(PAYER);
        channel.requestClose(channelId);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(PAYER);
        channel.withdraw(channelId);  // must not revert

        assertEq(token.balanceOf(PAYER), DEPOSIT);  // full refund (nothing settled)
    }

    // ─── Double requestClose resets the clock ────────────────────────────────
    //
    // A second requestClose overwrites closeRequestedAt with the new block.timestamp.
    // A client who called requestClose 23h ago and calls it again must wait another 24h.
    // This is a natural consequence of the storage overwrite — tested here to document it.

    function test_RequestClose_SecondCallResetsGracePeriod() public {
        vm.prank(PAYER);
        channel.requestClose(channelId);

        // Fast-forward 23 hours (almost at grace end)
        vm.warp(block.timestamp + 23 hours);

        // Payer calls requestClose again — resets the clock to now
        vm.prank(PAYER);
        channel.requestClose(channelId);

        // 1 second after original 24h would have elapsed — must still revert
        vm.warp(block.timestamp + 1 hours);  // only 1h since second requestClose
        vm.prank(PAYER);
        vm.expectRevert(ITempoStreamChannel.CloseNotReady.selector);
        channel.withdraw(channelId);

        // Full 24h after second requestClose — must succeed
        vm.warp(block.timestamp + 23 hours);
        vm.prank(PAYER);
        channel.withdraw(channelId);
        assertEq(token.balanceOf(PAYER), DEPOSIT);
    }

    // ─── settle cancels pending close ────────────────────────────────────────

    function test_Settle_CancelsPendingClose() public {
        vm.prank(PAYER);
        channel.requestClose(channelId);

        // Provider settles before grace ends — cancels the close
        uint128 amount = 100 * 1e6;
        bytes32 digest = channel.getVoucherDigest(channelId, amount);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(PAYEE);
        channel.settle(channelId, amount, sig);

        // Warp past grace period — withdraw must revert (closeRequestedAt reset to 0)
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(PAYER);
        vm.expectRevert(ITempoStreamChannel.CloseNotReady.selector);
        channel.withdraw(channelId);
    }

    // ─── Partial settlement + withdraw ───────────────────────────────────────

    function test_Withdraw_AfterPartialSettle_RefundsRemainder() public {
        uint128 settled = 400 * 1e6;
        bytes32 digest = channel.getVoucherDigest(channelId, settled);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(PAYEE);
        channel.settle(channelId, settled, sig);

        vm.prank(PAYER);
        channel.requestClose(channelId);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(PAYER);
        channel.withdraw(channelId);

        assertEq(token.balanceOf(PAYER), DEPOSIT - settled);
        assertEq(token.balanceOf(PAYEE), settled);
    }
}
```

---

### Step 3: Deploy Script

**File:** `contracts/script/TempoStreamChannel.s.sol` (NEW)

Note: Tempo chain requires fee token setup before broadcasting. Mirrors the `Mail.s.sol` pattern.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {StdPrecompiles} from "tempo-std/StdPrecompiles.sol";
import {StdTokens} from "tempo-std/StdTokens.sol";
import {TempoStreamChannel} from "../src/TempoStreamChannel.sol";

contract TempoStreamChannelScript is Script {
    function setUp() public {}

    function run() public {
        address feeToken = vm.envOr("TEMPO_FEE_TOKEN", StdTokens.ALPHA_USD_ADDRESS);
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(feeToken);

        vm.startBroadcast();

        TempoStreamChannel ch = new TempoStreamChannel();
        console.log("TempoStreamChannel deployed at:", address(ch));
        console.log("CLOSE_GRACE_PERIOD (seconds):", uint256(ch.CLOSE_GRACE_PERIOD()));

        vm.stopBroadcast();
    }
}
```

---

### Step 4: Run Tests

```bash
cd /Users/soubhik/Projects/janus/contracts
forge test --match-contract TempoStreamChannelTest -vv
```

All 5 tests must pass before deploying.

---

### Step 5: Deploy to Testnet

```bash
cd /Users/soubhik/Projects/janus/contracts
forge script script/TempoStreamChannel.s.sol \
    --rpc-url https://rpc.moderato.tempo.xyz \
    --broadcast \
    --private-key $PRIVATE_KEY
```

Note the deployed address printed by `console.log`.

---

### Step 6: Update Swift

**6a. `Sources/JanusShared/Tempo/TempoConfig.swift`** — lines 73 (comment) + 77 (address):

```swift
/// - Escrow: TempoStreamChannel deployed at <NEW_DEPLOYED_ADDRESS>
static let testnet = TempoConfig(
    escrowContract: try! EthAddress(hex: "<NEW_DEPLOYED_ADDRESS>"),
    paymentToken: try! EthAddress(hex: "0x20C0000000000000000000000000000000000000"),
    chainId: 42431,
    rpcURL: URL(string: "https://rpc.moderato.tempo.xyz")
)
```

**6b. `Tests/JanusSharedTests/OnChainTests.swift`** — line 167 asserts the escrow address directly. This **will break CI** if not updated:

```swift
// Before:
XCTAssertEqual(config.escrowContract.checksumAddress, "0xaB7409f3ea73952FC8C762ce7F01F245314920d9")

// After (substitute actual deployed address):
XCTAssertEqual(config.escrowContract.checksumAddress, "<NEW_DEPLOYED_ADDRESS>")
```

Lines 462, 477, 588 in `OnChainTests.swift` also hardcode the old address but in isolated ABI-encoding unit tests that don't go through `TempoConfig` — they will not break, but should be updated for consistency.

---

### Step 7: Rebuild + Redeploy Apps

```bash
# Rebuild JanusProvider (macOS)
cd /Users/soubhik/Projects/janus/JanusApp
xcodebuild -project JanusApp.xcodeproj -scheme JanusProvider -destination 'platform=macOS' build

# Rebuild JanusClient (iOS)
xcodebuild -project JanusApp.xcodeproj -scheme JanusClient \
    -destination 'generic/platform=iOS' build -allowProvisioningUpdates
```

**Upgrade ordering:** Provider and client must both be upgraded before either opens a new channel. If the client upgrades first and opens a channel on the new contract, an old provider will try to settle against the old contract address and get `ChannelNotFound`. Coordinate upgrades on both devices simultaneously.

**Existing channels:** Channels opened against the old contract (`0xaB7409f3ea73952FC8C762ce7F01F245314920d9`) keep their 15-minute grace period and are unaffected. The app's `SessionManager` detects the escrow address change and resets `channelOpenedOnChain = false`, automatically prompting a new channel open on the upgraded contract.

---

## Files Changed

| File | Change |
|------|--------|
| `contracts/src/TempoStreamChannel.sol` | Line 16: `15 minutes` → `24 hours` |
| `contracts/test/TempoStreamChannel.t.sol` | NEW — 5 tests |
| `contracts/script/TempoStreamChannel.s.sol` | NEW — deploy script |
| `Sources/JanusShared/Tempo/TempoConfig.swift` | Lines 73 + 77: new escrow contract address |
| `Tests/JanusSharedTests/OnChainTests.swift` | Line 167: update escrow address assertion |

---

## Future Work (not in scope for this feature)

- **Watchtower**: A third-party service holding the latest voucher that calls `settle()` on the provider's behalf when a `CloseRequested` event is detected — the proper long-term solution for providers that may be offline for days.
- **Close-request poller**: Background task in `ProviderEngine` that periodically checks `closeRequestedAt` on all active channels when online, and auto-settles + blacklists the client if a close is detected.
- **UI exposure**: Add `requestClose`/`withdraw` to `EthTransaction.swift` and surface cooperative close in the client UI, so the legitimate close path doesn't require external tooling.

## Review Notes

Identified during offline inference scenario review (2026-04-17). Both systems-architect and architecture-reviewer independently flagged this as P1. The contract design is sound — the fix is purely a parameter change + redeployment.

**Reviewed 2026-04-17** by systems-architect and architecture-reviewer. Both confirmed correctness. Blocking issues found and corrected in this plan:
- Deploy script: added `StdPrecompiles`/`StdTokens` imports + fee token setup (required for Tempo chain)
- Tests: pragma aligned to `>=0.8.20 <0.9.0`; added `test_RequestClose_SecondCallResetsGracePeriod`
- Swift: added `OnChainTests.swift` line 167 to update list; added upgrade ordering note
