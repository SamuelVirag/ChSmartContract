// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IChFactory} from "./interfaces/IChFactory.sol";
import {IChPair} from "./interfaces/IChPair.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {ChLibrary} from "./libraries/ChLibrary.sol";

/// @title ChRouter
/// @notice Router contract with slippage/deadline protection, ETH wrapping, and fee-on-transfer support
/// @dev Works with ChPair's dynamic fee system — queries per-pair fees for accurate quotes.
contract ChRouter {
    address public immutable factory;
    address public immutable WETH;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "ChRouter: EXPIRED");
        _;
    }

    constructor(address _factory, address _WETH) {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH);
    }

    // ============ ADD LIQUIDITY ============

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        if (IChFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            IChFactory(factory).createPair(tokenA, tokenB);
        }

        (uint256 reserveA, uint256 reserveB) = ChLibrary.getReserves(factory, tokenA, tokenB);

        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = ChLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "ChRouter: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = ChLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "ChRouter: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /// @notice Add liquidity to a token pair
    /// @param minLiquidity Minimum LP tokens to receive (sandwich protection for LP deposits)
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        uint256 minLiquidity
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = ChLibrary.pairFor(factory, tokenA, tokenB);
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IChPair(pair).mint(to);
        require(liquidity >= minLiquidity, "ChRouter: INSUFFICIENT_LIQUIDITY_MINTED");
    }

    /// @notice Add liquidity to an ETH/token pair
    /// @param minLiquidity Minimum LP tokens to receive (sandwich protection for LP deposits)
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        uint256 minLiquidity
    ) external payable ensure(deadline) returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        (amountToken, amountETH) =
            _addLiquidity(token, WETH, amountTokenDesired, msg.value, amountTokenMin, amountETHMin);
        address pair = ChLibrary.pairFor(factory, token, WETH);
        _safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = IChPair(pair).mint(to);
        require(liquidity >= minLiquidity, "ChRouter: INSUFFICIENT_LIQUIDITY_MINTED");
        if (msg.value > amountETH) {
            _safeTransferETH(msg.sender, msg.value - amountETH);
        }
    }

    // ============ REMOVE LIQUIDITY ============

    /// @notice Remove liquidity from a token pair
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = ChLibrary.pairFor(factory, tokenA, tokenB);
        bool sent = IERC20(pair).transferFrom(msg.sender, pair, liquidity);
        require(sent, "ChRouter: LP_TRANSFER_FAILED");
        (uint256 amount0, uint256 amount1) = IChPair(pair).burn(to);

        (address token0,) = ChLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);

        require(amountA >= amountAMin, "ChRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "ChRouter: INSUFFICIENT_B_AMOUNT");
    }

    /// @notice Remove liquidity from an ETH/token pair
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token, WETH, liquidity, amountTokenMin, amountETHMin, address(this), deadline
        );
        _safeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        _safeTransferETH(to, amountETH);
    }

    /// @notice Remove liquidity from an ETH/fee-on-transfer-token pair
    /// @dev Uses actual router balance after burn instead of returned amounts,
    ///      because fee-on-transfer tokens deliver less than the reported amount.
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountETH) {
        (, amountETH) = removeLiquidity(token, WETH, liquidity, amountTokenMin, amountETHMin, address(this), deadline);
        // Use actual balance — fee-on-transfer tokens deliver less than reported
        _safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        _safeTransferETH(to, amountETH);
    }

    // ============ SWAP ============

    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = ChLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? ChLibrary.pairFor(factory, output, path[i + 2]) : _to;
            IChPair(ChLibrary.pairFor(factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /// @notice Swap exact input for maximum output
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = ChLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "ChRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        _safeTransferFrom(path[0], msg.sender, ChLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice Swap minimum input for exact output
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = ChLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "ChRouter: EXCESSIVE_INPUT_AMOUNT");
        _safeTransferFrom(path[0], msg.sender, ChLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice Swap exact ETH for tokens
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "ChRouter: INVALID_PATH");
        amounts = ChLibrary.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "ChRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(ChLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
    }

    /// @notice Swap tokens for exact ETH
    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "ChRouter: INVALID_PATH");
        amounts = ChLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "ChRouter: EXCESSIVE_INPUT_AMOUNT");
        _safeTransferFrom(path[0], msg.sender, ChLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        _safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /// @notice Swap exact tokens for ETH
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "ChRouter: INVALID_PATH");
        amounts = ChLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "ChRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        _safeTransferFrom(path[0], msg.sender, ChLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        _safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /// @notice Swap ETH for exact tokens
    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "ChRouter: INVALID_PATH");
        amounts = ChLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, "ChRouter: EXCESSIVE_INPUT_AMOUNT");
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(ChLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        if (msg.value > amounts[0]) {
            _safeTransferETH(msg.sender, msg.value - amounts[0]);
        }
    }

    // ============ FEE-ON-TRANSFER TOKEN SUPPORT ============

    /// @dev Swap using actual balance changes (for fee-on-transfer tokens).
    ///      Uses MAX_FEE_BPS (100) as conservative fee estimate to avoid reverts when the
    ///      pair's max(preSwapFee, postSwapFee) exceeds the pre-swap fee. This trades
    ///      slightly worse execution for reliability.
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = ChLibrary.sortTokens(input, output);
            IChPair pair = IChPair(ChLibrary.pairFor(factory, input, output));

            uint256 amountOutput;
            {
                (uint256 reserveInput, uint256 reserveOutput) = ChLibrary.getReserves(factory, input, output);
                uint256 amountInput = IERC20(input).balanceOf(address(pair)) - reserveInput;
                // Use MAX_FEE_BPS to ensure K check passes even when post-swap fee > pre-swap fee
                amountOutput = ChLibrary.getAmountOut(amountInput, reserveInput, reserveOutput, 100);
            }

            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
            address to = i < path.length - 2 ? ChLibrary.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /// @notice Swap exact tokens for tokens, supporting fee-on-transfer tokens
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) {
        _safeTransferFrom(path[0], msg.sender, ChLibrary.pairFor(factory, path[0], path[1]), amountIn);
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin,
            "ChRouter: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    /// @notice Swap exact ETH for tokens, supporting fee-on-transfer tokens
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) {
        require(path[0] == WETH, "ChRouter: INVALID_PATH");
        uint256 amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        assert(IWETH(WETH).transfer(ChLibrary.pairFor(factory, path[0], path[1]), amountIn));
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin,
            "ChRouter: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    /// @notice Swap exact tokens for ETH, supporting fee-on-transfer tokens
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) {
        require(path[path.length - 1] == WETH, "ChRouter: INVALID_PATH");
        _safeTransferFrom(path[0], msg.sender, ChLibrary.pairFor(factory, path[0], path[1]), amountIn);
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint256 amountOut = IWETH(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, "ChRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWETH(WETH).withdraw(amountOut);
        _safeTransferETH(to, amountOut);
    }

    // ============ LIBRARY WRAPPERS ============

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB) {
        return ChLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        external
        pure
        returns (uint256 amountOut)
    {
        return ChLibrary.getAmountOut(amountIn, reserveIn, reserveOut, feeBps);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        external
        pure
        returns (uint256 amountIn)
    {
        return ChLibrary.getAmountIn(amountOut, reserveIn, reserveOut, feeBps);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        return ChLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts) {
        return ChLibrary.getAmountsIn(factory, amountOut, path);
    }

    // ============ INTERNAL HELPERS ============

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ChRouter: TRANSFER_FAILED");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ChRouter: TRANSFER_FROM_FAILED");
    }

    function _safeTransferETH(address to, uint256 value) private {
        (bool success,) = to.call{value: value}("");
        require(success, "ChRouter: ETH_TRANSFER_FAILED");
    }
}
