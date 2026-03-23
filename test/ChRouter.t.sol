// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {ChRouter} from "../src/ChRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {WETH9} from "./mocks/WETH9.sol";

contract ChRouterTest is Test {
    ChFactory factory;
    ChRouter router;
    WETH9 weth;
    MockERC20 tokenA;
    MockERC20 tokenB;
    FeeOnTransferToken feeToken;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant INITIAL_SUPPLY = 100_000 ether;

    function setUp() public {
        weth = new WETH9();
        factory = new ChFactory(address(this));
        router = new ChRouter(address(factory), address(weth));

        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        feeToken = new FeeOnTransferToken("Fee Token", "FEE");

        // Mint tokens
        tokenA.mint(alice, INITIAL_SUPPLY);
        tokenB.mint(alice, INITIAL_SUPPLY);
        tokenA.mint(bob, INITIAL_SUPPLY);
        tokenB.mint(bob, INITIAL_SUPPLY);
        feeToken.mint(alice, INITIAL_SUPPLY);
        feeToken.mint(bob, INITIAL_SUPPLY);

        // Give ETH
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // Approve router
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        feeToken.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        feeToken.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ============ ADD LIQUIDITY ============

    function test_addLiquidity() public {
        vm.startPrank(alice);
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            10 ether,
            10 ether,
            0,
            0,
            alice,
            block.timestamp + 1,
            0
        );
        vm.stopPrank();

        assertEq(amountA, 10 ether);
        assertEq(amountB, 10 ether);
        assertGt(liquidity, 0);
    }

    function test_addLiquidity_createsNewPair() public {
        assertEq(factory.getPair(address(tokenA), address(tokenB)), address(0));

        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 10 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        assertTrue(factory.getPair(address(tokenA), address(tokenB)) != address(0));
    }

    function test_addLiquidity_proportional() public {
        // First deposit
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 20 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        // Second deposit — should be proportional
        vm.prank(bob);
        (uint256 amountA, uint256 amountB,) = router.addLiquidity(
            address(tokenA), address(tokenB), 5 ether, 20 ether, 0, 0, bob, block.timestamp + 1, 0
        );

        assertEq(amountA, 5 ether);
        assertEq(amountB, 10 ether); // proportional: 5 * 20/10 = 10
    }

    function test_addLiquidityETH() public {
        vm.prank(alice);
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = router.addLiquidityETH{value: 5 ether}(
            address(tokenA), 10 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        assertEq(amountToken, 10 ether);
        assertEq(amountETH, 5 ether);
        assertGt(liquidity, 0);
    }

    function test_addLiquidityETH_refundsExcess() public {
        vm.prank(alice);
        // First, create the pool
        router.addLiquidityETH{value: 5 ether}(
            address(tokenA), 10 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        // Add more with excess ETH
        router.addLiquidityETH{value: 10 ether}(
            address(tokenA), 10 ether, 0, 0, alice, block.timestamp + 1, 0
        );
        uint256 balanceAfter = alice.balance;

        // Should get refund — only 5 ETH needed to match 10 tokenA at 2:1 ratio
        assertEq(balanceBefore - balanceAfter, 5 ether);
    }

    // ============ REMOVE LIQUIDITY ============

    function test_removeLiquidity() public {
        vm.startPrank(alice);
        (,, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 10 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        // Approve LP tokens for router
        address pair = factory.getPair(address(tokenA), address(tokenB));
        ChPair(pair).approve(address(router), liquidity);

        uint256 tokenABefore = tokenA.balanceOf(alice);
        uint256 tokenBBefore = tokenB.balanceOf(alice);

        router.removeLiquidity(
            address(tokenA), address(tokenB), liquidity, 0, 0, alice, block.timestamp + 1
        );
        vm.stopPrank();

        assertGt(tokenA.balanceOf(alice) - tokenABefore, 0);
        assertGt(tokenB.balanceOf(alice) - tokenBBefore, 0);
    }

    function test_removeLiquidityETH() public {
        vm.startPrank(alice);
        (,, uint256 liquidity) = router.addLiquidityETH{value: 5 ether}(
            address(tokenA), 10 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        address pair = factory.getPair(address(tokenA), address(weth));
        ChPair(pair).approve(address(router), liquidity);

        uint256 ethBefore = alice.balance;
        router.removeLiquidityETH(
            address(tokenA), liquidity, 0, 0, alice, block.timestamp + 1
        );
        vm.stopPrank();

        assertGt(alice.balance - ethBefore, 0);
    }

    // ============ SWAP: EXACT IN ============

    function test_swapExactTokensForTokens() public {
        // Large pool to keep swaps within circuit breaker (< 10% price impact)
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 100 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 bobTokenBBefore = tokenB.balanceOf(bob);

        vm.prank(bob);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            1 ether, 0, path, bob, block.timestamp + 1
        );

        assertGt(amounts[1], 0);
        assertEq(tokenB.balanceOf(bob) - bobTokenBBefore, amounts[1]);
    }

    function test_swapExactETHForTokens() public {
        vm.deal(alice, 200 ether);
        vm.prank(alice);
        router.addLiquidityETH{value: 50 ether}(
            address(tokenA), 50 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(tokenA);

        uint256 bobTokenABefore = tokenA.balanceOf(bob);

        vm.prank(bob);
        router.swapExactETHForTokens{value: 1 ether}(0, path, bob, block.timestamp + 1);

        assertGt(tokenA.balanceOf(bob) - bobTokenABefore, 0);
    }

    function test_swapExactTokensForETH() public {
        vm.deal(alice, 200 ether);
        vm.prank(alice);
        router.addLiquidityETH{value: 50 ether}(
            address(tokenA), 50 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(weth);

        uint256 bobEthBefore = bob.balance;

        vm.prank(bob);
        router.swapExactTokensForETH(1 ether, 0, path, bob, block.timestamp + 1);

        assertGt(bob.balance - bobEthBefore, 0);
    }

    // ============ SWAP: EXACT OUT ============

    function test_swapTokensForExactTokens() public {
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 10 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 bobTokenABefore = tokenA.balanceOf(bob);

        vm.prank(bob);
        uint256[] memory amounts = router.swapTokensForExactTokens(
            0.5 ether, 2 ether, path, bob, block.timestamp + 1
        );

        // Bob got exactly 0.5 ether of tokenB
        assertEq(amounts[amounts.length - 1], 0.5 ether);
        // Bob spent some tokenA
        assertGt(bobTokenABefore - tokenA.balanceOf(bob), 0);
    }

    function test_swapTokensForExactETH() public {
        vm.deal(alice, 200 ether);
        vm.prank(alice);
        router.addLiquidityETH{value: 50 ether}(
            address(tokenA), 50 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(weth);

        uint256 bobEthBefore = bob.balance;

        vm.prank(bob);
        uint256[] memory amounts = router.swapTokensForExactETH(
            0.5 ether, 2 ether, path, bob, block.timestamp + 1
        );

        assertEq(amounts[amounts.length - 1], 0.5 ether);
        assertGe(bob.balance - bobEthBefore, 0.5 ether);
    }

    function test_swapETHForExactTokens() public {
        vm.deal(alice, 200 ether);
        vm.prank(alice);
        router.addLiquidityETH{value: 50 ether}(
            address(tokenA), 50 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(tokenA);

        uint256 bobTokenABefore = tokenA.balanceOf(bob);
        uint256 bobEthBefore = bob.balance;

        vm.prank(bob);
        uint256[] memory amounts = router.swapETHForExactTokens{value: 5 ether}(
            0.5 ether, path, bob, block.timestamp + 1
        );

        assertEq(amounts[amounts.length - 1], 0.5 ether);
        assertGe(tokenA.balanceOf(bob) - bobTokenABefore, 0.5 ether);
        // Excess ETH should be refunded
        assertGt(bob.balance, bobEthBefore - 5 ether);
    }

    // ============ SLIPPAGE & DEADLINE PROTECTION ============

    function test_swap_revert_slippageProtection() public {
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 10 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.prank(bob);
        vm.expectRevert("ChRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        router.swapExactTokensForTokens(1 ether, 10 ether, path, bob, block.timestamp + 1);
    }

    function test_swap_revert_deadline() public {
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 10 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.prank(bob);
        vm.expectRevert("ChRouter: EXPIRED");
        router.swapExactTokensForTokens(1 ether, 0, path, bob, block.timestamp - 1);
    }

    function test_addLiquidity_revert_slippage() public {
        // First deposit
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 20 ether, 0, 0, alice, block.timestamp + 1, 0
        );

        // Second deposit with too-tight slippage
        vm.prank(bob);
        vm.expectRevert("ChRouter: INSUFFICIENT_A_AMOUNT");
        router.addLiquidity(
            address(tokenA), address(tokenB),
            5 ether, 5 ether,
            5 ether, 5 ether,
            bob, block.timestamp + 1,
            0
        );
    }

    // ============ MULTI-HOP ============

    function test_multiHopSwap() public {
        MockERC20 tokenC = new MockERC20("Token C", "TKC", 18);
        tokenC.mint(alice, INITIAL_SUPPLY);
        tokenC.mint(bob, INITIAL_SUPPLY);

        vm.startPrank(alice);
        tokenC.approve(address(router), type(uint256).max);
        // Create A-B pool (large enough for circuit breaker)
        router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 100 ether, 0, 0, alice, block.timestamp + 1, 0
        );
        // Create B-C pool
        router.addLiquidity(
            address(tokenB), address(tokenC), 100 ether, 100 ether, 0, 0, alice, block.timestamp + 1, 0
        );
        vm.stopPrank();

        // Bob swaps A -> B -> C
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 bobTokenCBefore = tokenC.balanceOf(bob);

        vm.prank(bob);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            1 ether, 0, path, bob, block.timestamp + 1
        );

        assertEq(amounts.length, 3);
        assertGt(tokenC.balanceOf(bob) - bobTokenCBefore, 0);
    }

    // ============ FEE-ON-TRANSFER SWAPS ============

    function test_feeOnTransferSwap_exactTokensForTokens() public {
        // Add liquidity directly to pair (bypass router transfer fee issues)
        _addFeeTokenLiquidityDirect(50 ether, 50 ether);

        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(tokenA);

        uint256 bobTokenABefore = tokenA.balanceOf(bob);

        vm.prank(bob);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, 0, path, bob, block.timestamp + 1
        );

        assertGt(tokenA.balanceOf(bob) - bobTokenABefore, 0);
    }

    function test_feeOnTransferSwap_exactTokensForETH() public {
        // Create feeToken/WETH pair directly
        address pairAddr = factory.createPair(address(feeToken), address(weth));

        vm.startPrank(alice);
        feeToken.transfer(pairAddr, 50 ether); // 49 arrives (2% fee)
        weth.deposit{value: 50 ether}();
        weth.transfer(pairAddr, 50 ether);
        ChPair(pairAddr).mint(alice);
        vm.stopPrank();

        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(weth);

        uint256 bobEthBefore = bob.balance;

        vm.prank(bob);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1 ether, 0, path, bob, block.timestamp + 1
        );

        assertGt(bob.balance - bobEthBefore, 0);
    }

    function test_feeOnTransferSwap_exactETHForTokens() public {
        // Create feeToken/WETH pair directly
        address pairAddr = factory.createPair(address(feeToken), address(weth));

        vm.startPrank(alice);
        feeToken.transfer(pairAddr, 50 ether);
        weth.deposit{value: 50 ether}();
        weth.transfer(pairAddr, 50 ether);
        ChPair(pairAddr).mint(alice);
        vm.stopPrank();

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(feeToken);

        uint256 bobFeeTokenBefore = feeToken.balanceOf(bob);

        vm.prank(bob);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(
            0, path, bob, block.timestamp + 1
        );

        // feeToken has 2% transfer fee, so bob receives less, but should still receive some
        assertGt(feeToken.balanceOf(bob) - bobFeeTokenBefore, 0);
    }

    function test_feeOnTransferSwap_revert_slippage() public {
        _addFeeTokenLiquidityDirect(50 ether, 50 ether);

        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(tokenA);

        vm.prank(bob);
        vm.expectRevert("ChRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, 100 ether, path, bob, block.timestamp + 1
        );
    }

    // ============ HELPERS ============

    function _addFeeTokenLiquidityDirect(uint256 feeAmount, uint256 normalAmount) internal {
        address pairAddr = factory.getPair(address(feeToken), address(tokenA));
        if (pairAddr == address(0)) {
            pairAddr = factory.createPair(address(feeToken), address(tokenA));
        }

        vm.startPrank(alice);
        feeToken.transfer(pairAddr, feeAmount); // 2% fee taken
        tokenA.transfer(pairAddr, normalAmount);
        ChPair(pairAddr).mint(alice);
        vm.stopPrank();
    }
}
