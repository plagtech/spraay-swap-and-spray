// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {PayoutSpec} from "../../src/libraries/PayoutSpec.sol";
import {ForkBase, IUsdcAdmin} from "./ForkBase.sol";

/// @notice The router against real Base state: real Spray, real USDC, the real ETH/USDC pool
contract RouterForkTest is ForkBase {
    function _threeAmounts() internal pure returns (uint256[] memory values) {
        values = new uint256[](3);
        values[0] = 1_000_000;
        values[1] = 2_000_000;
        values[2] = 3_000_000;
    }

    function test_Fork_LiveSprayMatchesExpectedFee() public onlyBase {
        assertEq(SPRAY.feeBps(), SPRAY_FEE_BPS);
    }

    function test_Fork_ExactOutput_EthIn_FixedUsdcPerRecipient() public onlyBase {
        address[] memory recipients = _freshRecipients(3, 1);
        uint256[] memory values = _threeAmounts();
        PayoutSpec memory spec = _amounts(payer, recipients, values);
        uint256 required = router.requiredOutput(spec);
        uint256 feeBefore = _usdc(feeRecipient);
        uint256 ethBefore = address(this).balance;

        (uint256 amountIn, uint256 output) = router.swapAndSpray{value: 0.05 ether}(
            ethUsdc, _exactOutEthToUsdc(required), 0.05 ether, spec, block.timestamp
        );

        assertEq(output, required, "exact output");
        assertEq(ethBefore - address(this).balance, amountIn, "unused ETH returned");
        for (uint256 i; i < 3; ++i) {
            assertEq(_usdc(recipients[i]), values[i], "fixed USDC delivered");
        }
        assertEq(_usdc(feeRecipient) - feeBefore, _fee(6_000_000), "real 30 bps fee");
        assertEq(_usdc(payer), 0, "no leftover");
        assertEq(_usdc(address(router)), 0, "router empty");
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(IERC20(USDC).allowance(address(router), address(SPRAY)), 0, "allowance cleared");
    }

    function test_Fork_ExactOutput_RevertWhen_InputAboveMaximum() public onlyBase {
        PayoutSpec memory spec = _amounts(payer, _freshRecipients(3, 2), _threeAmounts());
        uint256 required = router.requiredOutput(spec);

        vm.expectRevert();
        router.swapAndSpray{value: 0.05 ether}(ethUsdc, _exactOutEthToUsdc(required), 1, spec, block.timestamp);
    }

    function test_Fork_ExactInput_Shares_PoolAgnostic() public onlyBase {
        address[] memory recipients = _freshRecipients(3, 3);
        uint256 feeBefore = _usdc(feeRecipient);

        (, uint256 output) = router.swapAndSpray{value: 0.001 ether}(
            ethUsdc, _exactInEthToUsdc(0.001 ether), 0, _shares(payer, recipients), block.timestamp
        );

        uint256 paid = _usdc(recipients[0]) + _usdc(recipients[1]) + _usdc(recipients[2]);
        uint256 fee = _usdc(feeRecipient) - feeBefore;
        assertEq(fee, _fee(paid), "real fee formula");
        assertEq(paid + fee + _usdc(payer), output, "every wei accounted for");
        assertLe(_usdc(payer), 1, "at most 1 unreachable wei");
        assertEq(_usdc(address(router)), 0, "router empty");
    }

    function test_Fork_BlocklistedRecipient_RefundedToPayerInSameCall() public onlyBase {
        address blocked = makeAddr("blocked");
        address good = makeAddr("good");
        vm.prank(IUsdcAdmin(USDC).blacklister());
        IUsdcAdmin(USDC).blacklist(blocked);
        PayoutSpec memory spec = _amounts(payer, _pair(blocked, good), _filled(2, 1_000_000));
        uint256 required = router.requiredOutput(spec);
        uint256 feeBefore = _usdc(feeRecipient);

        router.swapAndSpray{value: 0.05 ether}(ethUsdc, _exactOutEthToUsdc(required), 0.05 ether, spec, block.timestamp);

        assertEq(_usdc(good), 1_000_000, "healthy recipient paid");
        assertEq(_usdc(blocked), 0, "blocked recipient skipped");
        assertEq(_usdc(feeRecipient) - feeBefore, _fee(1_000_000), "fee only on delivered");
        assertEq(_usdc(payer), required - 1_000_000 - _fee(1_000_000), "refund forwarded");
        assertEq(_usdc(address(router)), 0, "router empty");
    }

    function test_Fork_RevertWhen_PayerBlockedFromRefund() public onlyBase {
        address blocked = makeAddr("blocked");
        vm.startPrank(IUsdcAdmin(USDC).blacklister());
        IUsdcAdmin(USDC).blacklist(blocked);
        IUsdcAdmin(USDC).blacklist(payer);
        vm.stopPrank();
        PayoutSpec memory spec = _amounts(payer, _pair(blocked, makeAddr("good")), _filled(2, 1_000_000));
        uint256 required = router.requiredOutput(spec);

        vm.expectRevert();
        router.swapAndSpray{value: 0.05 ether}(ethUsdc, _exactOutEthToUsdc(required), 0.05 ether, spec, block.timestamp);
    }

    function test_Fork_UsdcIn_NativeOut_Shares() public onlyBase {
        deal(USDC, address(this), 100e6);
        IERC20(USDC).approve(address(router), type(uint256).max);
        address[] memory recipients = _freshRecipients(3, 4);
        uint256 feeBefore = feeRecipient.balance;
        SwapParams memory params = SwapParams(false, -int256(10e6), TickMath.MAX_SQRT_PRICE - 1);

        (, uint256 output) = router.swapAndSpray(ethUsdc, params, 0, _shares(payer, recipients), block.timestamp);

        uint256 paid = recipients[0].balance + recipients[1].balance + recipients[2].balance;
        uint256 fee = feeRecipient.balance - feeBefore;
        assertEq(fee, _fee(paid), "real fee formula");
        assertEq(paid + fee + payer.balance, output, "every wei accounted for");
        assertEq(address(router).balance, 0, "router empty");
    }
}
