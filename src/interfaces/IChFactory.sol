// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title IChFactory
/// @notice Interface for the ChSwap Factory contract
interface IChFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairIndex);
    event FeeToProposed(address indexed newFeeTo, uint256 executeAfter);
    event FeeToChanged(address indexed newFeeTo);
    event FeeToSetterProposed(address indexed newFeeToSetter, uint256 executeAfter);
    event FeeToSetterChanged(address indexed newFeeToSetter);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function timelockDelay() external view returns (uint256);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
    function createPair(address tokenA, address tokenB) external returns (address pair);

    // Timelock governance
    function proposeFeeTo(address _feeTo) external;
    function executeFeeTo() external;
    function proposeFeeToSetter(address _feeToSetter) external;
    function executeFeeToSetter() external;
    function cancelPendingFeeTo() external;
    function cancelPendingFeeToSetter() external;
}
