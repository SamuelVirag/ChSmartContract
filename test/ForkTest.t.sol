// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {ChRouter} from "../src/ChRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Fork Test with Real Mainnet Tokens
/// @notice Deploys ChSwap on a mainnet fork and tests with real USDC, USDT, WBTC, WETH
/// @dev Run with: forge test --match-contract ForkTest --fork-url $ETH_RPC_URL -vv
contract ForkTest is Test {
    // Real mainnet token addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 decimals
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 decimals, missing return value
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 8 decimals

    ChFactory factory;
    ChRouter router;

    address alice = makeAddr("alice");

    function setUp() public {
        // Skip if not running on a fork (WETH won't exist at the mainnet address)
        if (WETH.code.length == 0) {
            vm.skip(true);
        }

        // Deploy our DEX on mainnet fork
        factory = new ChFactory(address(this));
        router = new ChRouter(address(factory), WETH);

        // Fund alice with real tokens via deal()
        deal(WETH, alice, 100 ether);
        deal(USDC, alice, 1_000_000 * 1e6); // 1M USDC (6 decimals)
        deal(USDT, alice, 1_000_000 * 1e6); // 1M USDT (6 decimals)
        deal(WBTC, alice, 100 * 1e8); // 100 WBTC (8 decimals)

        // Approve router
        vm.startPrank(alice);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(WBTC).approve(address(router), type(uint256).max);
        // USDT requires zero-first approval pattern
        (bool s,) = USDT.call(abi.encodeWithSelector(IERC20.approve.selector, address(router), 0));
        require(s, "USDT zero approve failed");
        (s,) = USDT.call(abi.encodeWithSelector(IERC20.approve.selector, address(router), type(uint256).max));
        require(s, "USDT approve failed");
        vm.stopPrank();
    }

    // ============ WETH/USDC (18/6 decimals - most common pair) ============

    function test_fork_wethUsdc_addLiquidityAndSwap() public {
        // Add liquidity: 10 WETH + 25,000 USDC (roughly $2500/ETH)
        vm.startPrank(alice);
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            router.addLiquidity(WETH, USDC, 10 ether, 25_000 * 1e6, 0, 0, alice, block.timestamp + 1, 0);
        vm.stopPrank();

        assertGt(liquidity, 0, "No LP tokens minted for WETH/USDC");
        console.log("WETH/USDC LP tokens:", liquidity);
        console.log("WETH deposited:", amountA);
        console.log("USDC deposited:", amountB);

        // Swap 0.1 WETH for USDC
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256[] memory amounts = router.swapExactTokensForTokens(0.1 ether, 0, path, alice, block.timestamp + 1);

        uint256 usdcReceived = IERC20(USDC).balanceOf(alice) - usdcBefore;
        assertGt(usdcReceived, 0, "No USDC received from swap");
        console.log("Swapped 0.1 WETH for USDC:", usdcReceived);
    }

    // ============ USDT (missing return value - SafeTransfer test) ============

    function test_fork_usdt_safeTransferHandling() public {
        // USDT doesn't return bool on transfer - our _safeTransfer handles this
        // Add USDT/USDC liquidity (stablecoin pair, both 6 decimals)
        vm.startPrank(alice);
        (,, uint256 liquidity) =
            router.addLiquidity(USDT, USDC, 100_000 * 1e6, 100_000 * 1e6, 0, 0, alice, block.timestamp + 1, 0);
        vm.stopPrank();

        assertGt(liquidity, 0, "No LP tokens minted for USDT/USDC");
        console.log("USDT/USDC LP tokens:", liquidity);

        // Swap USDC → USDT (USDT transfer out must handle missing return)
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = USDT;

        uint256 usdtBefore = IERC20(USDT).balanceOf(alice);
        vm.prank(alice);
        router.swapExactTokensForTokens(1000 * 1e6, 0, path, alice, block.timestamp + 1);

        uint256 usdtReceived = IERC20(USDT).balanceOf(alice) - usdtBefore;
        assertGt(usdtReceived, 0, "No USDT received - safeTransfer may have failed");
        console.log("Swapped 1000 USDC for USDT:", usdtReceived);
    }

    // ============ WBTC (8 decimals - low decimal precision test) ============

    function test_fork_wbtc_lowDecimalPrecision() public {
        // Add WBTC/WETH liquidity (8 and 18 decimals)
        vm.startPrank(alice);
        (,, uint256 liquidity) = router.addLiquidity(
            WBTC,
            WETH,
            10 * 1e8,
            100 ether, // ~10 BTC : 100 ETH
            0,
            0,
            alice,
            block.timestamp + 1,
            0
        );
        vm.stopPrank();

        assertGt(liquidity, 0, "No LP tokens minted for WBTC/WETH");
        console.log("WBTC/WETH LP tokens:", liquidity);

        // Small WBTC swap (0.01 BTC) to test precision
        address[] memory path = new address[](2);
        path[0] = WBTC;
        path[1] = WETH;

        uint256 wethBefore = IERC20(WETH).balanceOf(alice);
        vm.prank(alice);
        router.swapExactTokensForTokens(
            1e6,
            0,
            path,
            alice,
            block.timestamp + 1 // 0.01 WBTC
        );

        uint256 wethReceived = IERC20(WETH).balanceOf(alice) - wethBefore;
        assertGt(wethReceived, 0, "No WETH received for WBTC swap");
        console.log("Swapped 0.01 WBTC for WETH:", wethReceived);
    }

    // ============ MULTI-HOP with real tokens ============

    function test_fork_multihop_wbtc_to_usdc_via_weth() public {
        // Create two pools: WBTC/WETH and WETH/USDC
        // Re-approve WETH since other tests may have consumed allowance
        vm.startPrank(alice);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(WBTC).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.addLiquidity(WBTC, WETH, 10 * 1e8, 50 ether, 0, 0, alice, block.timestamp + 1, 0);
        router.addLiquidity(WETH, USDC, 10 ether, 25_000 * 1e6, 0, 0, alice, block.timestamp + 1, 0);
        vm.stopPrank();

        // Multi-hop: WBTC → WETH → USDC
        address[] memory path = new address[](3);
        path[0] = WBTC;
        path[1] = WETH;
        path[2] = USDC;

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            1e6,
            0,
            path,
            alice,
            block.timestamp + 1 // 0.01 WBTC (small enough for circuit breaker)
        );

        assertEq(amounts.length, 3, "Multi-hop should have 3 amounts");
        uint256 usdcReceived = IERC20(USDC).balanceOf(alice) - usdcBefore;
        assertGt(usdcReceived, 0, "No USDC received from multi-hop");
        console.log("Multi-hop WBTC -> WETH -> USDC received:", usdcReceived);
    }

    // ============ DYNAMIC FEE with real tokens ============

    function test_fork_dynamicFee_worksWithRealTokens() public {
        vm.startPrank(alice);
        router.addLiquidity(WETH, USDC, 50 ether, 125_000 * 1e6, 0, 0, alice, block.timestamp + 1, 0);
        vm.stopPrank();

        address pair = factory.getPair(WETH, USDC);
        uint256 fee = ChPair(pair).getSwapFee();
        assertEq(fee, 30, "Initial fee should be base (30 bps)");
        console.log("WETH/USDC initial fee:", fee, "bps");
    }

    // ============ REMOVE LIQUIDITY with real tokens ============

    function test_fork_removeLiquidity_realTokens() public {
        vm.startPrank(alice);
        (,, uint256 liquidity) =
            router.addLiquidity(WETH, USDC, 10 ether, 25_000 * 1e6, 0, 0, alice, block.timestamp + 1, 0);

        address pair = factory.getPair(WETH, USDC);
        IERC20(pair).approve(address(router), liquidity);

        uint256 wethBefore = IERC20(WETH).balanceOf(alice);
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);

        router.removeLiquidity(WETH, USDC, liquidity, 0, 0, alice, block.timestamp + 1);
        vm.stopPrank();

        assertGt(IERC20(WETH).balanceOf(alice) - wethBefore, 0, "No WETH returned");
        assertGt(IERC20(USDC).balanceOf(alice) - usdcBefore, 0, "No USDC returned");
        console.log("Removed liquidity - WETH returned:", IERC20(WETH).balanceOf(alice) - wethBefore);
        console.log("Removed liquidity - USDC returned:", IERC20(USDC).balanceOf(alice) - usdcBefore);
    }
}
