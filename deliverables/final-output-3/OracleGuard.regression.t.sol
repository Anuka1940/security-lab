// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {BaseForkFixedTest} from "./BaseForkFixed.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {OracleAttackReceiver} from "../src/OracleAttackReceiver.sol";
import {TwapPriceOracle} from "../src/oracle/TwapPriceOracle.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";

contract OracleGuardRegressionTest is BaseForkFixedTest {
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    function test_initialState() public {
        assertEq(oracle.getPrice(), 2_000e18);
        assertEq(amm.spotPrice1In0(), 2_000e18);
        assertEq(oracle.observationCount_(), 3);
        assertEq(lendingPool.totalCollateral(), 0);
        assertEq(lendingPool.totalDebt(), 0);
        assertEq(IERC20(USDC).balanceOf(address(lendingPool)), POOL_USDC_LIQUIDITY);
    }

    function test_legitimateBorrowRepayWithdraw() public {
        _deposit(alice, 100e18);
        uint256 maxBorrow = lendingPool.maxBorrow(alice);
        assertEq(maxBorrow, 160_000e6);

        vm.startPrank(alice);
        lendingPool.borrow(100_000e6);
        assertEq(lendingPool.debt(alice), 100_000e6);
        assertGt(lendingPool.healthFactor(alice), 1e18);

        IERC20(USDC).approve(address(lendingPool), 100_000e6);
        lendingPool.repay(100_000e6);
        lendingPool.withdraw(100e18);
        vm.stopPrank();

        assertEq(lendingPool.debt(alice), 0);
        assertEq(lendingPool.collateralBalance(alice), 0);
        assertEq(IERC20(WETH).balanceOf(alice), 100e18);
    }

    function test_repayIsCappedAtDebt() public {
        _deposit(alice, 100e18);
        vm.startPrank(alice);
        lendingPool.borrow(100_000e6);
        deal(USDC, alice, 150_000e6);
        IERC20(USDC).approve(address(lendingPool), 150_000e6);
        lendingPool.repay(150_000e6);
        assertEq(lendingPool.debt(alice), 0);
        assertEq(IERC20(USDC).balanceOf(alice), 50_000e6);
        vm.stopPrank();
    }

    function test_withdrawBelowHealthReverts() public {
        _deposit(alice, 100e18);
        vm.startPrank(alice);
        lendingPool.borrow(150_000e6);
        vm.expectRevert(LendingPool.Undercollateralized.selector);
        lendingPool.withdraw(25e18);
        vm.stopPrank();
    }

    function test_sameBlockFlashPumpRevertsOnDeviation() public {
        OracleAttackReceiver receiver = _deployReceiver(address(lendingPool));

        vm.expectRevert();
        receiver.attack(2_000_000e6);
    }

    function test_twapOnlyAttackCannotOverBorrow() public {
        TwapPriceOracle twapOnly = _newOracle(50_000);
        _warmUp(twapOnly);
        LendingPool twapOnlyPool = _newPool(address(twapOnly));
        deal(USDC, address(twapOnlyPool), POOL_USDC_LIQUIDITY);
        _depositTo(address(twapOnlyPool), alice, 500e18);

        uint256 safeMax = twapOnlyPool.maxBorrow(alice);
        OracleAttackReceiver receiver = _deployReceiver(address(twapOnlyPool));
        _fund(address(receiver), 1_300_000e6);

        receiver.attack(2_000_000e6);

        uint256 borrowed = receiver.borrowedAgainstCollateral();
        uint256 debt = twapOnlyPool.debt(address(receiver));
        uint256 collateralValue = twapOnlyPool.collateralValue(address(receiver));
        uint256 health = twapOnlyPool.healthFactor(address(receiver));

        assertLe(borrowed, safeMax);
        assertEq(debt, borrowed);
        assertLe(debt, collateralValue);
        assertGe(health, 1e18);
        assertApproxEqRel(borrowed, 798_000e6, 0.002e18);
    }

    function test_staleOracleRevertsOnBorrow() public {
        _deposit(alice, 100e18);
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TwapPriceOracle.OracleStale.selector, MAX_STALENESS + 1));
        lendingPool.borrow(1_000e6);
    }

    function test_missingRecentObservationReverts() public {
        vm.warp(block.timestamp + TWAP_WINDOW + 5 minutes);

        vm.expectRevert(TwapPriceOracle.NoRecentObservation.selector);
        oracle.getPrice();
    }

    function test_moderateVolatilityIsAccepted() public {
        OracleAttackReceiver receiver = _deployReceiver(address(lendingPool));
        _fund(address(receiver), 100_000e6);

        receiver.attack(140_000e6);

        uint256 deviationBps = ((_currentSpot() - 2_000e18) * 10_000) / 2_000e18;
        assertLt(deviationBps, MAX_DEVIATION_BPS);
        assertGt(receiver.borrowedAgainstCollateral(), 0);
        assertLe(receiver.borrowedAgainstCollateral(), 112_000e6);
    }

    function test_priceBoundsRejected() public {
        TwapPriceOracle narrow = new TwapPriceOracle(
            address(amm), WETH, USDC, TWAP_WINDOW, MIN_UPDATE_INTERVAL, MAX_STALENESS, 0, 3_000e18, 4_000e18
        );
        _warmUp(narrow);

        vm.expectRevert(abi.encodeWithSelector(TwapPriceOracle.PriceOutOfBounds.selector, 2_000e18));
        narrow.getPrice();
    }

    function test_updateRateLimit() public {
        vm.expectRevert(TwapPriceOracle.UpdateTooSoon.selector);
        oracle.update();
    }

    function test_decimalNormalizationAtBorrowBoundary() public {
        _deposit(alice, 100e18);
        assertEq(lendingPool.maxBorrow(alice), 160_000e6);

        vm.startPrank(alice);
        lendingPool.borrow(160_000e6);
        assertEq(lendingPool.debt(alice), 160_000e6);

        vm.expectRevert(LendingPool.ExceedsMaxBorrow.selector);
        lendingPool.borrow(1);
        vm.stopPrank();
    }

    function test_chainlinkAlternativeNormalizesAndChecksStaleness() public {
        ChainlinkPriceOracle chainlink =
            new ChainlinkPriceOracle(CHAINLINK_ETH_USD, WETH, USDC, 2 hours, MIN_PRICE, MAX_PRICE);

        uint256 price = chainlink.getPrice();
        assertGt(price, 1_000e18);
        assertLt(price, 10_000e18);

        vm.warp(block.timestamp + 3 hours);
        vm.expectRevert();
        chainlink.getPrice();
    }

    function test_constructorRejectsInvalidConfiguration() public {
        vm.expectRevert("WINDOW_TOO_SHORT");
        new TwapPriceOracle(
            address(amm), WETH, USDC, 40, MIN_UPDATE_INTERVAL, MAX_STALENESS, MAX_DEVIATION_BPS, MIN_PRICE, MAX_PRICE
        );

        vm.expectRevert("BAD_BOUNDS");
        new TwapPriceOracle(
            address(amm), WETH, USDC, TWAP_WINDOW, MIN_UPDATE_INTERVAL, MAX_STALENESS, MAX_DEVIATION_BPS, 0, MAX_PRICE
        );
    }
}
