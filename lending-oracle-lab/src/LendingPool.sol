// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title lending pool
contract LendingPool {
    uint256 public constant BPS = 10_000;

    IERC20 public immutable collateral;
    IERC20 public immutable borrowToken;
    IPriceOracle public immutable oracle;
    uint256 public immutable ltvBps;
    uint256 public immutable liquidationThresholdBps;
    uint8 private immutable borrowDecimals;

    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public debt;
    uint256 public totalDebt;

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Borrowed(address indexed account, uint256 amount);
    event Repaid(address indexed account, uint256 amount);

    constructor(
        address collateral_,
        address borrowToken_,
        address oracle_,
        uint256 ltvBps_,
        uint256 liquidationThresholdBps_
    ) {
        require(ltvBps_ > 0 && ltvBps_ <= liquidationThresholdBps_, "BAD_LTV");
        require(liquidationThresholdBps_ <= BPS, "BAD_THRESHOLD");
        collateral = IERC20(collateral_);
        borrowToken = IERC20(borrowToken_);
        oracle = IPriceOracle(oracle_);
        ltvBps = ltvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        borrowDecimals = IERC20(borrowToken_).decimals();
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        collateral.transferFrom(msg.sender, address(this), amount);
        collateralBalance[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0 && amount <= collateralBalance[msg.sender], "BAD_AMOUNT");
        collateralBalance[msg.sender] -= amount;
        require(_isCollateralized(msg.sender), "UNDERCOLLATERALIZED");
        collateral.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        require(amount <= maxBorrow(msg.sender), "EXCEEDS_MAX_BORROW");
        require(amount <= borrowToken.balanceOf(address(this)), "INSUFFICIENT_LIQUIDITY");

        debt[msg.sender] += amount;
        totalDebt += amount;
        borrowToken.transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 owed = debt[msg.sender];
        uint256 repaid = amount < owed ? amount : owed;
        debt[msg.sender] = owed - repaid;
        totalDebt -= repaid;
        borrowToken.transferFrom(msg.sender, address(this), repaid);
        emit Repaid(msg.sender, repaid);
    }

    function maxBorrow(address account) public returns (uint256) {
        uint256 value = _collateralValue(account);
        uint256 limit = (value * ltvBps) / BPS;
        uint256 currentDebt = debt[account];
        return limit > currentDebt ? limit - currentDebt : 0;
    }

    function collateralValue(address account) external returns (uint256) {
        return _collateralValue(account);
    }

    function healthFactor(address account) external returns (uint256) {
        uint256 currentDebt = debt[account];
        if (currentDebt == 0) return type(uint256).max;
        uint256 liquidationValue = (_collateralValue(account) * liquidationThresholdBps) / BPS;
        return (liquidationValue * 1e18) / currentDebt;
    }

    function _collateralValue(address account) internal returns (uint256) {
        uint256 amount = collateralBalance[account];
        if (amount == 0) return 0;
        uint256 value18 = (amount * oracle.getPrice()) / 1e18;
        if (borrowDecimals < 18) return value18 / 10 ** (18 - borrowDecimals);
        if (borrowDecimals > 18) return value18 * 10 ** (borrowDecimals - 18);
        return value18;
    }

    function _isCollateralized(address account) internal returns (bool) {
        if (debt[account] == 0) return true;
        uint256 liquidationValue = (_collateralValue(account) * liquidationThresholdBps) / BPS;
        return liquidationValue >= debt[account];
    }
}
