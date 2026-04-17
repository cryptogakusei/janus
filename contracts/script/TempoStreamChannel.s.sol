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
