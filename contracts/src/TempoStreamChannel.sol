// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {ECDSA} from "solady/utils/ECDSA.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ITIP20} from "tempo-std/interfaces/ITIP20.sol";
import {ITempoStreamChannel} from "tempo-std/interfaces/ITempoStreamChannel.sol";
import {TempoUtilities} from "./TempoUtilities.sol";

/// @title TempoStreamChannel
/// @notice Unidirectional payment channel for streaming payments using EIP-712 signed vouchers.
/// @dev Reference implementation from Tempo TIPs.
///      Spec: https://paymentauth.tempo.xyz/draft-tempo-stream-00
contract TempoStreamChannel is ITempoStreamChannel, EIP712 {
    /// @notice The grace period (in seconds) after a close is requested before the payer can withdraw.
    uint64 public constant CLOSE_GRACE_PERIOD = 24 hours;

    /// @notice The EIP-712 typehash for the Voucher struct.
    bytes32 public constant VOUCHER_TYPEHASH = keccak256("Voucher(bytes32 channelId,uint128 cumulativeAmount)");

    /// @notice Mapping from channelId to Channel data.
    mapping(bytes32 => Channel) private _channels;

    // ─── EIP-712 domain ───────────────────────────────────────────────

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Tempo Stream Channel";
        version = "1";
    }

    /// @notice Returns the EIP-712 domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ─── Channel lifecycle ────────────────────────────────────────────

    /// @inheritdoc ITempoStreamChannel
    function open(address payee, address token, uint128 deposit, bytes32 salt, address authorizedSigner)
        external
        returns (bytes32 channelId)
    {
        if (payee == address(0) || payee == msg.sender) revert InvalidPayee();
        if (!TempoUtilities.isTIP20(token)) revert InvalidToken();
        if (deposit == 0) revert ZeroDeposit();

        channelId = _computeChannelId(msg.sender, payee, token, salt, authorizedSigner);

        if (_channels[channelId].payer != address(0)) revert ChannelAlreadyExists();

        _channels[channelId] = Channel({
            finalized: false,
            closeRequestedAt: 0,
            payer: msg.sender,
            payee: payee,
            token: token,
            authorizedSigner: authorizedSigner,
            deposit: deposit,
            settled: 0
        });

        // Transfer deposit from payer into this contract.
        bool ok = ITIP20(token).transferFrom(msg.sender, address(this), deposit);
        if (!ok) revert TransferFailed();

        emit ChannelOpened(channelId, msg.sender, payee, token, authorizedSigner, salt, deposit);
    }

    /// @inheritdoc ITempoStreamChannel
    function settle(bytes32 channelId, uint128 cumulativeAmount, bytes calldata signature) external {
        Channel storage ch = _mustExist(channelId);
        if (ch.finalized) revert ChannelFinalized();
        if (msg.sender != ch.payee) revert NotPayee();

        _verifyVoucher(channelId, cumulativeAmount, signature, ch.authorizedSigner);

        if (cumulativeAmount <= ch.settled) revert AmountNotIncreasing();
        if (cumulativeAmount > ch.deposit) revert AmountExceedsDeposit();

        uint128 delta = cumulativeAmount - ch.settled;
        ch.settled = cumulativeAmount;

        // Cancel any pending close request on successful settlement.
        if (ch.closeRequestedAt != 0) {
            ch.closeRequestedAt = 0;
            emit CloseRequestCancelled(channelId, ch.payer, ch.payee);
        }

        // Transfer delta to payee.
        bool ok = ITIP20(ch.token).transfer(ch.payee, delta);
        if (!ok) revert TransferFailed();

        emit Settled(channelId, ch.payer, ch.payee, cumulativeAmount, delta, ch.settled);
    }

    /// @inheritdoc ITempoStreamChannel
    function topUp(bytes32 channelId, uint256 additionalDeposit) external {
        Channel storage ch = _mustExist(channelId);
        if (ch.finalized) revert ChannelFinalized();
        if (msg.sender != ch.payer) revert NotPayer();

        uint256 newDeposit = uint256(ch.deposit) + additionalDeposit;
        if (newDeposit > type(uint128).max) revert DepositOverflow();
        ch.deposit = uint128(newDeposit);

        bool ok = ITIP20(ch.token).transferFrom(msg.sender, address(this), additionalDeposit);
        if (!ok) revert TransferFailed();

        emit TopUp(channelId, ch.payer, ch.payee, additionalDeposit, newDeposit);
    }

    /// @inheritdoc ITempoStreamChannel
    function close(bytes32 channelId, uint128 cumulativeAmount, bytes calldata signature) external {
        Channel storage ch = _mustExist(channelId);
        if (ch.finalized) revert ChannelFinalized();
        if (msg.sender != ch.payer) revert NotPayer();

        _verifyVoucher(channelId, cumulativeAmount, signature, ch.payee);

        if (cumulativeAmount < ch.settled) revert AmountNotIncreasing();
        if (cumulativeAmount > ch.deposit) revert AmountExceedsDeposit();

        ch.finalized = true;

        uint128 delta = cumulativeAmount - ch.settled;
        ch.settled = cumulativeAmount;

        uint256 refund = uint256(ch.deposit) - uint256(cumulativeAmount);

        // Pay remaining to payee.
        if (delta > 0) {
            bool ok = ITIP20(ch.token).transfer(ch.payee, delta);
            if (!ok) revert TransferFailed();
        }
        // Refund remainder to payer.
        if (refund > 0) {
            bool ok = ITIP20(ch.token).transfer(ch.payer, refund);
            if (!ok) revert TransferFailed();
        }

        emit ChannelClosed(channelId, ch.payer, ch.payee, cumulativeAmount, refund);
    }

    /// @inheritdoc ITempoStreamChannel
    function requestClose(bytes32 channelId) external {
        Channel storage ch = _mustExist(channelId);
        if (ch.finalized) revert ChannelFinalized();
        if (msg.sender != ch.payer) revert NotPayer();

        ch.closeRequestedAt = uint64(block.timestamp);

        uint256 graceEnd = block.timestamp + CLOSE_GRACE_PERIOD;
        emit CloseRequested(channelId, ch.payer, ch.payee, graceEnd);
    }

    /// @inheritdoc ITempoStreamChannel
    function withdraw(bytes32 channelId) external {
        Channel storage ch = _mustExist(channelId);
        if (ch.finalized) revert ChannelFinalized();
        if (msg.sender != ch.payer) revert NotPayer();
        if (ch.closeRequestedAt == 0 || block.timestamp < ch.closeRequestedAt + CLOSE_GRACE_PERIOD) {
            revert CloseNotReady();
        }

        ch.finalized = true;

        uint256 settled = ch.settled;
        uint256 refund = uint256(ch.deposit) - settled;

        if (refund > 0) {
            bool ok = ITIP20(ch.token).transfer(ch.payer, refund);
            if (!ok) revert TransferFailed();
        }

        emit ChannelExpired(channelId, ch.payer, ch.payee);
    }

    // ─── View helpers ─────────────────────────────────────────────────

    /// @inheritdoc ITempoStreamChannel
    function getChannel(bytes32 channelId) external view returns (Channel memory) {
        return _channels[channelId];
    }

    /// @inheritdoc ITempoStreamChannel
    function getChannelsBatch(bytes32[] calldata channelIds) external view returns (Channel[] memory result) {
        result = new Channel[](channelIds.length);
        for (uint256 i; i < channelIds.length; ++i) {
            result[i] = _channels[channelIds[i]];
        }
    }

    /// @inheritdoc ITempoStreamChannel
    function computeChannelId(address payer, address payee, address token, bytes32 salt, address authorizedSigner)
        external
        view
        returns (bytes32)
    {
        return _computeChannelId(payer, payee, token, salt, authorizedSigner);
    }

    /// @inheritdoc ITempoStreamChannel
    function getVoucherDigest(bytes32 channelId, uint128 cumulativeAmount) external view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(VOUCHER_TYPEHASH, channelId, cumulativeAmount)));
    }

    // ─── Internals ────────────────────────────────────────────────────

    function _computeChannelId(address payer, address payee, address token, bytes32 salt, address authorizedSigner)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(payer, payee, token, salt, authorizedSigner, address(this), block.chainid));
    }

    function _verifyVoucher(bytes32 channelId, uint128 cumulativeAmount, bytes calldata signature, address expectedSigner)
        internal
        view
    {
        bytes32 digest = _hashTypedData(keccak256(abi.encode(VOUCHER_TYPEHASH, channelId, cumulativeAmount)));
        address signer = ECDSA.recover(digest, signature);
        if (signer != expectedSigner) revert InvalidSignature();
    }

    function _mustExist(bytes32 channelId) internal view returns (Channel storage ch) {
        ch = _channels[channelId];
        if (ch.payer == address(0)) revert ChannelNotFound();
    }
}
