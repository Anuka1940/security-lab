// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {console2} from "forge-std/console2.sol";
import {BaseForkTest} from "./BaseFork.t.sol";

/// @notice Fork baseline is only partly completed. The manipulation test is a stub.
contract ForkBaselineTest is BaseForkTest {
    function test_baselineSpotPrice() public {
        uint256 price = oracle.getPrice();
        console2.log("baseline WETH price (18 decimals)", price);
        assertApproxEqRel(price, 2_000e18, 0.001e18);
    }

    function test_baselineBorrowCapacity() public {
        _deposit(alice, 500e18);
        assertEq(lendingPool.maxBorrow(alice), 800_000e6);
    }

    function test_TODO_oracleManipulation() public {
        // TODO: flash-borrow USDC, pump the AMM, deposit WETH, borrow, compare.
    }
}
