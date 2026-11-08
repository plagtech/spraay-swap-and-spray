// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BaseTestHooks} from "v4-core/src/test/BaseTestHooks.sol";

import {SwapAndSprayRouter} from "../../src/SwapAndSprayRouter.sol";
import {PayoutSpec} from "../../src/libraries/PayoutSpec.sol";

/// @notice Refuses native currency
contract RevertingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// @notice ERC-20 that reverts on transfers to blocked accounts, as USDC does
contract BlocklistToken is MockERC20("Blocklist", "BLK", 18) {
    mapping(address => bool) public blocked;

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transfer(to, amount);
    }
}

/// @notice A hook unrelated to Spray that lets swaps through unchanged
contract PassThroughHook is BaseTestHooks {
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }
}

/// @notice Re-enters the router when it receives its unused native input
contract ReentrantCaller {
    SwapAndSprayRouter internal immutable router;
    PoolKey internal key;
    SwapParams internal params;
    PayoutSpec internal spec;
    uint256 internal amountLimit;

    bool public attempted;
    bytes public revertData;

    constructor(SwapAndSprayRouter _router) {
        router = _router;
    }

    function attack(PoolKey memory _key, SwapParams memory _params, uint256 _amountLimit, PayoutSpec memory _spec)
        external
        payable
    {
        key = _key;
        params = _params;
        amountLimit = _amountLimit;
        spec = _spec;
        router.swapAndSpray{value: msg.value}(_key, _params, _amountLimit, _spec, block.timestamp);
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;
        try router.swapAndSpray(key, params, amountLimit, spec, block.timestamp) {}
        catch (bytes memory data) {
            revertData = data;
        }
    }
}
