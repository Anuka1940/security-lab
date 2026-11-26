// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

/// @notice Interface for collateralized borrowing markets.
interface ICreditMarket {
    function supplyCollateral(uint256 amount) external;
    function redeemCollateral(uint256 amount) external;
    function drawDebt(uint256 amount) external;
    function settleDebt(uint256 amount) external;
    function availableCredit(address borrower) external returns (uint256);
    function suppliedCollateral(address borrower) external view returns (uint256);
    function borrowedDebt(address borrower) external view returns (uint256);
}
