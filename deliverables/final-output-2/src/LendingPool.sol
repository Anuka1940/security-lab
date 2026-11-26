// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title Hardened collateralized lending pool
/// @notice Differences from the vulnerable lab:
///         - collateral is priced through a validated TWAP oracle,
///         - borrows revert on stale, out-of-range, or deviating prices,
///         - borrow-token decimal normalization is explicit,
///         - all accounting mutations are reentrancy-guarded,
///         - total collateral is tracked for invariant testing.
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
    uint256 public totalCollateral;
    uint256 public totalDebt;

    uint256 private locked = 1;

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Borrowed(address indexed account, uint256 amount, uint256 price);
    event Repaid(address indexed account, uint256 amount);

    error ZeroAmount();
    error BadAmount();
    error BadConfiguration();
    error ExceedsMaxBorrow();
    error InsufficientLiquidity();
    error Undercollateralized();
    error Reentrancy();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(
        address collateral_,
        address borrowToken_,
        address oracle_,
        uint256 ltvBps_,
        uint256 liquidationThresholdBps_
    ) {
        if (ltvBps_ == 0 || ltvBps_ > liquidationThresholdBps_ || liquidationThresholdBps_ > BPS) {
            revert BadConfiguration();
        }
        collateral = IERC20(collateral_);
        borrowToken = IERC20(borrowToken_);
        oracle = IPriceOracle(oracle_);
        ltvBps = ltvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        borrowDecimals = IERC20(borrowToken_).decimals();
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        collateral.transferFrom(msg.sender, address(this), amount);
        collateralBalance[msg.sender] += amount;
        totalCollateral += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > collateralBalance[msg.sender]) revert BadAmount();
        collateralBalance[msg.sender] -= amount;
        totalCollateral -= amount;
        if (!_isCollateralized(msg.sender)) revert Undercollateralized();
        collateral.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > maxBorrow(msg.sender)) revert ExceedsMaxBorrow();
        if (amount > borrowToken.balanceOf(address(this))) revert InsufficientLiquidity();

        debt[msg.sender] += amount;
        totalDebt += amount;
        borrowToken.transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount, oracle.getPrice());
    }

    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
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
