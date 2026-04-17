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

    function test_RequestClose_SecondCallResetsGracePeriod() public {
        vm.prank(PAYER);
        channel.requestClose(channelId);

        // Fast-forward 23 hours (almost at grace end)
        vm.warp(block.timestamp + 23 hours);

        // Payer calls requestClose again — resets the clock to now
        vm.prank(PAYER);
        channel.requestClose(channelId);

        // 1h later: original 24h window would have elapsed, but only 1h since second requestClose
        vm.warp(block.timestamp + 1 hours);
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
