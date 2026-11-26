// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {console2} from "forge-std/console2.sol";
import {VulnerableForkFixture} from "./BaseFork.t.sol";

/// @notice Initial fork baseline sanity checks prior to running the full exploit proof.
contract BaselineMarketChecksTest is VulnerableForkFixture {
    function test_initialAmmSpotQuote() public view {
        uint256 spotQuote = spotFeed.readPrice();
        console2.log("initial WETH/USDC spot quote (1e18)", spotQuote);
        assertApproxEqRel(spotQuote, 2_000e18, 0.001e18);
    }

    function test_unmanipulatedCreditLimit() public {
        _supplyWeth(borrowerAlice, 500e18);
        assertEq(creditMarket.availableCredit(borrowerAlice), 800_000e6);
    }

    function test_placeholderManipulationScenario() public {
        // Placeholder stub retained from the baseline lab skeleton; full exploit lives in FlashLoanOracleManipulation.t.sol.
    }
}
