// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {IConstantProductPool} from "./interfaces/ISimpleAMM.sol";

/// @notice Constant-product automated market maker with a 0.30% swap fee.
/// @dev Token addresses are sorted at construction: `asset0` is the lower address (USDC on mainnet)
///      and `asset1` is the higher address (WETH on mainnet).
contract ConstantProductPool is IConstantProductPool {
    uint256 public constant SWAP_FEE_KEEP = 997;
    uint256 public constant FEE_SCALE = 1000;

    address public immutable asset0;
    address public immutable asset1;
    uint8 private immutable decimals0;
    uint8 private immutable decimals1;

    uint112 public poolReserve0;
    uint112 public poolReserve1;

    uint256 public totalLpShares;
    mapping(address => uint256) public lpSharesOf;

    event LiquidityProvided(address indexed provider, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, address indexed recipient);
    event TokenSwapped(
        address indexed trader,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed recipient
    );
    event ReservesUpdated(uint112 reserve0, uint112 reserve1);

    constructor(address tokenA, address tokenB) {
        require(tokenA != tokenB, "DUPLICATE_TOKEN");
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        asset0 = sorted0;
        asset1 = sorted1;
        decimals0 = IERC20(sorted0).decimals();
        decimals1 = IERC20(sorted1).decimals();
    }

    function currentReserves() external view returns (uint112, uint112) {
        return (poolReserve0, poolReserve1);
    }

    /// @notice Instantaneous price of 1 unit of `asset1` in terms of `asset0`, scaled to 1e18.
    function quoteAsset1InAsset0() public view returns (uint256) {
        if (poolReserve1 == 0) return 0;
        return (uint256(poolReserve0) * (10 ** decimals1) * 1e18) / (uint256(poolReserve1) * (10 ** decimals0));
    }

    /// @notice Instantaneous price of 1 unit of `asset0` in terms of `asset1`, scaled to 1e18.
    function quoteAsset0InAsset1() public view returns (uint256) {
        if (poolReserve0 == 0) return 0;
        return (uint256(poolReserve1) * (10 ** decimals0) * 1e18) / (uint256(poolReserve0) * (10 ** decimals1));
    }

    function provideLiquidity(uint256 deposit0, uint256 deposit1) external returns (uint256 mintedShares) {
        uint256 existingShares = totalLpShares;
        if (existingShares == 0) {
            mintedShares = _integerSqrt(deposit0 * deposit1);
        } else {
            uint256 share0 = (deposit0 * existingShares) / poolReserve0;
            uint256 share1 = (deposit1 * existingShares) / poolReserve1;
            mintedShares = share0 < share1 ? share0 : share1;
        }
        require(mintedShares > 0, "INSUFFICIENT_LP_MINT");

        IERC20(asset0).transferFrom(msg.sender, address(this), deposit0);
        IERC20(asset1).transferFrom(msg.sender, address(this), deposit1);

        totalLpShares = existingShares + mintedShares;
        lpSharesOf[msg.sender] += mintedShares;

        _refreshReserves();
        emit LiquidityProvided(msg.sender, deposit0, deposit1);
    }

    function withdrawLiquidity(uint256 sharesToBurn, address recipient)
        external
        returns (uint256 out0, uint256 out1)
    {
        require(sharesToBurn > 0, "ZERO_LP_BURN");

        uint256 existingShares = totalLpShares;
        out0 = (uint256(poolReserve0) * sharesToBurn) / existingShares;
        out1 = (uint256(poolReserve1) * sharesToBurn) / existingShares;
        require(out0 > 0 && out1 > 0, "EMPTY_WITHDRAWAL");

        lpSharesOf[msg.sender] -= sharesToBurn;
        totalLpShares = existingShares - sharesToBurn;

        IERC20(asset0).transfer(recipient, out0);
        IERC20(asset1).transfer(recipient, out1);

        _refreshReserves();
        emit LiquidityRemoved(msg.sender, out0, out1, recipient);
    }

    function swapExactIn(uint256 amountIn, uint256 minOut, address tokenIn, address recipient)
        external
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "ZERO_SWAP_INPUT");
        require(recipient != address(0), "INVALID_RECIPIENT");

        bool sellingAsset0 = tokenIn == asset0;
        require(sellingAsset0 || tokenIn == asset1, "UNSUPPORTED_ASSET");

        uint112 reserveIn = sellingAsset0 ? poolReserve0 : poolReserve1;
        uint112 reserveOut = sellingAsset0 ? poolReserve1 : poolReserve0;
        amountOut = computeSwapOutput(amountIn, reserveIn, reserveOut);
        require(amountOut > 0 && amountOut < reserveOut, "INVALID_SWAP_OUTPUT");
        require(amountOut >= minOut, "SLIPPAGE_EXCEEDED");

        address tokenOut = sellingAsset0 ? asset1 : asset0;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(recipient, amountOut);

        _refreshReserves();

        emit TokenSwapped(
            msg.sender,
            sellingAsset0 ? amountIn : 0,
            sellingAsset0 ? 0 : amountIn,
            sellingAsset0 ? 0 : amountOut,
            sellingAsset0 ? amountOut : 0,
            recipient
        );
    }

    function computeSwapOutput(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256)
    {
        require(amountIn > 0 && reserveIn > 0 && reserveOut > 0, "EMPTY_RESERVES");
        uint256 netInput = amountIn * SWAP_FEE_KEEP;
        return (netInput * reserveOut) / (reserveIn * FEE_SCALE + netInput);
    }

    function _refreshReserves() private {
        uint256 actual0 = IERC20(asset0).balanceOf(address(this));
        uint256 actual1 = IERC20(asset1).balanceOf(address(this));
        require(actual0 <= type(uint112).max && actual1 <= type(uint112).max, "RESERVE_OVERFLOW");
        poolReserve0 = uint112(actual0);
        poolReserve1 = uint112(actual1);
        emit ReservesUpdated(poolReserve0, poolReserve1);
    }

    function _integerSqrt(uint256 value) private pure returns (uint256 root) {
        if (value > 3) {
            root = value;
            uint256 estimate = value / 2 + 1;
            while (estimate < root) {
                root = estimate;
                estimate = (value / estimate + estimate) / 2;
            }
        } else if (value != 0) {
            root = 1;
        }
    }
}
