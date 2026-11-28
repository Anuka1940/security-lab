// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {HardenedForkFixture} from "./BaseForkFixed.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {FlashPumpExploiter} from "../src/OracleAttackReceiver.sol";


contract HardenedOracleRegressionSuiteTest is HardenedForkFixture {
    function test_initialState() public view {
        uint256 oracleQuote = chainlinkFeed.readPrice();
        assertGt(oracleQuote, 1_000e18);
        assertLt(oracleQuote, 10_000e18);
        assertEq(ammPool.quoteAsset1InAsset0(), 2_000e18);
        assertEq(creditMarket.totalSuppliedCollateral(), 0);
        assertEq(creditMarket.aggregateDebt(), 0);
        assertEq(IERC20(MAINNET_USDC).balanceOf(address(creditMarket)), MARKET_USDC_RESERVE);
    }

    function test_sameBlockFlashPumpReverts() public {
        FlashPumpExploiter exploiter = _createExploiterForMarket(address(creditMarket));

        vm.expectRevert();
        exploiter.executeExploit(2_000_000e6);
    }

    function test_staleChainlinkFeedReverts() public {
        vm.warp(block.timestamp + MAX_HEARTBEAT_AGE + 1);
        vm.expectRevert();
        chainlinkFeed.readPrice();
    }
}
