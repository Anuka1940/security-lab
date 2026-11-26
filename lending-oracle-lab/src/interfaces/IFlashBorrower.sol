// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

/// @notice Callback interface for contracts receiving atomic flash liquidity.
interface IFlashLoanCallback {
    function executeOperation(
        address caller,
        address asset,
        uint256 principal,
        uint256 feeAmount,
        bytes calldata payload
    ) external returns (bytes32);
}
