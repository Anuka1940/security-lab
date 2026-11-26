// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

interface ILendingPool {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function borrow(uint256 amount) external;
    function repay(uint256 amount) external;
    function maxBorrow(address account) external returns (uint256);
    function collateralBalance(address account) external view returns (uint256);
    function debt(address account) external view returns (uint256);
}
