// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    address public immutable base;
    address public immutable quote;
    uint256 public price;

    constructor(address base_, address quote_, uint256 price_) {
        base = base_;
        quote = quote_;
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }
}
