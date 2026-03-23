// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IChFactory} from "./interfaces/IChFactory.sol";
import {ChPair} from "./ChPair.sol";

/// @title ChFactory
/// @notice Factory contract with timelock governance for admin changes
/// @dev All admin changes (feeTo, feeToSetter) require a proposal + delay + execution.
///      This prevents instant admin abuse — changes are visible on-chain before taking effect.
contract ChFactory is IChFactory {
    /// @notice Minimum delay for timelock governance (24 hours)
    uint256 public constant TIMELOCK_DELAY = 24 hours;

    /// @notice Address that receives protocol fees (if enabled)
    address public feeTo;

    /// @notice Address authorized to propose governance changes
    address public feeToSetter;

    /// @notice Mapping from token pair to pool address
    mapping(address => mapping(address => address)) public getPair;

    /// @notice Array of all created pairs
    address[] public allPairs;

    /// @dev Pending governance change structure
    struct PendingChange {
        address newValue;
        uint256 executeAfter;
    }

    /// @notice Pending feeTo change (visible on-chain during timelock)
    PendingChange public pendingFeeTo;

    /// @notice Pending feeToSetter change (visible on-chain during timelock)
    PendingChange public pendingFeeToSetter;

    /// @notice Returns the timelock delay
    function timelockDelay() external pure returns (uint256) {
        return TIMELOCK_DELAY;
    }

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    /// @notice Returns the total number of pairs created
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @notice Creates a new trading pair for two tokens
    /// @dev Uses CREATE2 for deterministic pair addresses
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "ChFactory: IDENTICAL_ADDRESSES");

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        require(token0 != address(0), "ChFactory: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "ChFactory: PAIR_EXISTS");

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        ChPair newPair = new ChPair{salt: salt}();
        pair = address(newPair);

        ChPair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // ============ TIMELOCK GOVERNANCE ============

    /// @notice Propose a new feeTo address. Takes effect after TIMELOCK_DELAY.
    /// @dev The proposed change is visible on-chain, giving users time to react.
    function proposeFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "ChFactory: FORBIDDEN");
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;
        pendingFeeTo = PendingChange(_feeTo, executeAfter);
        emit FeeToProposed(_feeTo, executeAfter);
    }

    /// @notice Execute a previously proposed feeTo change after the timelock expires
    function executeFeeTo() external {
        require(msg.sender == feeToSetter, "ChFactory: FORBIDDEN");
        PendingChange memory pending = pendingFeeTo;
        require(pending.executeAfter != 0, "ChFactory: NO_PENDING_CHANGE");
        require(block.timestamp >= pending.executeAfter, "ChFactory: TIMELOCK_NOT_EXPIRED");

        feeTo = pending.newValue;
        delete pendingFeeTo;
        emit FeeToChanged(pending.newValue);
    }

    /// @notice Cancel a pending feeTo change
    function cancelPendingFeeTo() external {
        require(msg.sender == feeToSetter, "ChFactory: FORBIDDEN");
        delete pendingFeeTo;
    }

    /// @notice Propose a new feeToSetter address. Takes effect after TIMELOCK_DELAY.
    function proposeFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "ChFactory: FORBIDDEN");
        require(_feeToSetter != address(0), "ChFactory: ZERO_ADDRESS");
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;
        pendingFeeToSetter = PendingChange(_feeToSetter, executeAfter);
        emit FeeToSetterProposed(_feeToSetter, executeAfter);
    }

    /// @notice Execute a previously proposed feeToSetter change after the timelock expires
    function executeFeeToSetter() external {
        require(msg.sender == feeToSetter, "ChFactory: FORBIDDEN");
        PendingChange memory pending = pendingFeeToSetter;
        require(pending.executeAfter != 0, "ChFactory: NO_PENDING_CHANGE");
        require(block.timestamp >= pending.executeAfter, "ChFactory: TIMELOCK_NOT_EXPIRED");

        feeToSetter = pending.newValue;
        delete pendingFeeToSetter;
        emit FeeToSetterChanged(pending.newValue);
    }

    /// @notice Cancel a pending feeToSetter change
    function cancelPendingFeeToSetter() external {
        require(msg.sender == feeToSetter, "ChFactory: FORBIDDEN");
        delete pendingFeeToSetter;
    }
}
