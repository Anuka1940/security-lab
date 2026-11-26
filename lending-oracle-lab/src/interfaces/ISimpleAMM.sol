// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

/// @notice Interface for the constant-product liquidity pool and cumulative price tracker.
interface IConstantProductPool {
    function asset0() external view returns (address);
    function asset1() external view returns (address);
    function poolReserve0() external view returns (uint112);
    function poolReserve1() external view returns (uint112);
    function cumulativePrice1() external view returns (uint256);
    function syncAccumulator() external;
    function currentReserves() external view returns (uint112, uint112, uint32);
    function quoteAsset1InAsset0() external view returns (uint256);
    function quoteAsset0InAsset1() external view returns (uint256);
    function swapExactIn(uint256 amountIn, uint256 minOut, address tokenIn, address recipient)
        external
        returns (uint256 amountOut);
}
