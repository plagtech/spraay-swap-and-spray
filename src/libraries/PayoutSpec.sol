// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Who gets paid from a swap's output, shared by the router's calldata and the hook's `hookData`.
/// @param mode 0 = SHARES (bps summing to 10000), 1 = AMOUNTS (fixed raw token amounts)
/// @param payer Receives any remainder and any amount Spray could not deliver
/// @param minOutput Minimum gross swap output accepted, before the Spray fee
/// @param maxFeeBps Highest live Spray `feeBps` the caller accepts
/// @param recipients 1 to MAX_RECIPIENTS addresses
/// @param values Bps in SHARES mode, raw token amounts in AMOUNTS mode
struct PayoutSpec {
    uint8 mode;
    address payer;
    uint256 minOutput;
    uint256 maxFeeBps;
    address[] recipients;
    uint256[] values;
}

library PayoutSpecLib {
    uint8 internal constant MODE_SHARES = 0;
    uint8 internal constant MODE_AMOUNTS = 1;
    uint256 internal constant BPS = 10_000;

    /// @dev Largest batch that measured under 70% of Base's per-transaction gas cap. See GAS.md.
    uint256 internal constant MAX_RECIPIENTS = 200;

    error InvalidMode(uint8 mode);
    error ZeroPayer();
    error LengthMismatch(uint256 recipients, uint256 values);
    error InvalidRecipientCount(uint256 count);
    error InvalidRecipient(uint256 index, address recipient);
    error ZeroValue(uint256 index);
    error SharesNotFullBps(uint256 sum);

    /// @notice Reverts unless `spec` can be paid out by Spray
    /// @dev Runs in the settling contract's context, so `address(this)` is the router or hook.
    function validate(PayoutSpec memory spec, address spray) internal view {
        if (spec.mode > MODE_AMOUNTS) revert InvalidMode(spec.mode);
        if (spec.payer == address(0)) revert ZeroPayer();

        uint256 count = spec.recipients.length;
        if (count != spec.values.length) revert LengthMismatch(count, spec.values.length);
        if (count == 0 || count > MAX_RECIPIENTS) revert InvalidRecipientCount(count);

        uint256 sum;
        for (uint256 i; i < count; ++i) {
            address recipient = spec.recipients[i];
            // Spray rejects itself and the zero address, and would strand funds sent to this contract.
            if (recipient == address(0) || recipient == spray || recipient == address(this)) {
                revert InvalidRecipient(i, recipient);
            }
            if (spec.values[i] == 0) revert ZeroValue(i);
            sum += spec.values[i];
        }

        if (spec.mode == MODE_SHARES && sum != BPS) revert SharesNotFullBps(sum);
    }
}
