// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {IFlashBorrower} from "./interfaces/IFlashBorrower.sol";

/// @notice Tiny ERC-3156-style lender used to simulate atomic, uncollateralized capital.
contract FlashLoanPool {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    IERC20 public immutable token;
    uint256 public immutable feeBps;
    uint256 public constant BPS = 10_000;

    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);

    constructor(address token_, uint256 feeBps_) {
        require(feeBps_ <= 100, "FEE_TOO_HIGH");
        token = IERC20(token_);
        feeBps = feeBps_;
    }

    function flashLoan(address receiver, uint256 amount, bytes calldata data) external {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 fee = (amount * feeBps) / BPS;
        uint256 balanceBefore = token.balanceOf(address(this));

        token.transfer(receiver, amount);
        require(
            IFlashBorrower(receiver).onFlashLoan(msg.sender, address(token), amount, fee, data) == CALLBACK_SUCCESS,
            "BAD_CALLBACK"
        );
        token.transferFrom(receiver, address(this), amount + fee);
        require(token.balanceOf(address(this)) >= balanceBefore + fee, "FEE_NOT_PAID");

        emit FlashLoan(receiver, amount, fee);
    }

    function maxFlashLoan() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
