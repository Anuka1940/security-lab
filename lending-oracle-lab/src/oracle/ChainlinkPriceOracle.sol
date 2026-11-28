// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IOracleFeed} from "../interfaces/IPriceOracle.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";


contract ChainlinkFeedAdapter is IOracleFeed {
    AggregatorV3Interface public immutable aggregator;
    address public immutable baseAsset;
    address public immutable quoteAsset;
    uint8 private immutable aggregatorDecimals;
    uint256 public immutable maxHeartbeatAge;
    uint256 public immutable floorPrice;
    uint256 public immutable ceilingPrice;

    constructor(
        address aggregatorAddress,
        address baseAsset_,
        address quoteAsset_,
        uint256 maxHeartbeatAge_,
        uint256 floorPrice_,
        uint256 ceilingPrice_
    ) {
        require(floorPrice_ > 0 && floorPrice_ < ceilingPrice_, "INVALID_PRICE_BOUNDS");
        aggregator = AggregatorV3Interface(aggregatorAddress);
        baseAsset = baseAsset_;
        quoteAsset = quoteAsset_;
        aggregatorDecimals = AggregatorV3Interface(aggregatorAddress).decimals();
        maxHeartbeatAge = maxHeartbeatAge_;
        floorPrice = floorPrice_;
        ceilingPrice = ceilingPrice_;
    }

    function readPrice() external view returns (uint256 normalizedPrice) {
        (uint80 roundId, int256 rawAnswer,, uint256 updatedAt, uint80 answeredInRound) =
            aggregator.latestRoundData();
        if (rawAnswer <= 0) revert();
        if (answeredInRound < roundId || updatedAt == 0) revert();

        uint256 elapsedAge = block.timestamp - updatedAt;
        if (elapsedAge > maxHeartbeatAge) revert();

        normalizedPrice = uint256(rawAnswer);
        if (aggregatorDecimals < 18) {
            normalizedPrice *= 10 ** (18 - aggregatorDecimals);
        } else if (aggregatorDecimals > 18) {
            normalizedPrice /= 10 ** (aggregatorDecimals - 18);
        }

        if (normalizedPrice < floorPrice || normalizedPrice > ceilingPrice) {
            revert();
        }
    }
}
