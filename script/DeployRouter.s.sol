// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {SwapAndSprayRouter} from "../src/SwapAndSprayRouter.sol";
import {ISpray} from "../src/interfaces/ISpray.sol";

/// @notice Deploys the router to Base mainnet. The deployer key comes from DEPLOYER_PRIVATE_KEY.
contract DeployRouter is Script {
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    ISpray internal constant SPRAY = ISpray(0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c);

    function run() external returns (SwapAndSprayRouter router) {
        require(block.chainid == 8453, "Base mainnet only");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        router = new SwapAndSprayRouter(POOL_MANAGER, SPRAY);
        vm.stopBroadcast();

        console2.log("SwapAndSprayRouter", address(router));
    }
}
