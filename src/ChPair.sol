// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IChPair} from "./interfaces/IChPair.sol";
import {IChFactory} from "./interfaces/IChFactory.sol";
import {IChCallee} from "./interfaces/IChCallee.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {Math} from "./libraries/Math.sol";

/// @title ChPair
/// @notice AMM pair contract implementing constant product (x * y = k) with six innovations:
///         1. Virtual reserves — first-depositor protection without burning LP tokens
///         2. Dynamic fees — volatility-adjusted swap fees (30-100 bps)
///         3. Explicit flash loan fee — flash swaps pay a surcharge
///         4. EMA oracle — per-block exponential moving average price
///         5. Circuit breaker — per-block baseline, reverts if cumulative impact exceeds threshold
///         6. Timelock governance — admin changes require delay (enforced in Factory)
/// @dev Follows Checks-Effects-Interactions (CEI) pattern throughout.
///      Uses OpenZeppelin's ReentrancyGuard for reentrancy protection.
contract ChPair is IChPair, ERC20, ReentrancyGuard {
    using UQ112x112 for uint224;

    // ============ CONSTANTS ============

    /// @notice Virtual offset added to reserves and supply in LP calculations.
    uint256 public constant VIRTUAL_OFFSET = 1000;

    /// @notice Base swap fee in basis points (0.3%). This is also the effective minimum fee
    ///         since the dynamic fee formula only adds to BASE_FEE_BPS.
    uint256 public constant BASE_FEE_BPS = 30;

    /// @notice Maximum swap fee in basis points (1.0%)
    uint256 public constant MAX_FEE_BPS = 100;

    /// @notice Additional fee charged on flash swaps, in basis points (0.09%)
    uint256 public constant FLASH_FEE_BPS = 9;

    /// @notice Maximum allowed price impact per block in basis points (10%)
    /// @dev Circuit breaker uses per-block baseline: all swaps within a block are compared
    ///      against the reserves at the start of the block, preventing split-swap bypass.
    uint256 public constant MAX_PRICE_IMPACT_BPS = 1000;

    /// @notice EMA smoothing factor in basis points (5% = new observation weight)
    /// @dev EMA updates once per block (gated by timestamp), preventing multi-swap
    ///      compounding and sync-loop manipulation within a single block.
    uint256 public constant EMA_ALPHA_BPS = 500;

    /// @notice Basis point denominator
    uint256 private constant BPS = 10000;

    // ============ STATE ============

    /// @notice The factory that created this pair
    address public immutable factory;

    /// @notice The first token in the pair (sorted by address, token0 < token1)
    address public token0;

    /// @notice The second token in the pair
    address public token1;

    /// @dev Reserve of token0 — packed with reserve1 and blockTimestampLast
    uint112 private reserve0;

    /// @dev Reserve of token1
    uint112 private reserve1;

    /// @dev Timestamp of the last block where reserves were updated
    uint32 private blockTimestampLast;

    /// @notice Cumulative price of token0 (V2-compatible, for external TWAP consumers)
    uint256 public price0CumulativeLast;

    /// @notice Cumulative price of token1 (V2-compatible, for external TWAP consumers)
    uint256 public price1CumulativeLast;

    /// @notice k after the most recent liquidity event (for protocol fee calculation)
    uint256 public kLast;

    /// @dev EMA price of token0 in terms of token1 (scaled by 1e18).
    ///      Private to prevent stale reads during flash swaps — use getEmaPrice0().
    uint256 private _emaPrice0;

    /// @dev EMA price of token1 in terms of token0 (scaled by 1e18).
    uint256 private _emaPrice1;

    /// @dev Circuit breaker per-block baseline reserves.
    ///      Set on the first swap of each block; all subsequent swaps in the same block
    ///      are compared against this baseline, preventing split-swap bypass.
    uint112 private cbBaselineReserve0;
    uint112 private cbBaselineReserve1;
    uint32 private cbBaselineBlock;

    constructor() ERC20("ChSwap LP Token", "CH-LP") {
        factory = msg.sender;
    }

    /// @notice Initialize the pair with token addresses
    /// @dev Called once by the factory at deployment. Cannot be called again.
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "ChPair: FORBIDDEN");
        require(token0 == address(0), "ChPair: ALREADY_INITIALIZED");
        token0 = _token0;
        token1 = _token1;
    }

    /// @notice Returns whether the contract is currently in a nonReentrant call
    /// @dev Enables consuming contracts to verify they are not reading stale mid-transaction state.
    function isLocked() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    /// @notice Returns the current reserves and the timestamp of the last update
    /// @dev Protected by nonReentrantView to prevent read-only reentrancy.
    function getReserves()
        public
        view
        nonReentrantView
        returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast)
    {
        return _getReserves();
    }

    /// @dev Internal reserves accessor — no reentrancy check
    function _getReserves() private view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /// @notice Returns EMA price of token0 in terms of token1 (scaled by 1e18)
    /// @dev Protected by nonReentrantView to prevent stale reads during flash swaps.
    function emaPrice0() external view nonReentrantView returns (uint256) {
        return _emaPrice0;
    }

    /// @notice Returns EMA price of token1 in terms of token0 (scaled by 1e18)
    /// @dev Protected by nonReentrantView to prevent stale reads during flash swaps.
    function emaPrice1() external view nonReentrantView returns (uint256) {
        return _emaPrice1;
    }

    /// @notice Returns the current dynamic swap fee in basis points
    /// @dev Protected by nonReentrantView to prevent stale fee reads during flash swaps.
    ///      The actual fee applied during swap uses _computeFee() with post-swap balances
    ///      and takes max(preSwapFee, postSwapFee) to prevent fee manipulation.
    function getSwapFee() public view nonReentrantView returns (uint256 feeBps) {
        return _computeFee(uint256(reserve0), uint256(reserve1));
    }

    /// @dev Internal fee accessor for use within nonReentrant functions
    function _getSwapFee() private view returns (uint256 feeBps) {
        return _computeFee(uint256(reserve0), uint256(reserve1));
    }

    /// @dev Compute dynamic fee for a given price point
    /// @return feeBps Fee in basis points, clamped to [BASE_FEE, MAX_FEE]
    function _computeFee(uint256 bal0, uint256 bal1) private view returns (uint256 feeBps) {
        if (_emaPrice0 == 0 || bal0 == 0) {
            return BASE_FEE_BPS;
        }

        uint256 spotPrice = (bal1 * 1e18) / bal0;

        uint256 deviation;
        if (spotPrice > _emaPrice0) {
            deviation = ((spotPrice - _emaPrice0) * BPS) / _emaPrice0;
        } else {
            deviation = ((_emaPrice0 - spotPrice) * BPS) / _emaPrice0;
        }

        // Fee scales linearly with deviation: 1% deviation adds ~3 bps
        feeBps = BASE_FEE_BPS + (deviation * 3);

        if (feeBps > MAX_FEE_BPS) feeBps = MAX_FEE_BPS;
    }

    // ============ ORACLE ============

    /// @dev Updates both the V2-compatible cumulative price oracle AND the EMA oracle.
    ///      EMA is gated to update only once per block (when timeElapsed > 0), preventing
    ///      multi-swap compounding and sync-loop manipulation within a single block.
    function _updateOracle(uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) private {
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);

        unchecked {
            uint32 timeElapsed = blockTimestamp - _blockTimestampLast;
            if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
                // V2-compatible cumulative prices
                price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
                price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;

                // EMA oracle — gated by block timestamp (once per block only)
                uint256 spotPrice0 = (uint256(_reserve1) * 1e18) / uint256(_reserve0);
                uint256 spotPrice1 = (uint256(_reserve0) * 1e18) / uint256(_reserve1);

                if (_emaPrice0 == 0) {
                    _emaPrice0 = spotPrice0;
                    _emaPrice1 = spotPrice1;
                } else {
                    _emaPrice0 = (_emaPrice0 * (BPS - EMA_ALPHA_BPS) + spotPrice0 * EMA_ALPHA_BPS) / BPS;
                    _emaPrice1 = (_emaPrice1 * (BPS - EMA_ALPHA_BPS) + spotPrice1 * EMA_ALPHA_BPS) / BPS;
                }
            }
        }
    }

    /// @dev Updates reserves and both oracles
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "ChPair: OVERFLOW");

        _updateOracle(_reserve0, _reserve1, blockTimestampLast);

        // forge-lint: disable-next-line(unsafe-typecast)
        reserve0 = uint112(balance0); // safe: checked by require above
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve1 = uint112(balance1); // safe: checked by require above
        blockTimestampLast = uint32(block.timestamp % 2 ** 32);

        emit Sync(reserve0, reserve1);
    }

    // ============ CIRCUIT BREAKER ============

    /// @dev Reverts if cumulative price impact within the current block exceeds threshold.
    ///      Uses per-block baseline: the first swap in a block snapshots the starting reserves,
    ///      and all subsequent swaps are compared against that baseline. This prevents
    ///      split-swap bypass where N small swaps each pass individually but compound to
    ///      exceed the threshold.
    function _checkCircuitBreaker(
        uint256 _reserveBefore0,
        uint256 _reserveBefore1,
        uint256 reserveAfter0,
        uint256 reserveAfter1
    ) private {
        // Set baseline on first swap of the block
        if (cbBaselineBlock != uint32(block.number)) {
            cbBaselineReserve0 = uint112(_reserveBefore0);
            cbBaselineReserve1 = uint112(_reserveBefore1);
            cbBaselineBlock = uint32(block.number);
        }

        // Compare against start-of-block baseline, not per-swap reserves
        uint256 crossBefore = uint256(cbBaselineReserve1) * reserveAfter0;
        uint256 crossAfter = reserveAfter1 * uint256(cbBaselineReserve0);

        uint256 deviation;
        if (crossAfter > crossBefore) {
            // Round up for protective check (strict enforcement)
            deviation = ((crossAfter - crossBefore) * BPS + crossBefore - 1) / crossBefore;
        } else {
            deviation = ((crossBefore - crossAfter) * BPS + crossBefore - 1) / crossBefore;
        }

        require(deviation <= MAX_PRICE_IMPACT_BPS, "ChPair: CIRCUIT_BREAKER");
    }

    // ============ PROTOCOL FEE ============

    /// @dev Mints protocol fee as LP tokens if feeTo is set.
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IChFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;

        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(uint256(_reserve0) * uint256(_reserve1));
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 effectiveSupply = totalSupply() + VIRTUAL_OFFSET;
                    uint256 numerator = effectiveSupply * (rootK - rootKLast);
                    uint256 denominator = rootK * 5 + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) {
                        _mint(feeTo, liquidity);
                    }
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // ============ MINT (ADD LIQUIDITY) ============

    /// @notice Add liquidity to the pair and receive LP tokens
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = _getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - uint256(_reserve0);
        uint256 amount1 = balance1 - uint256(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1);
            require(liquidity > 0, "ChPair: INSUFFICIENT_LIQUIDITY_MINTED");
        } else {
            uint256 effectiveSupply = _totalSupply + VIRTUAL_OFFSET;
            uint256 effectiveReserve0 = uint256(_reserve0) + VIRTUAL_OFFSET;
            uint256 effectiveReserve1 = uint256(_reserve1) + VIRTUAL_OFFSET;

            liquidity = Math.min(
                (amount0 * effectiveSupply) / effectiveReserve0, (amount1 * effectiveSupply) / effectiveReserve1
            );
            require(liquidity > 0, "ChPair: INSUFFICIENT_LIQUIDITY_MINTED");
        }

        _mint(to, liquidity);
        _update(balance0, balance1, _reserve0, _reserve1);

        if (feeOn) {
            kLast = uint256(reserve0) * uint256(reserve1);
        }

        emit Mint(msg.sender, amount0, amount1);
    }

    // ============ BURN (REMOVE LIQUIDITY) ============

    /// @notice Remove liquidity by burning LP tokens and receiving underlying tokens
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = _getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(_reserve0, _reserve1);

        uint256 effectiveSupply = totalSupply() + VIRTUAL_OFFSET;

        amount0 = (liquidity * balance0) / effectiveSupply;
        amount1 = (liquidity * balance1) / effectiveSupply;
        require(amount0 > 0 && amount1 > 0, "ChPair: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);

        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        _update(balance0, balance1, _reserve0, _reserve1);

        if (feeOn) {
            kLast = uint256(reserve0) * uint256(reserve1);
        }

        emit Burn(msg.sender, amount0, amount1, to);
    }

    // ============ SWAP ============

    /// @notice Swap tokens with dynamic fees, flash loan surcharge, and per-block circuit breaker
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, "ChPair: INSUFFICIENT_OUTPUT_AMOUNT");

        (uint112 _reserve0, uint112 _reserve1,) = _getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "ChPair: INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        bool isFlashSwap;

        {
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "ChPair: INVALID_TO");

            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);

            isFlashSwap = data.length > 0;
            if (isFlashSwap) {
                IChCallee(to).chSwapCall(msg.sender, amount0Out, amount1Out, data);
            }

            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "ChPair: INSUFFICIENT_INPUT_AMOUNT");

        // Dynamic fee: max(pre, post) to prevent manipulation
        uint256 preSwapFee = _computeFee(uint256(_reserve0), uint256(_reserve1));
        uint256 postSwapFee = _computeFee(balance0, balance1);
        uint256 feeBps = preSwapFee > postSwapFee ? preSwapFee : postSwapFee;
        if (isFlashSwap) {
            feeBps += FLASH_FEE_BPS;
        }

        // K invariant check
        {
            uint256 balance0Adjusted = balance0 * BPS - (amount0In * feeBps);
            uint256 balance1Adjusted = balance1 * BPS - (amount1In * feeBps);
            require(
                balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * uint256(_reserve1) * (BPS ** 2), "ChPair: K"
            );
        }

        // Per-block circuit breaker (uses start-of-block baseline)
        _checkCircuitBreaker(uint256(_reserve0), uint256(_reserve1), balance0, balance1);

        _update(balance0, balance1, _reserve0, _reserve1);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // ============ SAFETY FUNCTIONS ============

    /// @notice Force balances to match reserves (recover mistakenly sent tokens)
    function skim(address to) external nonReentrant {
        address _token0 = token0;
        address _token1 = token1;
        uint256 excess0 = IERC20(_token0).balanceOf(address(this)) - reserve0;
        uint256 excess1 = IERC20(_token1).balanceOf(address(this)) - reserve1;
        if (excess0 > 0) _safeTransfer(_token0, to, excess0);
        if (excess1 > 0) _safeTransfer(_token1, to, excess1);
    }

    /// @notice Force reserves to match current token balances
    /// @dev Safety function for rebasing tokens. EMA only updates once per block.
    function sync() external nonReentrant {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    // ============ INTERNAL ============

    /// @dev Safe token transfer that handles tokens not returning a bool (like USDT)
    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ChPair: TRANSFER_FAILED");
    }
}
