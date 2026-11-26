// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {BaseForkFixedTest} from "./BaseForkFixed.t.sol";
import {TwapPriceOracle} from "../src/oracle/TwapPriceOracle.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function description() external pure returns (string memory) {
        return "mock";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

contract OracleGuardFuzzTest is BaseForkFixedTest {
    uint256 internal constant BASELINE_PRICE = 2_000e18;

    function testFuzz_sameBlockPumpNeverMovesTwap(uint256 pumpSeed) public {
        TwapPriceOracle twapOnly = _newOracle(1_000_000);
        _warmUp(twapOnly);

        uint256 pumpAmount = bound(pumpSeed, 1e6, 10_000_000e6);
        _pump(pumpAmount);

        assertEq(twapOnly.getPrice(), BASELINE_PRICE);
    }

    function testFuzz_deviationGuardMatchesBoundary(uint256 pumpSeed) public {
        uint256 pumpAmount = bound(pumpSeed, 1e6, 500_000e6);
        _pump(pumpAmount);

        uint256 spot = _currentSpot();
        uint256 deviationBps = ((spot - BASELINE_PRICE) * 10_000) / BASELINE_PRICE;

        if (deviationBps > MAX_DEVIATION_BPS) {
            vm.expectRevert();
            oracle.getPrice();
        } else {
            assertEq(oracle.getPrice(), BASELINE_PRICE);
        }
    }

    function testFuzz_moderatePumpAccepted(uint256 pumpSeed) public {
        uint256 pumpAmount = bound(pumpSeed, 1e6, 130_000e6);
        _pump(pumpAmount);

        uint256 spot = _currentSpot();
        assertLe(((spot - BASELINE_PRICE) * 10_000) / BASELINE_PRICE, MAX_DEVIATION_BPS);
        assertEq(oracle.getPrice(), BASELINE_PRICE);
    }

    function testFuzz_stalenessStates(uint256 ageSeed) public {
        uint256 age = bound(ageSeed, 0, 3 hours);
        vm.warp(block.timestamp + age);

        if (age > MAX_STALENESS) {
            vm.expectRevert(abi.encodeWithSelector(TwapPriceOracle.OracleStale.selector, age));
            oracle.getPrice();
        } else if (age > TWAP_WINDOW) {
            vm.expectRevert();
            oracle.getPrice();
        } else {
            assertEq(oracle.getPrice(), BASELINE_PRICE);
        }
    }

    function testFuzz_updateCadence(uint256 deltaSeed) public {
        uint256 delta = bound(deltaSeed, 0, 2 * MIN_UPDATE_INTERVAL);
        uint256 countBefore = oracle.observationCount_();
        vm.warp(block.timestamp + delta);

        if (delta < MIN_UPDATE_INTERVAL) {
            vm.expectRevert();
            oracle.update();
        } else {
            oracle.update();
            assertEq(oracle.observationCount_(), countBefore + 1);
            (uint32 timestamp,) = oracle.latestObservation();
            assertEq(timestamp, block.timestamp);
        }
    }

    function testFuzz_minPriceBoundRejected(uint256 minSeed) public {
        uint256 minPrice = bound(minSeed, 2_001e18, 99_999e18);
        TwapPriceOracle narrow = new TwapPriceOracle(
            address(amm), WETH, USDC, TWAP_WINDOW, MIN_UPDATE_INTERVAL, MAX_STALENESS, 0, minPrice, MAX_PRICE
        );
        _warmUp(narrow);

        vm.expectRevert();
        narrow.getPrice();
    }

    function testFuzz_chainlinkDecimalNormalization(uint8 feedDecimals, uint256 answerSeed) public {
        feedDecimals = uint8(bound(feedDecimals, 0, 18));
        uint256 maxAnswer = 10_000 * 10 ** feedDecimals;
        uint256 answer = bound(answerSeed, 1, maxAnswer);

        MockAggregatorV3 feed = new MockAggregatorV3(feedDecimals, int256(answer));
        ChainlinkPriceOracle chainlink = new ChainlinkPriceOracle(address(feed), WETH, USDC, 2 hours, 1, 100_000e18);

        uint256 expected = answer * 10 ** (18 - feedDecimals);
        assertEq(chainlink.getPrice(), expected);
    }

    function testFuzz_chainlinkStaleness(uint256 ageSeed) public {
        uint256 age = bound(ageSeed, 0, 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 2_000e8);
        feed.setAnswer(2_000e8, block.timestamp);
        ChainlinkPriceOracle chainlink = new ChainlinkPriceOracle(address(feed), WETH, USDC, 1 hours, 1, 100_000e18);

        vm.warp(block.timestamp + age);

        if (age > 1 hours) {
            vm.expectRevert();
            chainlink.getPrice();
        } else {
            assertEq(chainlink.getPrice(), 2_000e18);
        }
    }
}
