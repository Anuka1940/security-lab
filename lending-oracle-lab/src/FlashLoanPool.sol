// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {IFlashLoanCallback} from "./interfaces/IFlashBorrower.sol";

/// @notice Minimal atomic flash lender providing uncollateralized single-transaction liquidity.
contract AtomicFlashVault {
    bytes32 public constant CALLBACK_TAG = keccak256("IFlashLoanCallback.executeOperation");
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable liquidityAsset;
    uint256 public immutable feeRateBps;

    event FlashLoanExecuted(address indexed borrower, uint256 principal, uint256 feeAmount);

    constructor(address assetAddress, uint256 feeRateBps_) {
        require(feeRateBps_ <= 100, "EXCESSIVE_FEE_RATE");
        liquidityAsset = IERC20(assetAddress);
        feeRateBps = feeRateBps_;
    }

    function requestFlashLoan(address borrowerContract, uint256 principal, bytes calldata payload) external {
        require(principal > 0, "ZERO_PRINCIPAL");
        uint256 feeAmount = (principal * feeRateBps) / BPS_DENOMINATOR;
        uint256 startingCash = liquidityAsset.balanceOf(address(this));

        liquidityAsset.transfer(borrowerContract, principal);
        bytes32 ack = IFlashLoanCallback(borrowerContract).executeOperation(
            msg.sender, address(liquidityAsset), principal, feeAmount, payload
        );
        require(ack == CALLBACK_TAG, "INVALID_FLASH_CALLBACK");

        liquidityAsset.transferFrom(borrowerContract, address(this), principal + feeAmount);
        require(liquidityAsset.balanceOf(address(this)) >= startingCash + feeAmount, "UNPAID_FLASH_LOAN");

        emit FlashLoanExecuted(borrowerContract, principal, feeAmount);
    }

    function availableFlashLiquidity() external view returns (uint256) {
        return liquidityAsset.balanceOf(address(this));
    }
}
