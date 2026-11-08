// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {SwapAndSprayHook} from "../src/SwapAndSprayHook.sol";
import {ISpray} from "../src/interfaces/ISpray.sol";

/// @notice Mines a CREATE2 salt for the hook's flag bits and deploys it to Base mainnet.
/// The deployer key comes from DEPLOYER_PRIVATE_KEY.
contract DeployHook is Script {
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    ISpray internal constant SPRAY = ISpray(0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c);
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (SwapAndSprayHook hook) {
        require(block.chainid == 8453, "Base mainnet only");

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(SwapAndSprayHook).creationCode, abi.encode(POOL_MANAGER, SPRAY)
        );

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        hook = new SwapAndSprayHook{salt: salt}(POOL_MANAGER, SPRAY);
        vm.stopBroadcast();

        require(address(hook) == predicted, "Mined address mismatch");
        console2.log("SwapAndSprayHook", address(hook));
        console2.logBytes32(salt);
    }
}
