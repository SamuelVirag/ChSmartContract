// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {IChCallee} from "../src/interfaces/IChCallee.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ChPairTest is Test {
    ChFactory factory;
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address admin = makeAddr("admin");

    uint256 constant INITIAL_SUPPLY = 100_000 ether;
    uint256 constant VIRTUAL_OFFSET = 1000;

    function setUp() public {
        factory = new ChFactory(admin);
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);

        // Ensure token0 < token1 for consistent ordering
        (token0, token1) = address(tokenA) < address(tokenB)
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = ChPair(pairAddr);

        // Mint tokens to test accounts
        token0.mint(alice, INITIAL_SUPPLY);
        token1.mint(alice, INITIAL_SUPPLY);
        token0.mint(bob, INITIAL_SUPPLY);
        token1.mint(bob, INITIAL_SUPPLY);
    }

    // ============ INITIALIZATION ============

    function test_initialize() public view {
        assertEq(pair.factory(), address(factory));
        assertEq(pair.token0(), address(token0));
        assertEq(pair.token1(), address(token1));
        assertEq(pair.totalSupply(), 0);
    }

    function test_initialize_revert_notFactory() public {
        ChPair newPair = new ChPair();
        vm.prank(alice);
        vm.expectRevert("ChPair: FORBIDDEN");
        newPair.initialize(address(token0), address(token1));
    }

    function test_initialize_revert_alreadyInitialized() public {
        vm.prank(address(factory));
        vm.expectRevert("ChPair: ALREADY_INITIALIZED");
        pair.initialize(address(token0), address(token1));
    }

    // ============ MINT (ADD LIQUIDITY) ============

    function test_mint_initialDeposit() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 4 ether;

        _addLiquidity(alice, amount0, amount1);

        // First deposit: liquidity = sqrt(amount0 * amount1) — NO subtraction
        uint256 expectedLiquidity = 2 ether; // sqrt(1e18 * 4e18) = 2e18
        assertEq(pair.totalSupply(), expectedLiquidity);
        // Alice gets the full amount — no tokens burned to dead address
        assertEq(pair.balanceOf(alice), expectedLiquidity);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertEq(reserve0, amount0);
        assertEq(reserve1, amount1);
    }

    function test_mint_subsequentDeposit() public {
        _addLiquidity(alice, 1 ether, 4 ether);

        uint256 supplyBefore = pair.totalSupply(); // 2 ether

        // Bob adds proportional liquidity
        _addLiquidity(bob, 1 ether, 4 ether);

        // Subsequent: uses effectiveSupply and effectiveReserve with VIRTUAL_OFFSET
        uint256 bobLP = pair.balanceOf(bob);
        assertGt(bobLP, 0);
        assertGt(pair.totalSupply(), supplyBefore);
    }

    function test_mint_revert_zeroLiquidity() public {
        // sqrt(0 * 0) = 0, which should revert INSUFFICIENT_LIQUIDITY_MINTED
        vm.startPrank(alice);
        token0.transfer(address(pair), 0);
        token1.transfer(address(pair), 0);
        vm.expectRevert();
        pair.mint(alice);
        vm.stopPrank();
    }

    function test_mint_unbalancedDeposit() public {
        _addLiquidity(alice, 1 ether, 4 ether);

        // Bob adds unbalanced — gets LP based on the lesser ratio
        vm.startPrank(bob);
        token0.transfer(address(pair), 2 ether);
        token1.transfer(address(pair), 4 ether);
        pair.mint(bob);
        vm.stopPrank();

        // Key point: unbalanced deposits use min() so no extra LP for excess
        assertTrue(pair.balanceOf(bob) > 0);
    }

    // ============ BURN (REMOVE LIQUIDITY) ============

    function test_burn() public {
        _addLiquidity(alice, 1 ether, 4 ether);

        uint256 aliceLiquidity = pair.balanceOf(alice);
        vm.startPrank(alice);
        pair.transfer(address(pair), aliceLiquidity);
        (uint256 amount0, uint256 amount1) = pair.burn(alice);
        vm.stopPrank();

        assertEq(pair.balanceOf(alice), 0);
        // Alice gets back slightly less than deposited due to virtual offset dilution
        // effectiveSupply = totalSupply + VIRTUAL_OFFSET, so: amount = liquidity * balance / effectiveSupply
        assertTrue(amount0 > 0 && amount0 < 1 ether);
        assertTrue(amount1 > 0 && amount1 < 4 ether);
    }

    function test_burn_revert_noLiquidity() public {
        _addLiquidity(alice, 1 ether, 4 ether);

        // Bob has no LP tokens — pair has 0 LP balance
        vm.expectRevert("ChPair: INSUFFICIENT_LIQUIDITY_BURNED");
        pair.burn(bob);
    }

    // ============ SWAP ============

    function test_swap_token0ForToken1() public {
        // Use large pool so small swap stays within circuit breaker (< 10% impact)
        _addLiquidity(alice, 100 ether, 100 ether);

        uint256 swapAmount = 1 ether;
        uint256 expectedOutput = _getAmountOut(swapAmount, 100 ether, 100 ether);

        vm.startPrank(bob);
        token0.transfer(address(pair), swapAmount);
        pair.swap(0, expectedOutput, bob, "");
        vm.stopPrank();

        assertEq(token1.balanceOf(bob), INITIAL_SUPPLY + expectedOutput);
    }

    function test_swap_token1ForToken0() public {
        _addLiquidity(alice, 100 ether, 100 ether);

        uint256 swapAmount = 1 ether;
        uint256 expectedOutput = _getAmountOut(swapAmount, 100 ether, 100 ether);

        vm.startPrank(bob);
        token1.transfer(address(pair), swapAmount);
        pair.swap(expectedOutput, 0, bob, "");
        vm.stopPrank();

        assertEq(token0.balanceOf(bob), INITIAL_SUPPLY + expectedOutput);
    }

    function test_swap_revert_insufficientOutput() public {
        _addLiquidity(alice, 5 ether, 10 ether);

        vm.expectRevert("ChPair: INSUFFICIENT_OUTPUT_AMOUNT");
        pair.swap(0, 0, bob, "");
    }

    function test_swap_revert_insufficientLiquidity() public {
        _addLiquidity(alice, 5 ether, 10 ether);

        vm.expectRevert("ChPair: INSUFFICIENT_LIQUIDITY");
        pair.swap(5 ether, 0, bob, ""); // trying to withdraw all reserves
    }

    function test_swap_revert_invalidTo() public {
        _addLiquidity(alice, 100 ether, 100 ether);

        vm.startPrank(bob);
        token0.transfer(address(pair), 1 ether);
        vm.expectRevert("ChPair: INVALID_TO");
        pair.swap(0, 1 ether, address(token0), "");
        vm.stopPrank();
    }

    function test_swap_revert_kInvariant() public {
        _addLiquidity(alice, 100 ether, 100 ether);

        // Try to extract more than allowed by the constant product
        vm.startPrank(bob);
        token0.transfer(address(pair), 1 ether);
        uint256 tooMuchOutput = 5 ether; // much more than fee-adjusted output
        vm.expectRevert("ChPair: K");
        pair.swap(0, tooMuchOutput, bob, "");
        vm.stopPrank();
    }

    // ============ FLASH SWAP WITH SURCHARGE ============

    function test_flashSwap() public {
        // Large pool to keep flash borrow within circuit breaker limits
        _addLiquidity(alice, 100 ether, 100 ether);

        FlashBorrower borrower = new FlashBorrower(pair, token0, token1);
        token0.mint(address(borrower), 5 ether); // give borrower enough to repay

        // Borrow 1 ether of token1 — small enough relative to 100 ether pool
        borrower.flashBorrow(0, 1 ether);

        // Verify borrower received the callback
        assertTrue(borrower.callbackReceived());
    }

    function test_flashSwap_revert_noRepayment() public {
        _addLiquidity(alice, 100 ether, 100 ether);

        MaliciousFlashBorrower borrower = new MaliciousFlashBorrower();

        // With no repayment, both input amounts are 0
        vm.expectRevert("ChPair: INSUFFICIENT_INPUT_AMOUNT");
        pair.swap(0, 1 ether, address(borrower), "flash");
    }

    // ============ SKIM & SYNC ============

    function test_skim() public {
        _addLiquidity(alice, 5 ether, 10 ether);

        // Send extra tokens directly (donation)
        vm.prank(alice);
        token0.transfer(address(pair), 1 ether);

        uint256 bobBefore = token0.balanceOf(bob);
        pair.skim(bob);
        assertEq(token0.balanceOf(bob) - bobBefore, 1 ether);
    }

    function test_sync() public {
        _addLiquidity(alice, 5 ether, 10 ether);

        // Send extra tokens directly
        vm.prank(alice);
        token0.transfer(address(pair), 1 ether);

        pair.sync();

        (uint112 reserve0,,) = pair.getReserves();
        assertEq(reserve0, 6 ether);
    }

    // ============ ORACLE: CUMULATIVE + EMA ============

    function test_oracle_cumulativePrices() public {
        _addLiquidity(alice, 1 ether, 1 ether);

        // Advance time
        vm.warp(block.timestamp + 1);

        // Trigger an update via sync
        pair.sync();

        assertTrue(pair.price0CumulativeLast() > 0);
        assertTrue(pair.price1CumulativeLast() > 0);
    }

    function test_oracle_emaInitializedAfterSecondInteraction() public {
        _addLiquidity(alice, 1 ether, 2 ether);

        // After first mint, _updateOracle is called with old reserves (0,0),
        // so EMA stays 0. Advance time so timeElapsed > 0 (per-block EMA gating),
        // then trigger sync to initialize with actual reserves.
        vm.warp(block.timestamp + 1);
        pair.sync();

        // Now EMA should be initialized to spot price
        // spotPrice0 = reserve1/reserve0 * 1e18 = 2e18
        assertEq(pair.emaPrice0(), 2e18);
        // spotPrice1 = reserve0/reserve1 * 1e18 = 0.5e18
        assertEq(pair.emaPrice1(), 0.5e18);
    }

    function test_oracle_emaUpdatesOnSync() public {
        _addLiquidity(alice, 1 ether, 1 ether);

        // Initialize EMA via sync — need vm.warp so timeElapsed > 0 (per-block EMA gating)
        vm.warp(100);
        pair.sync();
        uint256 emaBefore = pair.emaPrice0();
        assertEq(emaBefore, 1e18);

        // Donate tokens to change ratio, then sync with time advancement between each:
        // 1st sync: _updateOracle sees old reserves (1:1), but stores new reserves (2:1)
        // 2nd sync: _updateOracle sees old reserves (2:1), updates EMA toward 0.5e18
        vm.prank(alice);
        token0.transfer(address(pair), 1 ether);
        vm.warp(200);
        pair.sync(); // oracle sees old reserves (1:1), EMA stays at 1e18
        vm.warp(300);
        pair.sync(); // oracle sees stored reserves (2:1), spot = 0.5e18, EMA shifts

        uint256 emaAfter = pair.emaPrice0();
        assertTrue(emaAfter < emaBefore); // EMA decreased toward new lower spot price
        assertTrue(emaAfter > 0.5e18); // But hasn't fully reached spot yet (5% alpha)
    }

    // ============ DYNAMIC FEE ============

    function test_dynamicFee_baseAtEquilibrium() public {
        _addLiquidity(alice, 1 ether, 1 ether);

        // At equilibrium (spot == EMA or EMA == 0), fee should be the base fee
        uint256 fee = pair.getSwapFee();
        assertEq(fee, 30); // BASE_FEE_BPS
    }

    function test_dynamicFee_increasesOnDeviation() public {
        _addLiquidity(alice, 100 ether, 100 ether);

        // Initialize EMA — need vm.warp so timeElapsed > 0 (per-block EMA gating)
        vm.warp(block.timestamp + 1);
        pair.sync();

        // Do a small swap to move spot price away from EMA (within circuit breaker)
        // Use MAX_FEE (100 bps) as conservative estimate since max(pre, post) is used
        uint256 swapAmount = 2 ether;
        uint256 amountOut = _getAmountOutWithFee(swapAmount, 100 ether, 100 ether, 100);

        vm.startPrank(bob);
        token0.transfer(address(pair), swapAmount);
        pair.swap(0, amountOut, bob, "");
        vm.stopPrank();

        // With per-block EMA gating, EMA doesn't update in the same block as the swap.
        // Advance time and sync so EMA catches up, then check fee on a second swap.
        vm.warp(block.timestamp + 1);
        pair.sync();

        // Now do a second small swap — fee should be elevated because spot deviates from EMA
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 swapAmount2 = 0.1 ether;
        uint256 amountOut2 = _getAmountOutWithFee(swapAmount2, r0, r1, 100);

        vm.startPrank(bob);
        token0.transfer(address(pair), swapAmount2);
        pair.swap(0, amountOut2, bob, "");
        vm.stopPrank();

        // Fee should have increased because spot now deviates from EMA
        uint256 fee = pair.getSwapFee();
        assertGt(fee, 30); // greater than BASE_FEE_BPS
    }

    // ============ CIRCUIT BREAKER ============

    function test_circuitBreaker_revertOnLargeSwap() public {
        _addLiquidity(alice, 10 ether, 10 ether);

        // A swap of 4 ether into a 10:10 pool moves price significantly (> 10%)
        uint256 hugeSwap = 4 ether;
        uint256 amountOut = _getAmountOut(hugeSwap, 10 ether, 10 ether);

        vm.startPrank(bob);
        token0.transfer(address(pair), hugeSwap);
        vm.expectRevert("ChPair: CIRCUIT_BREAKER");
        pair.swap(0, amountOut, bob, "");
        vm.stopPrank();
    }

    function test_circuitBreaker_allowsSmallSwap() public {
        _addLiquidity(alice, 100 ether, 100 ether);

        // A small swap should pass the circuit breaker
        uint256 smallSwap = 0.5 ether;
        uint256 amountOut = _getAmountOut(smallSwap, 100 ether, 100 ether);

        vm.startPrank(bob);
        token0.transfer(address(pair), smallSwap);
        pair.swap(0, amountOut, bob, "");
        vm.stopPrank();

        assertEq(token1.balanceOf(bob), INITIAL_SUPPLY + amountOut);
    }

    // ============ PROTOCOL FEE ============

    function test_protocolFee_mintsFeeOnLiquidityEvent() public {
        // Enable protocol fee via timelock
        vm.prank(admin);
        factory.proposeFeeTo(address(this));
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(admin);
        factory.executeFeeTo();

        // Use large pool to keep swaps within circuit breaker
        _addLiquidity(alice, 100 ether, 100 ether);

        // Do a swap to generate fees (small enough for circuit breaker)
        vm.startPrank(bob);
        token0.transfer(address(pair), 1 ether);
        pair.swap(0, _getAmountOut(1 ether, 100 ether, 100 ether), bob, "");
        vm.stopPrank();

        // Another liquidity event triggers fee minting
        _addLiquidity(alice, 1 ether, 1 ether);

        // feeTo should have received some LP tokens
        assertTrue(pair.balanceOf(address(this)) > 0);
    }

    // ============ FUZZ TESTS ============

    function testFuzz_swap_kNeverDecreases(uint256 swapAmount) public {
        // Use large pool to minimize circuit breaker triggers
        _addLiquidity(alice, 100 ether, 100 ether);

        // Bound swap to range that stays within circuit breaker (< ~10% of reserves)
        swapAmount = bound(swapAmount, 0.001 ether, 4.5 ether);

        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        uint256 amountOut = _getAmountOut(swapAmount, r0Before, r1Before);

        vm.startPrank(bob);
        token0.transfer(address(pair), swapAmount);
        pair.swap(0, amountOut, bob, "");
        vm.stopPrank();

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);

        // k should never decrease (it increases due to fees)
        assertGe(kAfter, kBefore);
    }

    function testFuzz_mint_proportionalShares(uint256 amount0, uint256 amount1) public {
        // First deposit to establish pool
        _addLiquidity(alice, 10 ether, 10 ether);

        // Bound to reasonable amounts
        amount0 = bound(amount0, 1e6, 50 ether);
        amount1 = bound(amount1, 1e6, 50 ether);

        uint256 supplyBefore = pair.totalSupply();

        vm.startPrank(bob);
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        uint256 liquidity = pair.mint(bob);
        vm.stopPrank();

        // Liquidity minted should be > 0
        assertGt(liquidity, 0);
        // Total supply should increase
        assertGt(pair.totalSupply(), supplyBefore);
    }

    // ============ HELPERS ============

    function _addLiquidity(address user, uint256 amount0, uint256 amount1) internal {
        vm.startPrank(user);
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        pair.mint(user);
        vm.stopPrank();
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256)
    {
        return _getAmountOutWithFee(amountIn, reserveIn, reserveOut, 30);
    }

    function _getAmountOutWithFee(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;
        return numerator / denominator;
    }
}

