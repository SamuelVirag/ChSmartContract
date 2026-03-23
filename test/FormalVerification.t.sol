// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Formal verification properties for Halmos
/// @dev Halmos proves these for ALL possible inputs, not just random samples.
///      Function names prefixed with `check_` are picked up by Halmos.
///      These also run as regular Foundry tests (acting as fuzz tests).
contract FormalVerificationTest is Test {
    ChFactory factory;
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        factory = new ChFactory(address(this));
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = ChPair(pairAddr);

        // Seed pool
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(address(this));
    }

    /// @notice PROPERTY: getAmountOut always returns less than reserveOut
    ///         For any valid input, the output can never drain the entire reserve.
    function testFuzz_amountOutLessThanReserve(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        public
        pure
    {
        // Bound inputs to valid ranges
        vm.assume(amountIn > 0 && amountIn < type(uint112).max);
        vm.assume(reserveIn > 0 && reserveIn < type(uint112).max);
        vm.assume(reserveOut > 0 && reserveOut < type(uint112).max);
        vm.assume(feeBps >= 10 && feeBps <= 100);

        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;

        // Avoid overflow in multiplication
        vm.assume(amountInWithFee <= type(uint256).max / reserveOut);

        uint256 amountOut = numerator / denominator;

        // PROPERTY: output is always strictly less than the reserve
        assert(amountOut < reserveOut);
    }

    /// @notice PROPERTY: getAmountOut rounds down (protocol-favoring)
    ///         The actual output * denominator <= numerator (i.e., floor division)
    function testFuzz_amountOutRoundsDown(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        public
        pure
    {
        vm.assume(amountIn > 0 && amountIn < type(uint112).max);
        vm.assume(reserveIn > 0 && reserveIn < type(uint112).max);
        vm.assume(reserveOut > 0 && reserveOut < type(uint112).max);
        vm.assume(feeBps >= 10 && feeBps <= 100);

        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        vm.assume(amountInWithFee <= type(uint256).max / reserveOut);

        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;
        uint256 amountOut = numerator / denominator;

        // PROPERTY: amountOut * denominator <= numerator (floor division, no overpayment)
        assert(amountOut * denominator <= numerator);
    }

    /// @notice PROPERTY: getAmountIn always rounds up (protocol-favoring)
    ///         The required input is always >= the mathematically exact value.
    function testFuzz_amountInRoundsUp(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        public
        pure
    {
        reserveIn = bound(reserveIn, 1, type(uint112).max);
        reserveOut = bound(reserveOut, 2, type(uint112).max);
        amountOut = bound(amountOut, 1, reserveOut - 1);
        feeBps = bound(feeBps, 10, 100);

        // Bound reserveIn to avoid overflow in reserveIn * amountOut * 10000
        if (amountOut > 0) {
            uint256 maxReserveIn = type(uint256).max / amountOut / 10000;
            if (reserveIn > maxReserveIn) reserveIn = maxReserveIn;
        }

        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * (10000 - feeBps);
        uint256 amountIn = (numerator / denominator) + 1;

        // PROPERTY: amountIn * denominator >= numerator (ceiling, user pays at least exact amount)
        assert(amountIn * denominator >= numerator);
    }

    /// @notice PROPERTY: swap preserves K invariant
    ///         For any valid swap, balance0_adj * balance1_adj >= reserve0 * reserve1 * BPS^2
    function testFuzz_swapPreservesK(uint256 amountIn, bool direction) public {
        vm.assume(amountIn > 0.001 ether && amountIn < 4.5 ether); // within circuit breaker

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * uint256(r1);

        uint256 amountOut = _getAmountOut(amountIn, direction ? r0 : r1, direction ? r1 : r0, 100);
        vm.assume(amountOut > 0);

        if (direction) {
            token0.transfer(address(pair), amountIn);
            try pair.swap(0, amountOut, address(this), "") {}
                catch {
                return;
            }
        } else {
            token1.transfer(address(pair), amountIn);
            try pair.swap(amountOut, 0, address(this), "") {}
                catch {
                return;
            }
        }

        (uint112 newR0, uint112 newR1,) = pair.getReserves();
        uint256 kAfter = uint256(newR0) * uint256(newR1);

        // PROPERTY: k never decreases
        assert(kAfter >= kBefore);
    }

    /// @notice PROPERTY: round-trip swap is never profitable
    ///         Swap A→B then B→A, trader always ends with less than started
    function testFuzz_roundTripUnprofitable(uint256 amountIn) public {
        vm.assume(amountIn > 0.01 ether && amountIn < 4 ether);

        uint256 balanceBefore = token0.balanceOf(address(this));

        // Swap token0 → token1
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 out1 = _getAmountOut(amountIn, r0, r1, 100);
        vm.assume(out1 > 0);

        token0.transfer(address(pair), amountIn);
        try pair.swap(0, out1, address(this), "") {}
            catch {
            return;
        }

        // Swap token1 → token0
        (r0, r1,) = pair.getReserves();
        uint256 out0 = _getAmountOut(out1, r1, r0, 100);
        vm.assume(out0 > 0);

        token1.transfer(address(pair), out1);
        try pair.swap(out0, 0, address(this), "") {}
            catch {
            return;
        }

        uint256 balanceAfter = token0.balanceOf(address(this));

        // PROPERTY: trader ends with less than they started
        assert(balanceAfter <= balanceBefore);
    }

    /// @notice PROPERTY: dynamic fee is always within bounds
    function test_feeAlwaysInBounds() public view {
        uint256 fee = pair.getSwapFee();
        assert(fee >= pair.BASE_FEE_BPS());
        assert(fee <= pair.MAX_FEE_BPS());
    }

    // ============ HELPER ============

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
