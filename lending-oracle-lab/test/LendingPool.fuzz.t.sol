// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {HardenedForkFixture} from "./BaseForkFixed.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

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

}
