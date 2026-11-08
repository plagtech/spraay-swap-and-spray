// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {ISpray} from "./interfaces/ISpray.sol";
import {PayoutSpec, PayoutSpecLib} from "./libraries/PayoutSpec.sol";
import {SpraySettlement} from "./SpraySettlement.sol";

/// @notice Swaps on any v4 pool and pays the output to a list of recipients in one transaction
/// @dev No owner, no admin functions, no storage. Spray's fee is the only fee. `hookData` is always
/// empty, so a pool with SwapAndSprayHook attached passes the swap through and this router settles.
contract SwapAndSprayRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PayoutSpecLib for PayoutSpec;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    struct CallbackData {
        address sender;
        uint256 value;
        PoolKey key;
        SwapParams params;
        uint256 amountLimit;
        PayoutSpec spec;
    }

    // keccak256("spraay.swapandspray.router.lock")
    bytes32 private constant LOCK_SLOT = 0x37f6b1bf8580b4f8ef6a771a621b6c5b63049b11a06f5ee914dfd67ede930896;

    IPoolManager public immutable poolManager;
    ISpray public immutable spray;

    error Reentrancy();
    error NotPoolManager();
    error UnexpectedSender(address sender);
    error DeadlinePassed(uint256 deadline);
    error UnexpectedValue(uint256 value);
    error InsufficientValue(uint256 value, uint256 required);
    error ExactOutputMismatch(uint256 amountSpecified, uint256 required);
    error UnexpectedSwapDelta(int128 deltaIn, int128 deltaOut);
    error TooMuchRequested(uint256 amountIn, uint256 amountInMax);
    error TooLittleReceived(uint256 output, uint256 amountOutMin);

    modifier nonReentrant() {
        bool locked;
        assembly ("memory-safe") {
            locked := tload(LOCK_SLOT)
            tstore(LOCK_SLOT, 1)
        }
        if (locked) revert Reentrancy();
        _;
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 0)
        }
    }

    constructor(IPoolManager _poolManager, ISpray _spray) {
        poolManager = _poolManager;
        spray = _spray;
    }

    /// @dev Native output and Spray's native refunds arrive here. Nothing else should send ETH.
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(spray)) revert UnexpectedSender(msg.sender);
    }

    /// @notice Swaps and pays `spec` from the swap's output
    /// @param params Negative `amountSpecified` is exact-input, positive is exact-output. For an
    /// exact-output AMOUNTS spec it must equal `requiredOutput(spec)`.
    /// @param amountLimit Minimum output on exact-input, maximum input on exact-output
    /// @param deadline Latest block timestamp at which the call may execute
    /// @return amountIn Input paid to the pool
    /// @return output Output produced by the swap
    function swapAndSpray(
        PoolKey memory key,
        SwapParams memory params,
        uint256 amountLimit,
        PayoutSpec memory spec,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountIn, uint256 output) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        spec.validate(address(spray));

        if (params.amountSpecified > 0 && spec.mode == PayoutSpecLib.MODE_AMOUNTS) {
            uint256 required = requiredOutput(spec);
            if (uint256(params.amountSpecified) != required) {
                revert ExactOutputMismatch(uint256(params.amountSpecified), required);
            }
        }

        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        if (!currencyIn.isAddressZero() && msg.value != 0) revert UnexpectedValue(msg.value);

        (amountIn, output) = abi.decode(
            poolManager.unlock(abi.encode(CallbackData(msg.sender, msg.value, key, params, amountLimit, spec))),
            (uint256, uint256)
        );

        if (currencyIn.isAddressZero() && msg.value > amountIn) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, msg.value - amountIn);
        }
    }

    /// @notice The exact output an AMOUNTS spec needs at Spray's live fee
    function requiredOutput(PayoutSpec memory spec) public view returns (uint256) {
        return SpraySettlement.requiredOutput(spec, spray.feeBps());
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        bool zeroForOne = data.params.zeroForOne;
        BalanceDelta delta = poolManager.swap(data.key, data.params, "");
        (int128 deltaIn, int128 deltaOut) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (deltaIn >= 0 || deltaOut <= 0) revert UnexpectedSwapDelta(deltaIn, deltaOut);

        uint256 amountIn = uint256(uint128(-deltaIn));
        uint256 output = uint256(uint128(deltaOut));

        if (data.params.amountSpecified > 0) {
            if (amountIn > data.amountLimit) revert TooMuchRequested(amountIn, data.amountLimit);
        } else if (output < data.amountLimit) {
            revert TooLittleReceived(output, data.amountLimit);
        }

        // Input is settled before Spray runs: recipients execute code during the unlock, and
        // PoolManager.sync is unguarded, so nothing may run between sync and settle.
        _settleInput(zeroForOne ? data.key.currency0 : data.key.currency1, data.sender, data.value, amountIn);

        Currency currencyOut = zeroForOne ? data.key.currency1 : data.key.currency0;
        poolManager.take(currencyOut, address(this), output);
        SpraySettlement.settle(spray, data.key.toId(), currencyOut, output, data.spec);

        return abi.encode(amountIn, output);
    }

    function _settleInput(Currency currency, address sender, uint256 value, uint256 amount) private {
        if (currency.isAddressZero()) {
            if (amount > value) revert InsufficientValue(value, amount);
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(sender, address(poolManager), amount);
            poolManager.settle();
        }
    }
}
