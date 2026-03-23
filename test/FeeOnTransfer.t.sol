// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {ChRouter} from "../src/ChRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {WETH9} from "./mocks/WETH9.sol";

/// @title Fee-on-Transfer Token Tests
/// @notice Verifies the DEX handles deflationary tokens correctly
contract FeeOnTransferTest is Test {
    ChFactory factory;
    ChRouter router;
    WETH9 weth;
    FeeOnTransferToken feeToken;
    MockERC20 normalToken;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        weth = new WETH9();
        factory = new ChFactory(address(this));
        router = new ChRouter(address(factory), address(weth));

        feeToken = new FeeOnTransferToken("Fee Token", "FEE");
        normalToken = new MockERC20("Normal Token", "NRM", 18);

        // Mint tokens
        feeToken.mint(alice, 1000 ether);
        normalToken.mint(alice, 1000 ether);
        feeToken.mint(bob, 1000 ether);
        normalToken.mint(bob, 1000 ether);

        // Approve router
        vm.startPrank(alice);
        feeToken.approve(address(router), type(uint256).max);
        normalToken.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        feeToken.approve(address(router), type(uint256).max);
        normalToken.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Regular swapExactTokensForTokens REVERTS with fee-on-transfer tokens
    function test_regularSwap_reverts_withFeeToken() public {
        // Add liquidity directly to pair (bypassing router fee issues for setup)
        _addLiquidityDirect(alice, 50 ether, 50 ether);

        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(normalToken);

        // Regular swap should fail because pair receives less than expected
        vm.prank(bob);
        vm.expectRevert(); // K invariant check fails
        router.swapExactTokensForTokens(1 ether, 0, path, bob, block.timestamp + 1);
    }

    /// @notice SupportingFeeOnTransferTokens variant works correctly
    function test_feeOnTransferSwap_succeeds() public {
        _addLiquidityDirect(alice, 50 ether, 50 ether);

        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(normalToken);

        uint256 bobNormalBefore = normalToken.balanceOf(bob);

        vm.prank(bob);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, 0, path, bob, block.timestamp + 1);

        // Bob received some normal tokens
        assertGt(normalToken.balanceOf(bob) - bobNormalBefore, 0);
    }

    /// @notice Fee-on-transfer swap respects slippage protection
    function test_feeOnTransferSwap_slippageProtection() public {
        _addLiquidityDirect(alice, 50 ether, 50 ether);

        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(normalToken);

        vm.prank(bob);
        vm.expectRevert("ChRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, 100 ether, path, bob, block.timestamp + 1);
    }

    /// @notice Fee-on-transfer with ETH pair
    function test_feeOnTransferSwap_ETHOutput() public {
        // Create feeToken/WETH pair
        vm.deal(alice, 100 ether);

        address pairAddr = factory.createPair(address(feeToken), address(weth));

        // Add liquidity directly
        vm.startPrank(alice);
        feeToken.transfer(pairAddr, 50 ether); // 49 arrives (2% fee)
        weth.deposit{value: 50 ether}();
        weth.transfer(pairAddr, 50 ether);
        ChPair(pairAddr).mint(alice);
        vm.stopPrank();

        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(weth);

        uint256 bobEthBefore = bob.balance;

        vm.prank(bob);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(1 ether, 0, path, bob, block.timestamp + 1);

        assertGt(bob.balance - bobEthBefore, 0);
    }

    // ============ HELPERS ============

    /// @dev Add liquidity directly to pair, bypassing router (fee-on-transfer safe)
    function _addLiquidityDirect(address user, uint256 feeAmount, uint256 normalAmount) internal {
        // Sort tokens for pair lookup
        address pairAddr = factory.getPair(address(feeToken), address(normalToken));
        if (pairAddr == address(0)) {
            pairAddr = factory.createPair(address(feeToken), address(normalToken));
        }

        vm.startPrank(user);
        feeToken.transfer(pairAddr, feeAmount); // 2% fee taken, pair receives 98%
        normalToken.transfer(pairAddr, normalAmount);
        ChPair(pairAddr).mint(user);
        vm.stopPrank();
    }
}
