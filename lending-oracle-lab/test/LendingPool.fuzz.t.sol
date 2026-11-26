// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {BaseForkFixedTest} from "./BaseForkFixed.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {LendingPool} from "../src/LendingPool.sol";

contract LendingPoolFuzzTest is BaseForkFixedTest {
    uint256 internal constant PRICE = 2_000e18;
    uint256 internal constant USDC_SCALE = 1e12;

    function testFuzz_borrowWithinLtv(uint256 collateralSeed, uint256 fractionSeed) public {
        uint256 collateral = bound(collateralSeed, 0.1e18, 1_000e18);
        uint256 value6 = (collateral * PRICE) / 1e18 / USDC_SCALE;
        uint256 maxBorrow = (value6 * LTV_BPS) / 10_000;
        uint256 borrowAmount = (maxBorrow * bound(fractionSeed, 1, 10_000)) / 10_000;

        _deposit(alice, collateral);
        assertEq(lendingPool.maxBorrow(alice), maxBorrow);

        vm.prank(alice);
        lendingPool.borrow(borrowAmount);

        assertEq(lendingPool.debt(alice), borrowAmount);
        assertEq(lendingPool.totalDebt(), borrowAmount);
        assertEq(IERC20(USDC).balanceOf(alice), borrowAmount);
    }

    function testFuzz_oneAboveMaxReverts(uint256 collateralSeed) public {
        uint256 collateral = bound(collateralSeed, 0.1e18, 1_000e18);
        _deposit(alice, collateral);

        uint256 maxBorrow = lendingPool.maxBorrow(alice);
        vm.prank(alice);
        vm.expectRevert();
        lendingPool.borrow(maxBorrow + 1);
    }

    function testFuzz_repayThenWithdrawRoundTrip(uint256 collateralSeed, uint256 fractionSeed) public {
        uint256 collateral = bound(collateralSeed, 1e18, 1_000e18);
        _deposit(alice, collateral);

        uint256 maxBorrow = lendingPool.maxBorrow(alice);
        uint256 borrowAmount = (maxBorrow * bound(fractionSeed, 1, 10_000)) / 10_000;

        vm.startPrank(alice);
        lendingPool.borrow(borrowAmount);
        IERC20(USDC).approve(address(lendingPool), borrowAmount);
        lendingPool.repay(borrowAmount);
        lendingPool.withdraw(collateral);
        vm.stopPrank();

        assertEq(lendingPool.debt(alice), 0);
        assertEq(lendingPool.collateralBalance(alice), 0);
        assertEq(IERC20(WETH).balanceOf(alice), collateral);
    }

    function testFuzz_partialRepay(uint256 collateralSeed, uint256 borrowFraction, uint256 repayFraction) public {
        uint256 collateral = bound(collateralSeed, 1e18, 1_000e18);
        _deposit(alice, collateral);

        uint256 maxBorrow = lendingPool.maxBorrow(alice);
        uint256 borrowAmount = (maxBorrow * bound(borrowFraction, 1, 10_000)) / 10_000;
        if (borrowAmount == 0) return;

        uint256 repayAmount = (borrowAmount * bound(repayFraction, 1, 10_000)) / 10_000;

        vm.startPrank(alice);
        lendingPool.borrow(borrowAmount);
        IERC20(USDC).approve(address(lendingPool), repayAmount);
        lendingPool.repay(repayAmount);
        vm.stopPrank();

        assertEq(lendingPool.debt(alice), borrowAmount - repayAmount);
        assertEq(IERC20(USDC).balanceOf(alice), borrowAmount - repayAmount);
    }

    function testFuzz_withdrawPreservesThreshold(
        uint256 collateralSeed,
        uint256 borrowFraction,
        uint256 withdrawFraction
    ) public {
        uint256 collateral = bound(collateralSeed, 100e18, 1_000e18);
        _deposit(alice, collateral);

        uint256 maxBorrow = lendingPool.maxBorrow(alice);
        uint256 borrowAmount = (maxBorrow * bound(borrowFraction, 1, 10_000)) / 10_000;

        vm.prank(alice);
        lendingPool.borrow(borrowAmount);

        uint256 minCollateral =
            _ceilDiv(borrowAmount * USDC_SCALE * 1e18 * 10_000, PRICE * LIQUIDATION_THRESHOLD_BPS) + 1e12;
        uint256 withdrawable = collateral > minCollateral ? collateral - minCollateral : 0;
        uint256 toWithdraw = (withdrawable * bound(withdrawFraction, 0, 10_000)) / 10_000;

        if (toWithdraw > 0) {
            vm.prank(alice);
            lendingPool.withdraw(toWithdraw);
        }

        if (lendingPool.debt(alice) > 0) {
            assertGe(lendingPool.healthFactor(alice), 1e18);
        }
    }

    function testFuzz_decimalNormalization(uint256 collateralSeed) public {
        uint256 collateral = bound(collateralSeed, 1e15, 100_000e18);
        _deposit(alice, collateral);

        uint256 expected = (((collateral * PRICE) / 1e18) / USDC_SCALE * LTV_BPS) / 10_000;
        assertEq(lendingPool.maxBorrow(alice), expected);
    }

    function testFuzz_solvencyAccounting(uint256 collateralA, uint256 collateralB, uint256 fractionA, uint256 fractionB)
        public
    {
        uint256 amountA = bound(collateralA, 1e18, 1_000e18);
        uint256 amountB = bound(collateralB, 1e18, 1_000e18);
        _deposit(alice, amountA);
        _deposit(bob, amountB);

        uint256 borrowA = (lendingPool.maxBorrow(alice) * bound(fractionA, 0, 10_000)) / 10_000;
        if (borrowA > 0) {
            vm.prank(alice);
            lendingPool.borrow(borrowA);
        }

        uint256 borrowB = (lendingPool.maxBorrow(bob) * bound(fractionB, 0, 10_000)) / 10_000;
        if (borrowB > 0) {
            vm.prank(bob);
            lendingPool.borrow(borrowB);
        }

        assertEq(IERC20(USDC).balanceOf(address(lendingPool)) + lendingPool.totalDebt(), POOL_USDC_LIQUIDITY);
        assertEq(lendingPool.totalCollateral(), amountA + amountB);
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
