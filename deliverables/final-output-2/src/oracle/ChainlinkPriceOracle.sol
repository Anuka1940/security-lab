// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title Chainlink fallback / alternative price source
/// @notice Demonstrates the second mitigation architecture: an external push oracle
///         with round-completeness, staleness, positive-price, bounds, and decimal
///         normalization checks. Not used by the default TWAP deployment path.
contract ChainlinkPriceOracle is IPriceOracle {
    AggregatorV3Interface public immutable feed;
    address public immutable base;
    address public immutable quote;
    uint8 private immutable feedDecimals;
    uint256 public immutable maxStaleness;
    uint256 public immutable minPrice;
    uint256 public immutable maxPrice;

    error StalePrice(uint256 age);
    error InvalidPrice(int256 answer);
    error IncompleteRound();
    error PriceOutOfBounds(uint256 price);

    constructor(
        address feed_,
        address base_,
        address quote_,
        uint256 maxStaleness_,
        uint256 minPrice_,
        uint256 maxPrice_
    ) {
        require(minPrice_ > 0 && minPrice_ < maxPrice_, "BAD_BOUNDS");
        feed = AggregatorV3Interface(feed_);
        base = base_;
        quote = quote_;
        feedDecimals = AggregatorV3Interface(feed_).decimals();
        maxStaleness = maxStaleness_;
        minPrice = minPrice_;
        maxPrice = maxPrice_;
    }

    function getPrice() external view returns (uint256 price) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        if (answeredInRound < roundId || updatedAt == 0) revert IncompleteRound();

        uint256 age = block.timestamp - updatedAt;
        if (age > maxStaleness) revert StalePrice(age);

        price = uint256(answer);
        if (feedDecimals < 18) {
            price *= 10 ** (18 - feedDecimals);
        } else if (feedDecimals > 18) {
            price /= 10 ** (feedDecimals - 18);
        }

        if (price < minPrice || price > maxPrice) revert PriceOutOfBounds(price);
    }
}
