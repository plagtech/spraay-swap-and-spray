// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PayoutSpec} from "../../src/libraries/PayoutSpec.sol";

abstract contract SpecHelpers {
    uint256 internal constant SPRAY_FEE_BPS = 30;

    /// @dev Keyless addresses that have never held a balance, the most expensive case for a transfer
    function _freshRecipients(uint256 count, uint256 salt) internal pure returns (address[] memory recipients) {
        recipients = new address[](count);
        for (uint256 i; i < count; ++i) {
            recipients[i] = address(uint160(uint256(keccak256(abi.encode("spraay.recipient", salt, i)))));
        }
    }

    function _equalBps(uint256 count) internal pure returns (uint256[] memory bps) {
        bps = new uint256[](count);
        uint256 each = 10_000 / count;
        for (uint256 i; i < count; ++i) {
            bps[i] = i == count - 1 ? 10_000 - each * (count - 1) : each;
        }
    }

    function _filled(uint256 count, uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            values[i] = value;
        }
    }

    function _sum(uint256[] memory values) internal pure returns (uint256 total) {
        for (uint256 i; i < values.length; ++i) {
            total += values[i];
        }
    }

    function _fee(uint256 total) internal pure returns (uint256) {
        return (total * SPRAY_FEE_BPS) / 10_000;
    }

    function _shares(address payer, address[] memory recipients) internal pure returns (PayoutSpec memory) {
        return PayoutSpec(0, payer, 0, SPRAY_FEE_BPS, recipients, _equalBps(recipients.length));
    }

    function _amounts(address payer, address[] memory recipients, uint256[] memory values)
        internal
        pure
        returns (PayoutSpec memory)
    {
        return PayoutSpec(1, payer, 0, SPRAY_FEE_BPS, recipients, values);
    }

    function _pair(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _triple(address a, address b, address c) internal pure returns (address[] memory list) {
        list = new address[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }
}
