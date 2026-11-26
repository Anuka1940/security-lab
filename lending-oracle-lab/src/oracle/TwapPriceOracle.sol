// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IOracleFeed} from "../interfaces/IPriceOracle.sol";
import {IConstantProductPool} from "../interfaces/ISimpleAMM.sol";

/// @title Time-Weighted Average Price (TWAP) oracle with multi-layer sanity and deviation guards
/// @notice Computes collateral value from cumulative AMM price checkpoints over a rolling time
///         horizon rather than instantaneous reserves. Rejects uninitialized buffers, stale
///         checkpoints, missing window coverage, zero reserves, out-of-range prices, and
///         excessive spot-versus-TWAP divergence. Always returns an 18-decimal normalized price.
contract GuardedTwapFeed is IOracleFeed {
    uint256 public constant BPS_SCALE = 10_000;
    uint256 public constant RING_CAPACITY = 64;

    IConstantProductPool public immutable liquidityPool;
    address public immutable baseAsset;
    address public immutable quoteAsset;
    uint8 private immutable baseAssetDecimals;
    uint8 private immutable quoteAssetDecimals;

    uint32 public immutable twapHorizon;
    uint32 public immutable heartbeatCooldown;
    uint32 public immutable stalenessLimit;
    uint256 public immutable deviationLimitBps;
    uint256 public immutable floorPrice;
    uint256 public immutable ceilingPrice;

    struct PriceCheckpoint {
        uint32 recordedAt;
        uint256 cumulativeValue;
    }

    PriceCheckpoint[RING_CAPACITY] private ringBuffer;
    uint256 private totalCheckpoints;

    error InsufficientObservations();
    error HeartbeatCooldownActive();
    error StaleCheckpoint(uint256 elapsedAge);
    error WindowUncovered();
    error ZeroSpotReserve();
    error PriceOutsideBounds(uint256 twapPrice);
    error SpotDeviationTooHigh(uint256 observedDeviationBps);
    error InvalidPoolTokenOrder();

    event CheckpointRecorded(uint32 indexed timestamp, uint256 cumulativePrice);

    constructor(
        address poolAddress,
        address baseAsset_,
        address quoteAsset_,
        uint32 twapHorizon_,
        uint32 heartbeatCooldown_,
        uint32 stalenessLimit_,
        uint256 deviationLimitBps_,
        uint256 floorPrice_,
        uint256 ceilingPrice_
    ) {
        if (
            IConstantProductPool(poolAddress).asset0() != quoteAsset_
                || IConstantProductPool(poolAddress).asset1() != baseAsset_
        ) {
            revert InvalidPoolTokenOrder();
        }
        require(twapHorizon_ >= 2 * heartbeatCooldown_, "HORIZON_TOO_SHORT");
        require(stalenessLimit_ >= heartbeatCooldown_, "STALENESS_BELOW_COOLDOWN");
        require(deviationLimitBps_ <= 1_000_000, "DEVIATION_CAP_INVALID");
        require(floorPrice_ > 0 && floorPrice_ < ceilingPrice_, "INVALID_PRICE_BOUNDS");

        liquidityPool = IConstantProductPool(poolAddress);
        baseAsset = baseAsset_;
        quoteAsset = quoteAsset_;
        baseAssetDecimals = _queryDecimals(baseAsset_);
        quoteAssetDecimals = _queryDecimals(quoteAsset_);
        twapHorizon = twapHorizon_;
        heartbeatCooldown = heartbeatCooldown_;
        stalenessLimit = stalenessLimit_;
        deviationLimitBps = deviationLimitBps_;
        floorPrice = floorPrice_;
        ceilingPrice = ceilingPrice_;

        _pushCheckpoint();
    }

    /// @notice Permissionless keeper entrypoint to record a new cumulative price observation.
    function recordObservation() external {
        PriceCheckpoint memory head = _headCheckpoint();
        if (block.timestamp - head.recordedAt < heartbeatCooldown) revert HeartbeatCooldownActive();
        _pushCheckpoint();
    }

    /// @inheritdoc IOracleFeed
    function readPrice() external returns (uint256 twapPrice) {
        uint256 recordedCount = totalCheckpoints;
        if (recordedCount < 2) revert InsufficientObservations();

        uint32 currentTs = uint32(block.timestamp);
        PriceCheckpoint memory head = _headCheckpoint();
        uint256 checkpointAge = currentTs - head.recordedAt;
        if (checkpointAge > stalenessLimit) revert StaleCheckpoint(checkpointAge);

        uint32 boundaryTs = currentTs - twapHorizon;
        if (head.recordedAt < boundaryTs) revert WindowUncovered();

        (PriceCheckpoint memory olderPoint, PriceCheckpoint memory newerPoint) = _locateBracketingPair(boundaryTs);
        if (olderPoint.recordedAt == 0) revert InsufficientObservations();

        uint256 interpolatedCumulative = olderPoint.cumulativeValue;
        if (olderPoint.recordedAt != boundaryTs) {
            uint256 intervalSpan = newerPoint.recordedAt - olderPoint.recordedAt;
            uint256 cumulativeGain = newerPoint.cumulativeValue - olderPoint.cumulativeValue;
            interpolatedCumulative += (cumulativeGain * (boundaryTs - olderPoint.recordedAt)) / intervalSpan;
        }

        liquidityPool.syncAccumulator();
        uint256 currentCumulative = liquidityPool.cumulativePrice1();
        twapPrice = (currentCumulative - interpolatedCumulative) / twapHorizon;

        if (twapPrice < floorPrice || twapPrice > ceilingPrice) revert PriceOutsideBounds(twapPrice);

        uint256 currentSpot = _calculateInstantSpot();
        if (currentSpot == 0) revert ZeroSpotReserve();

        uint256 observedDeviationBps = currentSpot > twapPrice
            ? ((currentSpot - twapPrice) * BPS_SCALE) / twapPrice
            : ((twapPrice - currentSpot) * BPS_SCALE) / twapPrice;

        if (observedDeviationBps > deviationLimitBps) revert SpotDeviationTooHigh(observedDeviationBps);
    }

    function latestCheckpoint() external view returns (uint32 recordedAt, uint256 cumulativeValue) {
        PriceCheckpoint memory head = _headCheckpoint();
        return (head.recordedAt, head.cumulativeValue);
    }

    function totalObservations() external view returns (uint256) {
        return totalCheckpoints;
    }

    function _pushCheckpoint() private {
        liquidityPool.syncAccumulator();
        uint256 currentCumulative = liquidityPool.cumulativePrice1();
        ringBuffer[totalCheckpoints % RING_CAPACITY] =
            PriceCheckpoint(uint32(block.timestamp), currentCumulative);
        totalCheckpoints++;
        emit CheckpointRecorded(uint32(block.timestamp), currentCumulative);
    }

    function _headCheckpoint() private view returns (PriceCheckpoint memory) {
        if (totalCheckpoints == 0) revert InsufficientObservations();
        return ringBuffer[(totalCheckpoints - 1) % RING_CAPACITY];
    }

    function _locateBracketingPair(uint32 boundaryTs)
        private
        view
        returns (PriceCheckpoint memory olderPoint, PriceCheckpoint memory newerPoint)
    {
        uint256 recordedCount = totalCheckpoints;
        uint256 available = recordedCount < RING_CAPACITY ? recordedCount : RING_CAPACITY;
        PriceCheckpoint memory following;

        for (uint256 offset = 1; offset <= available; offset++) {
            PriceCheckpoint memory entry = ringBuffer[(recordedCount - offset) % RING_CAPACITY];
            if (entry.recordedAt <= boundaryTs) {
                olderPoint = entry;
                newerPoint = following;
                break;
            }
            following = entry;
        }
    }

    function _calculateInstantSpot() private view returns (uint256) {
        uint256 res0 = liquidityPool.poolReserve0();
        uint256 res1 = liquidityPool.poolReserve1();
        if (res0 == 0 || res1 == 0) return 0;
        return (res0 * (10 ** baseAssetDecimals) * 1e18) / (res1 * (10 ** quoteAssetDecimals));
    }

    function _queryDecimals(address tokenAddress) private view returns (uint8) {
        (bool success, bytes memory returnData) =
            tokenAddress.staticcall(abi.encodeWithSignature("decimals()"));
        require(success && returnData.length >= 32, "DECIMAL_QUERY_FAILED");
        return abi.decode(returnData, (uint8));
    }
}
