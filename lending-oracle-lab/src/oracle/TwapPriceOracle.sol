// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {ISimpleAMM} from "../interfaces/ISimpleAMM.sol";

/// @title Manipulation-resistant AMM TWAP oracle with validation gates
/// @notice Collateral is priced from a time-weighted average, not the instantaneous
///         spot price. A same-block flash-loan pump therefore cannot move the value
///         used for borrowing. Guards reject stale, out-of-range, zero, and
///         abnormally deviating markets. Output is always normalized to 18 decimals.
contract TwapPriceOracle is IPriceOracle {
    uint256 public constant BPS = 10_000;
    uint256 public constant BUFFER_SIZE = 64;

    ISimpleAMM public immutable amm;
    address public immutable base;
    address public immutable quote;
    uint8 private immutable baseDecimals;
    uint8 private immutable quoteDecimals;

    uint32 public immutable window;
    uint32 public immutable minUpdateInterval;
    uint32 public immutable maxStaleness;
    uint256 public immutable maxDeviationBps;
    uint256 public immutable minPrice;
    uint256 public immutable maxPrice;

    struct Observation {
        uint32 timestamp;
        uint256 cumulative;
    }

    Observation[BUFFER_SIZE] private observations;
    uint256 private observationCount;

    error OracleNotReady();
    error UpdateTooSoon();
    error OracleStale(uint256 age);
    error NoRecentObservation();
    error InvalidSpotPrice();
    error PriceOutOfBounds(uint256 price);
    error ExcessiveSpotDeviation(uint256 deviationBps);
    error UnsupportedTokenOrder();

    event OracleUpdated(uint32 indexed timestamp, uint256 cumulative);

    constructor(
        address amm_,
        address base_,
        address quote_,
        uint32 window_,
        uint32 minUpdateInterval_,
        uint32 maxStaleness_,
        uint256 maxDeviationBps_,
        uint256 minPrice_,
        uint256 maxPrice_
    ) {
        if (ISimpleAMM(amm_).token0() != quote_ || ISimpleAMM(amm_).token1() != base_) {
            revert UnsupportedTokenOrder();
        }
        require(window_ >= 2 * minUpdateInterval_, "WINDOW_TOO_SHORT");
        require(maxStaleness_ >= minUpdateInterval_, "STALENESS_TOO_SHORT");
        require(maxDeviationBps_ <= 1_000_000, "DEVIATION_TOO_HIGH");
        require(minPrice_ > 0 && minPrice_ < maxPrice_, "BAD_BOUNDS");

        amm = ISimpleAMM(amm_);
        base = base_;
        quote = quote_;
        baseDecimals = _decimals(base_);
        quoteDecimals = _decimals(quote_);
        window = window_;
        minUpdateInterval = minUpdateInterval_;
        maxStaleness = maxStaleness_;
        maxDeviationBps = maxDeviationBps_;
        minPrice = minPrice_;
        maxPrice = maxPrice_;

        _record();
    }

    /// @notice Permissionless heartbeat. Safe to call from a keeper.
    function update() external {
        Observation memory latest = _latest();
        if (block.timestamp - latest.timestamp < minUpdateInterval) revert UpdateTooSoon();
        _record();
    }

    /// @inheritdoc IPriceOracle
    function getPrice() external returns (uint256 price) {
        uint256 count = observationCount;
        if (count < 2) revert OracleNotReady();

        uint32 now32 = uint32(block.timestamp);
        Observation memory latest = _latest();
        uint256 age = now32 - latest.timestamp;
        if (age > maxStaleness) revert OracleStale(age);

        uint32 target = now32 - window;
        if (latest.timestamp < target) revert NoRecentObservation();

        (Observation memory beforeTarget, Observation memory afterTarget) = _bracket(target);
        if (beforeTarget.timestamp == 0) revert OracleNotReady();

        uint256 cumulativeAtTarget = beforeTarget.cumulative;
        if (beforeTarget.timestamp != target) {
            uint256 span = afterTarget.timestamp - beforeTarget.timestamp;
            uint256 delta = afterTarget.cumulative - beforeTarget.cumulative;
            cumulativeAtTarget += (delta * (target - beforeTarget.timestamp)) / span;
        }

        amm.accrue();
        uint256 cumulativeNow = amm.price1CumulativeLast();
        price = (cumulativeNow - cumulativeAtTarget) / window;

        if (price < minPrice || price > maxPrice) revert PriceOutOfBounds(price);

        uint256 spot = _spotPrice();
        if (spot == 0) revert InvalidSpotPrice();

        uint256 deviationBps;
        if (spot > price) {
            deviationBps = ((spot - price) * BPS) / price;
        } else {
            deviationBps = ((price - spot) * BPS) / price;
        }
        if (deviationBps > maxDeviationBps) revert ExcessiveSpotDeviation(deviationBps);
    }

    function latestObservation() external view returns (uint32 timestamp, uint256 cumulative) {
        Observation memory latest = _latest();
        return (latest.timestamp, latest.cumulative);
    }

    function observationCount_() external view returns (uint256) {
        return observationCount;
    }

    function _record() private {
        amm.accrue();
        uint256 cumulative = amm.price1CumulativeLast();
        observations[observationCount % BUFFER_SIZE] = Observation(uint32(block.timestamp), cumulative);
        observationCount++;
        emit OracleUpdated(uint32(block.timestamp), cumulative);
    }

    function _latest() private view returns (Observation memory) {
        if (observationCount == 0) revert OracleNotReady();
        return observations[(observationCount - 1) % BUFFER_SIZE];
    }

    function _bracket(uint32 target)
        private
        view
        returns (Observation memory beforeTarget, Observation memory afterTarget)
    {
        uint256 count = observationCount;
        uint256 length = count < BUFFER_SIZE ? count : BUFFER_SIZE;
        Observation memory newer;

        for (uint256 i = 1; i <= length; i++) {
            Observation memory candidate = observations[(count - i) % BUFFER_SIZE];
            if (candidate.timestamp <= target) {
                beforeTarget = candidate;
                afterTarget = newer;
                break;
            }
            newer = candidate;
        }
    }

    function _spotPrice() private view returns (uint256) {
        uint256 reserve0 = amm.reserve0();
        uint256 reserve1 = amm.reserve1();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        return (reserve0 * 10 ** baseDecimals * 1e18) / (reserve1 * 10 ** quoteDecimals);
    }

    function _decimals(address token) private view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && data.length >= 32, "DECIMALS_FAILED");
        return abi.decode(data, (uint8));
    }
}
