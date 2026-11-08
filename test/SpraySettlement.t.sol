// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {SpraySettlement} from "../src/SpraySettlement.sol";
import {ISpray} from "../src/interfaces/ISpray.sol";
import {PayoutSpec, PayoutSpecLib} from "../src/libraries/PayoutSpec.sol";
import {SprayContract} from "./mocks/SprayContractV2.sol";
import {SpecHelpers} from "./utils/SpecHelpers.sol";

/// @dev Internal library reverts need an external frame to be caught by vm.expectRevert
contract Harness {
    using PayoutSpecLib for PayoutSpec;

    function validate(PayoutSpec memory spec, address spray) external view {
        spec.validate(spray);
    }

    function buildBatch(uint256 output, uint256 feeBps, PayoutSpec memory spec)
        external
        pure
        returns (ISpray.Recipient[] memory batch, uint256 total, uint256 fee)
    {
        return SpraySettlement.buildBatch(output, feeBps, spec);
    }
}

contract SpraySettlementTest is Test, SpecHelpers {
    using PayoutSpecLib for PayoutSpec;

    Harness internal harness = new Harness();
    address internal constant SPRAY = address(0x5352);
    address internal constant PAYER = address(0xBEEF);

    function _validShares(uint256 count) internal pure returns (PayoutSpec memory) {
        return _shares(PAYER, _freshRecipients(count, 1));
    }

    // ---- maxSprayable and fee formula ----

    function testFuzz_MaxSprayableIsTheTrueMaximum(uint128 rawOutput, uint16 rawFee) public pure {
        uint256 output = bound(rawOutput, 1, type(uint128).max);
        uint256 feeBps = bound(rawFee, 0, 500);

        uint256 total = SpraySettlement.maxSprayable(output, feeBps);

        assertLe(total + SpraySettlement.feeOn(total, feeBps), output, "must be affordable");
        assertGt(total + 1 + SpraySettlement.feeOn(total + 1, feeBps), output, "must be maximal");
    }

    function testFuzz_UnspentIsAtMostOneWei(uint128 rawOutput, uint16 rawFee) public pure {
        uint256 output = bound(rawOutput, 1, type(uint128).max);
        uint256 feeBps = bound(rawFee, 0, 500);

        uint256 total = SpraySettlement.maxSprayable(output, feeBps);

        assertLe(output - total - SpraySettlement.feeOn(total, feeBps), 1);
    }

    function test_MaxSprayableBeatsTheClosedForm() public pure {
        // Closed form gives 998 here, leaving 1 wei that 999 can use.
        assertEq(SpraySettlement.maxSprayable(1001, 30), 999);
    }

    function test_UnreachableOutputLeavesExactlyOneWei() public pure {
        // 333 + fee 0 = 333 and 334 + fee 1 = 335, so an output of 334 cannot be spent exactly.
        uint256 total = SpraySettlement.maxSprayable(334, 30);
        assertEq(total, 333);
        assertEq(334 - total - SpraySettlement.feeOn(total, 30), 1);
    }

    function testFuzz_FeeFormulaMatchesSpray(uint128 amount, uint16 rawFee) public {
        uint256 feeBps = bound(rawFee, 0, 500);
        SprayContract spray = new SprayContract(address(1), feeBps);
        assertEq(SpraySettlement.feeOn(amount, feeBps), spray.calculateFee(amount));
    }

    // ---- buildBatch ----

    function testFuzz_SharesSumExactlyAndDustGoesLast(uint96 rawOutput, uint8 rawCount) public view {
        uint256 count = bound(rawCount, 1, 200);
        uint256 output = bound(rawOutput, 100_000, type(uint96).max);
        PayoutSpec memory spec = _validShares(count);

        (ISpray.Recipient[] memory batch, uint256 total, uint256 fee) = harness.buildBatch(output, SPRAY_FEE_BPS, spec);

        uint256 sum;
        for (uint256 i; i < count; ++i) {
            sum += batch[i].amount;
        }
        assertEq(sum, total, "batch sums to total");
        assertEq(fee, _fee(total), "fee uses Spray's formula");
        assertLe(output - total - fee, 1, "at most 1 wei unspent");

        uint256 floored = (total * spec.values[count - 1]) / 10_000;
        assertGe(batch[count - 1].amount, floored, "last recipient takes the dust");
    }

    function test_RevertWhen_ShareRoundsToZero() public {
        PayoutSpec memory spec = _validShares(200);
        // 50 bps of a very small total floors to 0 on the first recipient.
        vm.expectRevert(abi.encodeWithSelector(SpraySettlement.ShareRoundsToZero.selector, 0));
        harness.buildBatch(100, SPRAY_FEE_BPS, spec);
    }

    function test_RevertWhen_TinyOutputFloorsAShare() public {
        // At 100 the dust keeps the 1 bps last share above zero. At 1 the first share floors to zero.
        uint256[] memory bps = new uint256[](3);
        bps[0] = 5000;
        bps[1] = 4999;
        bps[2] = 1;
        address[] memory recipients = _freshRecipients(3, 2);
        PayoutSpec memory spec = PayoutSpec(0, PAYER, 0, 30, recipients, bps);

        (ISpray.Recipient[] memory batch,,) = harness.buildBatch(100, SPRAY_FEE_BPS, spec);
        assertGt(batch[2].amount, 0, "dust rescues the last share here");

        vm.expectRevert(abi.encodeWithSelector(SpraySettlement.ShareRoundsToZero.selector, 0));
        harness.buildBatch(1, SPRAY_FEE_BPS, spec);
    }

    function test_RevertWhen_AmountsPlusFeeExceedOutput() public {
        PayoutSpec memory spec = _amounts(PAYER, _freshRecipients(2, 3), _filled(2, 500));
        // 1000 + fee 3 = 1003, so 1002 is one short.
        vm.expectRevert(abi.encodeWithSelector(SpraySettlement.InsufficientOutput.selector, 1002, 1003));
        harness.buildBatch(1002, SPRAY_FEE_BPS, spec);
        harness.buildBatch(1003, SPRAY_FEE_BPS, spec);
    }

    // ---- validation ----

    function test_ValidSpecsPass() public view {
        harness.validate(_validShares(1), SPRAY);
        harness.validate(_validShares(200), SPRAY);
        harness.validate(_amounts(PAYER, _freshRecipients(2, 1), _filled(2, 1)), SPRAY);
    }

    function test_RevertWhen_ModeInvalid() public {
        PayoutSpec memory spec = _validShares(2);
        spec.mode = 2;
        vm.expectRevert(abi.encodeWithSelector(PayoutSpecLib.InvalidMode.selector, 2));
        harness.validate(spec, SPRAY);
    }

    function test_RevertWhen_PayerZero() public {
        PayoutSpec memory spec = _validShares(2);
        spec.payer = address(0);
        vm.expectRevert(PayoutSpecLib.ZeroPayer.selector);
        harness.validate(spec, SPRAY);
    }

    function test_RevertWhen_LengthsDiffer() public {
        PayoutSpec memory spec = _validShares(2);
        spec.values = _filled(3, 1);
        vm.expectRevert(abi.encodeWithSelector(PayoutSpecLib.LengthMismatch.selector, 2, 3));
        harness.validate(spec, SPRAY);
    }

    function test_RevertWhen_NoRecipients() public {
        PayoutSpec memory spec = PayoutSpec(0, PAYER, 0, 30, new address[](0), new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(PayoutSpecLib.InvalidRecipientCount.selector, 0));
        harness.validate(spec, SPRAY);
    }

    function test_RevertWhen_TooManyRecipients() public {
        uint256 count = PayoutSpecLib.MAX_RECIPIENTS + 1;
        PayoutSpec memory spec = PayoutSpec(1, PAYER, 0, 30, _freshRecipients(count, 1), _filled(count, 1));
        vm.expectRevert(abi.encodeWithSelector(PayoutSpecLib.InvalidRecipientCount.selector, count));
        harness.validate(spec, SPRAY);
    }

    function test_RevertWhen_RecipientZero() public {
        PayoutSpec memory spec = _validShares(2);
        spec.recipients[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(PayoutSpecLib.InvalidRecipient.selector, 1, address(0)));
        harness.validate(spec, SPRAY);
    }

    function test_RevertWhen_RecipientIsSpray() public {
        PayoutSpec memory spec = _validShares(2);
        spec.recipients[0] = SPRAY;
        vm.expectRevert(abi.encodeWithSelector(PayoutSpecLib.InvalidRecipient.selector, 0, SPRAY));
        harness.validate(spec, SPRAY);
    }

    function test_RevertWhen_RecipientIsSettlingContract() public {
        PayoutSpec memory spec = _validShares(2);
        spec.recipients[0] = address(harness);
        vm.expectRevert(abi.encodeWithSelector(PayoutSpecLib.InvalidRecipient.selector, 0, address(harness)));
        harness.validate(spec, SPRAY);
    }

    function test_RevertWhen_ValueZero() public {
        PayoutSpec memory spec = _amounts(PAYER, _freshRecipients(2, 1), _filled(2, 1));
        spec.values[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(PayoutSpecLib.ZeroValue.selector, 1));
        harness.validate(spec, SPRAY);
    }

    function test_RevertWhen_BpsDoNotSumToFull() public {
        PayoutSpec memory spec = _validShares(2);
        spec.values[0] += 1;
        vm.expectRevert(abi.encodeWithSelector(PayoutSpecLib.SharesNotFullBps.selector, 10_001));
        harness.validate(spec, SPRAY);
    }
}
