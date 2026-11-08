// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {SwapAndSprayRouter} from "../../src/SwapAndSprayRouter.sol";
import {PayoutSpec} from "../../src/libraries/PayoutSpec.sol";
import {ForkBase} from "./ForkBase.sol";

/// @notice Router gas with a real swap and real USDC to never-funded recipients.
/// Run with --isolate so each call is costed as its own transaction. See GAS.md.
contract RouterGasTest is ForkBase {
    uint256 internal constant AMOUNT_EACH = 100_000; // 0.10 USDC

    function _spec(uint256 count) internal view returns (PayoutSpec memory) {
        return _amounts(payer, _freshRecipients(count, 7000 + count), _filled(count, AMOUNT_EACH));
    }

    function _measure(uint256 count) internal {
        PayoutSpec memory spec = _spec(count);
        uint256 required = (count * AMOUNT_EACH) + _fee(count * AMOUNT_EACH);
        uint256 maxIn = 0.5 ether;
        vm.deal(address(this), 10 ether);

        router.swapAndSpray{value: maxIn}(ethUsdc, _exactOutEthToUsdc(required), maxIn, spec, block.timestamp);
        uint256 frame = vm.lastFrameGas().gasTotalUsed;

        bytes memory data = abi.encodeCall(
            SwapAndSprayRouter.swapAndSpray, (ethUsdc, _exactOutEthToUsdc(required), maxIn, spec, block.timestamp)
        );
        console2.log("router recipients", count);
        console2.log("  frame gas", frame);
        console2.log("  intrinsic gas", _intrinsicGas(data));
        console2.log("  calldata bytes", data.length);
        assertEq(
            _usdc(address(uint160(uint256(keccak256(abi.encode("spraay.recipient", 7000 + count, count - 1)))))),
            AMOUNT_EACH
        );
    }

    /// @dev Spray needs 150,000 gas left before every transfer, so the gas limit a transaction must
    /// set is higher than the gas it uses. This bisects for the true minimum.
    function test_Gas_Router_200_MinimumGasLimit() public onlyBase {
        uint256 count = 200;
        PayoutSpec memory spec = _spec(count);
        uint256 required = (count * AMOUNT_EACH) + _fee(count * AMOUNT_EACH);
        SwapParams memory params = _exactOutEthToUsdc(required);
        vm.deal(address(this), 10 ether);

        uint256 failing = 6_000_000;
        uint256 passing = GAS_CEILING;
        assertFalse(_succeedsWith(failing, params, spec), "lower bound must fail");
        assertTrue(_succeedsWith(passing, params, spec), "upper bound must pass");
        while (passing - failing > 500) {
            uint256 middle = (passing + failing) / 2;
            if (_succeedsWith(middle, params, spec)) passing = middle;
            else failing = middle;
        }

        bytes memory data =
            abi.encodeCall(SwapAndSprayRouter.swapAndSpray, (ethUsdc, params, 0.5 ether, spec, block.timestamp));
        console2.log("router 200 minimum forwarded gas", passing);
        console2.log("router 200 minimum transaction gas limit", passing + _intrinsicGas(data));
        assertLt(passing + _intrinsicGas(data), GAS_CEILING, "minimum limit is under the 70% ceiling");
    }

    function _succeedsWith(uint256 gasLimit, SwapParams memory params, PayoutSpec memory spec)
        internal
        returns (bool ok)
    {
        uint256 snapshot = vm.snapshotState();
        try router.swapAndSpray{value: 0.5 ether, gas: gasLimit}(ethUsdc, params, 0.5 ether, spec, block.timestamp) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.revertToState(snapshot);
    }

    function test_Gas_Router_010() public onlyBase {
        _measure(10);
    }

    function test_Gas_Router_050() public onlyBase {
        _measure(50);
    }

    function test_Gas_Router_100() public onlyBase {
        _measure(100);
    }

    function test_Gas_Router_150() public onlyBase {
        _measure(150);
    }

    function test_Gas_Router_200() public onlyBase {
        _measure(200);
    }
}
