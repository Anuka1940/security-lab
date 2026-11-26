// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

interface ISimpleAMM {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function reserve0() external view returns (uint112);
    function reserve1() external view returns (uint112);
    function price1CumulativeLast() external view returns (uint256);
    function accrue() external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function spotPrice1In0() external view returns (uint256);
    function spotPrice0In1() external view returns (uint256);
    function swapExactTokensForTokens(uint256 amountIn, uint256 minAmountOut, address tokenIn, address to)
        external
        returns (uint256 amountOut);
}
