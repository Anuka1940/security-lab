// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {VulnerableForkFixture} from "./BaseFork.t.sol";
import {FlashPumpExploiter} from "../src/OracleAttackReceiver.sol";

/// @notice End-to-end smoke test verifying atomic flash borrowing, AMM swap, collateral posting, and loan settlement.
contract FlashPlumbingSimulationTest is VulnerableForkFixture {
    function test_atomicFlashLoanExecutionCycle() public {
        FlashPumpExploiter exploiter = _createExploiter();
        _seedStableBuffer(address(exploiter), 50_000e6);

        exploiter.executeExploit(100_000e6);

        assertEq(exploiter.settledFlashTotal(), 100_000e6 + (100_000e6 * 9) / 10_000);
        assertGt(exploiter.postedCollateral(), 0);
        assertGt(exploiter.drawnAgainstCollateral(), 0);
        assertEq(creditMarket.suppliedCollateral(address(exploiter)), exploiter.postedCollateral());
    }
}
