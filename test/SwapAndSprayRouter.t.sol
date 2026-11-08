// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {SwapAndSprayRouter} from "../src/SwapAndSprayRouter.sol";
import {SpraySettlement} from "../src/SpraySettlement.sol";
import {ISpray} from "../src/interfaces/ISpray.sol";
import {PayoutSpec, PayoutSpecLib} from "../src/libraries/PayoutSpec.sol";
import {SprayContract} from "./mocks/SprayContractV2.sol";
import {BlocklistToken, PassThroughHook, ReentrantCaller, RevertingReceiver} from "./mocks/Mocks.sol";
import {SpecHelpers} from "./utils/SpecHelpers.sol";

contract SwapAndSprayRouterTest is Test, Deployers, SpecHelpers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SprayContract internal spray;
    SwapAndSprayRouter internal router;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal payer = makeAddr("payer");

    function setUp() public {
        initializeManagerRoutersAndPoolsWithLiq(IHooks(address(0)));
        spray = new SprayContract(feeRecipient, SPRAY_FEE_BPS);
        router = new SwapAndSprayRouter(manager, ISpray(address(spray)));
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function _exactIn(bool zeroForOne, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, -int256(amount), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    function _exactOut(bool zeroForOne, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, int256(amount), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    function _balance(Currency currency, address account) internal view returns (uint256) {
        return currency.balanceOf(account);
    }

    function _assertRouterEmpty(Currency currency) internal view {
        assertEq(_balance(currency, address(router)), 0, "router holds output");
        assertEq(address(router).balance, 0, "router holds native");
        if (!currency.isAddressZero()) {
            assertEq(MockERC20(Currency.unwrap(currency)).allowance(address(router), address(spray)), 0, "allowance");
        }
    }

    // ---- exact-output: the primary path, fixed amounts paid with native input ----

    function test_ExactOutput_NativeIn_PaysFixedAmountsAndRefundsUnusedInput() public {
        address[] memory recipients = _freshRecipients(3, 1);
        uint256[] memory values = _filled(3, 1e14);
        PayoutSpec memory spec = _amounts(payer, recipients, values);
        uint256 required = _sum(values) + _fee(_sum(values));
        uint256 ethBefore = address(this).balance;

        (uint256 amountIn, uint256 output) =
            router.swapAndSpray{value: 1e16}(nativeKey, _exactOut(true, required), 1e16, spec, block.timestamp);

        assertEq(output, required, "exact output");
        assertEq(ethBefore - address(this).balance, amountIn, "only the swap input was spent");
        for (uint256 i; i < 3; ++i) {
            assertEq(_balance(currency1, recipients[i]), 1e14);
        }
        assertEq(_balance(currency1, feeRecipient), _fee(3e14), "fee");
        assertEq(_balance(currency1, payer), 0, "no leftover");
        _assertRouterEmpty(currency1);
    }

    function test_ExactOutput_EmitsSwapSettled() public {
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(2, 30), _filled(2, 1e14));
        uint256 required = 2e14 + _fee(2e14);

        vm.expectEmit(true, true, true, true, address(router));
        emit SpraySettlement.SwapSettled(payer, nativeKey.toId(), currency1, required, 2e14, _fee(2e14), 2, 0, 0);
        router.swapAndSpray{value: 1e16}(nativeKey, _exactOut(true, required), 1e16, spec, block.timestamp);
    }

    function test_ExactOutput_RequiredOutputMatchesLiveFee() public view {
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(2, 1), _filled(2, 500));
        assertEq(router.requiredOutput(spec), 1003);
    }

    function test_ExactOutput_RevertWhen_AmountSpecifiedMismatch() public {
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(2, 1), _filled(2, 500));
        vm.expectRevert(abi.encodeWithSelector(SwapAndSprayRouter.ExactOutputMismatch.selector, 1004, 1003));
        router.swapAndSpray{value: 1e16}(nativeKey, _exactOut(true, 1004), 1e16, spec, block.timestamp);
    }

    function test_ExactOutput_RevertWhen_InputAboveMaximum() public {
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(1, 1), _filled(1, 1e14));
        uint256 required = 1e14 + _fee(1e14);
        vm.expectPartialRevert(SwapAndSprayRouter.TooMuchRequested.selector);
        router.swapAndSpray{value: 1e16}(nativeKey, _exactOut(true, required), 1000, spec, block.timestamp);
    }

    function test_ExactOutput_RevertWhen_ValueCannotCoverInput() public {
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(1, 1), _filled(1, 1e14));
        uint256 required = 1e14 + _fee(1e14);
        vm.expectPartialRevert(SwapAndSprayRouter.InsufficientValue.selector);
        router.swapAndSpray{value: 1000}(nativeKey, _exactOut(true, required), 1e16, spec, block.timestamp);
    }

    function test_ExactOutput_Erc20Input() public {
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(2, 2), _filled(2, 1e14));
        uint256 required = 2e14 + _fee(2e14);
        uint256 before0 = _balance(currency0, address(this));

        (uint256 amountIn,) = router.swapAndSpray(key, _exactOut(true, required), 1e16, spec, block.timestamp);

        assertEq(before0 - _balance(currency0, address(this)), amountIn, "pulls exactly the swap input");
        _assertRouterEmpty(currency1);
    }

    function test_ExactOutput_NativeOutput() public {
        address[] memory recipients = _freshRecipients(2, 3);
        PayoutSpec memory spec = _amounts(payer, recipients, _filled(2, 1e14));
        uint256 required = 2e14 + _fee(2e14);

        router.swapAndSpray(nativeKey, _exactOut(false, required), 1e16, spec, block.timestamp);

        assertEq(recipients[0].balance, 1e14);
        assertEq(recipients[1].balance, 1e14);
        assertEq(feeRecipient.balance, _fee(2e14));
        _assertRouterEmpty(CurrencyLibrary.ADDRESS_ZERO);
    }

    // ---- exact-input ----

    function _assertShares(uint256 count) internal {
        address[] memory recipients = _freshRecipients(count, 100 + count);
        PayoutSpec memory spec = _shares(payer, recipients);

        (, uint256 output) = router.swapAndSpray(key, _exactIn(true, 1e15), 0, spec, block.timestamp);

        uint256 paid;
        for (uint256 i; i < count; ++i) {
            paid += _balance(currency1, recipients[i]);
        }
        uint256 fee = _balance(currency1, feeRecipient);
        assertEq(fee, _fee(paid), "fee uses Spray's formula");
        assertEq(paid + fee + _balance(currency1, payer), output, "every wei accounted for");
        assertLe(_balance(currency1, payer), 1, "at most 1 unreachable wei");
        assertGe(_balance(currency1, recipients[count - 1]), (paid * spec.values[count - 1]) / 10_000, "dust last");
        _assertRouterEmpty(currency1);
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

    function test_Amounts_RemainderGoesToPayer() public {
        address[] memory recipients = _freshRecipients(2, 4);
        PayoutSpec memory spec = _amounts(payer, recipients, _filled(2, 1e14));

        (, uint256 output) = router.swapAndSpray(key, _exactIn(true, 1e15), 0, spec, block.timestamp);

        assertEq(_balance(currency1, payer), output - 2e14 - _fee(2e14), "remainder");
        _assertRouterEmpty(currency1);
    }

    function test_Amounts_RevertWhen_OutputShort() public {
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(2, 5), _filled(2, 1e15));
        vm.expectPartialRevert(SpraySettlement.InsufficientOutput.selector);
        router.swapAndSpray(key, _exactIn(true, 1e15), 0, spec, block.timestamp);
    }

    function test_NativeOutput_Shares() public {
        address[] memory recipients = _freshRecipients(3, 6);

        (, uint256 output) =
            router.swapAndSpray(nativeKey, _exactIn(false, 1e15), 0, _shares(payer, recipients), block.timestamp);

        uint256 paid = recipients[0].balance + recipients[1].balance + recipients[2].balance;
        assertEq(paid + feeRecipient.balance + payer.balance, output, "every wei accounted for");
        _assertRouterEmpty(CurrencyLibrary.ADDRESS_ZERO);
    }

    // ---- skip-on-fail and same-call refunds ----

    function test_SkipOnFail_Native_RefundsPayerInSameCall() public {
        address bad = address(new RevertingReceiver());
        address good = makeAddr("good");
        PayoutSpec memory spec = _amounts(payer, _pair(bad, good), _filled(2, 1e14));
        uint256 required = 2e14 + _fee(2e14);

        router.swapAndSpray(nativeKey, _exactOut(false, required), 1e16, spec, block.timestamp);

        assertEq(good.balance, 1e14, "healthy recipient paid");
        assertEq(bad.balance, 0, "bad recipient skipped");
        assertEq(feeRecipient.balance, _fee(1e14), "fee only on delivered");
        assertEq(payer.balance, required - 1e14 - _fee(1e14), "undelivered and unused fee refunded");
        _assertRouterEmpty(CurrencyLibrary.ADDRESS_ZERO);
    }

    function _blocklistPool() internal returns (PoolKey memory blockKey, BlocklistToken token, bool tokenIsZero) {
        token = new BlocklistToken();
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        token.mint(address(this), 1e24);
        other.mint(address(this), 1e24);
        for (uint256 i; i < 2; ++i) {
            MockERC20 t = i == 0 ? MockERC20(address(token)) : other;
            t.approve(address(modifyLiquidityRouter), type(uint256).max);
            t.approve(address(router), type(uint256).max);
        }
        tokenIsZero = address(token) < address(other);
        (Currency c0, Currency c1) = tokenIsZero
            ? (Currency.wrap(address(token)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(token)));
        (blockKey,) = initPoolAndAddLiquidity(c0, c1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
    }

    function test_SkipOnFail_BlocklistedToken_RefundsPayer() public {
        (PoolKey memory blockKey, BlocklistToken token, bool tokenIsZero) = _blocklistPool();
        address bad = makeAddr("bad");
        address good = makeAddr("good");
        token.setBlocked(bad, true);
        PayoutSpec memory spec = _amounts(payer, _pair(bad, good), _filled(2, 1e14));
        uint256 required = 2e14 + _fee(2e14);

        router.swapAndSpray(blockKey, _exactOut(!tokenIsZero, required), 1e16, spec, block.timestamp);

        assertEq(token.balanceOf(good), 1e14);
        assertEq(token.balanceOf(bad), 0);
        assertEq(token.balanceOf(feeRecipient), _fee(1e14));
        assertEq(token.balanceOf(payer), required - 1e14 - _fee(1e14));
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_RevertWhen_PayerCannotReceiveNativeRefund() public {
        address badPayer = address(new RevertingReceiver());
        address bad = address(new RevertingReceiver());
        PayoutSpec memory spec = _amounts(badPayer, _pair(bad, makeAddr("good")), _filled(2, 1e14));
        uint256 required = 2e14 + _fee(2e14);

        vm.expectRevert();
        router.swapAndSpray(nativeKey, _exactOut(false, required), 1e16, spec, block.timestamp);
    }

    function test_RevertWhen_PayerBlockedFromTokenRefund() public {
        (PoolKey memory blockKey, BlocklistToken token, bool tokenIsZero) = _blocklistPool();
        address bad = makeAddr("bad");
        token.setBlocked(bad, true);
        token.setBlocked(payer, true);
        PayoutSpec memory spec = _amounts(payer, _pair(bad, makeAddr("good")), _filled(2, 1e14));
        uint256 required = 2e14 + _fee(2e14);

        vm.expectRevert();
        router.swapAndSpray(blockKey, _exactOut(!tokenIsZero, required), 1e16, spec, block.timestamp);
    }

    function test_RevertWhen_EveryRecipientFails() public {
        address bad = address(new RevertingReceiver());
        PayoutSpec memory spec = _amounts(payer, _pair(bad, address(new RevertingReceiver())), _filled(2, 1e14));
        uint256 required = 2e14 + _fee(2e14);

        vm.expectRevert("All transfers failed");
        router.swapAndSpray(nativeKey, _exactOut(false, required), 1e16, spec, block.timestamp);
    }

    // ---- guards ----

    function test_RevertWhen_FeeAboveCallerMaximum() public {
        spray.updateFee(31);
        PayoutSpec memory spec = _shares(payer, _freshRecipients(2, 7));
        vm.expectRevert(abi.encodeWithSelector(SpraySettlement.FeeExceedsMaximum.selector, 31, 30));
        router.swapAndSpray(key, _exactIn(true, 1e15), 0, spec, block.timestamp);
    }

    function test_FeeIsReadLive() public {
        spray.updateFee(100);
        address[] memory recipients = _freshRecipients(1, 8);
        PayoutSpec memory spec = _shares(payer, recipients);
        spec.maxFeeBps = 100;

        (, uint256 output) = router.swapAndSpray(key, _exactIn(true, 1e15), 0, spec, block.timestamp);

        uint256 paid = _balance(currency1, recipients[0]);
        assertEq(_balance(currency1, feeRecipient), (paid * 100) / 10_000);
        assertEq(paid + _balance(currency1, feeRecipient) + _balance(currency1, payer), output);
    }

    function test_RevertWhen_OutputBelowSpecMinimum() public {
        PayoutSpec memory spec = _shares(payer, _freshRecipients(2, 9));
        spec.minOutput = 1e18;
        vm.expectPartialRevert(SpraySettlement.OutputBelowMinimum.selector);
        router.swapAndSpray(key, _exactIn(true, 1e15), 0, spec, block.timestamp);
    }

    function test_ExactInput_RevertWhen_OutputBelowLimit() public {
        PayoutSpec memory spec = _shares(payer, _freshRecipients(2, 10));
        vm.expectPartialRevert(SwapAndSprayRouter.TooLittleReceived.selector);
        router.swapAndSpray(key, _exactIn(true, 1e15), 1e18, spec, block.timestamp);
    }

    function test_RevertWhen_DeadlinePassed() public {
        PayoutSpec memory spec = _shares(payer, _freshRecipients(2, 11));
        uint256 deadline = block.timestamp;
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(SwapAndSprayRouter.DeadlinePassed.selector, deadline));
        router.swapAndSpray(key, _exactIn(true, 1e15), 0, spec, deadline);
    }

    function test_RevertWhen_ValueSentWithErc20Input() public {
        PayoutSpec memory spec = _shares(payer, _freshRecipients(2, 12));
        vm.expectRevert(abi.encodeWithSelector(SwapAndSprayRouter.UnexpectedValue.selector, 1));
        router.swapAndSpray{value: 1}(key, _exactIn(true, 1e15), 0, spec, block.timestamp);
    }

    function test_RevertWhen_SpecInvalid() public {
        PayoutSpec memory spec = _shares(address(0), _freshRecipients(2, 13));
        vm.expectRevert(PayoutSpecLib.ZeroPayer.selector);
        router.swapAndSpray(key, _exactIn(true, 1e15), 0, spec, block.timestamp);
    }

    function test_RevertWhen_UnlockCallbackNotFromManager() public {
        vm.expectRevert(SwapAndSprayRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }

    function test_RevertWhen_StrangerSendsNative() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(router).call{value: 1}("");
        assertFalse(ok);
    }

    function test_RevertWhen_Reentered() public {
        ReentrantCaller caller = new ReentrantCaller(router);
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(1, 14), _filled(1, 1e14));
        uint256 required = 1e14 + _fee(1e14);
        SwapParams memory params = _exactOut(true, required);

        caller.attack{value: 1e16}(nativeKey, params, 1e16, spec);

        assertTrue(caller.attempted(), "reentry attempted");
        assertEq(bytes4(caller.revertData()), SwapAndSprayRouter.Reentrancy.selector);
    }

    // ---- pool-agnostic ----

    function test_WorksOnPoolWithUnrelatedHook() public {
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) | (uint160(1) << 150));
        vm.etch(hookAddress, address(new PassThroughHook()).code);
        (PoolKey memory hookedKey,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddress), 500, SQRT_PRICE_1_1);
        address[] memory recipients = _freshRecipients(2, 15);

        (, uint256 output) =
            router.swapAndSpray(hookedKey, _exactIn(true, 1e15), 0, _shares(payer, recipients), block.timestamp);

        uint256 paid = _balance(currency1, recipients[0]) + _balance(currency1, recipients[1]);
        assertEq(paid + _balance(currency1, feeRecipient) + _balance(currency1, payer), output);
    }
}
