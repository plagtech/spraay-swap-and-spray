// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {SwapAndSprayRouter} from "../../src/SwapAndSprayRouter.sol";
import {ISpray} from "../../src/interfaces/ISpray.sol";
import {SpecHelpers} from "../utils/SpecHelpers.sol";

interface ISprayAdmin is ISpray {
    function feeRecipient() external view returns (address);
}

interface IUsdcAdmin {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
}

/// @notice Base mainnet fork setup. Tests skip themselves when not forking Base.
abstract contract ForkBase is Test, SpecHelpers {
    IPoolManager internal constant MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    ISprayAdmin internal constant SPRAY = ISprayAdmin(0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Base's per-transaction gas maximum, and the 70% ceiling set for MAX_RECIPIENTS
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    uint256 internal constant GAS_CEILING = (TX_GAS_CAP * 70) / 100;

    SwapAndSprayRouter internal router;
    PoolKey internal ethUsdc;
    address internal feeRecipient;
    address internal payer = makeAddr("payer");

    modifier onlyBase() {
        if (block.chainid != 8453) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public virtual {
        if (block.chainid != 8453) return;
        router = new SwapAndSprayRouter(MANAGER, SPRAY);
        // The deepest ETH/USDC v4 pool on Base by active liquidity, with no hook.
        ethUsdc = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), 3000, 60, IHooks(address(0)));
        feeRecipient = SPRAY.feeRecipient();
    }

    function _usdc(address account) internal view returns (uint256) {
        return IERC20(USDC).balanceOf(account);
    }

    function _exactOutEthToUsdc(uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(true, int256(amount), TickMath.MIN_SQRT_PRICE + 1);
    }

    function _exactInEthToUsdc(uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1);
    }

    /// @dev What a transaction pays before execution: base cost plus calldata
    function _intrinsicGas(bytes memory data) internal pure returns (uint256 gasCost) {
        gasCost = 21_000;
        for (uint256 i; i < data.length; ++i) {
            gasCost += data[i] == 0 ? 4 : 16;
        }
    }

    receive() external payable {}
}
