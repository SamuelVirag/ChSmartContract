// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title UQ112x112
/// @notice A library for handling binary fixed point numbers (https://en.wikipedia.org/wiki/Q_(number_format))
/// @dev Range: [0, 2^112 - 1]. Resolution: 1 / 2^112.
///      Used by the pair contract to store cumulative prices for the TWAP oracle.
library UQ112x112 {
    uint224 internal constant Q112 = 2 ** 112;

    /// @notice Encode a uint112 as a UQ112x112 fixed point number
    /// @param y The uint112 to encode
    /// @return z The encoded UQ112x112 value
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112;
    }

    /// @notice Divide a UQ112x112 by a uint112, returning a UQ112x112
    /// @dev Intentionally allows division to overflow for cumulative price wrapping
    /// @param x The UQ112x112 numerator
    /// @param y The uint112 denominator
    /// @return z The UQ112x112 result
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}
