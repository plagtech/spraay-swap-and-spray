// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {ISpray} from "./interfaces/ISpray.sol";
import {PayoutSpec, PayoutSpecLib} from "./libraries/PayoutSpec.sol";

/// @notice Pays a swap's output out through Spray and returns everything undelivered to the payer
/// @dev Stateless and non-custodial. The refund is measured by balance change and forwarded in the
/// same call. If the payer cannot receive it, the whole swap reverts.
library SpraySettlement {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /// @param total Amount sent to Spray for recipients
    /// @param fee Spray's fee on `total`. Spray keeps less if some recipients were skipped.
    /// @param failedCount Recipients Spray skipped
    /// @param refund Amount forwarded to the payer: skipped amounts, their unused fee, any remainder
    event SwapSettled(
        address indexed payer,
        PoolId indexed poolId,
        Currency indexed currencyOut,
        uint256 output,
        uint256 total,
        uint256 fee,
        uint256 recipientCount,
        uint256 failedCount,
        uint256 refund
    );

    error FeeExceedsMaximum(uint256 feeBps, uint256 maxFeeBps);
    error OutputBelowMinimum(uint256 output, uint256 minOutput);
    error InsufficientOutput(uint256 output, uint256 required);
    error ShareRoundsToZero(uint256 index);

    /// @notice Settles `output` of `currencyOut`, which this contract must already hold
    function settle(ISpray spray, PoolId poolId, Currency currencyOut, uint256 output, PayoutSpec memory spec)
        internal
    {
        uint256 feeBps = spray.feeBps();
        if (feeBps > spec.maxFeeBps) revert FeeExceedsMaximum(feeBps, spec.maxFeeBps);
        if (output < spec.minOutput) revert OutputBelowMinimum(output, spec.minOutput);

        uint256 balanceBefore = currencyOut.balanceOfSelf() - output;
        (ISpray.Recipient[] memory batch, uint256 total, uint256 fee) = buildBatch(output, feeBps, spec);

        uint256 failedCount = _spray(spray, currencyOut, batch, total + fee);

        uint256 refund = currencyOut.balanceOfSelf() - balanceBefore;
        if (refund > 0) currencyOut.transfer(spec.payer, refund);

        emit SwapSettled(spec.payer, poolId, currencyOut, output, total, fee, batch.length, failedCount, refund);
    }

    /// @notice Spray's own fee formula
    function feeOn(uint256 total, uint256 feeBps) internal pure returns (uint256) {
        return (total * feeBps) / PayoutSpecLib.BPS;
    }

    /// @notice The output an AMOUNTS spec consumes exactly
    function requiredOutput(PayoutSpec memory spec, uint256 feeBps) internal pure returns (uint256) {
        uint256 total;
        for (uint256 i; i < spec.values.length; ++i) {
            total += spec.values[i];
        }
        return total + feeOn(total, feeBps);
    }

    /// @notice The largest `total` with `total + feeOn(total) <= output`
    /// @dev The floored closed form is at most one below the true maximum, so one step is enough.
    /// Spray's floored fee makes some outputs unreachable, so at most 1 wei can remain unspent.
    function maxSprayable(uint256 output, uint256 feeBps) internal pure returns (uint256 total) {
        total = (output * PayoutSpecLib.BPS) / (PayoutSpecLib.BPS + feeBps);
        if (total + 1 + feeOn(total + 1, feeBps) <= output) ++total;
    }

    /// @notice Converts a spec into Spray recipients for a known output
    function buildBatch(uint256 output, uint256 feeBps, PayoutSpec memory spec)
        internal
        pure
        returns (ISpray.Recipient[] memory batch, uint256 total, uint256 fee)
    {
        uint256 count = spec.recipients.length;
        batch = new ISpray.Recipient[](count);

        if (spec.mode == PayoutSpecLib.MODE_SHARES) {
            total = maxSprayable(output, feeBps);
            uint256 assigned;
            for (uint256 i; i < count; ++i) {
                // Flooring dust goes to the last recipient so the batch sums to `total` exactly.
                uint256 amount = i == count - 1 ? total - assigned : (total * spec.values[i]) / PayoutSpecLib.BPS;
                if (amount == 0) revert ShareRoundsToZero(i);
                assigned += amount;
                batch[i] = ISpray.Recipient(payable(spec.recipients[i]), amount);
            }
        } else {
            for (uint256 i; i < count; ++i) {
                total += spec.values[i];
                batch[i] = ISpray.Recipient(payable(spec.recipients[i]), spec.values[i]);
            }
        }

        fee = feeOn(total, feeBps);
        if (total + fee > output) revert InsufficientOutput(output, total + fee);
    }

    function _spray(ISpray spray, Currency currency, ISpray.Recipient[] memory batch, uint256 cost)
        private
        returns (uint256 failedCount)
    {
        if (currency.isAddressZero()) return spray.sprayETH{value: cost}(batch);

        IERC20 token = IERC20(Currency.unwrap(currency));
        token.forceApprove(address(spray), cost);
        failedCount = spray.sprayToken(address(token), batch);
        token.forceApprove(address(spray), 0);
    }
}
