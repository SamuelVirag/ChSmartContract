// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Multi-actor handler for invariant testing
/// @dev Three independent actors (alice, bob, charlie) interact with the pool.
///      The handler tracks per-actor deposits, withdrawals, and LP balances.
contract MultiActorHandler is Test {
    ChPair public pair;
    MockERC20 public token0;
    MockERC20 public token1;

    address[3] public actors;
    uint256 constant MAX_FEE = 100; // conservative fee for K check

    // Per-actor ghost tracking
    mapping(address => uint256) public deposited0;
    mapping(address => uint256) public deposited1;
    mapping(address => uint256) public withdrawn0;
    mapping(address => uint256) public withdrawn1;

    // Global ghost tracking
    uint256 public totalDeposited0;
    uint256 public totalDeposited1;
    uint256 public totalWithdrawn0;
    uint256 public totalWithdrawn1;
    uint256 public totalSwappedIn0;
    uint256 public totalSwappedIn1;
    uint256 public swapCount;
    uint256 public syncCount;
    uint256 public skimCount;

    constructor(ChPair _pair, MockERC20 _token0, MockERC20 _token1) {
        pair = _pair;
        token0 = _token0;
        token1 = _token1;

        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("charlie");

        // Pre-mint tokens to each actor
        for (uint256 i = 0; i < 3; i++) {
            token0.mint(actors[i], 1_000_000 ether);
            token1.mint(actors[i], 1_000_000 ether);
        }
    }

    /// @dev Pick one of 3 actors based on a seed
    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    /// @dev Add liquidity from a randomly selected actor
    function addLiquidity(uint256 actorSeed, uint256 amount0, uint256 amount1) external {
        address actor = _pickActor(actorSeed);
        amount0 = bound(amount0, 1e6, 10_000 ether);
        amount1 = bound(amount1, 1e6, 10_000 ether);

        vm.startPrank(actor);
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        // Track transfers regardless of mint success — tokens are in the pair either way
        totalDeposited0 += amount0;
        totalDeposited1 += amount1;

        try pair.mint(actor) returns (uint256) {
            deposited0[actor] += amount0;
            deposited1[actor] += amount1;
        } catch {
            // Mint can fail for valid reasons (e.g., zero liquidity)
            // Tokens remain in pair as donation
        }
        vm.stopPrank();
    }

    /// @dev Remove liquidity for a randomly selected actor
    function removeLiquidity(uint256 actorSeed, uint256 lpAmount) external {
        address actor = _pickActor(actorSeed);
        uint256 balance = pair.balanceOf(actor);
        if (balance == 0) return;

        lpAmount = bound(lpAmount, 1, balance);

        vm.startPrank(actor);
        pair.transfer(address(pair), lpAmount);

        try pair.burn(actor) returns (uint256 amount0, uint256 amount1) {
            withdrawn0[actor] += amount0;
            withdrawn1[actor] += amount1;
            totalWithdrawn0 += amount0;
            totalWithdrawn1 += amount1;
        } catch {
            // Burn can fail if amounts round to zero
        }
        vm.stopPrank();
    }

    /// @dev Swap token0 for token1 from a randomly selected actor
    function swapToken0ForToken1(uint256 actorSeed, uint256 amountIn) external {
        address actor = _pickActor(actorSeed);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;

        // Keep swaps within 5% of reserves to avoid circuit breaker
        uint256 maxSwap = uint256(r0) / 20;
        if (maxSwap < 1e3) return;
        amountIn = bound(amountIn, 1e3, maxSwap);

        // Calculate output with MAX_FEE to ensure K check passes
        uint256 amountOut = (amountIn * (10000 - MAX_FEE) * uint256(r1)) / (uint256(r0) * 10000 + amountIn * (10000 - MAX_FEE));
        if (amountOut == 0 || amountOut >= r1) return;

        vm.startPrank(actor);
        token0.transfer(address(pair), amountIn);
        // Track transfer regardless of swap success — tokens are in the pair either way
        totalSwappedIn0 += amountIn;

        try pair.swap(0, amountOut, actor, "") {
            swapCount++;
        } catch {
            // Swap can fail (circuit breaker, K check, etc.)
            // Tokens remain in pair as donation (recoverable via skim/sync)
        }
        vm.stopPrank();
    }

    /// @dev Swap token1 for token0 from a randomly selected actor
    function swapToken1ForToken0(uint256 actorSeed, uint256 amountIn) external {
        address actor = _pickActor(actorSeed);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;

        // Keep swaps within 5% of reserves
        uint256 maxSwap = uint256(r1) / 20;
        if (maxSwap < 1e3) return;
        amountIn = bound(amountIn, 1e3, maxSwap);

        uint256 amountOut = (amountIn * (10000 - MAX_FEE) * uint256(r0)) / (uint256(r1) * 10000 + amountIn * (10000 - MAX_FEE));
        if (amountOut == 0 || amountOut >= r0) return;

        vm.startPrank(actor);
        token1.transfer(address(pair), amountIn);
        // Track transfer regardless of swap success
        totalSwappedIn1 += amountIn;

        try pair.swap(amountOut, 0, actor, "") {
            swapCount++;
        } catch {}
        vm.stopPrank();
    }

    /// @dev Call sync to force reserves to match balances
    function sync() external {
        try pair.sync() {
            syncCount++;
        } catch {}
    }

    /// @dev Skim excess tokens to a randomly selected actor
    function skim(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);

        try pair.skim(actor) {
            skimCount++;
        } catch {}
    }

    /// @dev Get total LP balance held by all actors
    function totalActorLP() external view returns (uint256 total) {
        for (uint256 i = 0; i < 3; i++) {
            total += pair.balanceOf(actors[i]);
        }
    }
}

