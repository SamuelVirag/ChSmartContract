// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IChPair} from "../interfaces/IChPair.sol";
import {ChPair} from "../ChPair.sol";

/// @title ChLibrary
/// @notice Helper functions for computing swap amounts with dynamic fees
/// @dev All fee parameters are in basis points (1 bps = 0.01%). 30 bps = 0.3%.
library ChLibrary {
    uint256 private constant BPS = 10000;

    /// @notice Sort two token addresses into canonical order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "ChLibrary: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ChLibrary: ZERO_ADDRESS");
    }

    /// @notice Compute the CREATE2 address for a pair
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            factory,
                            keccak256(abi.encodePacked(token0, token1)),
                            keccak256(type(ChPair).creationCode)
                        )
                    )
                )
            )
        );
    }

    /// @notice Fetch current reserves for a pair
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint112 reserve0, uint112 reserve1,) = IChPair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) =
            tokenA == token0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
    }

    /// @notice Fetch the current dynamic swap fee for a pair
    /// @return feeBps Fee in basis points
    function getSwapFee(address factory, address tokenA, address tokenB) internal view returns (uint256 feeBps) {
        feeBps = IChPair(pairFor(factory, tokenA, tokenB)).getSwapFee();
    }

    /// @notice Calculate output amount given input amount and dynamic fee
    /// @dev amountOut = (amountIn * (BPS - feeBps) * reserveOut) / (reserveIn * BPS + amountIn * (BPS - feeBps))
    /// @param amountIn Input token amount
    /// @param reserveIn Reserve of the input token
    /// @param reserveOut Reserve of the output token
    /// @param feeBps Fee in basis points
    /// @return amountOut Maximum output amount (rounds down — favors pool)
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "ChLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "ChLibrary: INSUFFICIENT_LIQUIDITY");

        uint256 amountInWithFee = amountIn * (BPS - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * BPS) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Calculate required input amount for a desired output, with dynamic fee
    /// @dev Rounds up (+1) so the pair always gets at least enough input
    /// @param amountOut Desired output amount
    /// @param reserveIn Reserve of the input token
    /// @param reserveOut Reserve of the output token
    /// @param feeBps Fee in basis points
    /// @return amountIn Required input amount (rounds up — favors pool)
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "ChLibrary: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "ChLibrary: INSUFFICIENT_LIQUIDITY");

        uint256 numerator = reserveIn * amountOut * BPS;
        uint256 denominator = (reserveOut - amountOut) * (BPS - feeBps);
        amountIn = (numerator / denominator) + 1;
    }

    /// @notice Calculate output amounts for a multi-hop swap with per-pair dynamic fees
    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "ChLibrary: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            uint256 feeBps = getSwapFee(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, feeBps);
        }
    }

    /// @notice Calculate input amounts for a multi-hop swap with per-pair dynamic fees
    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "ChLibrary: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            uint256 feeBps = getSwapFee(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut, feeBps);
        }
    }

    /// @notice Calculate optimal tokenB amount for a deposit
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "ChLibrary: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "ChLibrary: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }
}
