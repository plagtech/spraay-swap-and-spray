// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {SwapAndSprayRouter} from "../src/SwapAndSprayRouter.sol";
import {ISpray} from "../src/interfaces/ISpray.sol";
import {PayoutSpec} from "../src/libraries/PayoutSpec.sol";

/// @notice LOCAL ONLY. Sends real signed transactions to an Anvil fork of Base started with
/// `--chain-id 31337`, to cross-check GAS.md against transaction receipts.
contract LocalGasCheck is Script {
    IPoolManager internal constant MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    ISpray internal constant SPRAY = ISpray(0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 internal constant AMOUNT_EACH = 100_000;

    function run() external {
        require(block.chainid == 31337, "Local Anvil only");

        uint256 count = vm.envUint("RECIPIENTS");
        address[] memory recipients = new address[](count);
        uint256[] memory values = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            recipients[i] = address(uint160(uint256(keccak256(abi.encode("spraay.local", count, i)))));
            values[i] = AMOUNT_EACH;
        }

        vm.startBroadcast();
        SwapAndSprayRouter router = new SwapAndSprayRouter(MANAGER, SPRAY);
        PayoutSpec memory spec = PayoutSpec(1, msg.sender, 0, 30, recipients, values);
        SwapParams memory params = SwapParams(true, int256(router.requiredOutput(spec)), TickMath.MIN_SQRT_PRICE + 1);
        PoolKey memory key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), 3000, 60, IHooks(address(0)));
        router.swapAndSpray{value: 0.5 ether}(key, params, 0.5 ether, spec, block.timestamp + 3600);
        vm.stopBroadcast();

        console2.log("recipients", count);
    }
}
