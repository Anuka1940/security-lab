// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {HardenedForkFixture} from "./BaseForkFixed.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {HardenedCreditMarket} from "../src/LendingPoolFix.sol";
import {FlashPumpExploiter} from "../src/OracleAttackReceiver.sol";
import {GuardedTwapFeed} from "../src/oracle/TwapPriceOracle.sol";
import {ChainlinkFeedAdapter} from "../src/oracle/ChainlinkPriceOracle.sol";

/// @notice Deterministic regression suite validating the guarded TWAP oracle, hardened credit
///         market, and Chainlink adapter against manipulation and edge-case inputs.
contract HardenedOracleRegressionSuiteTest is HardenedForkFixture {
    address internal constant MAINNET_CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    function test_initialState() public {
        assertEq(twapFeed.readPrice(), 2_000e18);
        assertEq(ammPool.quoteAsset1InAsset0(), 2_000e18);
        assertEq(twapFeed.totalObservations(), 3);
        assertEq(creditMarket.totalSuppliedCollateral(), 0);
        assertEq(creditMarket.aggregateDebt(), 0);
        assertEq(IERC20(MAINNET_USDC).balanceOf(address(creditMarket)), MARKET_USDC_RESERVE);
    }

    function test_legitimateBorrowRepayWithdraw() public {
        _supplyWeth(borrowerAlice, 100e18);
        uint256 creditLimit = creditMarket.availableCredit(borrowerAlice);
        assertEq(creditLimit, 160_000e6);

        vm.startPrank(borrowerAlice);
        creditMarket.drawDebt(100_000e6);
        assertEq(creditMarket.borrowedDebt(borrowerAlice), 100_000e6);
        assertGt(creditMarket.positionHealth(borrowerAlice), 1e18);

        IERC20(MAINNET_USDC).approve(address(creditMarket), 100_000e6);
        creditMarket.settleDebt(100_000e6);
        creditMarket.redeemCollateral(100e18);
        vm.stopPrank();

        assertEq(creditMarket.borrowedDebt(borrowerAlice), 0);
        assertEq(creditMarket.suppliedCollateral(borrowerAlice), 0);
        assertEq(IERC20(MAINNET_WETH).balanceOf(borrowerAlice), 100e18);
    }

    function test_repayIsCappedAtDebt() public {
        _supplyWeth(borrowerAlice, 100e18);
        vm.startPrank(borrowerAlice);
        creditMarket.drawDebt(100_000e6);
        deal(MAINNET_USDC, borrowerAlice, 150_000e6);
        IERC20(MAINNET_USDC).approve(address(creditMarket), 150_000e6);
        creditMarket.settleDebt(150_000e6);
        assertEq(creditMarket.borrowedDebt(borrowerAlice), 0);
        assertEq(IERC20(MAINNET_USDC).balanceOf(borrowerAlice), 50_000e6);
        vm.stopPrank();
    }

    function test_withdrawBelowHealthReverts() public {
        _supplyWeth(borrowerAlice, 100e18);
        vm.startPrank(borrowerAlice);
        creditMarket.drawDebt(150_000e6);
        vm.expectRevert(HardenedCreditMarket.PositionUndercollateralized.selector);
        creditMarket.redeemCollateral(25e18);
        vm.stopPrank();
    }

    function test_sameBlockFlashPumpRevertsOnDeviation() public {
        FlashPumpExploiter exploiter = _createExploiterForMarket(address(creditMarket));

        vm.expectRevert();
        exploiter.executeExploit(2_000_000e6);
    }

    function test_twapOnlyAttackCannotOverBorrow() public {
        GuardedTwapFeed unguardedTwap = _deployTwapFeed(50_000);
        _primeOracleHistory(unguardedTwap);
        HardenedCreditMarket twapOnlyMarket = _deployCreditMarket(address(unguardedTwap));
        deal(MAINNET_USDC, address(twapOnlyMarket), MARKET_USDC_RESERVE);
        _supplyWethToMarket(address(twapOnlyMarket), borrowerAlice, 500e18);

        uint256 fairLimit = twapOnlyMarket.availableCredit(borrowerAlice);
        FlashPumpExploiter exploiter = _createExploiterForMarket(address(twapOnlyMarket));
        _grantUsdc(address(exploiter), 1_300_000e6);

        exploiter.executeExploit(2_000_000e6);

        uint256 drawnDebt = exploiter.drawnAgainstCollateral();
        uint256 recordedDebt = twapOnlyMarket.borrowedDebt(address(exploiter));
        uint256 collateralWorth = twapOnlyMarket.evaluateCollateral(address(exploiter));
        uint256 health = twapOnlyMarket.positionHealth(address(exploiter));

        assertLe(drawnDebt, fairLimit);
        assertEq(recordedDebt, drawnDebt);
        assertLe(recordedDebt, collateralWorth);
        assertGe(health, 1e18);
        assertApproxEqRel(drawnDebt, 798_000e6, 0.002e18);
    }

    function test_staleOracleRevertsOnBorrow() public {
        _supplyWeth(borrowerAlice, 100e18);
        vm.warp(block.timestamp + STALENESS_LIMIT + 1);

        vm.prank(borrowerAlice);
        vm.expectRevert(abi.encodeWithSelector(GuardedTwapFeed.StaleCheckpoint.selector, STALENESS_LIMIT + 1));
        creditMarket.drawDebt(1_000e6);
    }

    function test_missingRecentObservationReverts() public {
        vm.warp(block.timestamp + TWAP_HORIZON + 5 minutes);

        vm.expectRevert(GuardedTwapFeed.WindowUncovered.selector);
        twapFeed.readPrice();
    }

    function test_moderateVolatilityIsAccepted() public {
        FlashPumpExploiter exploiter = _createExploiterForMarket(address(creditMarket));
        _grantUsdc(address(exploiter), 100_000e6);

        exploiter.executeExploit(140_000e6);

        uint256 spotShiftBps = ((_readInstantSpot() - 2_000e18) * 10_000) / 2_000e18;
        assertLt(spotShiftBps, SPOT_DEVIATION_CAP_BPS);
        assertGt(exploiter.drawnAgainstCollateral(), 0);
        assertLe(exploiter.drawnAgainstCollateral(), 112_000e6);
    }

    function test_priceBoundsRejected() public {
        GuardedTwapFeed restrictedFeed = new GuardedTwapFeed(
            address(ammPool),
            MAINNET_WETH,
            MAINNET_USDC,
            TWAP_HORIZON,
            HEARTBEAT_COOLDOWN,
            STALENESS_LIMIT,
            0,
            3_000e18,
            4_000e18
        );
        _primeOracleHistory(restrictedFeed);

        vm.expectRevert(abi.encodeWithSelector(GuardedTwapFeed.PriceOutsideBounds.selector, 2_000e18));
        restrictedFeed.readPrice();
    }

    function test_updateRateLimit() public {
        vm.expectRevert(GuardedTwapFeed.HeartbeatCooldownActive.selector);
        twapFeed.recordObservation();
    }

    function test_decimalNormalizationAtBorrowBoundary() public {
        _supplyWeth(borrowerAlice, 100e18);
        assertEq(creditMarket.availableCredit(borrowerAlice), 160_000e6);

        vm.startPrank(borrowerAlice);
        creditMarket.drawDebt(160_000e6);
        assertEq(creditMarket.borrowedDebt(borrowerAlice), 160_000e6);

        vm.expectRevert(HardenedCreditMarket.BorrowCapacityExceeded.selector);
        creditMarket.drawDebt(1);
        vm.stopPrank();
    }

    function test_chainlinkAlternativeNormalizesAndChecksStaleness() public {
        ChainlinkFeedAdapter chainlinkAdapter = new ChainlinkFeedAdapter(
            MAINNET_CHAINLINK_ETH_USD, MAINNET_WETH, MAINNET_USDC, 2 hours, FLOOR_PRICE_18, CEILING_PRICE_18
        );

        uint256 normalizedQuote = chainlinkAdapter.readPrice();
        assertGt(normalizedQuote, 1_000e18);
        assertLt(normalizedQuote, 10_000e18);

        vm.warp(block.timestamp + 3 hours);
        vm.expectRevert();
        chainlinkAdapter.readPrice();
    }

    function test_constructorRejectsInvalidConfiguration() public {
        vm.expectRevert("HORIZON_TOO_SHORT");
        new GuardedTwapFeed(
            address(ammPool),
            MAINNET_WETH,
            MAINNET_USDC,
            40,
            HEARTBEAT_COOLDOWN,
            STALENESS_LIMIT,
            SPOT_DEVIATION_CAP_BPS,
            FLOOR_PRICE_18,
            CEILING_PRICE_18
        );

        vm.expectRevert("INVALID_PRICE_BOUNDS");
        new GuardedTwapFeed(
            address(ammPool),
            MAINNET_WETH,
            MAINNET_USDC,
            TWAP_HORIZON,
            HEARTBEAT_COOLDOWN,
            STALENESS_LIMIT,
            SPOT_DEVIATION_CAP_BPS,
            0,
            CEILING_PRICE_18
        );
    }
}
