// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {SwapAndSprayHook} from "../../src/SwapAndSprayHook.sol";
import {PayoutSpec, PayoutSpecLib} from "../../src/libraries/PayoutSpec.sol";
import {ForkBase} from "./ForkBase.sol";

/// @notice The hook on a fork of Base: real Spray and USDC, a new hooked pool at the live ETH price.
/// Run the gas tests with --isolate. See GAS.md.
contract HookForkTest is ForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    uint256 internal constant SWAP_IN = 0.05 ether;

    SwapAndSprayHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolKey internal hooked;

    function setUp() public override {
        super.setUp();
        if (block.chainid != 8453) return;

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SwapAndSprayHook).creationCode, abi.encode(MANAGER, SPRAY));
        hook = new SwapAndSprayHook{salt: salt}(MANAGER, SPRAY);
        swapRouter = new PoolSwapTest(MANAGER);
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(MANAGER);

        hooked = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), 3000, 60, IHooks(address(hook)));
        PoolId liveId = ethUsdc.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = StateLibrary.getSlot0(MANAGER, liveId);
        MANAGER.initialize(hooked, sqrtPriceX96);

        int24 lower = ((tick - 3000) / 60) * 60;
        int24 upper = ((tick + 3000) / 60) * 60;
        vm.deal(address(this), 100 ether);
        deal(USDC, address(this), 1_000_000e6);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 50 ether}(
            hooked, ModifyLiquidityParams(lower, upper, 5e15, bytes32(0)), ""
        );
    }

    function _swapHooked(PayoutSpec memory spec) internal {
        swapRouter.swap{value: SWAP_IN}(
            hooked, _exactInEthToUsdc(SWAP_IN), PoolSwapTest.TestSettings(false, false), abi.encode(spec)
        );
    }

    function test_Fork_Hook_ThreeRecipients_RealSprayAndUsdc() public onlyBase {
        address[] memory recipients = _freshRecipients(3, 11);
        uint256 feeBefore = _usdc(feeRecipient);

        _swapHooked(_shares(payer, recipients));

        uint256 paid = _usdc(recipients[0]) + _usdc(recipients[1]) + _usdc(recipients[2]);
        uint256 fee = _usdc(feeRecipient) - feeBefore;
        assertGt(paid, 0, "recipients paid");
        assertEq(fee, _fee(paid), "real 30 bps fee");
        assertLe(_usdc(payer), 1, "at most 1 unreachable wei");
        assertEq(_usdc(address(hook)), 0, "hook empty");
    }

    function test_Fork_Hook_Amounts_RemainderToPayer() public onlyBase {
        address[] memory recipients = _freshRecipients(3, 12);
        _swapHooked(_amounts(payer, recipients, _filled(3, 1_000_000)));

        assertEq(_usdc(recipients[2]), 1_000_000);
        assertGt(_usdc(payer), 0, "remainder forwarded");
        assertEq(_usdc(address(hook)), 0, "hook empty");
    }

    function test_Fork_RouterOnHookedPool_ExactOutput() public onlyBase {
        address[] memory recipients = _freshRecipients(3, 13);
        PayoutSpec memory spec = _amounts(payer, recipients, _filled(3, 1_000_000));
        uint256 required = router.requiredOutput(spec);

        router.swapAndSpray{value: 0.05 ether}(hooked, _exactOutEthToUsdc(required), 0.05 ether, spec, block.timestamp);

        assertEq(_usdc(recipients[0]), 1_000_000, "paid exactly once");
        assertEq(_usdc(address(hook)), 0, "hook not involved");
    }

    // ---- gas ----

    function _measure(uint256 count) internal {
        address[] memory recipients = _freshRecipients(count, 8000 + count);
        PayoutSpec memory spec = _shares(payer, recipients);
        SwapParams memory params = _exactInEthToUsdc(SWAP_IN);
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        swapRouter.swap{value: SWAP_IN}(hooked, params, settings, abi.encode(spec));
        uint256 frame = vm.lastFrameGas().gasTotalUsed;

        bytes memory data = abi.encodeCall(PoolSwapTest.swap, (hooked, params, settings, abi.encode(spec)));
        console2.log("hook recipients", count);
        console2.log("  frame gas", frame);
        console2.log("  intrinsic gas", _intrinsicGas(data));
        console2.log("  calldata bytes", data.length);
        assertGt(_usdc(recipients[count - 1]), 0);
    }

    function test_Gas_Hook_010() public onlyBase {
        _measure(10);
    }

    function test_Gas_Hook_050() public onlyBase {
        _measure(50);
    }

    function test_Gas_Hook_100() public onlyBase {
        _measure(100);
    }

    function test_Gas_Hook_150() public onlyBase {
        _measure(150);
    }

    function test_Gas_Hook_200() public onlyBase {
        _measure(200);
    }

    // ---- MAX_RECIPIENTS must fit under the 70% ceiling, as a real transaction gas limit ----

    function test_Fork_MaxRecipients_FitUnderCeiling_Router() public onlyBase {
        uint256 count = PayoutSpecLib.MAX_RECIPIENTS;
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(count, 9001), _filled(count, 100_000));
        uint256 required = router.requiredOutput(spec);
        SwapParams memory params = _exactOutEthToUsdc(required);
        bytes memory data = abi.encodeCall(router.swapAndSpray, (ethUsdc, params, 0.5 ether, spec, block.timestamp));

        router.swapAndSpray{value: 0.5 ether, gas: GAS_CEILING - _intrinsicGas(data)}(
            ethUsdc, params, 0.5 ether, spec, block.timestamp
        );

        assertEq(_usdc(spec.recipients[count - 1]), 100_000, "last recipient paid");
    }

    function test_Fork_MaxRecipients_FitUnderCeiling_Hook() public onlyBase {
        uint256 count = PayoutSpecLib.MAX_RECIPIENTS;
        PayoutSpec memory spec = _shares(payer, _freshRecipients(count, 9002));
        SwapParams memory params = _exactInEthToUsdc(SWAP_IN);
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);
        bytes memory data = abi.encodeCall(PoolSwapTest.swap, (hooked, params, settings, abi.encode(spec)));

        swapRouter.swap{value: SWAP_IN, gas: GAS_CEILING - _intrinsicGas(data)}(
            hooked, params, settings, abi.encode(spec)
        );

        assertGt(_usdc(spec.recipients[count - 1]), 0, "last recipient paid");
    }
}
