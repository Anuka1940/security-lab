// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

/// @notice Returns the value of 1 unit of `baseAsset` denominated in `quoteAsset`, scaled to 1e18.
interface IOracleFeed {
    function readPrice() external returns (uint256);
    function baseAsset() external view returns (address);
    function quoteAsset() external view returns (address);
}
