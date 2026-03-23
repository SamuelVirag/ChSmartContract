// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title IWETH
/// @notice Interface for Wrapped ETH contract
interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function withdraw(uint256) external;
    function balanceOf(address owner) external view returns (uint256);
}
