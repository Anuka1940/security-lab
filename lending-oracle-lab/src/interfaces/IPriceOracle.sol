// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

/// @notice Price of one unit of `base` in `quote`, normalized to 18 decimals.
interface IPriceOracle {
    function getPrice() external returns (uint256);
    function base() external view returns (address);
    function quote() external view returns (address);
}
