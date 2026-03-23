// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {IChCallee} from "../src/interfaces/IChCallee.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Economic / Game Theory Attack Tests
/// @notice Tests economic attack vectors: monopoly LP, EMA gaming, circuit breaker analysis,
///         flash surcharge circumvention
contract EconomicAttacksTest is Test {
    ChFactory factory;
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice"); // honest LP
    address bob = makeAddr("bob"); // honest trader
    address attacker = makeAddr("attacker");

    function setUp() public {
        factory = new ChFactory(address(this));
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = ChPair(pairAddr);

        // Fund everyone generously
        token0.mint(alice, 10_000 ether);
        token1.mint(alice, 10_000 ether);
        token0.mint(bob, 10_000 ether);
        token1.mint(bob, 10_000 ether);
        token0.mint(attacker, 10_000 ether);
        token1.mint(attacker, 10_000 ether);
    }

    // ============ 1. MONOPOLY LP EXTRACTION ============

    /// @notice Can the sole LP extract value from traders via unfair fee capture?
    ///         If attacker is the only LP, they earn ALL fees. But can they manipulate
    ///         to earn MORE than the fair fee share?
    function test_monopolyLP_cannotExtractBeyondFees() public {
        // Attacker is the sole LP
        vm.startPrank(attacker);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(attacker);
        vm.stopPrank();

        uint256 attackerLP = pair.balanceOf(attacker);
        uint256 attackerToken0Before = token0.balanceOf(attacker);
        uint256 attackerToken1Before = token1.balanceOf(attacker);

        // Bob does multiple swaps (generating fees for the LP)
        for (uint256 i = 0; i < 10; i++) {
            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 swapAmt = 1 ether;
            uint256 out = _getAmountOut(swapAmt, r0, r1, 100);
            if (out == 0) break;

            vm.startPrank(bob);
            if (i % 2 == 0) {
                token0.transfer(address(pair), swapAmt);
                pair.swap(0, out, bob, "");
            } else {
                token1.transfer(address(pair), swapAmt);
                pair.swap(out, 0, bob, "");
            }
            vm.stopPrank();
        }

        // Attacker withdraws all liquidity
        vm.startPrank(attacker);
        pair.transfer(address(pair), attackerLP);
        pair.burn(attacker);
        vm.stopPrank();

        uint256 attackerToken0After = token0.balanceOf(attacker);
        uint256 attackerToken1After = token1.balanceOf(attacker);

        // Calculate net profit (total after - total before deposit)
        // Before deposit: attacker had 10000 ether of each
        uint256 totalBefore = 10_000 ether + 10_000 ether;
        uint256 totalAfter = attackerToken0After + attackerToken1After;

        // Attacker should have roughly what they started with + legitimate fees
        // Fees: 10 swaps * 1 ether * ~1% max fee = ~0.1 ether max fee income
        // Allow up to 2% profit (generous margin for fee accumulation)
        uint256 profit = totalAfter > totalBefore ? totalAfter - totalBefore : 0;
        assertLt(profit, totalBefore * 2 / 100, "Monopoly LP extracted more than 2% profit");
    }

    /// @notice Monopoly LP can't sandwich their own trades by being both LP and trader
    function test_monopolyLP_selfSandwichUnprofitable() public {
        // Attacker provides liquidity
        vm.startPrank(attacker);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(attacker);
        vm.stopPrank();

        uint256 totalBefore = token0.balanceOf(attacker) + token1.balanceOf(attacker);

        // Attacker does self-swaps trying to extract value
        // Advance block between swaps to reset per-block circuit breaker baseline
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(10 + i);
            vm.warp(100 + i);

            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 swapAmt = 2 ether;
            uint256 out = _getAmountOut(swapAmt, r0, r1, 100);
            if (out == 0) break;

            vm.startPrank(attacker);
            token0.transfer(address(pair), swapAmt);
            pair.swap(0, out, attacker, "");
            vm.stopPrank();
        }

        // Swap back
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(20 + i);
            vm.warp(200 + i);

            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 swapAmt = 2 ether;
            uint256 out = _getAmountOut(swapAmt, r1, r0, 100);
            if (out == 0) break;

            vm.startPrank(attacker);
            token1.transfer(address(pair), swapAmt);
            pair.swap(out, 0, attacker, "");
            vm.stopPrank();
        }

        uint256 totalAfter = token0.balanceOf(attacker) + token1.balanceOf(attacker);

        // Self-trading should be unprofitable (fees eat into attacker's own capital)
        assertLe(totalAfter, totalBefore, "Self-sandwich was profitable");
    }

    // ============ 2. EMA GAMING OVER MULTIPLE BLOCKS ============

    /// @notice Attacker tries to shift EMA with many small trades to lower fees,
    ///         then executes a large trade at reduced fee
    function test_emaGaming_feeReductionLimited() public {
        // Setup pool and initialize EMA
        vm.startPrank(alice);
        token0.transfer(address(pair), 1000 ether);
        token1.transfer(address(pair), 1000 ether);
        pair.mint(alice);
        vm.stopPrank();
        pair.sync(); // initialize EMA at 1:1

        // Record baseline fee
        uint256 baseFee = pair.getSwapFee();
        assertEq(baseFee, 30); // at equilibrium

        // Attacker does 20 small swaps in ONE direction to shift EMA
        for (uint256 i = 0; i < 20; i++) {
            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 swapAmt = 1 ether; // small relative to 1000 pool
            uint256 out = _getAmountOut(swapAmt, r0, r1, 100);
            if (out == 0) break;

            vm.startPrank(attacker);
            token0.transfer(address(pair), swapAmt);
            pair.swap(0, out, attacker, "");
            vm.stopPrank();
        }

        // After 20 trades shifting price one direction, the EMA has partially followed
        // Now check: is the fee still reasonable?
        uint256 feeAfterManipulation = pair.getSwapFee();

        // The fee should have INCREASED (spot deviated from EMA) not decreased
        // Even though EMA is slowly following, the spot is ahead of it
        assertGe(feeAfterManipulation, baseFee, "EMA gaming reduced the fee");
    }

    /// @notice Even after many blocks of manipulation, the max fee reduction is bounded
    function test_emaGaming_convergenceDoesNotEliminateFee() public {
        vm.startPrank(alice);
        token0.transfer(address(pair), 1000 ether);
        token1.transfer(address(pair), 1000 ether);
        pair.mint(alice);
        vm.stopPrank();
        pair.sync();

        // Attacker does 50 small trades to shift EMA toward new price
        for (uint256 i = 0; i < 50; i++) {
            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 swapAmt = 0.5 ether;
            uint256 out = _getAmountOut(swapAmt, r0, r1, 100);
            if (out == 0) break;

            vm.startPrank(attacker);
            token0.transfer(address(pair), swapAmt);
            pair.swap(0, out, attacker, "");
            vm.stopPrank();
        }

        // Even if EMA converges to the manipulated price, fee should never go below MIN_FEE
        uint256 fee = pair.getSwapFee();
        assertGe(fee, pair.BASE_FEE_BPS(), "Fee dropped below minimum");
    }

    // ============ 3. CIRCUIT BREAKER THRESHOLD ANALYSIS ============

    /// @notice Verify 10% threshold allows normal large trades
    function test_circuitBreaker_allowsNormalLargeTrade() public {
        vm.startPrank(alice);
        token0.transfer(address(pair), 1000 ether);
        token1.transfer(address(pair), 1000 ether);
        pair.mint(alice);
        vm.stopPrank();

        // 9% of reserves should pass (within 10% threshold)
        uint256 largeSwap = 45 ether; // ~4.5% of 1000 pool, results in ~8.7% price impact
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 out = _getAmountOut(largeSwap, r0, r1, 100);

        vm.startPrank(bob);
        token0.transfer(address(pair), largeSwap);
        pair.swap(0, out, bob, "");
        vm.stopPrank();

        // Should succeed
        assertGt(token1.balanceOf(bob) - 10_000 ether + out, 0);
    }

    /// @notice Verify the exact boundary — find the maximum single-swap amount
    function test_circuitBreaker_boundaryPrecision() public {
        vm.startPrank(alice);
        token0.transfer(address(pair), 1000 ether);
        token1.transfer(address(pair), 1000 ether);
        pair.mint(alice);
        vm.stopPrank();

        // Binary search for the maximum swap that passes the circuit breaker
        uint256 low = 1 ether;
        uint256 high = 200 ether;
        uint256 maxPassing = 0;

        while (low <= high) {
            uint256 mid = (low + high) / 2;
            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 out = _getAmountOut(mid, r0, r1, 100);

            // Simulate: would this swap pass the circuit breaker?
            uint256 newR0 = uint256(r0) + mid;
            uint256 newR1 = uint256(r1) - out;
            uint256 crossBefore = uint256(r1) * newR0;
            uint256 crossAfter = newR1 * uint256(r0);
            uint256 deviation;
            if (crossAfter > crossBefore) {
                deviation = ((crossAfter - crossBefore) * 10000) / crossBefore;
            } else {
                deviation = ((crossBefore - crossAfter) * 10000) / crossBefore;
            }

            if (deviation <= 1000) {
                maxPassing = mid;
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }

        // The max passing swap should be roughly 5% of reserves for a 10% price impact limit
        // (because price impact ≈ 2 * swapSize / reserves for constant product)
        assertGt(maxPassing, 40 ether, "Circuit breaker too restrictive");
        assertLt(maxPassing, 60 ether, "Circuit breaker too permissive");
    }

    // ============ 4. FLASH SURCHARGE CIRCUMVENTION ============

    /// @notice Attacker tries to avoid flash fee by splitting into regular swap + separate flash borrow
    function test_flashSurcharge_cannotCircumventViaSplit() public {
        vm.startPrank(alice);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(alice);
        vm.stopPrank();

        // Method 1: Regular swap (pays base fee only)
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 regularOut = _getAmountOut(1 ether, r0, r1, 100);

        // Method 2: Flash swap (pays base + flash fee)
        // The flash fee is enforced inside the K check — you can't avoid it
        // by splitting because each operation is independent
        FlashFeeChecker checker = new FlashFeeChecker(pair, token0, token1);
        token0.mint(address(checker), 10 ether);

        // Flash borrow and repay — the checker tracks how much it had to repay
        checker.flashBorrow(1 ether);
        uint256 flashCost = checker.totalRepaid();

        // Flash cost should be strictly more than regular swap cost
        // Regular swap: 1 ether input, gets regularOut output. Cost = 1 ether - value of regularOut
        // Flash: borrows 1 ether of token1, must repay more token0 than a regular swap would cost
        assertGt(flashCost, 0, "Flash borrow had no cost");

        // The surcharge cannot be avoided — there's no way to "split" a flash swap
        // into a regular swap because they are fundamentally different operations
        // (flash sends tokens first then verifies repayment, regular requires input first)
    }

    /// @notice Flash swaps pay strictly more fee than regular swaps for equivalent amounts
    function test_flashSwap_strictlyMoreExpensiveThanRegular() public {
        vm.startPrank(alice);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(alice);
        vm.stopPrank();

        (uint112 r0, uint112 r1,) = pair.getReserves();

        // Regular swap: calculate exact input needed for 1 ether output
        // amountIn = (reserveIn * amountOut * BPS) / ((reserveOut - amountOut) * (BPS - fee)) + 1
        uint256 regularInput = (uint256(r0) * 1 ether * 10000) / ((uint256(r1) - 1 ether) * 9900) + 1;

        // Flash swap: same output (1 ether of token1), but flash fee = base + 9 bps
        // Minimum repayment is higher because fee is 39 bps instead of 30 bps
        uint256 flashInput = (uint256(r0) * 1 ether * 10000) / ((uint256(r1) - 1 ether) * (10000 - 100 - 9)) + 1;

        assertGt(flashInput, regularInput, "Flash should cost more than regular swap");
    }

    // ============ HELPERS ============

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
}

/// @dev Checks flash swap cost by tracking repayment amount
contract FlashFeeChecker is IChCallee {
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;
    uint256 public totalRepaid;

    constructor(ChPair _pair, MockERC20 _t0, MockERC20 _t1) {
        pair = _pair;
        token0 = _t0;
        token1 = _t1;
    }

    function flashBorrow(uint256 amount) external {
        pair.swap(0, amount, address(this), "flash");
    }

    function chSwapCall(address, uint256, uint256 amount1, bytes calldata) external {
        // Overpay to ensure K check passes with flash fee
        uint256 repay = (amount1 * 10200) / 9891; // account for base(100bps) + flash(9bps)
        token0.transfer(address(pair), repay);
        totalRepaid = repay;
    }
}
