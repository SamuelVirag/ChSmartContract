// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ChFactoryTest is Test {
    ChFactory factory;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address admin = makeAddr("admin");

    function setUp() public {
        factory = new ChFactory(admin);
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
    }

    // ============ PAIR CREATION ============

    function test_createPair() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));

        assertTrue(pair != address(0));
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair);
        // Reverse lookup works too
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair);
    }

    function test_createPair_sortedTokens() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        ChPair p = ChPair(pair);

        // token0 should be the smaller address
        if (address(tokenA) < address(tokenB)) {
            assertEq(p.token0(), address(tokenA));
            assertEq(p.token1(), address(tokenB));
        } else {
            assertEq(p.token0(), address(tokenB));
            assertEq(p.token1(), address(tokenA));
        }
    }

    function test_createPair_revert_identicalAddresses() public {
        vm.expectRevert("ChFactory: IDENTICAL_ADDRESSES");
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_createPair_revert_zeroAddress() public {
        vm.expectRevert("ChFactory: ZERO_ADDRESS");
        factory.createPair(address(0), address(tokenA));
    }

    function test_createPair_revert_pairExists() public {
        factory.createPair(address(tokenA), address(tokenB));

        vm.expectRevert("ChFactory: PAIR_EXISTS");
        factory.createPair(address(tokenA), address(tokenB));
    }

    function test_createPair_revert_pairExistsReversed() public {
        factory.createPair(address(tokenA), address(tokenB));

        vm.expectRevert("ChFactory: PAIR_EXISTS");
        factory.createPair(address(tokenB), address(tokenA));
    }

    function test_deterministic_addresses() public {
        MockERC20 tA = new MockERC20("A", "A", 18);
        MockERC20 tB = new MockERC20("B", "B", 18);

        address pair = factory.createPair(address(tA), address(tB));
        assertTrue(pair != address(0));

        // Verify deterministic via CREATE2
        assertEq(factory.getPair(address(tA), address(tB)), pair);
        assertEq(factory.getPair(address(tB), address(tA)), pair);
    }

    // ============ TIMELOCK GOVERNANCE: proposeFeeTo / executeFeeTo ============

    function test_proposeFeeTo_and_executeFeeTo() public {
        address feeRecipient = makeAddr("feeRecipient");

        // Step 1: Propose
        vm.prank(admin);
        factory.proposeFeeTo(feeRecipient);

        // feeTo should NOT have changed yet
        assertEq(factory.feeTo(), address(0));

        // Step 2: Wait for timelock to expire
        vm.warp(block.timestamp + 24 hours + 1);

        // Step 3: Execute
        vm.prank(admin);
        factory.executeFeeTo();

        // Now feeTo should be updated
        assertEq(factory.feeTo(), feeRecipient);
    }

    function test_proposeFeeTo_revert_notSetter() public {
        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.proposeFeeTo(makeAddr("feeRecipient"));
    }

    function test_executeFeeTo_revert_notSetter() public {
        address feeRecipient = makeAddr("feeRecipient");

        vm.prank(admin);
        factory.proposeFeeTo(feeRecipient);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.executeFeeTo(); // called by address(this), not admin
    }

    function test_executeFeeTo_revert_premature() public {
        address feeRecipient = makeAddr("feeRecipient");

        vm.prank(admin);
        factory.proposeFeeTo(feeRecipient);

        // Only advance 1 hour — timelock requires 24 hours
        vm.warp(block.timestamp + 1 hours);

        vm.prank(admin);
        vm.expectRevert("ChFactory: TIMELOCK_NOT_EXPIRED");
        factory.executeFeeTo();
    }

    function test_executeFeeTo_revert_noPending() public {
        vm.prank(admin);
        vm.expectRevert("ChFactory: NO_PENDING_CHANGE");
        factory.executeFeeTo();
    }

    function test_cancelPendingFeeTo() public {
        address feeRecipient = makeAddr("feeRecipient");

        vm.prank(admin);
        factory.proposeFeeTo(feeRecipient);

        // Cancel before timelock expires
        vm.prank(admin);
        factory.cancelPendingFeeTo();

        // Even after timelock period, execution should fail (no pending change)
        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(admin);
        vm.expectRevert("ChFactory: NO_PENDING_CHANGE");
        factory.executeFeeTo();

        // feeTo should remain unchanged
        assertEq(factory.feeTo(), address(0));
    }

    function test_cancelPendingFeeTo_revert_notSetter() public {
        vm.prank(admin);
        factory.proposeFeeTo(makeAddr("feeRecipient"));

        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.cancelPendingFeeTo();
    }

    // ============ TIMELOCK GOVERNANCE: proposeFeeToSetter / executeFeeToSetter ============

    function test_proposeFeeToSetter_and_execute() public {
        address newSetter = makeAddr("newSetter");

        vm.prank(admin);
        factory.proposeFeeToSetter(newSetter);

        // feeToSetter unchanged yet
        assertEq(factory.feeToSetter(), admin);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(admin);
        factory.executeFeeToSetter();

        assertEq(factory.feeToSetter(), newSetter);

        // Old setter can no longer propose
        vm.prank(admin);
        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.proposeFeeTo(makeAddr("someone"));
    }

    function test_proposeFeeToSetter_revert_notSetter() public {
        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.proposeFeeToSetter(makeAddr("newSetter"));
    }

    function test_executeFeeToSetter_revert_premature() public {
        vm.prank(admin);
        factory.proposeFeeToSetter(makeAddr("newSetter"));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(admin);
        vm.expectRevert("ChFactory: TIMELOCK_NOT_EXPIRED");
        factory.executeFeeToSetter();
    }

    function test_cancelPendingFeeToSetter() public {
        address newSetter = makeAddr("newSetter");

        vm.prank(admin);
        factory.proposeFeeToSetter(newSetter);

        vm.prank(admin);
        factory.cancelPendingFeeToSetter();

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(admin);
        vm.expectRevert("ChFactory: NO_PENDING_CHANGE");
        factory.executeFeeToSetter();

        assertEq(factory.feeToSetter(), admin);
    }

    function test_cancelPendingFeeToSetter_revert_notSetter() public {
        vm.prank(admin);
        factory.proposeFeeToSetter(makeAddr("newSetter"));

        vm.expectRevert("ChFactory: FORBIDDEN");
        factory.cancelPendingFeeToSetter();
    }

    // ============ TIMELOCK DELAY GETTER ============

    function test_timelockDelay() public view {
        assertEq(factory.timelockDelay(), 24 hours);
    }
}
