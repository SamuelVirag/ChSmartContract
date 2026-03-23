// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChPair} from "../src/ChPair.sol";
import {IChCallee} from "../src/interfaces/IChCallee.sol";
import {IChPair} from "../src/interfaces/IChPair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Cross-Contract Interaction Tests
/// @notice Tests that our read-only reentrancy defense (nonReentrantView, isLocked) works
///         end-to-end with consuming contracts (lending protocols, oracles).
contract CrossContractTest is Test {
    ChFactory factory;
    ChPair pair;
    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice");

    function setUp() public {
        factory = new ChFactory(address(this));
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = ChPair(pairAddr);

        // Add liquidity
        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);
        vm.startPrank(alice);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(alice);
        vm.stopPrank();
    }

    // ============ isLocked() TESTS ============

    /// @notice isLocked() returns false when no operation is in progress
    function test_isLocked_falseOutsideOperation() public view {
        assertFalse(pair.isLocked());
    }

    /// @notice isLocked() returns true during a flash swap callback
    function test_isLocked_trueDuringFlashSwap() public {
        LockChecker checker = new LockChecker(pair, token0);
        token0.mint(address(checker), 10 ether);

        checker.flashAndCheckLock(1 ether);

        assertTrue(checker.wasLockedDuringCallback());
    }

    // ============ nonReentrantView on getReserves() ============

    /// @notice getReserves() works normally outside of nonReentrant context
    function test_getReserves_worksNormally() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, 100 ether);
        assertEq(r1, 100 ether);
    }

    /// @notice getReserves() reverts during flash swap callback (read-only reentrancy defense)
    function test_getReserves_revertsDuringFlashSwap() public {
        ReserveReader reader = new ReserveReader(pair, token0);
        token0.mint(address(reader), 10 ether);

        reader.flashAndReadReserves(1 ether);

        // The reader caught the revert
        assertTrue(reader.getReservesReverted());
    }

    /// @notice getSwapFee() reverts during flash swap (has nonReentrantView)
    function test_getSwapFee_revertsDuringFlashSwap() public {
        FeeReader reader = new FeeReader(pair, token0);
        token0.mint(address(reader), 10 ether);

        reader.flashAndReadFee(1 ether);

        // Fee read should have reverted (nonReentrantView blocks it during flash)
        assertTrue(reader.getSwapFeeReverted());
    }

    // ============ MOCK LENDING PROTOCOL ============

    /// @notice A mock lending protocol that uses getReserves() for pricing
    ///         cannot be exploited via flash swap read-only reentrancy
    function test_lendingProtocol_protectedFromFlashManipulation() public {
        MockLendingProtocol lender = new MockLendingProtocol(pair);

        // Normal price check works
        uint256 price = lender.getPrice();
        assertGt(price, 0);

        // During a flash swap, the lending protocol's getPrice() reverts
        // because it calls pair.getReserves() which has nonReentrantView
        LendingExploiter exploiter = new LendingExploiter(pair, lender, token0, token1);
        token0.mint(address(exploiter), 10 ether);

        exploiter.attemptExploit(1 ether);

        // The exploit was blocked — lending protocol price read reverted during flash
        assertTrue(exploiter.exploitBlocked());
    }

    // ============ isLocked() CHECK PATTERN ============

    /// @notice A safe consuming contract checks isLocked() before reading state
    function test_safeConsumer_checksIsLocked() public {
        SafePriceConsumer consumer = new SafePriceConsumer(pair);

        // Normal read works
        (bool safe, uint256 price) = consumer.getSafePrice();
        assertTrue(safe);
        assertGt(price, 0);

        // During flash swap, consumer detects the lock and returns safe=false
        SafeConsumerFlashTest flashTest = new SafeConsumerFlashTest(pair, consumer, token0);
        token0.mint(address(flashTest), 10 ether);

        flashTest.flashAndCheckSafePrice(1 ether);

        // Consumer correctly detected the lock and refused to return a price
        assertFalse(flashTest.priceWasSafeDuringFlash());
    }
}

// ============ HELPER CONTRACTS ============

/// @dev Checks isLocked() during flash swap callback
contract LockChecker is IChCallee {
    ChPair pair;
    MockERC20 repayToken;
    bool public wasLockedDuringCallback;

    constructor(ChPair _pair, MockERC20 _token) {
        pair = _pair;
        repayToken = _token;
    }

    function flashAndCheckLock(uint256 amount) external {
        pair.swap(0, amount, address(this), "check");
    }

    function chSwapCall(address, uint256, uint256 amount1, bytes calldata) external {
        wasLockedDuringCallback = pair.isLocked();
        // Repay with generous amount
        uint256 repay = (amount1 * 10200) / 9900;
        repayToken.transfer(address(pair), repay);
    }
}

