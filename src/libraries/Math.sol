// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title Math
/// @notice Library for common math operations needed by the AMM
library Math {
    /// @notice Returns the smaller of two values
    /// @param x First value
    /// @param y Second value
    /// @return z The minimum of x and y
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    /// @notice Calculates the integer square root of a uint256 using the Babylonian method
    /// @dev Used to calculate initial LP token supply: sqrt(amount0 * amount1)
    /// @param y The value to take the square root of
    /// @return z The floor of the square root
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
        // else z = 0
    }
}
