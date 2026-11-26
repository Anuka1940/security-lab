// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {IOracleFeed} from "./interfaces/IPriceOracle.sol";
import {ICreditMarket} from "./interfaces/ILendingPool.sol";

/// @title Baseline collateralized credit market (vulnerable to instantaneous spot price manipulation)
contract VulnerableCreditMarket is ICreditMarket {
    uint256 public constant BPS_SCALE = 10_000;

    IERC20 public immutable collateralAsset;
    IERC20 public immutable debtAsset;
    IOracleFeed public immutable priceFeed;
    uint256 public immutable maxLtvBps;
    uint256 public immutable liquidationLimitBps;
    uint8 private immutable debtDecimals;

    mapping(address => uint256) public suppliedCollateral;
    mapping(address => uint256) public borrowedDebt;
    uint256 public aggregateDebt;

    event CollateralSupplied(address indexed borrower, uint256 amount);
    event CollateralRedeemed(address indexed borrower, uint256 amount);
    event DebtDrawn(address indexed borrower, uint256 amount);
    event DebtSettled(address indexed borrower, uint256 amount);

    constructor(
        address collateralAsset_,
        address debtAsset_,
        address priceFeed_,
        uint256 maxLtvBps_,
        uint256 liquidationLimitBps_
    ) {
        require(maxLtvBps_ > 0 && maxLtvBps_ <= liquidationLimitBps_, "INVALID_LTV_CONFIG");
        require(liquidationLimitBps_ <= BPS_SCALE, "INVALID_LIQUIDATION_LIMIT");
        collateralAsset = IERC20(collateralAsset_);
        debtAsset = IERC20(debtAsset_);
        priceFeed = IOracleFeed(priceFeed_);
        maxLtvBps = maxLtvBps_;
        liquidationLimitBps = liquidationLimitBps_;
        debtDecimals = IERC20(debtAsset_).decimals();
    }

    function supplyCollateral(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        collateralAsset.transferFrom(msg.sender, address(this), amount);
        suppliedCollateral[msg.sender] += amount;
        emit CollateralSupplied(msg.sender, amount);
    }

    function redeemCollateral(uint256 amount) external {
        require(amount > 0 && amount <= suppliedCollateral[msg.sender], "INVALID_REDEEM_AMOUNT");
        suppliedCollateral[msg.sender] -= amount;
        require(_isHealthy(msg.sender), "POSITION_UNDERCOLLATERALIZED");
        collateralAsset.transfer(msg.sender, amount);
        emit CollateralRedeemed(msg.sender, amount);
    }

    function drawDebt(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        require(amount <= availableCredit(msg.sender), "BORROW_CAPACITY_EXCEEDED");
        require(amount <= debtAsset.balanceOf(address(this)), "MARKET_ILLIQUID");

        borrowedDebt[msg.sender] += amount;
        aggregateDebt += amount;
        debtAsset.transfer(msg.sender, amount);
        emit DebtDrawn(msg.sender, amount);
    }

    function settleDebt(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
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
