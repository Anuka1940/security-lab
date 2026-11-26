// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IOracleFeed} from "./interfaces/IPriceOracle.sol";
import {IConstantProductPool} from "./interfaces/ISimpleAMM.sol";

/// @notice Vulnerable oracle that directly exposes the AMM's unvalidated instantaneous spot ratio.
contract InstantSpotFeed is IOracleFeed {
    IConstantProductPool public immutable liquidityPool;
    address public immutable baseAsset;
    address public immutable quoteAsset;

    constructor(address poolAddress, address baseAsset_, address quoteAsset_) {
        liquidityPool = IConstantProductPool(poolAddress);
        baseAsset = baseAsset_;
        quoteAsset = quoteAsset_;
        require(
            liquidityPool.asset0() == quoteAsset_ && liquidityPool.asset1() == baseAsset_,
            "TOKEN_ORDER_MISMATCH"
        );
    }

    function readPrice() external view returns (uint256) {
        return liquidityPool.quoteAsset1InAsset0();
    }
}