/// @dev Flash swap borrower that properly repays (accounts for higher flash fee: base 30 + flash 9 = 39 bps)
contract FlashBorrower is IChCallee {
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;
    bool public callbackReceived;

    constructor(ChPair _pair, MockERC20 _token0, MockERC20 _token1) {
        pair = _pair;
        token0 = _token0;
        token1 = _token1;
    }

    function flashBorrow(uint256 amount0, uint256 amount1) external {
        pair.swap(amount0, amount1, address(this), "flash");
    }

    function chSwapCall(address, uint256, uint256 amount1, bytes calldata) external {
        callbackReceived = true;
        // Repay with token0 — must cover the flash fee (base 30 + flash 9 = 39 bps total)
        // For borrowing amount1Out from a 1:1 pool, required repayment in token0:
        // X >= reserveIn * amount1Out * BPS / ((reserveOut - amount1Out) * (BPS - feeBps))
        // With 100:100 pool, borrow 1e18: X >= 100e18 * 1e18 * 10000 / (99e18 * 9961) + 1
        // Overpay to be safe
        uint256 repayAmount = (amount1 * 10200) / 9961;
        token0.transfer(address(pair), repayAmount);
    }
}

/// @dev Malicious flash swap borrower that doesn't repay
contract MaliciousFlashBorrower is IChCallee {
    function chSwapCall(address, uint256, uint256, bytes calldata) external {
        // Do nothing — don't repay. This should fail the K invariant check.
    }
}
