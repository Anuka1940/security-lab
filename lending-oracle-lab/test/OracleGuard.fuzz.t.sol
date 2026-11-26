// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {HardenedForkFixture} from "./BaseForkFixed.t.sol";
import {GuardedTwapFeed} from "../src/oracle/TwapPriceOracle.sol";
import {ChainlinkFeedAdapter} from "../src/oracle/ChainlinkPriceOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @notice Controllable mock Chainlink V3 aggregator for fuzzing decimal scaling and heartbeat freshness.
contract StubChainlinkAggregator is AggregatorV3Interface {
    uint8 public immutable decimals;
    int256 public currentAnswer;
    uint256 public lastUpdatedAt;
    uint80 public currentRoundId;

    constructor(uint8 feedDecimals, int256 initialAnswer) {
        decimals = feedDecimals;
        currentAnswer = initialAnswer;
        lastUpdatedAt = block.timestamp;
        currentRoundId = 1;
    }

    function description() external pure returns (string memory) {
        return "stub-aggregator";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function pushRound(int256 nextAnswer, uint256 timestamp) external {
        currentAnswer = nextAnswer;
        lastUpdatedAt = timestamp;
        currentRoundId++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (currentRoundId, currentAnswer, lastUpdatedAt, lastUpdatedAt, currentRoundId);
    }
}

/// @notice Property-based fuzz suite for TWAP immutability under atomic swaps, deviation guard
///         thresholds, staleness windows, heartbeat cadence, and Chainlink feed normalization.
contract OracleGuardFuzzSuiteTest is HardenedForkFixture {
    uint256 internal constant EQUILIBRIUM_RATE = 2_000e18;

    function testFuzz_sameBlockPumpNeverMovesTwap(uint256 rawSwapInput) public {
        GuardedTwapFeed wideDeviationTwap = _deployTwapFeed(1_000_000);
        _primeOracleHistory(wideDeviationTwap);

        uint256 usdcSwapIn = bound(rawSwapInput, 1e6, 10_000_000e6);
        _buyWethWithUsdc(usdcSwapIn);

        assertEq(wideDeviationTwap.readPrice(), EQUILIBRIUM_RATE);
    }

    function testFuzz_deviationGuardMatchesBoundary(uint256 rawSwapInput) public {
        uint256 usdcSwapIn = bound(rawSwapInput, 1e6, 500_000e6);
        _buyWethWithUsdc(usdcSwapIn);

        uint256 postSwapSpot = _readInstantSpot();
        uint256 observedDeviationBps =
            ((postSwapSpot - EQUILIBRIUM_RATE) * 10_000) / EQUILIBRIUM_RATE;

        if (observedDeviationBps > SPOT_DEVIATION_CAP_BPS) {
            vm.expectRevert();
            twapFeed.readPrice();
        } else {
            assertEq(twapFeed.readPrice(), EQUILIBRIUM_RATE);
        }
    }

    function testFuzz_moderatePumpAccepted(uint256 rawSwapInput) public {
        uint256 usdcSwapIn = bound(rawSwapInput, 1e6, 130_000e6);
        _buyWethWithUsdc(usdcSwapIn);

        uint256 postSwapSpot = _readInstantSpot();
        assertLe(
            ((postSwapSpot - EQUILIBRIUM_RATE) * 10_000) / EQUILIBRIUM_RATE,
            SPOT_DEVIATION_CAP_BPS
        );
        assertEq(twapFeed.readPrice(), EQUILIBRIUM_RATE);
    }

    function testFuzz_stalenessStates(uint256 rawTimeJump) public {
        uint256 elapsed = bound(rawTimeJump, 0, 3 hours);
        vm.warp(block.timestamp + elapsed);

        if (elapsed > STALENESS_LIMIT) {
            vm.expectRevert(abi.encodeWithSelector(GuardedTwapFeed.StaleCheckpoint.selector, elapsed));
            twapFeed.readPrice();
        } else if (elapsed > TWAP_HORIZON) {
            vm.expectRevert();
            twapFeed.readPrice();
        } else {
            assertEq(twapFeed.readPrice(), EQUILIBRIUM_RATE);
        }
    }

    function testFuzz_updateCadence(uint256 rawInterval) public {
        uint256 waitDuration = bound(rawInterval, 0, 2 * HEARTBEAT_COOLDOWN);
        uint256 priorCount = twapFeed.totalObservations();
        vm.warp(block.timestamp + waitDuration);

        if (waitDuration < HEARTBEAT_COOLDOWN) {
            vm.expectRevert();
            twapFeed.recordObservation();
        } else {
            twapFeed.recordObservation();
            assertEq(twapFeed.totalObservations(), priorCount + 1);
            (uint32 checkpointTs,) = twapFeed.latestCheckpoint();
            assertEq(checkpointTs, block.timestamp);
        }
    }

    function testFuzz_minPriceBoundRejected(uint256 rawFloor) public {
        uint256 customFloor = bound(rawFloor, 2_001e18, 99_999e18);
        GuardedTwapFeed highFloorFeed = new GuardedTwapFeed(
            address(ammPool),
            MAINNET_WETH,
            MAINNET_USDC,
            TWAP_HORIZON,
            HEARTBEAT_COOLDOWN,
            STALENESS_LIMIT,
            0,
            customFloor,
            CEILING_PRICE_18
        );
        _primeOracleHistory(highFloorFeed);

        vm.expectRevert();
        highFloorFeed.readPrice();
    }

    function testFuzz_chainlinkDecimalNormalization(uint8 rawDecimals, uint256 rawAnswer) public {
        uint8 feedDecimals = uint8(bound(rawDecimals, 0, 18));
        uint256 maxRawAnswer = 10_000 * (10 ** feedDecimals);
        uint256 answerValue = bound(rawAnswer, 1, maxRawAnswer);

        StubChainlinkAggregator aggregator =
            new StubChainlinkAggregator(feedDecimals, int256(answerValue));
        ChainlinkFeedAdapter adapter = new ChainlinkFeedAdapter(
            address(aggregator), MAINNET_WETH, MAINNET_USDC, 2 hours, 1, 100_000e18
        );

        uint256 expectedNormalized = answerValue * (10 ** (18 - feedDecimals));
        assertEq(adapter.readPrice(), expectedNormalized);
    }

    function testFuzz_chainlinkStaleness(uint256 rawAge) public {
        uint256 elapsedAge = bound(rawAge, 0, 2 hours);
        StubChainlinkAggregator aggregator = new StubChainlinkAggregator(8, 2_000e8);
        aggregator.pushRound(2_000e8, block.timestamp);
        ChainlinkFeedAdapter adapter = new ChainlinkFeedAdapter(
            address(aggregator), MAINNET_WETH, MAINNET_USDC, 1 hours, 1, 100_000e18
        );

        vm.warp(block.timestamp + elapsedAge);

        if (elapsedAge > 1 hours) {
            vm.expectRevert();
            adapter.readPrice();
        } else {
            assertEq(adapter.readPrice(), 2_000e18);
        }
    }
}
