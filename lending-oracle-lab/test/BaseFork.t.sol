// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {SpotPriceOracle} from "../src/SpotPriceOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {FlashLoanPool} from "../src/FlashLoanPool.sol";
import {OracleAttackReceiver} from "../src/OracleAttackReceiver.sol";

/// @notice Shared deterministic mainnet-fork harness.
/// @dev Real USDC (6 decimals) and WETH (18 decimals) are used to keep decimal
///      normalization honest. The AMM and protocol are deployed locally.
abstract contract BaseForkTest is Test {
    uint256 internal constant DEFAULT_FORK_BLOCK = 26_000_000;
    uint256 internal constant BPS = 10_000;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 internal constant AMM_USDC_RESERVE = 2_000_000e6;
    uint256 internal constant AMM_WETH_RESERVE = 1_000e18;
    uint256 internal constant POOL_USDC_LIQUIDITY = 5_000_000e6;
    uint256 internal constant FLASH_POOL_LIQUIDITY = 2_000_000e6;
    uint256 internal constant LTV_BPS = 8_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_500;
    uint256 internal constant FLASH_FEE_BPS = 9;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");
    address internal keeper = makeAddr("keeper");

    SimpleAMM internal amm;
    SpotPriceOracle internal oracle;
    LendingPool internal lendingPool;
    FlashLoanPool internal flashPool;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_FORKING_URL"), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));

        startHoax(deployer);
        amm = new SimpleAMM(USDC, WETH);
        oracle = new SpotPriceOracle(address(amm), WETH, USDC);
        lendingPool = new LendingPool(WETH, USDC, address(oracle), LTV_BPS, LIQUIDATION_THRESHOLD_BPS);
        flashPool = new FlashLoanPool(USDC, FLASH_FEE_BPS);

        deal(USDC, deployer, AMM_USDC_RESERVE + POOL_USDC_LIQUIDITY + FLASH_POOL_LIQUIDITY + 10_000_000e6);
        deal(WETH, deployer, AMM_WETH_RESERVE + 10_000e18);

        IERC20(USDC).approve(address(amm), AMM_USDC_RESERVE);
        IERC20(WETH).approve(address(amm), AMM_WETH_RESERVE);
        amm.addLiquidity(AMM_USDC_RESERVE, AMM_WETH_RESERVE);

        IERC20(USDC).transfer(address(lendingPool), POOL_USDC_LIQUIDITY);
        IERC20(USDC).transfer(address(flashPool), FLASH_POOL_LIQUIDITY);

        vm.stopPrank();
    }

    function _deposit(address account, uint256 wethAmount) internal {
        deal(WETH, account, wethAmount);
        vm.startPrank(account);
        IERC20(WETH).approve(address(lendingPool), wethAmount);
        lendingPool.deposit(wethAmount);
        vm.stopPrank();
    }

    function _fundReceiver(address receiver, uint256 usdcAmount) internal {
        deal(USDC, receiver, usdcAmount);
    }

    function _deployReceiver() internal returns (OracleAttackReceiver receiver) {
        receiver =
            new OracleAttackReceiver(USDC, WETH, address(amm), address(lendingPool), address(flashPool), attacker);
    }
}
