// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {HardenedForkFixture} from "./BaseForkFixed.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Property-based fuzz suite for lending LTV boundaries, repayments, redemptions,
///         decimal scaling, and multi-user solvency conservation.
contract CreditMarketFuzzSuiteTest is HardenedForkFixture {
    uint256 internal constant EQUILIBRIUM_RATE = 2_000e18;
    uint256 internal constant DECIMAL_DOWNSCALE = 1e12;

    function testFuzz_borrowWithinLtv(uint256 rawCollateral, uint256 rawShareBps) public {
        uint256 wethCollateral = bound(rawCollateral, 0.1e18, 1_000e18);
        uint256 valuationUsdc = (wethCollateral * EQUILIBRIUM_RATE) / 1e18 / DECIMAL_DOWNSCALE;
        uint256 creditCeiling = (valuationUsdc * MAX_LTV_BPS) / 10_000;
        uint256 drawTarget = (creditCeiling * bound(rawShareBps, 1, 10_000)) / 10_000;

        _supplyWeth(borrowerAlice, wethCollateral);
        assertEq(creditMarket.availableCredit(borrowerAlice), creditCeiling);

        vm.prank(borrowerAlice);
        creditMarket.drawDebt(drawTarget);

        assertEq(creditMarket.borrowedDebt(borrowerAlice), drawTarget);
        assertEq(creditMarket.aggregateDebt(), drawTarget);
        assertEq(IERC20(MAINNET_USDC).balanceOf(borrowerAlice), drawTarget);
    }

    function testFuzz_oneAboveMaxReverts(uint256 rawCollateral) public {
        uint256 wethCollateral = bound(rawCollateral, 0.1e18, 1_000e18);
        _supplyWeth(borrowerAlice, wethCollateral);

        uint256 creditCeiling = creditMarket.availableCredit(borrowerAlice);
        vm.prank(borrowerAlice);
        vm.expectRevert();
        creditMarket.drawDebt(creditCeiling + 1);
    }

    function testFuzz_repayThenWithdrawRoundTrip(uint256 rawCollateral, uint256 rawShareBps) public {
        uint256 wethCollateral = bound(rawCollateral, 1e18, 1_000e18);
        _supplyWeth(borrowerAlice, wethCollateral);

        uint256 creditCeiling = creditMarket.availableCredit(borrowerAlice);
        uint256 drawTarget = (creditCeiling * bound(rawShareBps, 1, 10_000)) / 10_000;

        vm.startPrank(borrowerAlice);
        creditMarket.drawDebt(drawTarget);
        IERC20(MAINNET_USDC).approve(address(creditMarket), drawTarget);
        creditMarket.settleDebt(drawTarget);
        creditMarket.redeemCollateral(wethCollateral);
        vm.stopPrank();

        assertEq(creditMarket.borrowedDebt(borrowerAlice), 0);
        assertEq(creditMarket.suppliedCollateral(borrowerAlice), 0);
        assertEq(IERC20(MAINNET_WETH).balanceOf(borrowerAlice), wethCollateral);
    }

    function testFuzz_partialRepay(
        uint256 rawCollateral,
        uint256 rawDrawBps,
        uint256 rawRepayBps
    ) public {
        uint256 wethCollateral = bound(rawCollateral, 1e18, 1_000e18);
        _supplyWeth(borrowerAlice, wethCollateral);

        uint256 creditCeiling = creditMarket.availableCredit(borrowerAlice);
        uint256 drawTarget = (creditCeiling * bound(rawDrawBps, 1, 10_000)) / 10_000;
        if (drawTarget == 0) return;

        uint256 repayTarget = (drawTarget * bound(rawRepayBps, 1, 10_000)) / 10_000;

        vm.startPrank(borrowerAlice);
        creditMarket.drawDebt(drawTarget);
        IERC20(MAINNET_USDC).approve(address(creditMarket), repayTarget);
        creditMarket.settleDebt(repayTarget);
        vm.stopPrank();

        assertEq(creditMarket.borrowedDebt(borrowerAlice), drawTarget - repayTarget);
        assertEq(IERC20(MAINNET_USDC).balanceOf(borrowerAlice), drawTarget - repayTarget);
    }

    function testFuzz_withdrawPreservesThreshold(
        uint256 rawCollateral,
        uint256 rawDrawBps,
        uint256 rawRedeemBps
    ) public {
        uint256 wethCollateral = bound(rawCollateral, 100e18, 1_000e18);
        _supplyWeth(borrowerAlice, wethCollateral);

        uint256 creditCeiling = creditMarket.availableCredit(borrowerAlice);
        uint256 drawTarget = (creditCeiling * bound(rawDrawBps, 1, 10_000)) / 10_000;

        vm.prank(borrowerAlice);
        creditMarket.drawDebt(drawTarget);

        uint256 requiredCollateral = _roundUpDiv(
            drawTarget * DECIMAL_DOWNSCALE * 1e18 * 10_000,
            EQUILIBRIUM_RATE * LIQ_THRESHOLD_BPS
        ) + 1e12;
        uint256 excessCollateral =
            wethCollateral > requiredCollateral ? wethCollateral - requiredCollateral : 0;
        uint256 redeemAmount = (excessCollateral * bound(rawRedeemBps, 0, 10_000)) / 10_000;

        if (redeemAmount > 0) {
            vm.prank(borrowerAlice);
            creditMarket.redeemCollateral(redeemAmount);
        }

        if (creditMarket.borrowedDebt(borrowerAlice) > 0) {
            assertGe(creditMarket.positionHealth(borrowerAlice), 1e18);
        }
    }

    function testFuzz_decimalNormalization(uint256 rawCollateral) public {
        uint256 wethCollateral = bound(rawCollateral, 1e15, 100_000e18);
        _supplyWeth(borrowerAlice, wethCollateral);

        uint256 expectedCredit =
            ((((wethCollateral * EQUILIBRIUM_RATE) / 1e18) / DECIMAL_DOWNSCALE) * MAX_LTV_BPS) / 10_000;
        assertEq(creditMarket.availableCredit(borrowerAlice), expectedCredit);
    }

    function testFuzz_solvencyAccounting(
        uint256 rawCollateralAlice,
        uint256 rawCollateralBob,
        uint256 rawDrawAliceBps,
        uint256 rawDrawBobBps
    ) public {
        uint256 aliceWeth = bound(rawCollateralAlice, 1e18, 1_000e18);
        uint256 bobWeth = bound(rawCollateralBob, 1e18, 1_000e18);
        _supplyWeth(borrowerAlice, aliceWeth);
        _supplyWeth(borrowerBob, bobWeth);

        uint256 aliceDraw =
            (creditMarket.availableCredit(borrowerAlice) * bound(rawDrawAliceBps, 0, 10_000)) / 10_000;
        if (aliceDraw > 0) {
            vm.prank(borrowerAlice);
            creditMarket.drawDebt(aliceDraw);
        }

        uint256 bobDraw =
            (creditMarket.availableCredit(borrowerBob) * bound(rawDrawBobBps, 0, 10_000)) / 10_000;
        if (bobDraw > 0) {
            vm.prank(borrowerBob);
            creditMarket.drawDebt(bobDraw);
        }

        assertEq(
            IERC20(MAINNET_USDC).balanceOf(address(creditMarket)) + creditMarket.aggregateDebt(),
            MARKET_USDC_RESERVE
        );
        assertEq(creditMarket.totalSuppliedCollateral(), aliceWeth + bobWeth);
    }

    function _roundUpDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return (numerator + denominator - 1) / denominator;
    }
}
