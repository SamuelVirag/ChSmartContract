// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title IChCallee
/// @notice Interface for flash swap callback
/// @dev Contracts that want to use flash swaps must implement this interface
interface IChCallee {
    /// @notice Called by the pair contract during a flash swap
    /// @param sender The address that initiated the swap
    /// @param amount0 The amount of token0 sent to the callee
    /// @param amount1 The amount of token1 sent to the callee
    /// @param data Arbitrary data passed from the swap call
    function chSwapCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}
