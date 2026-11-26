// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {SpotPriceOracle} from "../src/SpotPriceOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {FlashLoanPool} from "../src/FlashLoanPool.sol";

contract DeployLab is Script {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        vm.startBroadcast();
        SimpleAMM amm = new SimpleAMM(USDC, WETH);
        SpotPriceOracle oracle = new SpotPriceOracle(address(amm), WETH, USDC);
        new LendingPool(WETH, USDC, address(oracle), 8_000, 8_500);
        new FlashLoanPool(USDC, 9);
        vm.stopBroadcast();
    }
}
