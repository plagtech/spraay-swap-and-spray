// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {ISpray} from "./interfaces/ISpray.sol";
import {PayoutSpec, PayoutSpecLib} from "./libraries/PayoutSpec.sol";
import {SpraySettlement} from "./SpraySettlement.sol";

/// @notice On pools that attach it, pays a swap's output to the recipients in `hookData`
/// @dev No owner, no admin functions, no storage. Spray's fee is the only fee. Empty `hookData`
/// passes the swap through untouched.
///
/// EXACT-INPUT ONLY: a v4 `afterSwap` return delta applies to the unspecified currency, which on
/// exact-output is the input currency.
///
/// SINGLE-HOP OR FINAL-HOP ONLY: this hook cannot see a route, so this is not enforced. It takes
/// the whole output, so the swapper's output delta is 0. A later hop would have nothing to swap,
/// and a router's own minimum-output check sees 0. Use `PayoutSpec.minOutput` for slippage.
contract SwapAndSprayHook is BaseHook {
    using PayoutSpecLib for PayoutSpec;
    using PoolIdLibrary for PoolKey;

    ISpray public immutable spray;

    error ExactOutputNotSupported();
    error NoOutput();
    error UnexpectedSender(address sender);

    constructor(IPoolManager _poolManager, ISpray _spray) BaseHook(_poolManager) {
        spray = _spray;
    }

    /// @dev Native output and Spray's native refunds arrive here. Nothing else should send ETH.
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(spray)) revert UnexpectedSender(msg.sender);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (hookData.length == 0) return (IHooks.afterSwap.selector, 0);
        if (params.amountSpecified > 0) revert ExactOutputNotSupported();

        PayoutSpec memory spec = abi.decode(hookData, (PayoutSpec));
        spec.validate(address(spray));

        (Currency currencyOut, int128 deltaOut) =
            params.zeroForOne ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (deltaOut <= 0) revert NoOutput();
        uint256 output = uint256(uint128(deltaOut));

        poolManager.take(currencyOut, address(this), output);
        SpraySettlement.settle(spray, key.toId(), currencyOut, output, spec);

        // Positive means the hook took this much of the swapper's output (IHooks.afterSwap).
        return (IHooks.afterSwap.selector, deltaOut);
    }
}
