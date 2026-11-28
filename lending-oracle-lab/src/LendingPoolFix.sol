// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {IOracleFeed} from "./interfaces/IPriceOracle.sol";
import {ICreditMarket} from "./interfaces/ILendingPool.sol";

/// @title Hardened collateralized credit market paired with a validated Chainlink oracle
/// @notice Security upgrades over the vulnerable baseline:
///         - prices collateral via a manipulation-resistant oracle feed,
///         - enforces reentrancy protection across all state-changing operations,
///         - tracks aggregate collateral custody alongside aggregate debt for invariant checks,
///         - normalizes 18-decimal oracle prices to the debt token's decimals exactly once.
contract HardenedCreditMarket is ICreditMarket {
    uint256 public constant BPS_SCALE = 10_000;

    IERC20 public immutable collateralAsset;
    IERC20 public immutable debtAsset;
    IOracleFeed public immutable priceFeed;
    uint256 public immutable maxLtvBps;
    uint256 public immutable liquidationLimitBps;
    uint8 private immutable debtDecimals;

    mapping(address => uint256) public suppliedCollateral;
    mapping(address => uint256) public borrowedDebt;
    uint256 public totalSuppliedCollateral;
    uint256 public aggregateDebt;

    uint256 private entryGuard = 1;

    event CollateralSupplied(address indexed borrower, uint256 amount);
    event CollateralRedeemed(address indexed borrower, uint256 amount);
    event DebtDrawn(address indexed borrower, uint256 amount, uint256 oracleRate);
    event DebtSettled(address indexed borrower, uint256 amount);

    error ZeroAmountProvided();
    error InvalidRedeemAmount();
    error InvalidMarketParameters();
    error BorrowCapacityExceeded();
    error MarketLiquidityInsufficient();
    error PositionUndercollateralized();
    error ReentrantCallBlocked();

    modifier nonReentrant() {
        if (entryGuard != 1) revert ReentrantCallBlocked();
        entryGuard = 2;
        _;
        entryGuard = 1;
    }

    constructor(
        address collateralAsset_,
        address debtAsset_,
        address priceFeed_,
        uint256 maxLtvBps_,
        uint256 liquidationLimitBps_
    ) {
        if (maxLtvBps_ == 0 || maxLtvBps_ > liquidationLimitBps_ || liquidationLimitBps_ > BPS_SCALE) {
            revert InvalidMarketParameters();
        }
        collateralAsset = IERC20(collateralAsset_);
        debtAsset = IERC20(debtAsset_);
        priceFeed = IOracleFeed(priceFeed_);
        maxLtvBps = maxLtvBps_;
        liquidationLimitBps = liquidationLimitBps_;
        debtDecimals = IERC20(debtAsset_).decimals();
    }

    function supplyCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmountProvided();
        collateralAsset.transferFrom(msg.sender, address(this), amount);
        suppliedCollateral[msg.sender] += amount;
        totalSuppliedCollateral += amount;
        emit CollateralSupplied(msg.sender, amount);
    }

    function redeemCollateral(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > suppliedCollateral[msg.sender]) revert InvalidRedeemAmount();
        suppliedCollateral[msg.sender] -= amount;
        totalSuppliedCollateral -= amount;
        if (!_isHealthy(msg.sender)) revert PositionUndercollateralized();
        collateralAsset.transfer(msg.sender, amount);
        emit CollateralRedeemed(msg.sender, amount);
    }

    function drawDebt(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmountProvided();
        if (amount > availableCredit(msg.sender)) revert BorrowCapacityExceeded();
        if (amount > debtAsset.balanceOf(address(this))) revert MarketLiquidityInsufficient();

        borrowedDebt[msg.sender] += amount;
        aggregateDebt += amount;
        debtAsset.transfer(msg.sender, amount);
        emit DebtDrawn(msg.sender, amount, priceFeed.readPrice());
    }

    function settleDebt(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmountProvided();
        uint256 currentLiability = borrowedDebt[msg.sender];
        uint256 actualRepay = amount < currentLiability ? amount : currentLiability;
        borrowedDebt[msg.sender] = currentLiability - actualRepay;
        aggregateDebt -= actualRepay;
        debtAsset.transferFrom(msg.sender, address(this), actualRepay);
        emit DebtSettled(msg.sender, actualRepay);
    }

    function availableCredit(address borrower) public returns (uint256) {
        uint256 collateralWorth = _evaluateCollateralInDebtUnits(borrower);
        uint256 creditCeiling = (collateralWorth * maxLtvBps) / BPS_SCALE;
        uint256 existingDebt = borrowedDebt[borrower];
        return creditCeiling > existingDebt ? creditCeiling - existingDebt : 0;
    }

    function evaluateCollateral(address borrower) external returns (uint256) {
        return _evaluateCollateralInDebtUnits(borrower);
    }

    function positionHealth(address borrower) external returns (uint256) {
        uint256 existingDebt = borrowedDebt[borrower];
        if (existingDebt == 0) return type(uint256).max;
        uint256 adjustedCollateral = (_evaluateCollateralInDebtUnits(borrower) * liquidationLimitBps) / BPS_SCALE;
        return (adjustedCollateral * 1e18) / existingDebt;
    }

    function _evaluateCollateralInDebtUnits(address borrower) internal returns (uint256) {
        uint256 collateralUnits = suppliedCollateral[borrower];
        if (collateralUnits == 0) return 0;

        uint256 valuation18 = (collateralUnits * priceFeed.readPrice()) / 1e18;
        if (debtDecimals < 18) return valuation18 / (10 ** (18 - debtDecimals));
        if (debtDecimals > 18) return valuation18 * (10 ** (debtDecimals - 18));
        return valuation18;
    }

    function _isHealthy(address borrower) internal returns (bool) {
        if (borrowedDebt[borrower] == 0) return true;
        uint256 adjustedCollateral = (_evaluateCollateralInDebtUnits(borrower) * liquidationLimitBps) / BPS_SCALE;
        return adjustedCollateral >= borrowedDebt[borrower];
    }
}
