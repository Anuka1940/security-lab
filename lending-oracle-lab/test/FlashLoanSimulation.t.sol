// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {BaseForkTest} from "./BaseFork.t.sol";
import {OracleAttackReceiver} from "../src/OracleAttackReceiver.sol";

/// @notice Partial flash-loan simulation. It exercises the plumbing but does not
///         assert on the collateralization failure yet.
contract FlashLoanSimulationTest is BaseForkTest {
    function test_flashLoanRoundTrip() public {
        OracleAttackReceiver receiver = _deployReceiver();
        _fundReceiver(address(receiver), 50_000e6);

        receiver.attack(100_000e6);

        assertEq(receiver.flashLoanRepaid(), 100_000e6 + (100_000e6 * 9) / 10_000);
        assertGt(receiver.collateralDeposited(), 0);
        assertGt(receiver.borrowedAgainstCollateral(), 0);
        assertEq(lendingPool.collateralBalance(address(receiver)), receiver.collateralDeposited());
    }
}
