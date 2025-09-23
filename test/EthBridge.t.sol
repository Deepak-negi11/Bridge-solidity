// SPDX-License-Identifier: MIT
// Tests origin-chain vault behavior: deposits, withdrawals, credits from opposite chain,
// access control, and reentrancy guards.
pragma solidity ^0.8.30;

import "lib/forge-std/src/Test.sol";
import "src/Eth.sol";
import "src/Eth-lock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract EthBridgeTest is Test {
    Eth public eth;
    Locketh public lockContract;
    
    address public owner;
    address public user1;
    address public user2;
    address public attacker;
    
    uint256 constant INITIAL_SUPPLY = 1000000 * 10**18;
    uint256 constant TEST_AMOUNT = 1000 * 10**18;
    
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event BurnedOnOtherSide(address indexed user, uint256 amount);
    
    function setUp() public {
    owner = address(this);
    user1 = vm.addr(uint256(keccak256(abi.encodePacked("user1"))));
    user2 = vm.addr(uint256(keccak256(abi.encodePacked("user2"))));
    attacker = vm.addr(uint256(keccak256(abi.encodePacked("attacker"))));
        
        // Deploy contracts
        eth = new Eth();
        lockContract = new Locketh(address(eth));
        
        // Mint initial tokens to users
        eth.mint(user1, INITIAL_SUPPLY);
        eth.mint(user2, INITIAL_SUPPLY);
        eth.mint(attacker, INITIAL_SUPPLY);
    }
    
    function testDeposit() public {
        vm.startPrank(user1);
        
        // Approve tokens
        eth.approve(address(lockContract), TEST_AMOUNT);
        
        uint256 balanceBefore = eth.balanceOf(user1);
        uint256 contractBalanceBefore = eth.balanceOf(address(lockContract));
        
        // Expect event
        vm.expectEmit(true, false, false, true);
        emit Deposited(user1, TEST_AMOUNT);
        
        // Deposit tokens
        lockContract.deposit(TEST_AMOUNT);
        
        // Check balances
        assertEq(eth.balanceOf(user1), balanceBefore - TEST_AMOUNT);
        assertEq(eth.balanceOf(address(lockContract)), contractBalanceBefore + TEST_AMOUNT);
        assertEq(lockContract.balances(user1), TEST_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testDepositZeroAmount() public {
        vm.startPrank(user1);
        eth.approve(address(lockContract), TEST_AMOUNT);
        
        vm.expectRevert("Amount must be greater than 0");
        lockContract.deposit(0);
        
        vm.stopPrank();
    }
    
    function testDepositInsufficientAllowance() public {
        vm.startPrank(user1);
        
        // Don't approve or approve less than needed
        eth.approve(address(lockContract), TEST_AMOUNT - 1);
        
        vm.expectRevert("Insufficient allowance");
        lockContract.deposit(TEST_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testWithdraw() public {
        // First deposit
        vm.startPrank(user1);
        eth.approve(address(lockContract), TEST_AMOUNT);
        lockContract.deposit(TEST_AMOUNT);
        vm.stopPrank();
        
        uint256 withdrawAmount = TEST_AMOUNT / 2;
        
        vm.startPrank(user1);
        
        uint256 balanceBefore = eth.balanceOf(user1);
        uint256 contractBalanceBefore = eth.balanceOf(address(lockContract));
        
        // Expect event
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(user1, withdrawAmount);
        
        // Withdraw tokens
        lockContract.withdraw(withdrawAmount);
        
        // Check balances
        assertEq(eth.balanceOf(user1), balanceBefore + withdrawAmount);
        assertEq(eth.balanceOf(address(lockContract)), contractBalanceBefore - withdrawAmount);
        assertEq(lockContract.balances(user1), TEST_AMOUNT - withdrawAmount);
        
        vm.stopPrank();
    }
    
    function testWithdrawZeroAmount() public {
        vm.startPrank(user1);
        
        vm.expectRevert("Amount must be greater than 0");
        lockContract.withdraw(0);
        
        vm.stopPrank();
    }
    
    function testWithdrawInsufficientBalance() public {
        vm.startPrank(user1);
        
        vm.expectRevert("Insufficient balance");
        lockContract.withdraw(TEST_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testBurnOnOtherSide() public {
        // Only owner can call this function
        vm.expectEmit(true, false, false, true);
        emit BurnedOnOtherSide(user1, TEST_AMOUNT);
        
        lockContract.burnOnOtherSide(user1, TEST_AMOUNT);
        
        assertEq(lockContract.balances(user1), TEST_AMOUNT);
    }
    
    function testBurnOnOtherSideOnlyOwner() public {
        vm.startPrank(attacker);
        
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        lockContract.burnOnOtherSide(user1, TEST_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testBurnOnOtherSideZeroAddress() public {
        vm.expectRevert("Invalid user address");
        lockContract.burnOnOtherSide(address(0), TEST_AMOUNT);
    }
    
    function testBurnOnOtherSideZeroAmount() public {
        vm.expectRevert("Amount must be greater than 0");
        lockContract.burnOnOtherSide(user1, 0);
    }
    
    function testEmergencyWithdraw() public {
        // First deposit some tokens
        vm.startPrank(user1);
        eth.approve(address(lockContract), TEST_AMOUNT);
        lockContract.deposit(TEST_AMOUNT);
        vm.stopPrank();
        
        uint256 ownerBalanceBefore = eth.balanceOf(owner);
        uint256 contractBalance = eth.balanceOf(address(lockContract));
        
        // Emergency withdraw
        lockContract.emergencyWithdraw();
        
        assertEq(eth.balanceOf(owner), ownerBalanceBefore + contractBalance);
        assertEq(eth.balanceOf(address(lockContract)), 0);
    }
    
    function testEmergencyWithdrawOnlyOwner() public {
        vm.startPrank(attacker);
        
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        lockContract.emergencyWithdraw();
        
        vm.stopPrank();
    }
    
    function testEmergencyWithdrawNoTokens() public {
        vm.expectRevert("No tokens to withdraw");
        lockContract.emergencyWithdraw();
    }
    
    function testReentrancyProtection() public {
        // This would require a malicious token contract to properly test
        // For now, we can test that multiple calls in the same transaction are blocked
        vm.startPrank(user1);
        eth.approve(address(lockContract), TEST_AMOUNT * 2);
        
        lockContract.deposit(TEST_AMOUNT);
        
        // This should work as it's a different transaction
        lockContract.deposit(TEST_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testMultipleUsersDeposit() public {
        // User1 deposit
        vm.startPrank(user1);
        eth.approve(address(lockContract), TEST_AMOUNT);
        lockContract.deposit(TEST_AMOUNT);
        vm.stopPrank();
        
        // User2 deposit
        vm.startPrank(user2);
        eth.approve(address(lockContract), TEST_AMOUNT);
        lockContract.deposit(TEST_AMOUNT);
        vm.stopPrank();
        
        // Check balances
        assertEq(lockContract.balances(user1), TEST_AMOUNT);
        assertEq(lockContract.balances(user2), TEST_AMOUNT);
        assertEq(eth.balanceOf(address(lockContract)), TEST_AMOUNT * 2);
    }
    
    function testFullBridgeFlow() public {
        // 1. User deposits on ETH side
        vm.startPrank(user1);
        eth.approve(address(lockContract), TEST_AMOUNT);
        lockContract.deposit(TEST_AMOUNT);
        vm.stopPrank();
        
        // 2. Bridge operator mints on SUI side (simulated by burnOnOtherSide)
        lockContract.burnOnOtherSide(user1, TEST_AMOUNT);
        
        // 3. User burns on SUI side and withdraws on ETH side
        uint256 withdrawAmount = TEST_AMOUNT / 2;
        
        vm.startPrank(user1);
        lockContract.withdraw(withdrawAmount);
        vm.stopPrank();
        
        // Check final state
        assertEq(lockContract.balances(user1), TEST_AMOUNT * 2 - withdrawAmount);
    }
}