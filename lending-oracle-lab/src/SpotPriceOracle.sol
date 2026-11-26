// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISimpleAMM} from "./interfaces/ISimpleAMM.sol";

contract SpotPriceOracle is IPriceOracle {
    ISimpleAMM public immutable amm;
    address public immutable base;
    address public immutable quote;

    constructor(address amm_, address base_, address quote_) {
        amm = ISimpleAMM(amm_);
        base = base_;
        quote = quote_;
        require(amm.token0() == quote_ && amm.token1() == base_, "UNSUPPORTED_ORDER");
    }

    function getPrice() external view returns (uint256) {
        return amm.spotPrice1In0();
    }
}
