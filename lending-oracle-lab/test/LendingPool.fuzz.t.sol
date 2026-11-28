// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {HardenedForkFixture} from "./BaseForkFixed.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {FlashPumpExploiter} from "../src/OracleAttackReceiver.sol";

contract CreditMarketFuzzSuiteTest is HardenedForkFixture {
    uint256 internal constant DECIMAL_DOWNSCALE = 1e12;

    function testFuzz_borrowWithinLtv(uint256 rawCollateral, uint256 rawShareBps) public {
        uint256 wethCollateral = bound(rawCollateral, 0.1e18, 1_000e18);
        uint256 oracleRate = chainlinkFeed.readPrice();
        uint256 valuationUsdc = (wethCollateral * oracleRate) / 1e18 / DECIMAL_DOWNSCALE;
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

    function testFuzz_flashLoanSpotManipulationCannotOverBorrow(uint256 rawFlashPrincipal) public {
        uint256 flashPrincipal = bound(rawFlashPrincipal, 100_000e6, FLASH_VAULT_USDC);
        uint256 oracleRateBefore = chainlinkFeed.readPrice();

        FlashPumpExploiter exploiter = _createExploiterForMarket(address(creditMarket));
        deal(MAINNET_USDC, address(exploiter), flashPrincipal);

        exploiter.executeExploit(flashPrincipal);

        uint256 oracleRateAfter = chainlinkFeed.readPrice();
        uint256 acquiredCollateral = exploiter.postedCollateral();
        uint256 drawnDebt = exploiter.drawnAgainstCollateral();
        uint256 fairCollateralValuation = (acquiredCollateral * oracleRateBefore) / 1e18 / DECIMAL_DOWNSCALE;
        uint256 fairCreditCeiling = (fairCollateralValuation * MAX_LTV_BPS) / 10_000;

        assertEq(oracleRateAfter, oracleRateBefore);
        assertGt(ammPool.quoteAsset1InAsset0(), 2_000e18);
        assertEq(drawnDebt, fairCreditCeiling);
        assertEq(creditMarket.borrowedDebt(address(exploiter)), drawnDebt);
        assertGe(creditMarket.positionHealth(address(exploiter)), 1e18);
    }
}
