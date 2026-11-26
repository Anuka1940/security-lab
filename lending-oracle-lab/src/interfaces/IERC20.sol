// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

/// @notice Minimal ERC-20 interface including token decimals for value scaling.
interface IERC20 {
    event Transfer(address indexed sender, address indexed recipient, uint256 value);
    event Approval(address indexed holder, address indexed operator, uint256 allowanceAmount);

    function totalSupply() external view returns (uint256);
    function balanceOf(address holder) external view returns (uint256);
    function allowance(address holder, address operator) external view returns (uint256);
    function approve(address operator, uint256 value) external returns (bool);
    function transfer(address recipient, uint256 value) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}
