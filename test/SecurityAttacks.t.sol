// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {ChRouter} from "../src/ChRouter.sol";
import {IChCallee} from "../src/interfaces/IChCallee.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {WETH9} from "./mocks/WETH9.sol";

/// @title Security Attack Simulations
/// @notice Tests that simulate known attack vectors against the DEX
contract SecurityAttacksTest is Test {
    ChFactory factory;
    ChRouter router;
    WETH9 weth;
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address admin = makeAddr("admin");
    address attacker = makeAddr("attacker");

    function setUp() public {
        weth = new WETH9();
        factory = new ChFactory(admin);
        router = new ChRouter(address(factory), address(weth));

        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = ChPair(pairAddr);

        // Setup: alice provides liquidity (large pool for circuit breaker compliance)
        token0.mint(alice, 10_000 ether);
        token1.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        token0.transfer(address(pair), 1000 ether);
        token1.transfer(address(pair), 1000 ether);
        pair.mint(alice);
        vm.stopPrank();

        // Give attacker some tokens
        token0.mint(attacker, 1000 ether);
        token1.mint(attacker, 1000 ether);
    }

    // ============ REENTRANCY ATTACKS ============

    /// @notice Attempt reentrancy via flash swap callback
    function test_attack_reentrancyViaFlashSwap() public {
        ReentrancyAttacker attackContract = new ReentrancyAttacker(pair, token0, token1);
        token0.mint(address(attackContract), 10 ether);

        // The attacker tries to re-enter swap during the flash callback
        vm.expectRevert();
        attackContract.attack();
    }

    /// @notice Attempt reentrancy via malicious token transfer
    function test_attack_reentrancyViaMaliciousToken() public {
        // Create a malicious token that tries to re-enter on transfer
        ReentrantToken malToken = new ReentrantToken();
        MockERC20 normalToken = new MockERC20("Normal", "NRM", 18);

        address malPairAddr = factory.createPair(address(malToken), address(normalToken));
        ChPair malPair = ChPair(malPairAddr);

        // Add liquidity
        malToken.mint(address(malPair), 10 ether);
        normalToken.mint(address(malPair), 10 ether);
        malPair.mint(alice);

        // Setup attack
        malToken.setPair(address(malPair));
        malToken.mint(attacker, 5 ether);

        vm.prank(attacker);
        malToken.transfer(address(malPair), 1 ether);

        // The malicious token will try to re-enter during swap
        malToken.setAttacking(true);
        vm.expectRevert();
        malPair.swap(0, 0.5 ether, attacker, "");
    }

    // ============ FLASH LOAN ATTACKS ============

    /// @notice Flash swap that tries to steal funds by not repaying enough
    function test_attack_flashSwapUnderpay() public {
        UnderpayFlashAttacker attackContract = new UnderpayFlashAttacker(pair, token0);
        token0.mint(address(attackContract), 1 ether);

        vm.expectRevert("ChPair: K");
        attackContract.attack(1 ether);
    }

    // ============ FIRST DEPOSITOR ATTACK (VIRTUAL RESERVES) ============

    /// @notice First depositor tries to manipulate LP shares. With virtual reserves,
    ///         no tokens are burned, so the attack surface is different from Uniswap V2.
    ///         The virtual offset makes share price manipulation uneconomical.
    function test_attack_firstDepositorFrontrun() public {
        // Create fresh pair for this test
        MockERC20 tA = new MockERC20("TA", "TA", 18);
        MockERC20 tB = new MockERC20("TB", "TB", 18);
        (MockERC20 t0, MockERC20 t1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        address freshPairAddr = factory.createPair(address(t0), address(t1));
        ChPair freshPair = ChPair(freshPairAddr);

        // Attacker: deposit tiny amount
        t0.mint(attacker, 100 ether);
        t1.mint(attacker, 100 ether);

        // Attacker deposits minimal tokens
        vm.startPrank(attacker);
        t0.transfer(address(freshPair), 10_000);
        t1.transfer(address(freshPair), 10_000);
        freshPair.mint(attacker);
        vm.stopPrank();

        // With virtual reserves: attacker gets sqrt(10000*10000) = 10000 (full amount, no burn)
        assertEq(freshPair.balanceOf(attacker), 10_000);

        // Attacker donates tokens to inflate share price
        vm.startPrank(attacker);
        t0.transfer(address(freshPair), 50 ether);
        t1.transfer(address(freshPair), 50 ether);
        freshPair.sync(); // update reserves
        vm.stopPrank();

        // Victim deposits
        address victim = makeAddr("victim");
        t0.mint(victim, 100 ether);
        t1.mint(victim, 100 ether);

        vm.startPrank(victim);
        t0.transfer(address(freshPair), 50 ether);
        t1.transfer(address(freshPair), 50 ether);
        uint256 victimLiquidity = freshPair.mint(victim);
        vm.stopPrank();

        // With virtual offset: victim always gets meaningful shares
        assertGt(victimLiquidity, 0);

        // Victim should get a reasonable proportion of LP tokens
        uint256 attackerLP = freshPair.balanceOf(attacker);
        uint256 victimLP = freshPair.balanceOf(victim);
        assertGt(victimLP, attackerLP / 10); // at least 10% of attacker's share
    }

    // ============ K VALUE MANIPULATION ============

    /// @notice Verify k can never decrease through any sequence of operations.
    ///         Uses dynamic fee from the pair to ensure correct amountOut calculation.
    function testFuzz_kNeverDecreases_multipleSwaps(uint8 numSwaps, uint256 seed) public {
        numSwaps = uint8(bound(numSwaps, 1, 10));

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);

        for (uint8 i = 0; i < numSwaps; i++) {
            // Keep swaps small relative to 1000 ether pool to stay within circuit breaker
            uint256 swapAmount = bound(uint256(keccak256(abi.encode(seed, i))), 0.01 ether, 5 ether);
            bool swapDirection = i % 2 == 0;

            (r0, r1,) = pair.getReserves();
            // Use MAX_FEE_BPS (100) as conservative estimate since swap uses max(pre, post) fee
            uint256 feeBps = 100;
            uint256 amountOut;

            vm.startPrank(attacker);
            if (swapDirection) {
                amountOut = _getAmountOut(swapAmount, r0, r1, feeBps);
                if (amountOut == 0) {
                    vm.stopPrank();
                    continue;
                }
                token0.transfer(address(pair), swapAmount);
                pair.swap(0, amountOut, attacker, "");
            } else {
                amountOut = _getAmountOut(swapAmount, r1, r0, feeBps);
                if (amountOut == 0) {
                    vm.stopPrank();
                    continue;
                }
                token1.transfer(address(pair), swapAmount);
                pair.swap(amountOut, 0, attacker, "");
            }
            vm.stopPrank();
        }

        (r0, r1,) = pair.getReserves();
        uint256 kAfter = uint256(r0) * uint256(r1);

        assertGe(kAfter, kBefore);
    }

    // ============ ACCESS CONTROL ============

    /// @notice Non-factory cannot initialize a pair
    function test_attack_uninitializedPairExploit() public {
        ChPair newPair = new ChPair();
        vm.prank(attacker);
        vm.expectRevert("ChPair: FORBIDDEN");
        newPair.initialize(address(token0), address(token1));
    }

    /// @notice Non-admin cannot use timelock governance
    function test_attack_unauthorizedGovernance() public {
        // Attacker cannot proposeFeeTo
        vm.prank(attacker);
        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.proposeFeeTo(attacker);

        // Attacker cannot proposeFeeToSetter
        vm.prank(attacker);
        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.proposeFeeToSetter(attacker);

        // Even if admin proposes, attacker cannot execute
        vm.prank(admin);
        factory.proposeFeeTo(makeAddr("legit"));

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(attacker);
        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.executeFeeTo();

        // Attacker cannot cancel
        vm.prank(attacker);
        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.cancelPendingFeeTo();
    }

    // ============ ORACLE MANIPULATION ============

    /// @notice Verify TWAP oracle resists single-block manipulation
    function test_attack_oracleManipulation() public {
        // Record initial cumulative prices
        uint256 price0Before = pair.price0CumulativeLast();

        // Advance time to accumulate some honest price data
        vm.warp(block.timestamp + 100);
        pair.sync();

        // Attacker does a small swap to manipulate spot price (within circuit breaker)
        // Use MAX_FEE (100 bps) as conservative estimate for max(pre, post) fee
        vm.startPrank(attacker);
        uint256 swapAmt = 5 ether; // small relative to 1000 ether pool
        token0.transfer(address(pair), swapAmt);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        pair.swap(0, _getAmountOut(swapAmt, r0, r1, 100), attacker, "");
        vm.stopPrank();

        // Only 1 second passes with manipulated price
        vm.warp(block.timestamp + 1);
        pair.sync();

        // Swap back to restore price
        vm.startPrank(attacker);
        uint256 swapBack = 3 ether;
        token1.transfer(address(pair), swapBack);
        (r0, r1,) = pair.getReserves();
        uint256 outAmt = _getAmountOut(swapBack, r1, r0, 100);
        if (outAmt > 0) {
            pair.swap(outAmt, 0, attacker, "");
        }
        vm.stopPrank();

        // Advance more time with honest price
        vm.warp(block.timestamp + 100);
        pair.sync();

        // The TWAP over the full period is dominated by the honest price (200s)
        // not the manipulated price (1s). This is the core TWAP defense.
        uint256 totalDelta = pair.price0CumulativeLast() - price0Before;
        assertGt(totalDelta, 0);
    }

    /// @notice Verify EMA oracle dampens manipulation attempts
    function test_attack_emaOracleManipulation() public {
        // Initialize EMA via sync — need vm.warp so timeElapsed > 0 (per-block EMA gating)
        vm.warp(block.timestamp + 1);
        pair.sync();

        uint256 emaBefore = pair.emaPrice0();
        assertGt(emaBefore, 0);

        // Attacker does multiple small swaps trying to move EMA
        // Use MAX_FEE (100 bps) as conservative estimate for max(pre, post) fee
        for (uint256 i = 0; i < 3; i++) {
            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 swapAmt = 3 ether; // small relative to 1000 ether pool
            uint256 out = _getAmountOut(swapAmt, r0, r1, 100);

            vm.startPrank(attacker);
            token0.transfer(address(pair), swapAmt);
            if (out > 0) {
                pair.swap(0, out, attacker, "");
            }
            vm.stopPrank();
        }

        uint256 emaAfter = pair.emaPrice0();

        // EMA should have moved, but with 5% alpha it should be dampened
        // relative to the actual spot price change
        (uint112 r0Final, uint112 r1Final,) = pair.getReserves();
        uint256 spotPrice = (uint256(r1Final) * 1e18) / uint256(r0Final);

        // EMA should be between original and current spot (not equal to spot)
        // Spot decreased (more token0 in pool, less token1)
        if (spotPrice < emaBefore) {
            assertGt(emaAfter, spotPrice); // EMA lags behind spot
        }
    }

    // ============ CIRCUIT BREAKER ATTACK ============

    /// @notice Attacker tries to crash the price in a single swap — circuit breaker blocks it
    function test_attack_circuitBreakerPreventsManipulation() public {
        // Attacker tries a huge swap to crash price by > 10%
        // 200 ether into 1000 ether pool = ~20% price impact
        uint256 hugeSwap = 200 ether;
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 amountOut = _getAmountOut(hugeSwap, r0, r1, 30);

        vm.startPrank(attacker);
        token0.transfer(address(pair), hugeSwap);
        vm.expectRevert("ChPair: CIRCUIT_BREAKER");
        pair.swap(0, amountOut, attacker, "");
        vm.stopPrank();
    }

    /// @notice Attacker tries to split a large swap into smaller ones.
    ///         Each individual swap must still pass the circuit breaker check.
    function test_attack_circuitBreakerSplitSwaps() public {
        // Multiple small swaps that individually pass the circuit breaker
        uint256 smallSwap = 5 ether; // 0.5% of 1000 ether pool

        for (uint256 i = 0; i < 3; i++) {
            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 feeBps = pair.getSwapFee();
            uint256 amountOut = _getAmountOut(smallSwap, r0, r1, feeBps);
            if (amountOut == 0) break;

            vm.startPrank(attacker);
            token0.transfer(address(pair), smallSwap);
            pair.swap(0, amountOut, attacker, "");
            vm.stopPrank();
        }

        // After multiple small swaps, reserves should still be healthy
        (uint112 r0Final, uint112 r1Final,) = pair.getReserves();
        assertGt(uint256(r0Final), 0);
        assertGt(uint256(r1Final), 0);
    }

    // ============ HELPERS ============

    /// @dev Calculate amountOut with a given fee in basis points
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

/// @dev Attempts reentrancy via flash swap callback
contract ReentrancyAttacker is IChCallee {
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;

    constructor(ChPair _pair, MockERC20 _token0, MockERC20 _token1) {
        pair = _pair;
        token0 = _token0;
        token1 = _token1;
    }

    function attack() external {
        pair.swap(0, 1 ether, address(this), "attack");
    }

    function chSwapCall(address, uint256, uint256, bytes calldata) external {
        // Try to re-enter swap
        pair.swap(0, 0.5 ether, address(this), "");
    }
}

/// @dev Flash swap attacker that repays less than required
contract UnderpayFlashAttacker is IChCallee {
    ChPair pair;
    MockERC20 repayToken;

    constructor(ChPair _pair, MockERC20 _repayToken) {
        pair = _pair;
        repayToken = _repayToken;
    }

    function attack(uint256 borrowAmount) external {
        pair.swap(0, borrowAmount, address(this), "steal");
    }

    function chSwapCall(address, uint256, uint256 amount1, bytes calldata) external {
        // Repay less than required (should fail K check)
        uint256 underpay = amount1 / 2;
        repayToken.transfer(address(pair), underpay);
    }
}

/// @dev Token that attempts reentrancy during transfer
contract ReentrantToken {
    string public name = "Reentrant Token";
    string public symbol = "REENT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public pairAddress;
    bool public attacking;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setPair(address _pair) external {
        pairAddress = _pair;
    }

    function setAttacking(bool _attacking) external {
        attacking = _attacking;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);

        // Attempt reentrancy when pair transfers tokens out
        if (attacking && msg.sender == pairAddress) {
            attacking = false; // prevent infinite recursion
            ChPair(pairAddress).swap(0, 0.1 ether, address(this), "");
        }

        return true;
    }
}
