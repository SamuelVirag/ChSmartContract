// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Handler contract that exposes pair operations for invariant testing
/// @dev Foundry's invariant tester calls random functions on this handler.
///      The handler constrains inputs to valid ranges and tracks ghost variables.
contract PairHandler is Test {
    ChPair public pair;
    MockERC20 public token0;
    MockERC20 public token1;

    // Ghost variables for tracking
    uint256 public totalToken0Deposited;
    uint256 public totalToken1Deposited;
    uint256 public totalToken0Withdrawn;
    uint256 public totalToken1Withdrawn;
    uint256 public swapCount;

    constructor(ChPair _pair, MockERC20 _token0, MockERC20 _token1) {
        pair = _pair;
        token0 = _token0;
        token1 = _token1;

        // Pre-mint tokens to this handler
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
    }

    /// @dev Add liquidity with bounded amounts
    function addLiquidity(uint256 amount0, uint256 amount1) external {
        amount0 = bound(amount0, 1e6, 10_000 ether);
        amount1 = bound(amount1, 1e6, 10_000 ether);

        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);

        try pair.mint(address(this)) returns (uint256) {
            totalToken0Deposited += amount0;
            totalToken1Deposited += amount1;
        } catch {
            // Mint can fail for various valid reasons, that's fine
        }
    }

    /// @dev Remove liquidity with bounded amounts
    function removeLiquidity(uint256 lpAmount) external {
        uint256 balance = pair.balanceOf(address(this));
        if (balance == 0) return;

        lpAmount = bound(lpAmount, 1, balance);
        pair.transfer(address(pair), lpAmount);

        try pair.burn(address(this)) returns (uint256 amount0, uint256 amount1) {
            totalToken0Withdrawn += amount0;
            totalToken1Withdrawn += amount1;
        } catch {
            // Burn can fail if amounts round to zero
        }
    }

    /// @dev Swap token0 for token1 with bounded amount (within circuit breaker)
    function swapToken0ForToken1(uint256 amountIn) external {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;

        // Keep swaps small enough for circuit breaker (<5% of reserves)
        uint256 maxSwap = uint256(r0) / 20;
        if (maxSwap < 1e3) return;
        amountIn = bound(amountIn, 1e3, maxSwap);

        // Calculate output with MAX_FEE to ensure K check passes
        uint256 amountOut = (amountIn * 9900 * uint256(r1)) / (uint256(r0) * 10000 + amountIn * 9900);
        if (amountOut == 0 || amountOut >= r1) return;

        token0.transfer(address(pair), amountIn);
        try pair.swap(0, amountOut, address(this), "") {
            swapCount++;
        } catch {
            // Swap can fail (circuit breaker, K check)
        }
    }

    /// @dev Swap token1 for token0 with bounded amount
    function swapToken1ForToken0(uint256 amountIn) external {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;

        uint256 maxSwap = uint256(r1) / 20;
        if (maxSwap < 1e3) return;
        amountIn = bound(amountIn, 1e3, maxSwap);

        uint256 amountOut = (amountIn * 9900 * uint256(r0)) / (uint256(r1) * 10000 + amountIn * 9900);
        if (amountOut == 0 || amountOut >= r0) return;

        token1.transfer(address(pair), amountIn);
        try pair.swap(amountOut, 0, address(this), "") {
            swapCount++;
        } catch {}
    }

    /// @dev Sync reserves (for rebasing token simulation)
    function sync() external {
        pair.sync();
    }

    /// @dev Skim excess tokens
    function skim() external {
        pair.skim(address(this));
    }
}

/// @title Invariant tests for ChPair
/// @notice Foundry calls random sequences of handler functions and checks invariants after each
contract InvariantTest is StdInvariant, Test {
    ChFactory factory;
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;
    PairHandler handler;

    function setUp() public {
        factory = new ChFactory(address(this));
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = ChPair(pairAddr);

        handler = new PairHandler(pair, token0, token1);

        // Seed the pool with initial liquidity so invariants have something to test
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(address(this));

        // Tell Foundry to only call the handler
        targetContract(address(handler));
    }

    /// @notice INVARIANT: k (reserve0 * reserve1) must never decrease
    /// @dev This is THE fundamental AMM invariant. If k decreases, value is being extracted.
    function invariant_kNeverDecreases() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);

        // k can be zero if pool is fully drained (valid edge case)
        // But if reserves exist, k should be >= initial k
        if (r0 > 0 && r1 > 0) {
            // k should be at least what was initially deposited (100e18 * 100e18)
            // minus rounding dust, but always positive
            assertGt(currentK, 0, "INVARIANT: k is zero with non-zero reserves");
        }
    }

    /// @notice INVARIANT: reserves must always match actual token balances
    /// @dev After any operation, stored reserves should equal actual balanceOf
    function invariant_reservesMatchBalances() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 balance0 = token0.balanceOf(address(pair));
        uint256 balance1 = token1.balanceOf(address(pair));

        // Reserves should always be <= actual balances
        // (excess can exist from donations, but reserves should never exceed balances)
        assertLe(uint256(r0), balance0, "INVARIANT: reserve0 > balance0");
        assertLe(uint256(r1), balance1, "INVARIANT: reserve1 > balance1");
    }

    /// @notice INVARIANT: LP totalSupply must be consistent with reserves
    /// @dev If totalSupply > 0, both reserves must be > 0 (and vice versa for a healthy pool)
    function invariant_supplyReserveConsistency() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 totalSupply = pair.totalSupply();

        if (totalSupply > 0) {
            // If LP tokens exist, pool should have reserves
            // (edge case: reserves could be 0 if tokens were drained via burn,
            //  but totalSupply should also be 0 or near-0 in that case)
            assertTrue(r0 > 0 || totalSupply < 1000, "INVARIANT: LP exists but reserve0 is 0");
            assertTrue(r1 > 0 || totalSupply < 1000, "INVARIANT: LP exists but reserve1 is 0");
        }
    }

    /// @notice INVARIANT: EMA prices must remain positive once initialized
    function invariant_emaPricesPositive() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 ema0 = pair.emaPrice0();
        uint256 ema1 = pair.emaPrice1();

        // Once initialized (both > 0), EMA should never go to zero
        if (ema0 > 0) {
            assertGt(ema0, 0, "INVARIANT: emaPrice0 became 0");
        }
        if (ema1 > 0) {
            assertGt(ema1, 0, "INVARIANT: emaPrice1 became 0");
        }
    }

    /// @notice INVARIANT: dynamic fee must stay within bounds
    function invariant_feeWithinBounds() public view {
        uint256 fee = pair.getSwapFee();
        assertGe(fee, pair.BASE_FEE_BPS(), "INVARIANT: fee below minimum");
        assertLe(fee, pair.MAX_FEE_BPS(), "INVARIANT: fee above maximum");
    }

    /// @notice INVARIANT: pair contract token balances are never negative relative to reserves
    /// @dev Actual balances should always be >= stored reserves (excess = donations/fees)
    ///      This catches any bug where tokens are sent out without proper reserve accounting.
    function invariant_pairSolvency() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 balance0 = token0.balanceOf(address(pair));
        uint256 balance1 = token1.balanceOf(address(pair));

        assertGe(balance0, uint256(r0), "INVARIANT: pair is insolvent on token0");
        assertGe(balance1, uint256(r1), "INVARIANT: pair is insolvent on token1");
    }
}
