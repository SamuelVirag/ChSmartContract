// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Low Decimal Token Tests
/// @notice Tests the DEX with tokens of varying decimal counts to catch precision and rounding issues.
///         Key concern: bidirectional rounding must always favor the pool, never the trader.
contract LowDecimalTokensTest is Test {
    ChFactory factory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant VIRTUAL_OFFSET = 1000;
    uint256 constant MAX_FEE = 100; // conservative fee estimate for K check

    function setUp() public {
        factory = new ChFactory(address(this));
    }

    // ============ HELPERS ============

    /// @dev Create a pair from two mock tokens and return (pair, token0, token1) in sorted order
    function _createPair(MockERC20 tokenA, MockERC20 tokenB)
        internal
        returns (ChPair pair, MockERC20 t0, MockERC20 t1)
    {
        (t0, t1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        address pairAddr = factory.createPair(address(t0), address(t1));
        pair = ChPair(pairAddr);
    }

    function _addLiquidity(ChPair pair, MockERC20 t0, MockERC20 t1, address user, uint256 a0, uint256 a1) internal {
        vm.startPrank(user);
        t0.transfer(address(pair), a0);
        t1.transfer(address(pair), a1);
        pair.mint(user);
        vm.stopPrank();
    }

    /// @dev Calculate amount out with BPS fee math (matches ChLibrary)
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;
        return numerator / denominator;
    }

    /// @dev Perform a swap of token0 -> token1, using MAX_FEE for K safety
    function _swapExact0For1(ChPair pair, MockERC20 t0, address user, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        amountOut = _getAmountOut(amountIn, r0, r1, MAX_FEE);

        vm.startPrank(user);
        t0.transfer(address(pair), amountIn);
        pair.swap(0, amountOut, user, "");
        vm.stopPrank();
    }

    /// @dev Perform a swap of token1 -> token0, using MAX_FEE for K safety
    function _swapExact1For0(ChPair pair, MockERC20 t1, address user, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        amountOut = _getAmountOut(amountIn, r1, r0, MAX_FEE);

        vm.startPrank(user);
        t1.transfer(address(pair), amountIn);
        pair.swap(amountOut, 0, user, "");
        vm.stopPrank();
    }

    // ============ 1. TWO-DECIMAL TOKEN PAIR (GUSD-like) ============

    function test_twoDecimalPair_addSwapRemove() public {
        MockERC20 tA = new MockERC20("GUSD A", "GUSDA", 2);
        MockERC20 tB = new MockERC20("GUSD B", "GUSDB", 2);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        // Mint tokens — 10_000.00 in 2-decimal representation
        uint256 supply = 10_000 * 1e2;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        // Add liquidity: 1000.00 each
        uint256 liqAmount = 1000 * 1e2;
        _addLiquidity(pair, t0, t1, alice, liqAmount, liqAmount);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(uint256(r0), liqAmount);
        assertEq(uint256(r1), liqAmount);

        // Swap 10.00 of token0 -> token1 (1% of pool, within circuit breaker)
        uint256 swapAmt = 10 * 1e2;
        uint256 t1Before = t1.balanceOf(bob);
        _swapExact0For1(pair, t0, bob, swapAmt);
        uint256 t1After = t1.balanceOf(bob);
        assertGt(t1After - t1Before, 0, "Should receive non-zero output");

        // Verify k didn't decrease
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGe(uint256(r0After) * uint256(r1After), uint256(r0) * uint256(r1), "k must not decrease");

        // Remove all liquidity
        uint256 aliceLP = pair.balanceOf(alice);
        vm.startPrank(alice);
        pair.transfer(address(pair), aliceLP);
        (uint256 out0, uint256 out1) = pair.burn(alice);
        vm.stopPrank();
        assertGt(out0, 0);
        assertGt(out1, 0);
    }

    // ============ 2. SIX-DECIMAL TOKEN PAIR (USDC/USDT-like) ============

    function test_sixDecimalPair_addSwapRemove() public {
        MockERC20 tA = new MockERC20("USDC", "USDC", 6);
        MockERC20 tB = new MockERC20("USDT", "USDT", 6);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        uint256 supply = 1_000_000 * 1e6;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        // Add liquidity: 100,000.000000 each
        uint256 liqAmount = 100_000 * 1e6;
        _addLiquidity(pair, t0, t1, alice, liqAmount, liqAmount);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);

        // Swap 100.000000 of t0 -> t1
        uint256 swapAmt = 100 * 1e6;
        uint256 outAmt = _swapExact0For1(pair, t0, bob, swapAmt);
        assertGt(outAmt, 0, "Should receive non-zero output for 6-decimal swap");

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGe(uint256(r0After) * uint256(r1After), kBefore, "k must not decrease for 6-decimal pair");
    }

    // ============ 3. MIXED DECIMALS ============

    function test_mixedDecimals_18and6() public {
        MockERC20 tA = new MockERC20("DAI", "DAI", 18);
        MockERC20 tB = new MockERC20("USDC", "USDC", 6);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        // Equivalent values: 100k DAI (18 dec) and 100k USDC (6 dec)
        t0.mint(alice, 200_000 * (10 ** t0.decimals()));
        t1.mint(alice, 200_000 * (10 ** t1.decimals()));
        t0.mint(bob, 200_000 * (10 ** t0.decimals()));
        t1.mint(bob, 200_000 * (10 ** t1.decimals()));

        uint256 liq0 = 100_000 * (10 ** t0.decimals());
        uint256 liq1 = 100_000 * (10 ** t1.decimals());
        _addLiquidity(pair, t0, t1, alice, liq0, liq1);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);

        // Swap 100 units of t0
        uint256 swapAmt = 100 * (10 ** t0.decimals());
        uint256 outAmt = _swapExact0For1(pair, t0, bob, swapAmt);
        assertGt(outAmt, 0, "Mixed 18/6 swap should produce output");

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGe(uint256(r0After) * uint256(r1After), kBefore, "k must not decrease for mixed 18/6");
    }

    function test_mixedDecimals_18and2() public {
        MockERC20 tA = new MockERC20("DAI", "DAI", 18);
        MockERC20 tB = new MockERC20("GUSD", "GUSD", 2);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        t0.mint(alice, 200_000 * (10 ** t0.decimals()));
        t1.mint(alice, 200_000 * (10 ** t1.decimals()));
        t0.mint(bob, 200_000 * (10 ** t0.decimals()));
        t1.mint(bob, 200_000 * (10 ** t1.decimals()));

        uint256 liq0 = 100_000 * (10 ** t0.decimals());
        uint256 liq1 = 100_000 * (10 ** t1.decimals());
        _addLiquidity(pair, t0, t1, alice, liq0, liq1);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);

        uint256 swapAmt = 100 * (10 ** t0.decimals());
        uint256 outAmt = _swapExact0For1(pair, t0, bob, swapAmt);
        assertGt(outAmt, 0, "Mixed 18/2 swap should produce output");

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGe(uint256(r0After) * uint256(r1After), kBefore, "k must not decrease for mixed 18/2");
    }

    function test_mixedDecimals_8and6() public {
        MockERC20 tA = new MockERC20("WBTC", "WBTC", 8);
        MockERC20 tB = new MockERC20("USDC", "USDC", 6);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        t0.mint(alice, 200_000 * (10 ** t0.decimals()));
        t1.mint(alice, 200_000 * (10 ** t1.decimals()));
        t0.mint(bob, 200_000 * (10 ** t0.decimals()));
        t1.mint(bob, 200_000 * (10 ** t1.decimals()));

        uint256 liq0 = 100_000 * (10 ** t0.decimals());
        uint256 liq1 = 100_000 * (10 ** t1.decimals());
        _addLiquidity(pair, t0, t1, alice, liq0, liq1);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);

        uint256 swapAmt = 100 * (10 ** t0.decimals());
        uint256 outAmt = _swapExact0For1(pair, t0, bob, swapAmt);
        assertGt(outAmt, 0, "Mixed 8/6 swap should produce output");

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGe(uint256(r0After) * uint256(r1After), kBefore, "k must not decrease for mixed 8/6");
    }

    // ============ 4. SMALL TRADE ROUNDING ============

    function test_smallTradeRounding_2decimal() public {
        MockERC20 tA = new MockERC20("GUSD A", "GUSDA", 2);
        MockERC20 tB = new MockERC20("GUSD B", "GUSDB", 2);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        // Supply: 10_000.00
        uint256 supply = 10_000 * 1e2;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        // Large-ish pool for 2 decimals: 5000.00 each
        _addLiquidity(pair, t0, t1, alice, 5000 * 1e2, 5000 * 1e2);

        // Test tiny trades: 1, 5, 10 units (0.01, 0.05, 0.10)
        uint256[3] memory tinyAmounts = [uint256(1), uint256(5), uint256(10)];

        for (uint256 i = 0; i < 3; i++) {
            uint256 amt = tinyAmounts[i];
            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 expectedOut = _getAmountOut(amt, r0, r1, MAX_FEE);

            uint256 bobT1Before = t1.balanceOf(bob);

            if (expectedOut == 0) {
                // If output is zero, verify trader doesn't lose tokens by confirming
                // the swap would revert (INSUFFICIENT_OUTPUT_AMOUNT) or produce zero
                vm.startPrank(bob);
                t0.transfer(address(pair), amt);
                vm.expectRevert(); // Should revert because amount0Out=0 and amount1Out=0
                pair.swap(0, 0, bob, "");
                vm.stopPrank();

                // Recover the sent tokens via sync + skim so they stay in the pool
                // (this is the expected behavior — tokens donated to the pool)
                // In practice, a router would prevent this trade
            } else {
                vm.startPrank(bob);
                t0.transfer(address(pair), amt);
                pair.swap(0, expectedOut, bob, "");
                vm.stopPrank();

                uint256 bobT1After = t1.balanceOf(bob);
                assertGt(bobT1After - bobT1Before, 0, "Non-zero output for small trade");
            }
        }
    }

    // ============ 5. ROUND-TRIP PROFITABILITY ============
    // THE key test: swap A->B then B->A, trader must end with LESS than they started.
    // This verifies bidirectional rounding favors the pool.

    function test_roundTrip_traderLoses_2decimal() public {
        _roundTripTest(2, 5000, 50);
    }

    function test_roundTrip_traderLoses_6decimal() public {
        _roundTripTest(6, 100_000, 1_000);
    }

    function test_roundTrip_traderLoses_18decimal() public {
        _roundTripTest(18, 100_000, 1_000);
    }

    /// @dev Core round-trip test: swap A->B then B->A, verify trader has LESS than start
    function _roundTripTest(uint8 decimals, uint256 poolUnits, uint256 swapUnits) internal {
        uint256 unit = 10 ** decimals;

        MockERC20 tA = new MockERC20("Token A", "TA", decimals);
        MockERC20 tB = new MockERC20("Token B", "TB", decimals);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        uint256 supply = poolUnits * 10 * unit;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        // Add liquidity — balanced pool
        uint256 liqAmount = poolUnits * unit;
        _addLiquidity(pair, t0, t1, alice, liqAmount, liqAmount);

        // Record bob's starting t1 balance
        uint256 bobT1Start = t1.balanceOf(bob);

        // Swap A -> B
        uint256 swapAmt = swapUnits * unit;
        uint256 outAmt = _swapExact0For1(pair, t0, bob, swapAmt);
        assertGt(outAmt, 0, "Forward swap should produce output");

        // Swap B -> A (use all received tokens)
        uint256 returnAmt = _swapExact1For0(pair, t1, bob, outAmt);
        assertGt(returnAmt, 0, "Reverse swap should produce output");

        // Verify trader ended with LESS token0 than they started
        uint256 bobT1End = t1.balanceOf(bob);

        // Bob spent swapAmt of t0, got back returnAmt of t0
        // Net t0: bobT0End = bobT0Start - swapAmt + returnAmt
        // We need returnAmt < swapAmt (trader loses on round trip)
        assertLt(returnAmt, swapAmt, "Round-trip must not be profitable: trader should get back less t0");

        // t1 balance should be unchanged (swapped out then swapped back the same amount)
        assertEq(bobT1End, bobT1Start, "t1 balance should be unchanged after round trip");

        // Pool gained value (k increased)
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGe(uint256(r0) * uint256(r1), liqAmount * liqAmount, "Pool k should be >= initial");
    }

    // ============ 6. FEE CALCULATION WITH LOW DECIMALS ============

    function test_feeNotTruncatedToZero_6decimal() public {
        MockERC20 tA = new MockERC20("USDC", "USDC", 6);
        MockERC20 tB = new MockERC20("USDT", "USDT", 6);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        uint256 supply = 10_000_000 * 1e6;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        // Pool: 1,000,000 USDC / 1,000,000 USDT
        uint256 liq = 1_000_000 * 1e6;
        _addLiquidity(pair, t0, t1, alice, liq, liq);

        // Small swap: 10 USDC (= 10e6)
        uint256 swapAmt = 10 * 1e6;
        (uint112 r0, uint112 r1,) = pair.getReserves();

        // Calculate output with base fee (30 bps) and with zero fee
        uint256 outWithFee = _getAmountOut(swapAmt, r0, r1, 30);
        uint256 outNoFee = _getAmountOut(swapAmt, r0, r1, 0);

        // Fee should create a measurable difference
        assertGt(outNoFee, outWithFee, "Fee must reduce output for 6-decimal tokens");
        assertGt(outNoFee - outWithFee, 0, "Fee difference should be non-zero");

        // Execute the swap to verify it works
        uint256 actualOut = _swapExact0For1(pair, t0, bob, swapAmt);
        assertGt(actualOut, 0, "Swap output should be non-zero");

        // The fee retained by the pool should be reflected in k increasing
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGt(
            uint256(r0After) * uint256(r1After),
            uint256(r0) * uint256(r1),
            "k should strictly increase (fee retained by pool)"
        );
    }

    // ============ 7. LARGE VALUE LOW-DECIMAL ============

    function test_largeValueLowDecimal() public {
        MockERC20 tA = new MockERC20("LowDec A", "LDA", 2);
        MockERC20 tB = new MockERC20("LowDec B", "LDB", 2);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        // Use large amounts but well below uint112 max (5.19e33)
        // For 2-decimal tokens, 1e12 units = 1e10 dollars — very large
        uint256 largeAmount = 1e12;
        t0.mint(alice, largeAmount * 10);
        t1.mint(alice, largeAmount * 10);
        t0.mint(bob, largeAmount * 10);
        t1.mint(bob, largeAmount * 10);

        _addLiquidity(pair, t0, t1, alice, largeAmount, largeAmount);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(uint256(r0), largeAmount);
        assertEq(uint256(r1), largeAmount);

        // Swap 1% of pool
        uint256 swapAmt = largeAmount / 100;
        uint256 outAmt = _swapExact0For1(pair, t0, bob, swapAmt);
        assertGt(outAmt, 0, "Large-value low-decimal swap should produce output");

        // k should increase
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGe(uint256(r0After) * uint256(r1After), uint256(r0) * uint256(r1), "k must not decrease");
    }

    // ============ 8. LP SHARE PRECISION ============

    function test_lpSharePrecision_2decimal() public {
        MockERC20 tA = new MockERC20("GUSD A", "GUSDA", 2);
        MockERC20 tB = new MockERC20("GUSD B", "GUSDB", 2);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        uint256 supply = 100_000 * 1e2;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        // Alice seeds pool: 1000.00 each
        _addLiquidity(pair, t0, t1, alice, 1000 * 1e2, 1000 * 1e2);

        uint256 aliceLP = pair.balanceOf(alice);
        // sqrt(100000 * 100000) = 100000
        assertEq(aliceLP, 100_000, "First depositor should get sqrt(a0*a1) LP tokens");

        // Bob deposits 100.00 each — should get non-zero LP
        _addLiquidity(pair, t0, t1, bob, 100 * 1e2, 100 * 1e2);
        uint256 bobLP = pair.balanceOf(bob);
        assertGt(bobLP, 0, "Second depositor should receive non-zero LP for 2-decimal tokens");

        // Bob's share should be roughly proportional (10% of Alice's deposit)
        // With virtual offset, it won't be exact but should be in the right ballpark
        assertGt(bobLP, aliceLP / 20, "Bob's LP should be reasonable proportion of Alice's");
    }

    function test_lpSharePrecision_smallDeposit_2decimal() public {
        MockERC20 tA = new MockERC20("GUSD A", "GUSDA", 2);
        MockERC20 tB = new MockERC20("GUSD B", "GUSDB", 2);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        uint256 supply = 100_000 * 1e2;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        // Alice seeds with a larger pool: 10000.00 each
        _addLiquidity(pair, t0, t1, alice, 10_000 * 1e2, 10_000 * 1e2);

        // Bob deposits a small but reasonable amount: 10.00 each (1000 units in 2-decimal)
        _addLiquidity(pair, t0, t1, bob, 10 * 1e2, 10 * 1e2);
        uint256 bobLP = pair.balanceOf(bob);
        assertGt(bobLP, 0, "Small but reasonable deposit should produce non-zero LP");
    }

    // ============ FUZZ: ROUND-TRIP NEVER PROFITABLE ============

    function testFuzz_roundTrip_neverProfitable(uint256 swapAmount) public {
        MockERC20 tA = new MockERC20("Token A", "TA", 18);
        MockERC20 tB = new MockERC20("Token B", "TB", 18);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        uint256 supply = 1_000_000 ether;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        uint256 liq = 100_000 ether;
        _addLiquidity(pair, t0, t1, alice, liq, liq);

        // Bound swap to 0.01% - 5% of pool (avoid circuit breaker + ensure meaningful output)
        swapAmount = bound(swapAmount, 10 ether, 4500 ether);

        // Forward swap: t0 -> t1
        uint256 outAmt = _swapExact0For1(pair, t0, bob, swapAmount);
        if (outAmt == 0) return; // skip trivial cases

        // Reverse swap: t1 -> t0
        uint256 returnAmt = _swapExact1For0(pair, t1, bob, outAmt);

        // Trader must always lose on round trips (fees + rounding favor pool)
        assertLt(returnAmt, swapAmount, "Fuzz: round-trip must never be profitable");
    }

    function testFuzz_roundTrip_neverProfitable_6decimal(uint256 swapAmount) public {
        MockERC20 tA = new MockERC20("USDC", "USDC", 6);
        MockERC20 tB = new MockERC20("USDT", "USDT", 6);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        uint256 supply = 1_000_000_000 * 1e6;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        uint256 liq = 100_000_000 * 1e6;
        _addLiquidity(pair, t0, t1, alice, liq, liq);

        // Bound swap to meaningful range for 6-decimal tokens (within circuit breaker)
        swapAmount = bound(swapAmount, 100 * 1e6, 4_500_000 * 1e6);

        uint256 outAmt = _swapExact0For1(pair, t0, bob, swapAmount);
        if (outAmt == 0) return;

        uint256 returnAmt = _swapExact1For0(pair, t1, bob, outAmt);
        assertLt(returnAmt, swapAmount, "Fuzz: round-trip must never be profitable (6 decimals)");
    }

    function testFuzz_roundTrip_neverProfitable_2decimal(uint256 swapAmount) public {
        MockERC20 tA = new MockERC20("GUSD A", "GUSDA", 2);
        MockERC20 tB = new MockERC20("GUSD B", "GUSDB", 2);

        (ChPair pair, MockERC20 t0, MockERC20 t1) = _createPair(tA, tB);

        uint256 supply = 1_000_000_000 * 1e2;
        t0.mint(alice, supply);
        t1.mint(alice, supply);
        t0.mint(bob, supply);
        t1.mint(bob, supply);

        uint256 liq = 100_000_000 * 1e2;
        _addLiquidity(pair, t0, t1, alice, liq, liq);

        // Bound swap to meaningful range for 2-decimal tokens
        swapAmount = bound(swapAmount, 100 * 1e2, 4_500_000 * 1e2);

        uint256 outAmt = _swapExact0For1(pair, t0, bob, swapAmount);
        if (outAmt == 0) return;

        uint256 returnAmt = _swapExact1For0(pair, t1, bob, outAmt);
        assertLt(returnAmt, swapAmount, "Fuzz: round-trip must never be profitable (2 decimals)");
    }
}
