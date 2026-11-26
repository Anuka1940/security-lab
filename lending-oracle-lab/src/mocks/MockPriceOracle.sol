// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IOracleFeed} from "../interfaces/IPriceOracle.sol";

/// @notice Configurable static price feed for isolated credit market unit tests.
contract StaticPriceFeed is IOracleFeed {
    address public immutable baseAsset;
    address public immutable quoteAsset;
    uint256 public configuredRate;

    constructor(address baseAsset_, address quoteAsset_, uint256 initialRate) {
        baseAsset = baseAsset_;
        quoteAsset = quoteAsset_;
        configuredRate = initialRate;
    }

    function updateRate(uint256 nextRate) external {
        configuredRate = nextRate;
    }

    function readPrice() external view returns (uint256) {
        return configuredRate;
    }
}
