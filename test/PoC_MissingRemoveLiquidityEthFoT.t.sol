// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {ChRouter} from "../src/ChRouter.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {WETH9} from "./mocks/WETH9.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PoC: Missing removeLiquidityETHSupportingFeeOnTransferTokens
/// @notice Demonstrates that removeLiquidityETH() always reverts when the non-WETH
///         token is a fee-on-transfer (FoT) token, because the router receives fewer
///         tokens than it attempts to forward. The workaround using removeLiquidity()
///         directly succeeds because the pair sends tokens to the user, not the router.
/// @dev Affected: ChRouter.sol:133-146
///
///      Root cause:
///        1. removeLiquidityETH() calls removeLiquidity() with to = address(this) (line 142)
///        2. The pair's burn() transfers `amountToken` of the FoT token to the router
///        3. Due to the 2% transfer fee, the router only receives 98% of `amountToken`
///        4. removeLiquidityETH() then calls _safeTransfer(token, to, amountToken) (line 143)
///           with the full pre-fee `amountToken`, which exceeds the router's balance
///        5. The transfer reverts — the router does not have enough tokens
///
///      Impact: Users who provide liquidity with FoT token / ETH pairs via the router
///      can add liquidity but can never remove it through removeLiquidityETH(). Their
///      LP tokens are effectively stuck unless they know the workaround.
///
///      Workaround: Call removeLiquidity() directly with the user's own address as `to`.
///      The pair sends tokens directly to the user (one FoT transfer), avoiding the
///      double-transfer problem in removeLiquidityETH().
contract PoC_MissingRemoveLiquidityEthFoT is Test {
    ChFactory factory;
    ChRouter router;
    FeeOnTransferToken fot;
    WETH9 weth;
    ChPair pair;

    address user = makeAddr("user");

    uint256 constant INITIAL_FOT = 100 ether;
    uint256 constant INITIAL_ETH = 50 ether;

    function setUp() public {
        // Deploy infrastructure
        factory = new ChFactory(address(this));
        weth = new WETH9();
        router = new ChRouter(address(factory), address(weth));

        // Deploy fee-on-transfer token (2% fee on every transfer)
        fot = new FeeOnTransferToken("FeeToken", "FOT");

        // Fund the user
        fot.mint(user, INITIAL_FOT);
        vm.deal(user, INITIAL_ETH + 1 ether); // extra ETH for gas

        // User adds liquidity: FOT / ETH pair via the router
        vm.startPrank(user);
        fot.approve(address(router), type(uint256).max);

        // addLiquidityETH creates the pair and seeds it.
        // Note: FoT token loses 2% on the transfer from user -> pair, so the pair
        // receives less FOT than `amountTokenDesired`. We set amountTokenMin = 0
        // to avoid slippage revert during setup.
        router.addLiquidityETH{value: INITIAL_ETH}(
            address(fot),
            INITIAL_FOT, // amountTokenDesired
            0, // amountTokenMin (flexible for FoT)
            0, // amountETHMin
            user, // LP tokens go to user
            block.timestamp + 1,
            0 // minLiquidity
        );
        vm.stopPrank();

        // Resolve the pair address
        address pairAddr = factory.getPair(address(fot), address(weth));
        require(pairAddr != address(0), "Pair not created");
        pair = ChPair(pairAddr);
    }

    /// @notice Proves removeLiquidityETH() reverts with fee-on-transfer tokens
    /// @dev The router tries to forward more FoT tokens than it actually received
    ///      from the pair, causing an arithmetic underflow / transfer failure.
    function test_removeLiquidityETH_reverts_with_FoT() public {
        uint256 lpBalance = pair.balanceOf(user);
        assertGt(lpBalance, 0, "User should hold LP tokens from setUp");

        emit log_named_uint("User LP balance", lpBalance);
        emit log_named_uint("FoT fee percent", fot.feePercent());

        // Attempt to remove half of the user's liquidity via removeLiquidityETH
        uint256 lpToRemove = lpBalance / 2;

        vm.startPrank(user);
        // Approve the router to pull LP tokens
        pair.approve(address(router), lpToRemove);

        // This MUST revert. The pair sends `amountToken` of FOT to the router,
        // but the router only receives 98% due to the 2% transfer fee. Then the
        // router tries to forward the full `amountToken` to the user, which fails
        // because the router's FOT balance is insufficient.
        vm.expectRevert();
        router.removeLiquidityETH(
            address(fot),
            lpToRemove,
            0, // amountTokenMin
            0, // amountETHMin
            user,
            block.timestamp + 1
        );
        vm.stopPrank();

        emit log("CONFIRMED: removeLiquidityETH() reverts with fee-on-transfer token");
    }

    /// @notice Proves the workaround: removeLiquidity() called directly succeeds
    /// @dev When removeLiquidity() sends tokens directly to the user, there is only
    ///      one FoT transfer (pair -> user). No double-transfer, no shortfall.
    ///      The user then unwraps WETH manually.
    function test_removeLiquidity_workaround_succeeds() public {
        uint256 lpBalance = pair.balanceOf(user);
        uint256 lpToRemove = lpBalance / 2;

        // Record pre-removal balances
        uint256 fotBefore = fot.balanceOf(user);
        uint256 ethBefore = user.balance;

        emit log_named_uint("User LP balance", lpBalance);
        emit log_named_uint("LP to remove", lpToRemove);
        emit log_named_uint("User FOT before", fotBefore);
        emit log_named_uint("User ETH before", ethBefore);
        emit log("---");

        vm.startPrank(user);
        // Approve the router to pull LP tokens
        pair.approve(address(router), lpToRemove);

        // Call removeLiquidity() with `to = user` — pair sends tokens directly to user.
        // Only one FoT transfer occurs (pair -> user), so the router never holds FOT.
        (uint256 amountFot, uint256 amountWeth) = router.removeLiquidity(
            address(fot),
            address(weth),
            lpToRemove,
            0, // amountAMin
            0, // amountBMin
            user, // tokens go directly to user, bypassing router
            block.timestamp + 1
        );

        // User received WETH, not ETH — unwrap manually
        uint256 wethBalance = IERC20(address(weth)).balanceOf(user);
        weth.withdraw(wethBalance);
        vm.stopPrank();

        // Verify the user received tokens
        uint256 fotAfter = fot.balanceOf(user);
        uint256 ethAfter = user.balance;

        // FOT received is amountFot minus 2% fee (pair -> user transfer)
        uint256 fotReceived = fotAfter - fotBefore;
        uint256 ethReceived = ethAfter - ethBefore;

        emit log_named_uint("removeLiquidity amountFot (pre-fee)", amountFot);
        emit log_named_uint("removeLiquidity amountWeth", amountWeth);
        emit log_named_uint("FOT actually received (post-fee)", fotReceived);
        emit log_named_uint("ETH actually received", ethReceived);
        emit log("---");

        // The workaround succeeded: user got FOT (minus transfer fee) and ETH
        assertGt(fotReceived, 0, "User should have received FOT tokens");
        assertGt(ethReceived, 0, "User should have received ETH");

        // Confirm the FoT fee was deducted (user receives less than amountFot)
        uint256 expectedFotReceived = amountFot - (amountFot * fot.feePercent()) / 100;
        assertEq(fotReceived, expectedFotReceived, "FOT received should reflect 2% fee");

        emit log("CONFIRMED: removeLiquidity() workaround succeeds with fee-on-transfer token");
        emit log("  Users must call removeLiquidity() + unwrap WETH manually");
    }

    /// @notice Combined test: proves the revert and the workaround in sequence
    /// @dev Step 1: removeLiquidityETH reverts (broken path)
    ///      Step 2: removeLiquidity succeeds (workaround path)
    ///      Test passage = exploit confirmed + workaround validated
    function test_removeLiquidityETH_FoT_full_scenario() public {
        uint256 lpBalance = pair.balanceOf(user);
        uint256 lpToRemove = lpBalance / 2;

        emit log("== Step 1: removeLiquidityETH MUST revert ==");

        vm.startPrank(user);
        pair.approve(address(router), type(uint256).max);

        // Step 1: removeLiquidityETH reverts
        vm.expectRevert();
        router.removeLiquidityETH(address(fot), lpToRemove, 0, 0, user, block.timestamp + 1);

        emit log("  REVERTED as expected");
        emit log("---");

        emit log("== Step 2: removeLiquidity workaround succeeds ==");

        // Step 2: removeLiquidity works — tokens sent directly to user
        uint256 fotBefore = fot.balanceOf(user);
        uint256 ethBefore = user.balance;

        router.removeLiquidity(address(fot), address(weth), lpToRemove, 0, 0, user, block.timestamp + 1);

        // Unwrap WETH to ETH
        uint256 wethBalance = IERC20(address(weth)).balanceOf(user);
        weth.withdraw(wethBalance);
        vm.stopPrank();

        uint256 fotReceived = fot.balanceOf(user) - fotBefore;
        uint256 ethReceived = user.balance - ethBefore;

        assertGt(fotReceived, 0, "Workaround: user received FOT");
        assertGt(ethReceived, 0, "Workaround: user received ETH");

        emit log_named_uint("  FOT received (post-fee)", fotReceived);
        emit log_named_uint("  ETH received", ethReceived);
        emit log("  SUCCESS: workaround completed");
        emit log("---");

        emit log("EXPLOIT CONFIRMED:");
        emit log("  removeLiquidityETH() is permanently broken for fee-on-transfer tokens.");
        emit log("  The router lacks removeLiquidityETHSupportingFeeOnTransferTokens().");
        emit log("  Workaround: use removeLiquidity() directly and unwrap WETH manually.");
    }
}
