// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title IChPair
/// @notice Interface for the ChSwap Pair contract
interface IChPair {
    // Events
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    // View functions
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function kLast() external view returns (uint256);

    // EMA oracle
    function emaPrice0() external view returns (uint256);
    function emaPrice1() external view returns (uint256);

    // Read-only reentrancy protection
    function isLocked() external view returns (bool);

    // Dynamic fee
    function getSwapFee() external view returns (uint256 feeBps);

    // State-changing functions
    function initialize(address token0, address token1) external;
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}
