// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Script} from "forge-std/Script.sol";
import {ConstantProductPool} from "../src/SimpleAMM.sol";
import {InstantSpotFeed} from "../src/SpotPriceOracle.sol";
import {VulnerableCreditMarket} from "../src/LendingPool.sol";
import {AtomicFlashVault} from "../src/FlashLoanPool.sol";

contract DeployLabScript is Script {
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        vm.startBroadcast();
        ConstantProductPool pool = new ConstantProductPool(MAINNET_USDC, MAINNET_WETH);
        InstantSpotFeed spotFeed = new InstantSpotFeed(address(pool), MAINNET_WETH, MAINNET_USDC);
        new VulnerableCreditMarket(MAINNET_WETH, MAINNET_USDC, address(spotFeed), 8_000, 8_500);
        new AtomicFlashVault(MAINNET_USDC, 9);
        vm.stopBroadcast();
    }
}
