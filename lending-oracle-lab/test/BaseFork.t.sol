// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ConstantProductPool} from "../src/SimpleAMM.sol";
import {InstantSpotFeed} from "../src/SpotPriceOracle.sol";
import {VulnerableCreditMarket} from "../src/LendingPool.sol";
import {AtomicFlashVault} from "../src/FlashLoanPool.sol";
import {FlashPumpExploiter} from "../src/OracleAttackReceiver.sol";

/// @notice Pinned Ethereum mainnet fork harness for the vulnerable spot-priced credit market.
abstract contract VulnerableForkFixture is Test {
    uint256 internal constant PINNED_FORK_BLOCK = 26_000_000;
    uint256 internal constant BPS_SCALE = 10_000;

    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 internal constant INITIAL_AMM_USDC = 2_000_000e6;
    uint256 internal constant INITIAL_AMM_WETH = 1_000e18;
    uint256 internal constant MARKET_USDC_RESERVE = 5_000_000e6;
    uint256 internal constant FLASH_VAULT_USDC = 2_000_000e6;
    uint256 internal constant MAX_LTV_BPS = 8_000;
    uint256 internal constant LIQ_THRESHOLD_BPS = 8_500;
    uint256 internal constant FLASH_FEE_BPS = 9;

    address internal operator = makeAddr("operator");
    address internal borrowerAlice = makeAddr("borrowerAlice");
    address internal exploiterOwner = makeAddr("exploiterOwner");
    address internal arbitrageBot = makeAddr("arbitrageBot");

    ConstantProductPool internal ammPool;
    InstantSpotFeed internal spotFeed;
    VulnerableCreditMarket internal creditMarket;
    AtomicFlashVault internal flashVault;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_FORKING_URL"), vm.envOr("FORK_BLOCK", PINNED_FORK_BLOCK));

        startHoax(operator);
        ammPool = new ConstantProductPool(MAINNET_USDC, MAINNET_WETH);
        spotFeed = new InstantSpotFeed(address(ammPool), MAINNET_WETH, MAINNET_USDC);
        creditMarket = new VulnerableCreditMarket(
            MAINNET_WETH, MAINNET_USDC, address(spotFeed), MAX_LTV_BPS, LIQ_THRESHOLD_BPS
        );
        flashVault = new AtomicFlashVault(MAINNET_USDC, FLASH_FEE_BPS);

        deal(
            MAINNET_USDC,
            operator,
            INITIAL_AMM_USDC + MARKET_USDC_RESERVE + FLASH_VAULT_USDC + 10_000_000e6
        );
        deal(MAINNET_WETH, operator, INITIAL_AMM_WETH + 10_000e18);

        IERC20(MAINNET_USDC).approve(address(ammPool), INITIAL_AMM_USDC);
        IERC20(MAINNET_WETH).approve(address(ammPool), INITIAL_AMM_WETH);
        ammPool.provideLiquidity(INITIAL_AMM_USDC, INITIAL_AMM_WETH);

        IERC20(MAINNET_USDC).transfer(address(creditMarket), MARKET_USDC_RESERVE);
        IERC20(MAINNET_USDC).transfer(address(flashVault), FLASH_VAULT_USDC);

        vm.stopPrank();
    }

    function _supplyWeth(address user, uint256 wethAmount) internal {
        deal(MAINNET_WETH, user, wethAmount);
        vm.startPrank(user);
        IERC20(MAINNET_WETH).approve(address(creditMarket), wethAmount);
        creditMarket.supplyCollateral(wethAmount);
        vm.stopPrank();
    }

    function _seedStableBuffer(address target, uint256 usdcAmount) internal {
        deal(MAINNET_USDC, target, usdcAmount);
    }

    function _createExploiter() internal returns (FlashPumpExploiter exploiterContract) {
        exploiterContract = new FlashPumpExploiter(
            MAINNET_USDC,
            MAINNET_WETH,
            address(ammPool),
            address(creditMarket),
            address(flashVault),
            exploiterOwner
        );
    }
}