/// @title Multi-actor invariant tests for ChPair
/// @notice Multiple independent actors (LPs and traders) interact with the pool.
///         Foundry calls random handler functions and checks invariants after each call.
contract MultiActorInvariantTest is StdInvariant, Test {
    ChFactory factory;
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;
    MultiActorHandler handler;

    uint256 initialK;

    function setUp() public {
        factory = new ChFactory(address(this));
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = ChPair(pairAddr);

        handler = new MultiActorHandler(pair, token0, token1);

        // Seed the pool with initial liquidity so invariants have something to test
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(address(this));

        (uint112 r0, uint112 r1,) = pair.getReserves();
        initialK = uint256(r0) * uint256(r1);

        // Tell Foundry to only call the handler
        targetContract(address(handler));
    }

    // ============ INVARIANT 1: k NEVER DECREASES ============

    /// @notice reserve0 * reserve1 must never be less than the initial k
    function invariant_kNeverDecreases() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);

        if (r0 > 0 && r1 > 0) {
            assertGe(currentK, initialK, "INVARIANT: k decreased below initial value");
        }
    }

    // ============ INVARIANT 2: PAIR SOLVENCY ============

    /// @notice Actual token balances must always be >= stored reserves
    function invariant_pairSolvency() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 balance0 = token0.balanceOf(address(pair));
        uint256 balance1 = token1.balanceOf(address(pair));

        assertGe(balance0, uint256(r0), "INVARIANT: pair insolvent on token0 (balance < reserve)");
        assertGe(balance1, uint256(r1), "INVARIANT: pair insolvent on token1 (balance < reserve)");
    }

    // ============ INVARIANT 3: LP CONSERVATION ============

    /// @notice Sum of all actor LP balances + LP held by pair itself == totalSupply
    function invariant_lpConservation() public view {
        uint256 actorLP = handler.totalActorLP();
        uint256 pairLP = pair.balanceOf(address(pair));
        uint256 testContractLP = pair.balanceOf(address(this));
        uint256 handlerLP = pair.balanceOf(address(handler));

        uint256 totalTracked = actorLP + pairLP + testContractLP + handlerLP;
        uint256 totalSupply = pair.totalSupply();

        // Account for any LP held by feeTo address (protocol fees)
        address feeTo = factory.feeTo();
        if (feeTo != address(0)) {
            totalTracked += pair.balanceOf(feeTo);
        }

        assertEq(totalTracked, totalSupply, "INVARIANT: LP conservation violated - tracked != totalSupply");
    }

    // ============ INVARIANT 4: NO GLOBAL VALUE EXTRACTION ============

    /// @notice Total tokens withdrawn across all actors must not exceed total tokens
    ///         that entered the pool. Tokens enter via liquidity deposits AND swap inputs.
    ///         Plus the initial seed from setUp.
    function invariant_noGlobalExtraction() public view {
        uint256 totalIn0 = handler.totalDeposited0() + handler.totalSwappedIn0();
        uint256 totalIn1 = handler.totalDeposited1() + handler.totalSwappedIn1();
        uint256 totalW0 = handler.totalWithdrawn0();
        uint256 totalW1 = handler.totalWithdrawn1();

        // Total withdrawn cannot exceed total that entered the pool + initial seed (100 ether each).
        // The pool can only redistribute existing tokens; it cannot create new ones.
        assertLe(
            totalW0,
            totalIn0 + 100 ether,
            "INVARIANT: more token0 withdrawn globally than entered pool"
        );
        assertLe(
            totalW1,
            totalIn1 + 100 ether,
            "INVARIANT: more token1 withdrawn globally than entered pool"
        );
    }

    // ============ INVARIANT 5: FEE BOUNDS ============

    /// @notice getSwapFee() must always return a value within [BASE_FEE_BPS, MAX_FEE_BPS]
    function invariant_feeBounds() public view {
        uint256 fee = pair.getSwapFee();
        assertGe(fee, pair.BASE_FEE_BPS(), "INVARIANT: fee below BASE_FEE_BPS");
        assertLe(fee, pair.MAX_FEE_BPS(), "INVARIANT: fee above MAX_FEE_BPS");
    }

    // ============ INVARIANT 6: RESERVES MATCH BALANCES AFTER SYNC ============

    /// @notice After calling sync, reserves must exactly equal actual token balances
    function invariant_reservesMatchAfterSync() public {
        // Call sync to force reserves to match balances
        pair.sync();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 balance0 = token0.balanceOf(address(pair));
        uint256 balance1 = token1.balanceOf(address(pair));

        assertEq(uint256(r0), balance0, "INVARIANT: reserve0 != balance0 after sync");
        assertEq(uint256(r1), balance1, "INVARIANT: reserve1 != balance1 after sync");
    }
}
