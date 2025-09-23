// SPDX-License-Identifier: MIT
// End-to-end tests covering ETH→SUI (lock→mint) and SUI→ETH (burn→unlock),
// partial bridging, round-trip, and multi-user interleaving.
pragma solidity ^0.8.30;

import "lib/forge-std/src/Test.sol";
import "src/Eth.sol";
import "src/Eth-lock.sol";
import "src/Sui.sol";
import "src/Sui-lock.sol";

contract BridgeIntegrationTest is Test {
    Eth public eth;
    Locketh public ethLock;
    Sui public sui;
    LockSui public suiLock;
    
    address public bridgeOperator;
    address public user1;
    address public user2;
    
    uint256 constant INITIAL_SUPPLY = 1000000 * 10**18;
    uint256 constant BRIDGE_AMOUNT = 1000 * 10**18;
    
    function setUp() public {
    bridgeOperator = address(this);
    user1 = vm.addr(uint256(keccak256(abi.encodePacked("user1"))));
    user2 = vm.addr(uint256(keccak256(abi.encodePacked("user2"))));
        
    // Deploy all contracts
        eth = new Eth();
        ethLock = new Locketh(address(eth));
        sui = new Sui();
        suiLock = new LockSui(address(sui));
        
        // Mint initial ETH tokens to users
        eth.mint(user1, INITIAL_SUPPLY);
        eth.mint(user2, INITIAL_SUPPLY);
        
    // Mint initial SUI tokens while test contract is still the owner
    sui.mint(user1, INITIAL_SUPPLY);
    sui.mint(user2, INITIAL_SUPPLY);

    // Transfer ownership of SUI token to the Sui lock contract for later operations
    sui.transferOwnership(address(suiLock));
    }
    
    function testETHToSUIBridge() public {
        // Step 1: User deposits ETH tokens on ETH side
        vm.startPrank(user1);
        eth.approve(address(ethLock), BRIDGE_AMOUNT);
        ethLock.deposit(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify ETH side state
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY - BRIDGE_AMOUNT);
        assertEq(eth.balanceOf(address(ethLock)), BRIDGE_AMOUNT);
        assertEq(ethLock.balances(user1), BRIDGE_AMOUNT);
        
        // Step 2: Bridge operator mints equivalent SUI tokens
        suiLock.burnedOnOppositeChain(user1, BRIDGE_AMOUNT);
        
        // Step 3: User withdraws SUI tokens on SUI side
        vm.startPrank(user1);
        uint256 suiBalanceBefore = sui.balanceOf(user1);
        suiLock.withdraw(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify SUI side state
        assertEq(sui.balanceOf(user1), suiBalanceBefore + BRIDGE_AMOUNT);
        assertEq(suiLock.pendingBalances(user1), 0);
        
        // Verify user now has tokens on SUI side but locked on ETH side
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY - BRIDGE_AMOUNT);
        assertEq(sui.balanceOf(user1), INITIAL_SUPPLY + BRIDGE_AMOUNT);
    }
    
    function testSUIToETHBridge() public {
        // Ensure user has enough SUI to burn (in case ownership state changed)
        if (sui.balanceOf(user1) < BRIDGE_AMOUNT) {
            // Credit pending on SUI side and let user withdraw
            suiLock.burnedOnOppositeChain(user1, BRIDGE_AMOUNT);
            vm.startPrank(user1);
            suiLock.withdraw(BRIDGE_AMOUNT);
            vm.stopPrank();
        }

        // Seed ETH vault with liquidity from another user to simulate prior ETH->SUI deposits
        vm.startPrank(user2);
        eth.approve(address(ethLock), BRIDGE_AMOUNT);
        ethLock.deposit(BRIDGE_AMOUNT);
        vm.stopPrank();

        // Step 1: User burns SUI tokens on SUI side
        vm.startPrank(user1);
        uint256 suiBalanceBefore = sui.balanceOf(user1);
        suiLock.burn(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify SUI side state
        assertEq(sui.balanceOf(user1), suiBalanceBefore - BRIDGE_AMOUNT);
        
        // Step 2: Bridge operator unlocks ETH tokens
        ethLock.burnOnOtherSide(user1, BRIDGE_AMOUNT);
        
        // Step 3: User withdraws ETH tokens on ETH side
        vm.startPrank(user1);
        uint256 ethBalanceBefore = eth.balanceOf(user1);
        ethLock.withdraw(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify ETH side state
        assertEq(eth.balanceOf(user1), ethBalanceBefore + BRIDGE_AMOUNT);
        assertEq(ethLock.balances(user1), 0);
        
        // Verify user now has fewer SUI tokens but more ETH tokens
        assertEq(sui.balanceOf(user1), INITIAL_SUPPLY - BRIDGE_AMOUNT);
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY + BRIDGE_AMOUNT);
    }
    
    function testRoundTripBridge() public {
        uint256 initialETH = eth.balanceOf(user1);
        uint256 initialSUI = sui.balanceOf(user1);
        
        // ETH to SUI
        vm.startPrank(user1);
        eth.approve(address(ethLock), BRIDGE_AMOUNT);
        ethLock.deposit(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        suiLock.burnedOnOppositeChain(user1, BRIDGE_AMOUNT);
        
        vm.startPrank(user1);
        suiLock.withdraw(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify intermediate state
        assertEq(eth.balanceOf(user1), initialETH - BRIDGE_AMOUNT);
        assertEq(sui.balanceOf(user1), initialSUI + BRIDGE_AMOUNT);
        
        // SUI back to ETH
        vm.startPrank(user1);
        suiLock.burn(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        ethLock.burnOnOtherSide(user1, BRIDGE_AMOUNT);
        
        vm.startPrank(user1);
        ethLock.withdraw(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify final state (should be back to initial)
        assertEq(eth.balanceOf(user1), initialETH);
        assertEq(sui.balanceOf(user1), initialSUI);
    }
    
    function testMultipleUsersBridging() public {
        // User1 bridges ETH to SUI
        vm.startPrank(user1);
        eth.approve(address(ethLock), BRIDGE_AMOUNT);
        ethLock.deposit(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // User2 bridges SUI to ETH
        vm.startPrank(user2);
        suiLock.burn(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Bridge operator processes both
        suiLock.burnedOnOppositeChain(user1, BRIDGE_AMOUNT);
        ethLock.burnOnOtherSide(user2, BRIDGE_AMOUNT);
        
        // Users complete their bridges
        vm.startPrank(user1);
        suiLock.withdraw(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        vm.startPrank(user2);
        ethLock.withdraw(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify final states
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY - BRIDGE_AMOUNT);
        assertEq(sui.balanceOf(user1), INITIAL_SUPPLY + BRIDGE_AMOUNT);
        assertEq(eth.balanceOf(user2), INITIAL_SUPPLY + BRIDGE_AMOUNT);
        assertEq(sui.balanceOf(user2), INITIAL_SUPPLY - BRIDGE_AMOUNT);
        
    // Verify contract states: liquidity used to pay user2, so balance is 0 now
    assertEq(eth.balanceOf(address(ethLock)), 0);
        assertEq(ethLock.balances(user1), BRIDGE_AMOUNT);
        assertEq(ethLock.balances(user2), 0);
        assertEq(suiLock.pendingBalances(user1), 0);
        assertEq(suiLock.pendingBalances(user2), 0);
    }
    
    function testPartialBridging() public {
        uint256 fullAmount = BRIDGE_AMOUNT;
        uint256 partialAmount = BRIDGE_AMOUNT / 3;
        
        // User deposits full amount on ETH side
        vm.startPrank(user1);
        eth.approve(address(ethLock), fullAmount);
        ethLock.deposit(fullAmount);
        vm.stopPrank();
        
        // Bridge operator mints partial amount on SUI side
        suiLock.burnedOnOppositeChain(user1, partialAmount);
        
        // User withdraws partial amount on SUI side
        vm.startPrank(user1);
        suiLock.withdraw(partialAmount);
        vm.stopPrank();
        
        // User burns partial amount on SUI side
        vm.startPrank(user1);
        suiLock.burn(partialAmount);
        vm.stopPrank();
        
        // Bridge operator unlocks partial amount on ETH side
        ethLock.burnOnOtherSide(user1, partialAmount);
        
        // User withdraws partial amount on ETH side
        vm.startPrank(user1);
        ethLock.withdraw(partialAmount);
        vm.stopPrank();
        
        // Verify final state
        uint256 remainingLocked = fullAmount - partialAmount;
        assertEq(ethLock.balances(user1), remainingLocked + partialAmount); // Still has the original lock plus the new credit
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY - fullAmount + partialAmount); // Got back the partial amount
        assertEq(sui.balanceOf(user1), INITIAL_SUPPLY); // Back to original SUI balance
    }
    
    function testBridgeOperatorSecurity() public {
    address maliciousActor = vm.addr(uint256(keccak256(abi.encodePacked("malicious"))));
        
        // Malicious actor tries to mint SUI tokens without proper ETH deposit
        vm.startPrank(maliciousActor);
        vm.expectRevert();
        suiLock.burnedOnOppositeChain(maliciousActor, BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Malicious actor tries to unlock ETH tokens without proper SUI burn
        vm.startPrank(maliciousActor);
        vm.expectRevert();
        ethLock.burnOnOtherSide(maliciousActor, BRIDGE_AMOUNT);
        vm.stopPrank();
    }
}