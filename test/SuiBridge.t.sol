// SPDX-License-Identifier: MIT
// Tests wrapped-token side: burn to go back to origin, withdraw (mint) on arrival,
// pending balances, access control, and safety checks.

// forge-std "Test" gives us the Foundry cheatcodes (vm, expectRevert, startPrank, etc.).
// We use these to simulate users and assert on reverts/events.
pragma solidity ^0.8.30;

import "lib/forge-std/src/Test.sol"; // Foundry testing utilities and cheatcodes
import "src/Sui.sol";                 // Wrapped token contract (destination chain)
import "src/Sui-lock.sol";            // Destination bridge contract managing mint/burn
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol"; // ERC20 interface
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";    // Access control

contract SuiBridgeTest is Test {
    // The wrapped token instance used in tests (destination chain representation)
    Sui public sui;
    // The destination bridge contract that owns the wrapped token and manages mint/burn
    LockSui public lockContract;
    
    // Test actors: contract deployer (owner), two users, and an attacker
    address public owner;
    address public user1;
    address public user2;
    address public attacker;
    
    // Constants for initial seeding and per-test amounts (18 decimals typical for ERC20)
    uint256 constant INITIAL_SUPPLY = 1000000 * 10**18; // 1,000,000 tokens
    uint256 constant TEST_AMOUNT = 1000 * 10**18;       // 1,000 tokens
    
    // Local copies of bridge events for vm.expectEmit matching
    event Burned(address indexed burner, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event BurnedOnOppositeChain(address indexed user, uint256 amount);
    
    function setUp() public {
        // The test contract itself is treated as the owner/deployer
        owner = address(this);
        // Deterministic EOA addresses for test users and attacker via vm.addr
        user1 = vm.addr(uint256(keccak256(abi.encodePacked("user1"))));
        user2 = vm.addr(uint256(keccak256(abi.encodePacked("user2"))));
        attacker = vm.addr(uint256(keccak256(abi.encodePacked("attacker"))));
        
        // Deploy wrapped token and the destination bridge contract
        sui = new Sui();
        lockContract = new LockSui(address(sui));
        
        // The bridge must own the wrapped token to control mint/burn
        sui.transferOwnership(address(lockContract));
        
        // Seed balances for users via the bridge: prank as the bridge (owner of SUI)
        vm.startPrank(address(lockContract));
        sui.mint(user1, INITIAL_SUPPLY); // give user1 1M SUI for test scenarios
        sui.mint(user2, INITIAL_SUPPLY); // give user2 1M SUI
        sui.mint(attacker, INITIAL_SUPPLY); // attacker also gets tokens to test ACL
        vm.stopPrank();
    }
    
    function testBurn() public {
        // Simulate all subsequent txs coming from user1
        vm.startPrank(user1);
        
        // Snapshot starting SUI balance for later comparison
        uint256 balanceBefore = sui.balanceOf(user1);
        
        // Expect a Burned event when burning wrapped tokens
        vm.expectEmit(true, false, false, true);
        emit Burned(user1, TEST_AMOUNT);
        
        // User burns wrapped SUI to move value back to the origin chain
        lockContract.burn(TEST_AMOUNT);
        
        // After burning, user1 balance should decrease exactly by TEST_AMOUNT
        assertEq(sui.balanceOf(user1), balanceBefore - TEST_AMOUNT);
        
        // Stop the prank (sender reverts to this test contract)
        vm.stopPrank();
    }
    
    function testBurnZeroAmount() public {
        vm.startPrank(user1);
        
        // Burning zero is invalid; contract should revert with a clear error message
        vm.expectRevert("Amount must be greater than 0");
        lockContract.burn(0);
        
        vm.stopPrank();
    }
    
    function testBurnInsufficientBalance() public {
        vm.startPrank(user1);
        
        // Attempt to burn more than balance; should revert with Insufficient balance
        vm.expectRevert("Insufficient balance");
        lockContract.burn(INITIAL_SUPPLY + 1);
        
        vm.stopPrank();
    }
    
    function testWithdraw() public {
        // Operator credits user1 after verifying an origin-chain deposit
        lockContract.burnedOnOppositeChain(user1, TEST_AMOUNT);
        
        // Now user1 can withdraw (mint) from pending on the destination chain
        vm.startPrank(user1);
        
        uint256 balanceBefore = sui.balanceOf(user1);            // current wrapped token balance
        uint256 pendingBefore = lockContract.pendingBalances(user1); // should be TEST_AMOUNT
        
        // Expect Withdrawn event for the exact amount
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(user1, TEST_AMOUNT);
        
        // Withdraw from pending; this mints wrapped tokens to user1
        lockContract.withdraw(TEST_AMOUNT);
        
        // After withdraw, user balance increased by amount and pending reduced accordingly
        assertEq(sui.balanceOf(user1), balanceBefore + TEST_AMOUNT);
        assertEq(lockContract.pendingBalances(user1), pendingBefore - TEST_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testWithdrawZeroAmount() public {
        vm.startPrank(user1);
        
        // Withdrawing zero is invalid; should revert
        vm.expectRevert("Amount must be greater than 0");
        lockContract.withdraw(0);
        
        vm.stopPrank();
    }
    
    function testWithdrawInsufficientPendingBalance() public {
        vm.startPrank(user1);
        
        // Without prior credit from the operator, pending is zero; should revert
        vm.expectRevert("Insufficient pending balance");
        lockContract.withdraw(TEST_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testBurnedOnOppositeChain() public {
        // Only the owner/operator can credit pending balances
        vm.expectEmit(true, false, false, true);
        emit BurnedOnOppositeChain(user1, TEST_AMOUNT);
        
        // Credit user1, representing a verified origin-chain deposit
        lockContract.burnedOnOppositeChain(user1, TEST_AMOUNT);
        
        // Pending should reflect the credited amount
        assertEq(lockContract.pendingBalances(user1), TEST_AMOUNT);
    }
    
    function testBurnedOnOppositeChainOnlyOwner() public {
        vm.startPrank(attacker);
        
        // Attacker should not be able to credit pending balances
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        lockContract.burnedOnOppositeChain(user1, TEST_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testBurnedOnOppositeChainZeroAddress() public {
        // Credit to zero address must revert to avoid minting to 0x0 later
        vm.expectRevert("Invalid user address");
        lockContract.burnedOnOppositeChain(address(0), TEST_AMOUNT);
    }
    
    function testBurnedOnOppositeChainZeroAmount() public {
        // Zero credit makes no sense; revert with clear error
        vm.expectRevert("Amount must be greater than 0");
        lockContract.burnedOnOppositeChain(user1, 0);
    }
    
    function testEmergencyWithdrawPending() public {
        // Operator credits a pending balance first
        lockContract.burnedOnOppositeChain(user1, TEST_AMOUNT);
        
        uint256 balanceBefore = sui.balanceOf(user1);
        uint256 pendingBefore = lockContract.pendingBalances(user1);
        
        // Owner can force-mint any pending to the user in emergencies (clears pending)
        lockContract.emergencyWithdrawPending(user1);
        
        assertEq(sui.balanceOf(user1), balanceBefore + pendingBefore);
        assertEq(lockContract.pendingBalances(user1), 0);
    }
    
    function testEmergencyWithdrawPendingOnlyOwner() public {
        vm.startPrank(attacker);
        
        // Attacker cannot invoke emergency minting
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        lockContract.emergencyWithdrawPending(user1);
        
        vm.stopPrank();
    }
    
    function testEmergencyWithdrawPendingZeroAddress() public {
        // Zero address checks prevent accidental minting to 0x0
        vm.expectRevert("Invalid user address");
        lockContract.emergencyWithdrawPending(address(0));
    }
    
    function testEmergencyWithdrawPendingNoPendingBalance() public {
        // Without any credit, there is nothing to mint; should revert
        vm.expectRevert("No pending balance");
        lockContract.emergencyWithdrawPending(user1);
    }
    
    function testReentrancyProtection() public {
        // Credit sufficient pending balance for two withdrawals
        lockContract.burnedOnOppositeChain(user1, TEST_AMOUNT * 2);
        
        vm.startPrank(user1);
        
        // Two withdrawals, each in its own transaction context; should both succeed
        lockContract.withdraw(TEST_AMOUNT);
        lockContract.withdraw(TEST_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testMultipleUsersBurn() public {
        // user1 burns
        vm.startPrank(user1);
        lockContract.burn(TEST_AMOUNT);
        vm.stopPrank();
        
        // user2 burns
        vm.startPrank(user2);
        lockContract.burn(TEST_AMOUNT);
        vm.stopPrank();
        
        // Each user's balance should be reduced independently
        assertEq(sui.balanceOf(user1), INITIAL_SUPPLY - TEST_AMOUNT);
        assertEq(sui.balanceOf(user2), INITIAL_SUPPLY - TEST_AMOUNT);
    }
    
    function testFullBridgeFlow() public {
        // 1) User burns wrapped SUI to go back to origin
        vm.startPrank(user1);
        uint256 balanceBefore = sui.balanceOf(user1);
        lockContract.burn(TEST_AMOUNT);
        assertEq(sui.balanceOf(user1), balanceBefore - TEST_AMOUNT);
        vm.stopPrank();
        
        // 2) Operator credits user1 pending (representing an origin-side deposit)
        lockContract.burnedOnOppositeChain(user1, TEST_AMOUNT / 2);
        
        // 3) User withdraws (mints) the pending amount
        vm.startPrank(user1);
        uint256 withdrawAmount = TEST_AMOUNT / 2;
        lockContract.withdraw(withdrawAmount);
        vm.stopPrank();
        
        // Final: user balance equals initial minus burned plus withdrawn; no pending left
        assertEq(sui.balanceOf(user1), balanceBefore - TEST_AMOUNT + withdrawAmount);
        assertEq(lockContract.pendingBalances(user1), 0);
    }
    
    function testTokenContractSeparately() public {
        // Deploy a fresh wrapped token to test ACL separately
        Sui testSui = new Sui();
        
        // Only owner can mint; attacker calls must revert with Ownable error
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        testSui.mint(attacker, TEST_AMOUNT);
        vm.stopPrank();
        
        // Only owner can burn; attacker calls must revert
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        testSui.burn(attacker, TEST_AMOUNT);
        vm.stopPrank();
        
        // The owner (this contract) can mint
        testSui.mint(user1, TEST_AMOUNT);
        assertEq(testSui.balanceOf(user1), TEST_AMOUNT);
        
        // And the owner can burn from user1 (simulating a bridge-controlled burn)
        testSui.burn(user1, TEST_AMOUNT / 2);
        assertEq(testSui.balanceOf(user1), TEST_AMOUNT / 2);
    }
}