// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";

/// @notice Minimal constant-product AMM used as the protocol's price source.
/// @dev Reserves are stored in token order. `token0` is the quote asset (USDC),
///      `token1` is the base asset (WETH). Fee is fixed at 0.30%.
contract SimpleAMM {
    uint256 public constant FEE_NUMERATOR = 997;
    uint256 public constant FEE_DENOMINATOR = 1000;

    address public immutable token0;
    address public immutable token1;
    uint8 private immutable decimals0;
    uint8 private immutable decimals1;

    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;
    uint256 public price1CumulativeLast;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor(address tokenA, address tokenB) {
        require(tokenA != tokenB, "IDENTICAL");
        (address token0_, address token1_) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        token0 = token0_;
        token1 = token1_;
        decimals0 = IERC20(token0_).decimals();
        decimals1 = IERC20(token1_).decimals();
        blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /// @notice Price of one token1 expressed in token0, normalized to 18 decimals.
    function spotPrice1In0() public view returns (uint256) {
        if (reserve1 == 0) return 0;
        return (uint256(reserve0) * 10 ** decimals1 * 1e18) / (uint256(reserve1) * 10 ** decimals0);
    }

    /// @notice Price of one token0 expressed in token1, normalized to 18 decimals.
    function spotPrice0In1() public view returns (uint256) {
        if (reserve0 == 0) return 0;
        return (uint256(reserve1) * 10 ** decimals0 * 1e18) / (uint256(reserve0) * 10 ** decimals1);
    }

    /// @notice Accrue the token1-in-token0 price cumulative up to the current timestamp.
    function accrue() public {
        uint32 timestamp = uint32(block.timestamp);
        uint32 elapsed = timestamp - blockTimestampLast;
        if (elapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            price1CumulativeLast += spotPrice1In0() * elapsed;
            blockTimestampLast = timestamp;
        }
    }

    function addLiquidity(uint256 amount0, uint256 amount1) external returns (uint256 shares) {
        accrue();

        uint256 supply = totalSupply;
        if (supply == 0) {
            shares = _sqrt(amount0 * amount1);
        } else {
            shares = _min((amount0 * supply) / reserve0, (amount1 * supply) / reserve1);
        }
        require(shares > 0, "ZERO_SHARES");

        IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1);

        totalSupply = supply + shares;
        balanceOf[msg.sender] += shares;

        _update();
        emit Mint(msg.sender, amount0, amount1);
    }

    function removeLiquidity(uint256 shares, address to) external returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "ZERO_SHARES");
        accrue();

        uint256 supply = totalSupply;
        amount0 = (uint256(reserve0) * shares) / supply;
        amount1 = (uint256(reserve1) * shares) / supply;
        require(amount0 > 0 && amount1 > 0, "ZERO_OUT");

        balanceOf[msg.sender] -= shares;
        totalSupply = supply - shares;

        IERC20(token0).transfer(to, amount0);
        IERC20(token1).transfer(to, amount1);

        _update();
        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 minAmountOut, address tokenIn, address to)
        external
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "ZERO_IN");
        require(to != address(0), "ZERO_TO");

        accrue();

        bool zeroForOne = tokenIn == token0;
        require(zeroForOne || tokenIn == token1, "BAD_TOKEN");

        uint112 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint112 reserveOut = zeroForOne ? reserve1 : reserve0;
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut > 0 && amountOut < reserveOut, "BAD_OUT");
        require(amountOut >= minAmountOut, "SLIPPAGE");

        address tokenOut = zeroForOne ? token1 : token0;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(to, amountOut);

        _update();

        emit Swap(
            msg.sender,
            zeroForOne ? amountIn : 0,
            zeroForOne ? 0 : amountIn,
            zeroForOne ? 0 : amountOut,
            zeroForOne ? amountOut : 0,
            to
        );
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        require(amountIn > 0 && reserveIn > 0 && reserveOut > 0, "BAD_RESERVES");
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        return (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    function _update() private {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "OVERFLOW");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        emit Sync(reserve0, reserve1);
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
