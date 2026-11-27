// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {HardenedForkFixture} from "./BaseForkFixed.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {FlashPumpExploiter} from "../src/OracleAttackReceiver.sol";


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

    function test_sameBlockFlashPumpRevertsOnDeviation() public {
        FlashPumpExploiter exploiter = _createExploiterForMarket(address(creditMarket));

        vm.expectRevert();
        exploiter.executeExploit(2_000_000e6);
    }

    
}
