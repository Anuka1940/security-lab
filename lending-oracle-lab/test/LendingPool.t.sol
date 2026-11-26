// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/mocks/MockERC20.sol";
import {StaticPriceFeed} from "../src/mocks/MockPriceOracle.sol";
import {VulnerableCreditMarket} from "../src/LendingPool.sol";

/// @notice Standalone unit test suite verifying core lending accounting with mock assets.
contract CreditMarketUnitSuiteTest is Test {
    TestToken internal mockUsdc;
    TestToken internal mockWeth;
    StaticPriceFeed internal staticFeed;
    VulnerableCreditMarket internal market;

    address internal userAlice = makeAddr("userAlice");

    function setUp() public {
        mockUsdc = new TestToken("Mock USD Coin", "mUSDC", 6);
        mockWeth = new TestToken("Mock Wrapped Ether", "mWETH", 18);
        staticFeed = new StaticPriceFeed(address(mockWeth), address(mockUsdc), 2_000e18);
        market = new VulnerableCreditMarket(
            address(mockWeth), address(mockUsdc), address(staticFeed), 8_000, 8_500
        );

        mockUsdc.mintTo(address(market), 5_000_000e6);
        mockWeth.mintTo(userAlice, 100e18);
    }

    function test_marketConfigurationParameters() public view {
        assertEq(market.maxLtvBps(), 8_000);
        assertEq(market.liquidationLimitBps(), 8_500);
        assertEq(mockUsdc.balanceOf(address(market)), 5_000_000e6);
    }

    function test_supplyAndDrawWithinCreditLimit() public {
        vm.startPrank(userAlice);
        mockWeth.approve(address(market), 100e18);
        market.supplyCollateral(100e18);

        uint256 creditLimit = market.availableCredit(userAlice);
        assertEq(creditLimit, 160_000e6);

        market.drawDebt(100_000e6);
        assertEq(market.borrowedDebt(userAlice), 100_000e6);
        assertEq(mockUsdc.balanceOf(userAlice), 100_000e6);
        vm.stopPrank();
    }

    function test_drawAboveCreditLimitReverts() public {
        vm.startPrank(userAlice);
        mockWeth.approve(address(market), 100e18);
        market.supplyCollateral(100e18);

        vm.expectRevert("BORROW_CAPACITY_EXCEEDED");
        market.drawDebt(160_001e6);
        vm.stopPrank();
    }

    function test_fullSettlementAndCollateralRedemption() public {
        vm.startPrank(userAlice);
        mockWeth.approve(address(market), 100e18);
        market.supplyCollateral(100e18);
        market.drawDebt(100_000e6);

        mockUsdc.approve(address(market), 100_000e6);
        market.settleDebt(100_000e6);
        market.redeemCollateral(100e18);

        assertEq(market.borrowedDebt(userAlice), 0);
        assertEq(market.suppliedCollateral(userAlice), 0);
        assertEq(mockWeth.balanceOf(userAlice), 100e18);
        vm.stopPrank();
    }

    function test_redeemViolatingLiquidationLimitReverts() public {
        vm.startPrank(userAlice);
        mockWeth.approve(address(market), 100e18);
        market.supplyCollateral(100e18);
        market.drawDebt(150_000e6);

        vm.expectRevert("POSITION_UNDERCOLLATERALIZED");
        market.redeemCollateral(20e18);
        vm.stopPrank();
    }
}
