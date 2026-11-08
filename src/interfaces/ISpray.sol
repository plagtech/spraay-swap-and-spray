// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal interface for SprayContract v2 (skip-on-fail) on Base,
/// 0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c. Signatures are taken from the verified source
/// (plagtech/spraay-uniswap-v4-hook tag v2.0.0, src/SprayContract.sol).
/// @dev A successful call does not mean every recipient was paid. Undelivered amounts and their
/// unused fee are pushed back to `msg.sender` inside the call. There is no refund ledger.
interface ISpray {
    struct Recipient {
        address payable recipient;
        uint256 amount;
    }

    function sprayETH(Recipient[] calldata recipients) external payable returns (uint256 failedCount);

    function sprayToken(address token, Recipient[] calldata recipients) external returns (uint256 failedCount);

    function feeBps() external view returns (uint256);
}
