// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ConstantProductPool} from "../src/SimpleAMM.sol";
import {HardenedCreditMarket} from "../src/LendingPoolFix.sol";
import {AtomicFlashVault} from "../src/FlashLoanPool.sol";
import {FlashPumpExploiter} from "../src/OracleAttackReceiver.sol";
import {GuardedTwapFeed} from "../src/oracle/TwapPriceOracle.sol";

/// @notice Pinned Ethereum mainnet fork harness for the hardened TWAP-backed credit market.
abstract contract HardenedForkFixture is Test {
    uint256 internal constant PINNED_FORK_BLOCK = 26_000_000;

    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 internal constant INITIAL_AMM_USDC = 2_000_000e6;
    uint256 internal constant INITIAL_AMM_WETH = 1_000e18;
    uint256 internal constant MARKET_USDC_RESERVE = 5_000_000e6;
    uint256 internal constant FLASH_VAULT_USDC = 2_000_000e6;
    uint256 internal constant MAX_LTV_BPS = 8_000;
    uint256 internal constant LIQ_THRESHOLD_BPS = 8_500;
    uint256 internal constant FLASH_FEE_BPS = 9;

    uint32 internal constant TWAP_HORIZON = 30 minutes;
    uint32 internal constant HEARTBEAT_COOLDOWN = 5 minutes;
    uint32 internal constant STALENESS_LIMIT = 40 minutes;
    uint256 internal constant SPOT_DEVIATION_CAP_BPS = 1_500;
    uint256 internal constant FLOOR_PRICE_18 = 100e18;
    uint256 internal constant CEILING_PRICE_18 = 100_000e18;

    address internal operator = makeAddr("operator");
    address internal borrowerAlice = makeAddr("borrowerAlice");
    address internal borrowerBob = makeAddr("borrowerBob");
    address internal exploiterOwner = makeAddr("exploiterOwner");
    address internal arbitrageBot = makeAddr("arbitrageBot");

    ConstantProductPool internal ammPool;
    GuardedTwapFeed internal twapFeed;
    HardenedCreditMarket internal creditMarket;
    AtomicFlashVault internal flashVault;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_FORKING_URL"), vm.envOr("FORK_BLOCK", PINNED_FORK_BLOCK));

        startHoax(operator);
        ammPool = new ConstantProductPool(MAINNET_USDC, MAINNET_WETH);
        flashVault = new AtomicFlashVault(MAINNET_USDC, FLASH_FEE_BPS);
        twapFeed = _deployTwapFeed(SPOT_DEVIATION_CAP_BPS);
        creditMarket = _deployCreditMarket(address(twapFeed));

        deal(
            MAINNET_USDC,
            operator,
            INITIAL_AMM_USDC + MARKET_USDC_RESERVE + FLASH_VAULT_USDC + 50_000_000e6
        );
        deal(MAINNET_WETH, operator, INITIAL_AMM_WETH + 50_000e18);

        IERC20(MAINNET_USDC).approve(address(ammPool), INITIAL_AMM_USDC);
        IERC20(MAINNET_WETH).approve(address(ammPool), INITIAL_AMM_WETH);
        ammPool.provideLiquidity(INITIAL_AMM_USDC, INITIAL_AMM_WETH);

        IERC20(MAINNET_USDC).transfer(address(creditMarket), MARKET_USDC_RESERVE);
        IERC20(MAINNET_USDC).transfer(address(flashVault), FLASH_VAULT_USDC);

        _primeOracleHistory(twapFeed);
        vm.stopPrank();
    }

    function _deployTwapFeed(uint256 deviationLimitBps) internal returns (GuardedTwapFeed feedInstance) {
        feedInstance = new GuardedTwapFeed(
            address(ammPool),
            MAINNET_WETH,
            MAINNET_USDC,
            TWAP_HORIZON,
            HEARTBEAT_COOLDOWN,
            STALENESS_LIMIT,
            deviationLimitBps,
            FLOOR_PRICE_18,
            CEILING_PRICE_18
        );
    }

    function _deployCreditMarket(address oracleAddress) internal returns (HardenedCreditMarket marketInstance) {
        marketInstance = new HardenedCreditMarket(
            MAINNET_WETH, MAINNET_USDC, oracleAddress, MAX_LTV_BPS, LIQ_THRESHOLD_BPS
        );
    }

    function _primeOracleHistory(GuardedTwapFeed feedInstance) internal {
        vm.warp(block.timestamp + TWAP_HORIZON);
        feedInstance.recordObservation();
        vm.warp(block.timestamp + TWAP_HORIZON);
        feedInstance.recordObservation();
    }

    function _advanceAndRecordHeartbeat() internal {
        vm.warp(block.timestamp + HEARTBEAT_COOLDOWN);
        twapFeed.recordObservation();
    }

    function _supplyWeth(address user, uint256 wethAmount) internal {
        deal(MAINNET_WETH, user, wethAmount);
        vm.startPrank(user);
        IERC20(MAINNET_WETH).approve(address(creditMarket), wethAmount);
        creditMarket.supplyCollateral(wethAmount);
        vm.stopPrank();
    }

    function _supplyWethToMarket(address targetMarket, address user, uint256 wethAmount) internal {
        deal(MAINNET_WETH, user, wethAmount);
        vm.startPrank(user);
        IERC20(MAINNET_WETH).approve(targetMarket, wethAmount);
        HardenedCreditMarket(targetMarket).supplyCollateral(wethAmount);
        vm.stopPrank();
    }

    function _buyWethWithUsdc(uint256 usdcIn) internal returns (uint256 wethOut) {
        deal(MAINNET_USDC, arbitrageBot, usdcIn);
        vm.startPrank(arbitrageBot);
        IERC20(MAINNET_USDC).approve(address(ammPool), usdcIn);
        wethOut = ammPool.swapExactIn(usdcIn, 0, MAINNET_USDC, arbitrageBot);
        vm.stopPrank();
    }

    function _sellWethForUsdc(uint256 wethIn) internal {
        deal(MAINNET_WETH, arbitrageBot, wethIn);
        vm.startPrank(arbitrageBot);
        IERC20(MAINNET_WETH).approve(address(ammPool), wethIn);
        ammPool.swapExactIn(wethIn, 0, MAINNET_WETH, arbitrageBot);
        vm.stopPrank();
    }

    function _createExploiterForMarket(address targetMarket) internal returns (FlashPumpExploiter exploiterContract) {
        exploiterContract = new FlashPumpExploiter(
            MAINNET_USDC,
            MAINNET_WETH,
            address(ammPool),
            targetMarket,
            address(flashVault),
            exploiterOwner
        );
    }

    function _grantUsdc(address recipient, uint256 usdcAmount) internal {
        deal(MAINNET_USDC, recipient, usdcAmount);
    }

    function _readInstantSpot() internal view returns (uint256) {
        return ammPool.quoteAsset1InAsset0();
    }
}
