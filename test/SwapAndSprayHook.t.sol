// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {SwapAndSprayHook} from "../src/SwapAndSprayHook.sol";
import {SwapAndSprayRouter} from "../src/SwapAndSprayRouter.sol";
import {SpraySettlement} from "../src/SpraySettlement.sol";
import {ISpray} from "../src/interfaces/ISpray.sol";
import {PayoutSpec, PayoutSpecLib} from "../src/libraries/PayoutSpec.sol";
import {SprayContract} from "./mocks/SprayContractV2.sol";
import {RevertingReceiver} from "./mocks/Mocks.sol";
import {SpecHelpers} from "./utils/SpecHelpers.sol";

contract SwapAndSprayHookTest is Test, Deployers, SpecHelpers {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    SprayContract internal spray;
    SwapAndSprayHook internal hook;
    PoolKey internal hooked;
    PoolKey internal hookedNative;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal payer = makeAddr("payer");

    PoolSwapTest.TestSettings internal settings = PoolSwapTest.TestSettings(false, false);

    function setUp() public {
        initializeManagerRoutersAndPoolsWithLiq(IHooks(address(0)));
        spray = new SprayContract(feeRecipient, SPRAY_FEE_BPS);

        bytes memory args = abi.encode(manager, ISpray(address(spray)));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(SwapAndSprayHook).creationCode, args);
        hook = new SwapAndSprayHook{salt: salt}(manager, ISpray(address(spray)));
        assertEq(address(hook), predicted);

        (hooked,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        (hookedNative,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1, 1 ether
        );
    }

    function _exactIn(bool zeroForOne, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, -int256(amount), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    function _swap(PoolKey memory poolKey, SwapParams memory params, bytes memory hookData) internal {
        swapRouter.swap(poolKey, params, settings, hookData);
    }

    /// @dev The output this swap produces, measured on the same pool with the hook passing through
    function _outputOf(PoolKey memory poolKey, SwapParams memory params) internal returns (uint256 output) {
        uint256 snapshot = vm.snapshotState();
        Currency currencyOut = params.zeroForOne ? poolKey.currency1 : poolKey.currency0;
        uint256 before = currencyOut.balanceOf(address(this));
        swapRouter.swap(poolKey, params, settings, ZERO_BYTES);
        output = currencyOut.balanceOf(address(this)) - before;
        vm.revertToState(snapshot);
    }

    function _expectHookRevert(bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _assertHookEmpty(Currency currency) internal view {
        assertEq(currency.balanceOf(address(hook)), 0, "hook holds output");
        assertEq(address(hook).balance, 0, "hook holds native");
    }

    // ---- permissions and mining ----

    function test_AddressFlagsMatchPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterSwap);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.beforeSwap || p.beforeSwapReturnDelta || p.beforeInitialize || p.afterInitialize);
        assertFalse(p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x44, "only the two flag bits");
    }

    // ---- SHARES ----

    function _assertShares(uint256 count) internal {
        address[] memory recipients = _freshRecipients(count, 200 + count);
        PayoutSpec memory spec = _shares(payer, recipients);
        SwapParams memory params = _exactIn(true, 1e15);
        uint256 output = _outputOf(hooked, params);
        uint256 swapperBefore = currency1.balanceOf(address(this));

        _swap(hooked, params, abi.encode(spec));

        uint256 paid;
        for (uint256 i; i < count; ++i) {
            paid += currency1.balanceOf(recipients[i]);
        }
        uint256 fee = currency1.balanceOf(feeRecipient);
        assertEq(currency1.balanceOf(address(this)), swapperBefore, "swapper receives no output directly");
        assertEq(fee, _fee(paid), "fee uses Spray's formula");
        assertEq(paid + fee + currency1.balanceOf(payer), output, "every wei accounted for");
        assertLe(currency1.balanceOf(payer), 1, "at most 1 unreachable wei");
        _assertHookEmpty(currency1);
    }

    function test_Shares_1Recipient() public {
        _assertShares(1);
    }

    function test_Shares_2Recipients() public {
        _assertShares(2);
    }

    function test_Shares_7Recipients() public {
        _assertShares(7);
    }

    function test_Shares_50Recipients() public {
        _assertShares(50);
    }

    function test_Shares_200Recipients() public {
        _assertShares(200);
    }

    // ---- return-delta accounting ----

    function test_ReturnDelta_ManagerBalancesAndUnlockSettle() public {
        SwapParams memory params = _exactIn(true, 1e15);
        uint256 output = _outputOf(hooked, params);
        uint256 manager0 = currency0.balanceOf(address(manager));
        uint256 manager1 = currency1.balanceOf(address(manager));

        // unlock() reverts with CurrencyNotSettled if any delta is left open.
        BalanceDelta delta =
            swapRouter.swap(hooked, params, settings, abi.encode(_shares(payer, _freshRecipients(2, 20))));

        assertEq(delta.amount0(), -int128(int256(1e15)), "swapper pays the input");
        assertEq(delta.amount1(), 0, "hook took the whole output");
        assertEq(currency0.balanceOf(address(manager)) - manager0, 1e15, "manager received the input");
        assertEq(manager1 - currency1.balanceOf(address(manager)), output, "manager paid out the output");
    }

    function test_EmitsSwapSettled() public {
        address[] memory recipients = _freshRecipients(1, 21);
        SwapParams memory params = _exactIn(true, 1e15);
        uint256 output = _outputOf(hooked, params);
        uint256 total = (output * 10_000) / 10_030;
        if (total + 1 + _fee(total + 1) <= output) ++total;
        uint256 fee = _fee(total);

        vm.expectEmit(true, true, true, true, address(hook));
        emit SpraySettlement.SwapSettled(
            payer, hooked.toId(), currency1, output, total, fee, 1, 0, output - total - fee
        );
        _swap(hooked, params, abi.encode(_shares(payer, recipients)));
    }

    // ---- AMOUNTS ----

    function test_Amounts_RemainderGoesToPayer() public {
        address[] memory recipients = _freshRecipients(2, 1);
        PayoutSpec memory spec = _amounts(payer, recipients, _filled(2, 1e14));
        SwapParams memory params = _exactIn(true, 1e15);
        uint256 output = _outputOf(hooked, params);

        _swap(hooked, params, abi.encode(spec));

        assertEq(currency1.balanceOf(recipients[0]), 1e14);
        assertEq(currency1.balanceOf(payer), output - 2e14 - _fee(2e14), "remainder");
        _assertHookEmpty(currency1);
    }

    function test_Amounts_RevertWhen_OutputShort() public {
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(2, 2), _filled(2, 1e15));
        SwapParams memory params = _exactIn(true, 1e15);
        uint256 output = _outputOf(hooked, params);
        _expectHookRevert(
            abi.encodeWithSelector(SpraySettlement.InsufficientOutput.selector, output, 2e15 + _fee(2e15))
        );
        _swap(hooked, params, abi.encode(spec));
    }

    // ---- pass-through and direction ----

    function test_EmptyHookData_BehavesLikeHooklessPool() public {
        SwapParams memory params = _exactIn(true, 1e15);
        BalanceDelta hookedDelta = swapRouter.swap(hooked, params, settings, ZERO_BYTES);
        BalanceDelta controlDelta = swapRouter.swap(key, params, settings, ZERO_BYTES);

        assertEq(hookedDelta.amount0(), controlDelta.amount0(), "input matches control pool");
        assertEq(hookedDelta.amount1(), controlDelta.amount1(), "output matches control pool");
        _assertHookEmpty(currency1);
    }

    function test_RevertWhen_ExactOutputWithHookData() public {
        PayoutSpec memory spec = _shares(payer, _freshRecipients(2, 3));
        SwapParams memory params = SwapParams(true, int256(1e14), MIN_PRICE_LIMIT);
        _expectHookRevert(abi.encodeWithSelector(SwapAndSprayHook.ExactOutputNotSupported.selector));
        _swap(hooked, params, abi.encode(spec));
    }

    function test_ExactOutputWithoutHookData_PassesThrough() public {
        uint256 before = currency1.balanceOf(address(this));
        _swap(hooked, SwapParams(true, int256(1e14), MIN_PRICE_LIMIT), ZERO_BYTES);
        assertEq(currency1.balanceOf(address(this)) - before, 1e14);
    }

    function test_OneForZeroDirection() public {
        address[] memory recipients = _freshRecipients(2, 4);
        SwapParams memory params = _exactIn(false, 1e15);
        uint256 output = _outputOf(hooked, params);

        _swap(hooked, params, abi.encode(_shares(payer, recipients)));

        uint256 paid = currency0.balanceOf(recipients[0]) + currency0.balanceOf(recipients[1]);
        assertEq(paid + currency0.balanceOf(feeRecipient) + currency0.balanceOf(payer), output);
    }

    // ---- native output and refunds ----

    function test_NativeOutput_Shares() public {
        address[] memory recipients = _freshRecipients(3, 5);
        SwapParams memory params = _exactIn(false, 1e15);
        uint256 output = _outputOf(hookedNative, params);

        _swap(hookedNative, params, abi.encode(_shares(payer, recipients)));

        uint256 paid = recipients[0].balance + recipients[1].balance + recipients[2].balance;
        assertEq(paid + feeRecipient.balance + payer.balance, output, "every wei accounted for");
        _assertHookEmpty(CurrencyLibrary.ADDRESS_ZERO);
    }

    function test_SkipOnFail_RefundsPayerInSameCall() public {
        address bad = address(new RevertingReceiver());
        address good = makeAddr("good");
        PayoutSpec memory spec = _amounts(payer, _pair(bad, good), _filled(2, 1e14));
        SwapParams memory params = _exactIn(false, 1e15);
        uint256 output = _outputOf(hookedNative, params);

        _swap(hookedNative, params, abi.encode(spec));

        assertEq(good.balance, 1e14, "healthy recipient paid");
        assertEq(bad.balance, 0, "bad recipient skipped");
        assertEq(feeRecipient.balance, _fee(1e14), "fee only on delivered");
        assertEq(payer.balance, output - 1e14 - _fee(1e14), "everything else refunded");
        _assertHookEmpty(CurrencyLibrary.ADDRESS_ZERO);
    }

    function test_RevertWhen_PayerCannotReceiveRefund() public {
        address badPayer = address(new RevertingReceiver());
        PayoutSpec memory spec =
            _amounts(badPayer, _pair(address(new RevertingReceiver()), makeAddr("good")), _filled(2, 1e14));
        vm.expectRevert();
        _swap(hookedNative, _exactIn(false, 1e15), abi.encode(spec));
    }

    // ---- guards ----

    function test_RevertWhen_OutputBelowSpecMinimum() public {
        PayoutSpec memory spec = _shares(payer, _freshRecipients(2, 6));
        spec.minOutput = 1e18;
        SwapParams memory params = _exactIn(true, 1e15);
        uint256 output = _outputOf(hooked, params);
        _expectHookRevert(abi.encodeWithSelector(SpraySettlement.OutputBelowMinimum.selector, output, 1e18));
        _swap(hooked, params, abi.encode(spec));
    }

    function test_RevertWhen_FeeAboveCallerMaximum() public {
        spray.updateFee(31);
        PayoutSpec memory spec = _shares(payer, _freshRecipients(2, 7));
        _expectHookRevert(abi.encodeWithSelector(SpraySettlement.FeeExceedsMaximum.selector, 31, 30));
        _swap(hooked, _exactIn(true, 1e15), abi.encode(spec));
    }

    function test_RevertWhen_SpecInvalid() public {
        PayoutSpec memory spec = _shares(address(0), _freshRecipients(2, 8));
        _expectHookRevert(abi.encodeWithSelector(PayoutSpecLib.ZeroPayer.selector));
        _swap(hooked, _exactIn(true, 1e15), abi.encode(spec));
    }

    function test_RevertWhen_ShareRoundsToZero() public {
        PayoutSpec memory spec = _shares(payer, _freshRecipients(200, 9));
        _expectHookRevert(abi.encodeWithSelector(SpraySettlement.ShareRoundsToZero.selector, 0));
        _swap(hooked, _exactIn(true, 100), abi.encode(spec));
    }

    function test_RevertWhen_AfterSwapNotFromManager() public {
        vm.expectRevert();
        hook.afterSwap(address(this), hooked, _exactIn(true, 1), BalanceDelta.wrap(0), ZERO_BYTES);
    }

    function test_RevertWhen_StrangerSendsNative() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
    }

    // ---- router on a hooked pool ----

    function test_RouterOnHookedPool_SettlesOnce() public {
        SwapAndSprayRouter router = new SwapAndSprayRouter(manager, ISpray(address(spray)));
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        address[] memory recipients = _freshRecipients(2, 10);
        PayoutSpec memory spec = _amounts(payer, recipients, _filled(2, 1e14));
        uint256 required = 2e14 + _fee(2e14);

        router.swapAndSpray(hooked, SwapParams(true, int256(required), MIN_PRICE_LIMIT), 1e16, spec, block.timestamp);

        assertEq(currency1.balanceOf(recipients[0]), 1e14, "paid once");
        assertEq(currency1.balanceOf(recipients[1]), 1e14, "paid once");
        assertEq(currency1.balanceOf(feeRecipient), _fee(2e14), "fee charged once");
        _assertHookEmpty(currency1);
    }
}
