// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPriceOracle} from "../src/mocks/MockPriceOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @notice Partial unit suite. Fork, manipulation, and fuzz coverage are still missing.
contract LendingPoolTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockPriceOracle internal oracle;
    LendingPool internal pool;

    address internal alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockPriceOracle(address(weth), address(usdc), 2_000e18);
        pool = new LendingPool(address(weth), address(usdc), address(oracle), 8_000, 8_500);

        usdc.mint(address(pool), 5_000_000e6);
        weth.mint(alice, 100e18);
    }

    function test_assertInitialState() public {
        assertEq(pool.ltvBps(), 8_000);
        assertEq(pool.liquidationThresholdBps(), 8_500);
        assertEq(usdc.balanceOf(address(pool)), 5_000_000e6);
    }

    function test_depositAndBorrowWithinLtv() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 100e18);
        pool.deposit(100e18);

        uint256 maxBorrow = pool.maxBorrow(alice);
        assertEq(maxBorrow, 160_000e6);

        pool.borrow(100_000e6);
        assertEq(pool.debt(alice), 100_000e6);
        assertEq(usdc.balanceOf(alice), 100_000e6);
        vm.stopPrank();
    }

    function test_borrowAboveLtvReverts() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 100e18);
        pool.deposit(100e18);

        vm.expectRevert("EXCEEDS_MAX_BORROW");
        pool.borrow(160_001e6);
        vm.stopPrank();
    }

    function test_repayAndWithdraw() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 100e18);
        pool.deposit(100e18);
        pool.borrow(100_000e6);

        usdc.approve(address(pool), 100_000e6);
        pool.repay(100_000e6);
        pool.withdraw(100e18);

        assertEq(pool.debt(alice), 0);
        assertEq(pool.collateralBalance(alice), 0);
        assertEq(weth.balanceOf(alice), 100e18);
        vm.stopPrank();
    }

    function test_withdrawThatBreaksCollateralizationReverts() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 100e18);
        pool.deposit(100e18);
        pool.borrow(150_000e6);

        vm.expectRevert("UNDERCOLLATERALIZED");
        pool.withdraw(20e18);
        vm.stopPrank();
    }
}
