// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {LendingPool} from "../src/LendingPoolFix.sol";
import {FlashLoanPool} from "../src/FlashLoanPool.sol";
import {OracleAttackReceiver} from "../src/OracleAttackReceiver.sol";
import {TwapPriceOracle} from "../src/oracle/TwapPriceOracle.sol";

abstract contract BaseForkFixedTest is Test {
    uint256 internal constant DEFAULT_FORK_BLOCK = 26_000_000;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 internal constant AMM_USDC_RESERVE = 2_000_000e6;
    uint256 internal constant AMM_WETH_RESERVE = 1_000e18;
    uint256 internal constant POOL_USDC_LIQUIDITY = 5_000_000e6;
    uint256 internal constant FLASH_POOL_LIQUIDITY = 2_000_000e6;
    uint256 internal constant LTV_BPS = 8_000;
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 8_500;
    uint256 internal constant FLASH_FEE_BPS = 9;

    uint32 internal constant TWAP_WINDOW = 30 minutes;
    uint32 internal constant MIN_UPDATE_INTERVAL = 5 minutes;
    uint32 internal constant MAX_STALENESS = 40 minutes;
    uint256 internal constant MAX_DEVIATION_BPS = 1_500;
    uint256 internal constant MIN_PRICE = 100e18;
    uint256 internal constant MAX_PRICE = 100_000e18;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal keeper = makeAddr("keeper");

    SimpleAMM internal amm;
    TwapPriceOracle internal oracle;
    LendingPool internal lendingPool;
    FlashLoanPool internal flashPool;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_FORKING_URL"), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));

        startHoax(deployer);
        amm = new SimpleAMM(USDC, WETH);
        flashPool = new FlashLoanPool(USDC, FLASH_FEE_BPS);
        oracle = _newOracle(MAX_DEVIATION_BPS);
        lendingPool = _newPool(address(oracle));

        deal(USDC, deployer, AMM_USDC_RESERVE + POOL_USDC_LIQUIDITY + FLASH_POOL_LIQUIDITY + 50_000_000e6);
        deal(WETH, deployer, AMM_WETH_RESERVE + 50_000e18);

        IERC20(USDC).approve(address(amm), AMM_USDC_RESERVE);
        IERC20(WETH).approve(address(amm), AMM_WETH_RESERVE);
        amm.addLiquidity(AMM_USDC_RESERVE, AMM_WETH_RESERVE);

        IERC20(USDC).transfer(address(lendingPool), POOL_USDC_LIQUIDITY);
        IERC20(USDC).transfer(address(flashPool), FLASH_POOL_LIQUIDITY);

        _warmUp(oracle);
        vm.stopPrank();
    }

    function _newOracle(uint256 maxDeviationBps) internal returns (TwapPriceOracle oracle_) {
        oracle_ = new TwapPriceOracle(
            address(amm),
            WETH,
            USDC,
            TWAP_WINDOW,
            MIN_UPDATE_INTERVAL,
            MAX_STALENESS,
            maxDeviationBps,
            MIN_PRICE,
            MAX_PRICE
        );
    }

    function _newPool(address oracle_) internal returns (LendingPool pool) {
        pool = new LendingPool(WETH, USDC, oracle_, LTV_BPS, LIQUIDATION_THRESHOLD_BPS);
    }

    function _warmUp(TwapPriceOracle oracle_) internal {
        vm.warp(block.timestamp + TWAP_WINDOW);
        oracle_.update();
        vm.warp(block.timestamp + TWAP_WINDOW);
        oracle_.update();
    }

    function _syncOracle() internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        oracle.update();
    }

    function _deposit(address account, uint256 wethAmount) internal {
        deal(WETH, account, wethAmount);
        vm.startPrank(account);
        IERC20(WETH).approve(address(lendingPool), wethAmount);
        lendingPool.deposit(wethAmount);
        vm.stopPrank();
    }

    function _depositTo(address pool, address account, uint256 wethAmount) internal {
        deal(WETH, account, wethAmount);
        vm.startPrank(account);
        IERC20(WETH).approve(pool, wethAmount);
        LendingPool(pool).deposit(wethAmount);
        vm.stopPrank();
    }

    function _pump(uint256 usdcAmount) internal returns (uint256 wethOut) {
        deal(USDC, keeper, usdcAmount);
        vm.startPrank(keeper);
        IERC20(USDC).approve(address(amm), usdcAmount);
        wethOut = amm.swapExactTokensForTokens(usdcAmount, 0, USDC, keeper);
        vm.stopPrank();
    }

    function _dump(uint256 wethAmount) internal {
        deal(WETH, keeper, wethAmount);
        vm.startPrank(keeper);
        IERC20(WETH).approve(address(amm), wethAmount);
        amm.swapExactTokensForTokens(wethAmount, 0, WETH, keeper);
        vm.stopPrank();
    }

    function _deployReceiver(address pool) internal returns (OracleAttackReceiver receiver) {
        receiver = new OracleAttackReceiver(USDC, WETH, address(amm), pool, address(flashPool), attacker);
    }

    function _fund(address account, uint256 usdcAmount) internal {
        deal(USDC, account, usdcAmount);
    }

    function _currentSpot() internal view returns (uint256) {
        return amm.spotPrice1In0();
    }
}