/// @dev Attempts to read getReserves() during flash swap
contract ReserveReader is IChCallee {
    ChPair pair;
    MockERC20 repayToken;
    bool public getReservesReverted;

    constructor(ChPair _pair, MockERC20 _token) {
        pair = _pair;
        repayToken = _token;
    }

    function flashAndReadReserves(uint256 amount) external {
        pair.swap(0, amount, address(this), "read");
    }

    function chSwapCall(address, uint256, uint256 amount1, bytes calldata) external {
        // Try to read reserves — should revert due to nonReentrantView
        try pair.getReserves() {
            getReservesReverted = false;
        } catch {
            getReservesReverted = true;
        }

        // Repay
        uint256 repay = (amount1 * 10200) / 9900;
        repayToken.transfer(address(pair), repay);
    }
}

/// @dev Attempts to read getSwapFee() during flash swap
contract FeeReader is IChCallee {
    ChPair pair;
    MockERC20 repayToken;
    bool public getSwapFeeReverted;

    constructor(ChPair _pair, MockERC20 _token) {
        pair = _pair;
        repayToken = _token;
    }

    function flashAndReadFee(uint256 amount) external {
        pair.swap(0, amount, address(this), "fee");
    }

    function chSwapCall(address, uint256, uint256 amount1, bytes calldata) external {
        // Try to read swap fee — should revert due to nonReentrantView
        try pair.getSwapFee() {
            getSwapFeeReverted = false;
        } catch {
            getSwapFeeReverted = true;
        }

        uint256 repay = (amount1 * 10200) / 9900;
        repayToken.transfer(address(pair), repay);
    }
}

/// @dev Mock lending protocol that prices assets using pair reserves
contract MockLendingProtocol {
    IChPair pair;

    constructor(IChPair _pair) {
        pair = _pair;
    }

    function getPrice() public view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0) return 0;
        return (uint256(r1) * 1e18) / uint256(r0);
    }
}

/// @dev Attempts to exploit the lending protocol during a flash swap
contract LendingExploiter is IChCallee {
    ChPair pair;
    MockLendingProtocol lender;
    MockERC20 token0;
    MockERC20 token1;
    bool public exploitBlocked;

    constructor(ChPair _pair, MockLendingProtocol _lender, MockERC20 _t0, MockERC20 _t1) {
        pair = _pair;
        lender = _lender;
        token0 = _t0;
        token1 = _t1;
    }

    function attemptExploit(uint256 borrowAmount) external {
        pair.swap(0, borrowAmount, address(this), "exploit");
    }

    function chSwapCall(address, uint256, uint256 amount1, bytes calldata) external {
        // During flash: try to use the lending protocol's getPrice()
        // This should fail because getPrice() calls pair.getReserves()
        // which has nonReentrantView
        try lender.getPrice() {
            exploitBlocked = false; // BAD: lending protocol returned stale price
        } catch {
            exploitBlocked = true; // GOOD: read-only reentrancy blocked
        }

        // Repay flash swap
        uint256 repay = (amount1 * 10200) / 9900;
        token0.transfer(address(pair), repay);
    }
}

/// @dev Safe price consumer that checks isLocked() before reading
contract SafePriceConsumer {
    IChPair pair;

    constructor(IChPair _pair) {
        pair = _pair;
    }

    function getSafePrice() external view returns (bool safe, uint256 price) {
        if (pair.isLocked()) {
            return (false, 0);
        }
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0) return (true, 0);
        return (true, (uint256(r1) * 1e18) / uint256(r0));
    }
}

/// @dev Tests SafePriceConsumer during flash swap
contract SafeConsumerFlashTest is IChCallee {
    ChPair pair;
    SafePriceConsumer consumer;
    MockERC20 repayToken;
    bool public priceWasSafeDuringFlash;

    constructor(ChPair _pair, SafePriceConsumer _consumer, MockERC20 _token) {
        pair = _pair;
        consumer = _consumer;
        repayToken = _token;
    }

    function flashAndCheckSafePrice(uint256 amount) external {
        pair.swap(0, amount, address(this), "safe");
    }

    function chSwapCall(address, uint256, uint256 amount1, bytes calldata) external {
        (bool safe,) = consumer.getSafePrice();
        priceWasSafeDuringFlash = safe;

        uint256 repay = (amount1 * 10200) / 9900;
        repayToken.transfer(address(pair), repay);
    }
}
