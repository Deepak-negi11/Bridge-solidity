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
    // Origin chain contracts (ETH side)
    Eth public eth;              // Canonical ERC20 token that users originally hold
    Locketh public ethLock;      // Vault that locks ETH tokens during ETH→SUI bridge
    
    // Destination chain contracts (SUI side) 
    Sui public sui;              // Wrapped token representing locked ETH on the other side
    LockSui public suiLock;      // Bridge that mints wrapped SUI and burns it when going back
    
    // Test actors
    address public bridgeOperator;  // The test contract acts as bridge operator
    address public user1;           // Primary test user doing bridge operations
    address public user2;           // Secondary user for multi-user scenarios
    
    // Test constants (18 decimals standard for ERC20)
    uint256 constant INITIAL_SUPPLY = 1000000 * 10**18;  // 1M tokens initial balance
    uint256 constant BRIDGE_AMOUNT = 1000 * 10**18;      // 1K tokens per bridge operation
    
    function setUp() public {
        // The test contract itself acts as the bridge operator (owner of both lock contracts)
        bridgeOperator = address(this);
        
        // Generate deterministic test user addresses from known strings
        user1 = vm.addr(uint256(keccak256(abi.encodePacked("user1"))));
        user2 = vm.addr(uint256(keccak256(abi.encodePacked("user2"))));
        
        // Deploy the bridge system:
        // 1) Origin chain: canonical token + vault
        eth = new Eth();                        // Canonical token users start with
        ethLock = new Locketh(address(eth));    // Vault that holds locked ETH tokens
        
        // 2) Destination chain: wrapped token + bridge
        sui = new Sui();                        // Wrapped token representing locked ETH
        suiLock = new LockSui(address(sui));    // Bridge that controls wrapped token supply
        
        // Seed users with canonical ETH tokens (simulates users having ETH to bridge)
        eth.mint(user1, INITIAL_SUPPLY);  // user1 gets 1M ETH tokens to play with
        eth.mint(user2, INITIAL_SUPPLY);  // user2 gets 1M ETH tokens
        
        // Seed users with wrapped SUI tokens (simulates previous ETH→SUI bridges)
        // NOTE: Must mint BEFORE transferring ownership to the bridge
        sui.mint(user1, INITIAL_SUPPLY);  // user1 gets 1M wrapped SUI 
        sui.mint(user2, INITIAL_SUPPLY);  // user2 gets 1M wrapped SUI

        // Transfer wrapped token control to the bridge (required for mint/burn operations)
        sui.transferOwnership(address(suiLock));
    }
    
    function testETHToSUIBridge() public {
        // === ETH → SUI BRIDGE FLOW ===
        // This simulates a user moving 1000 ETH tokens from origin to destination chain
        
        // Step 1: User locks ETH tokens on the origin chain
        vm.startPrank(user1);  // All subsequent calls come from user1
        
        // User must approve the vault to spend their ETH tokens
        eth.approve(address(ethLock), BRIDGE_AMOUNT);
        
        // User deposits (locks) ETH tokens in the vault
        // This creates an internal credit for user1 and holds the tokens
        ethLock.deposit(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify the lock worked correctly on ETH side:
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY - BRIDGE_AMOUNT);  // User lost ETH
        assertEq(eth.balanceOf(address(ethLock)), BRIDGE_AMOUNT);         // Vault holds ETH
        assertEq(ethLock.balances(user1), BRIDGE_AMOUNT);               // User credited in vault
        
        // Step 2: Bridge operator observes the ETH lock and credits user on SUI side
        // In reality: operator watches ETH chain events, verifies the lock, then calls this
        suiLock.burnedOnOppositeChain(user1, BRIDGE_AMOUNT);
        
        // Step 3: User claims their wrapped SUI tokens on the destination chain
        vm.startPrank(user1);
        uint256 suiBalanceBefore = sui.balanceOf(user1);  // Track balance before minting
        
        // User withdraws from pending balance, which mints wrapped SUI tokens
        suiLock.withdraw(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify the mint worked correctly on SUI side:
        assertEq(sui.balanceOf(user1), suiBalanceBefore + BRIDGE_AMOUNT);  // User gained wrapped SUI
        assertEq(suiLock.pendingBalances(user1), 0);                      // Pending cleared
        
        // Final state: user1 has locked ETH and gained wrapped SUI
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY - BRIDGE_AMOUNT);    // Less ETH than before
        assertEq(sui.balanceOf(user1), INITIAL_SUPPLY + BRIDGE_AMOUNT);    // More SUI than before
    }
    
    function testSUIToETHBridge() public {
        // === SUI → ETH BRIDGE FLOW ===
        // This simulates a user moving 1000 tokens back from destination to origin chain
        
        // Preparation: Ensure user1 has wrapped SUI tokens to burn
        // (In real usage, they'd have these from previous ETH→SUI bridges)
        if (sui.balanceOf(user1) < BRIDGE_AMOUNT) {
            // Simulate operator crediting user1 for a previous ETH lock
            suiLock.burnedOnOppositeChain(user1, BRIDGE_AMOUNT);
            vm.startPrank(user1);
            suiLock.withdraw(BRIDGE_AMOUNT);  // User claims the wrapped tokens
            vm.stopPrank();
        }

        // Preparation: Seed ETH vault with liquidity so user1 can unlock ETH later
        // (Simulates previous ETH→SUI deposits that created vault liquidity)
        vm.startPrank(user2);
        eth.approve(address(ethLock), BRIDGE_AMOUNT);
        ethLock.deposit(BRIDGE_AMOUNT);  // user2 deposits ETH, creating vault liquidity
        vm.stopPrank();

        // Step 1: User burns wrapped SUI tokens on destination chain
        vm.startPrank(user1);
        uint256 suiBalanceBefore = sui.balanceOf(user1);  // Track SUI balance before burn
        
        // User burns wrapped SUI to signal intent to move back to origin
        // This destroys the wrapped tokens and proves user "left" the destination chain
        suiLock.burn(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify the burn worked on SUI side:
        assertEq(sui.balanceOf(user1), suiBalanceBefore - BRIDGE_AMOUNT);  // User lost wrapped SUI
        
        // Step 2: Bridge operator observes the SUI burn and credits user on ETH side
        // In reality: operator watches SUI chain events, verifies the burn, then calls this
        ethLock.burnOnOtherSide(user1, BRIDGE_AMOUNT);
        
        // Step 3: User claims their unlocked ETH tokens on the origin chain
        vm.startPrank(user1);
        uint256 ethBalanceBefore = eth.balanceOf(user1);  // Track ETH balance before unlock
        
        // User withdraws from vault credit, which transfers locked ETH back to them
        ethLock.withdraw(BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // Verify the unlock worked correctly on ETH side:
        assertEq(eth.balanceOf(user1), ethBalanceBefore + BRIDGE_AMOUNT);  // User gained ETH
        assertEq(ethLock.balances(user1), 0);                             // User's credit cleared
        
        // Final state: user1 burned wrapped SUI and unlocked original ETH
        assertEq(sui.balanceOf(user1), INITIAL_SUPPLY - BRIDGE_AMOUNT);    // Less SUI than setup
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY + BRIDGE_AMOUNT);    // More ETH than setup
    }
    
    function testRoundTripBridge() public {
        // === ROUND TRIP: ETH → SUI → ETH ===
        // Tests that bridging in both directions returns user to original state
        
        // Record starting balances - user should end up back here
        uint256 initialETH = eth.balanceOf(user1);  // Should be INITIAL_SUPPLY
        uint256 initialSUI = sui.balanceOf(user1);  // Should be INITIAL_SUPPLY
        
        // === FIRST LEG: ETH → SUI ===
        // User locks ETH and gets wrapped SUI
        
        vm.startPrank(user1);
        eth.approve(address(ethLock), BRIDGE_AMOUNT);  // Approve vault to spend ETH
        ethLock.deposit(BRIDGE_AMOUNT);                // Lock ETH in vault
        vm.stopPrank();
        
        // Operator credits user on SUI side after verifying ETH lock
        suiLock.burnedOnOppositeChain(user1, BRIDGE_AMOUNT);
        
        vm.startPrank(user1);
        suiLock.withdraw(BRIDGE_AMOUNT);               // User claims wrapped SUI
        vm.stopPrank();
        
        // Verify intermediate state: less ETH, more SUI
        assertEq(eth.balanceOf(user1), initialETH - BRIDGE_AMOUNT);  // Lost 1000 ETH
        assertEq(sui.balanceOf(user1), initialSUI + BRIDGE_AMOUNT);  // Gained 1000 SUI
        
        // === SECOND LEG: SUI → ETH ===
        // User burns wrapped SUI and unlocks original ETH
        
        vm.startPrank(user1);
        suiLock.burn(BRIDGE_AMOUNT);                   // Burn wrapped SUI
        vm.stopPrank();
        
        // Operator credits user on ETH side after verifying SUI burn
        ethLock.burnOnOtherSide(user1, BRIDGE_AMOUNT);
        
        vm.startPrank(user1);
        ethLock.withdraw(BRIDGE_AMOUNT);               // User unlocks original ETH
        vm.stopPrank();
        
        // Verify final state: back to original balances (no fees in this test)
        assertEq(eth.balanceOf(user1), initialETH);    // Back to starting ETH
        assertEq(sui.balanceOf(user1), initialSUI);    // Back to starting SUI
    }
    
    function testMultipleUsersBridging() public {
        // === CONCURRENT MULTI-USER BRIDGING ===
        // Tests two users bridging in opposite directions simultaneously
        // This validates that bridge accounting isolates users correctly
        
        // User1 initiates ETH → SUI bridge
        vm.startPrank(user1);
        eth.approve(address(ethLock), BRIDGE_AMOUNT);  // user1 approves ETH vault
        ethLock.deposit(BRIDGE_AMOUNT);                // user1 locks 1000 ETH
        vm.stopPrank();
        
        // User2 initiates SUI → ETH bridge (opposite direction)
        vm.startPrank(user2);
        suiLock.burn(BRIDGE_AMOUNT);                   // user2 burns 1000 wrapped SUI
        vm.stopPrank();
        
        // Bridge operator processes both users' operations
        // (In reality, this happens after observing on-chain events)
        suiLock.burnedOnOppositeChain(user1, BRIDGE_AMOUNT);  // Credit user1 on SUI side
        ethLock.burnOnOtherSide(user2, BRIDGE_AMOUNT);        // Credit user2 on ETH side
        
        // Users complete their respective bridges
        vm.startPrank(user1);
        suiLock.withdraw(BRIDGE_AMOUNT);               // user1 claims wrapped SUI
        vm.stopPrank();
        
        vm.startPrank(user2);
        ethLock.withdraw(BRIDGE_AMOUNT);               // user2 unlocks ETH (from user1's deposit!)
        vm.stopPrank();
        
        // Verify each user got their expected outcome:
        // user1: lost ETH, gained SUI (ETH → SUI bridge)
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY - BRIDGE_AMOUNT);
        assertEq(sui.balanceOf(user1), INITIAL_SUPPLY + BRIDGE_AMOUNT);
        
        // user2: gained ETH, lost SUI (SUI → ETH bridge)
        assertEq(eth.balanceOf(user2), INITIAL_SUPPLY + BRIDGE_AMOUNT);
        assertEq(sui.balanceOf(user2), INITIAL_SUPPLY - BRIDGE_AMOUNT);
        
        // Verify bridge contract states:
        assertEq(eth.balanceOf(address(ethLock)), 0);           // user2 withdrew user1's deposit
        assertEq(ethLock.balances(user1), BRIDGE_AMOUNT);       // user1 still has credit from deposit
        assertEq(ethLock.balances(user2), 0);                   // user2 used up their credit
        assertEq(suiLock.pendingBalances(user1), 0);            // user1 claimed their SUI
        assertEq(suiLock.pendingBalances(user2), 0);            // user2 had no SUI pending
    }
    
    function testPartialBridging() public {
        // === PARTIAL BRIDGING TEST ===
        // Tests that users can bridge partial amounts rather than always full deposits
        // This is important for real-world usage where users don't always want to bridge everything
        
        uint256 fullAmount = BRIDGE_AMOUNT;      // 1000 tokens total
        uint256 partialAmount = BRIDGE_AMOUNT / 3;  // 333 tokens partial amount
        
        // Step 1: User deposits full amount on ETH side
        vm.startPrank(user1);
        eth.approve(address(ethLock), fullAmount);  // Approve the full 1000 tokens
        ethLock.deposit(fullAmount);                // Lock all 1000 ETH in vault
        vm.stopPrank();
        
        // Step 2: Operator credits user only PARTIAL amount on SUI side
        // (Maybe operator processes bridge requests in batches, or user only wants partial)
        suiLock.burnedOnOppositeChain(user1, partialAmount);  // Credit only 333 tokens
        
        // Step 3: User withdraws (mints) only the partial amount on SUI side
        vm.startPrank(user1);
        suiLock.withdraw(partialAmount);  // User claims 333 wrapped SUI tokens
        vm.stopPrank();
        
        // Step 4: User decides to bridge back the partial amount (SUI → ETH)
        vm.startPrank(user1);
        suiLock.burn(partialAmount);      // User burns the 333 wrapped SUI
        vm.stopPrank();
        
        // Step 5: Operator credits partial unlock on ETH side
        ethLock.burnOnOtherSide(user1, partialAmount);  // Credit user for 333 ETH unlock
        
        // Step 6: User withdraws partial amount from ETH vault
        vm.startPrank(user1);
        ethLock.withdraw(partialAmount);  // User gets back 333 ETH from vault
        vm.stopPrank();
        
        // Verify complex final state with partial bridging:
        uint256 remainingLocked = fullAmount - partialAmount;  // 667 ETH still locked
        
        // User has original 1000 ETH deposit credit + 333 from burn = 1333 credit, but withdrew 333
        assertEq(ethLock.balances(user1), remainingLocked + partialAmount);  // 667 + 333 = 1000 credit left
        
        // User started with 1M ETH, deposited 1000, got back 333
        assertEq(eth.balanceOf(user1), INITIAL_SUPPLY - fullAmount + partialAmount);  // Net -667 ETH
        
        // User is back to original SUI balance (gained 333, then burned 333)
        assertEq(sui.balanceOf(user1), INITIAL_SUPPLY); // Back to 1M wrapped SUI
    }
    
    function testBridgeOperatorSecurity() public {
        // === BRIDGE OPERATOR SECURITY TEST ===
        // Tests that only authorized operators can credit cross-chain pending balances
        // This prevents arbitrary minting/unlocking without proper verification
        
        address maliciousActor = vm.addr(uint256(keccak256(abi.encodePacked("malicious"))));
        
        // TEST 1: Malicious actor tries to credit SUI side without being operator
        vm.startPrank(maliciousActor);
        vm.expectRevert();  // Should revert with OwnableUnauthorizedAccount
        suiLock.burnedOnOppositeChain(maliciousActor, BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // TEST 2: Malicious actor tries to credit ETH side without being operator
        vm.startPrank(maliciousActor);
        vm.expectRevert();  // Should revert with OwnableUnauthorizedAccount
        ethLock.burnOnOtherSide(maliciousActor, BRIDGE_AMOUNT);
        vm.stopPrank();
        
        // These tests ensure that:
        // 1) Only the bridge operator can credit pending balances (prevents fake mints)
        // 2) Only the bridge operator can credit vault unlocks (prevents theft)
        // 3) Users cannot bypass the operator verification step
        // 4) The bridge maintains security even if malicious actors know the contract addresses
    }
}