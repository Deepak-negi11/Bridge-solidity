// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Example canonical token used on origin chain
/// @notice In production this would be a real token; here mint is restricted
///         to owner for test setup.
/// @dev This represents the "real" token that users want to bridge.
///      The bridge will LOCK these tokens (never burn them) and mint
///      wrapped representations on the destination chain.
///      Key properties:
///      - Standard ERC20 with controlled minting for tests
///      - Ownership allows test setup but real tokens wouldn't have this
///      - Bridge vault will hold large amounts of this token

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";  // Standard ERC20 implementation
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol"; // ERC20 interface
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";    // Access control for minting

contract Eth is ERC20, Ownable {
    
    /// @notice Deploy the canonical token that will be locked in the bridge vault
    /// @dev In production, this would be an existing token (USDC, WETH, etc.)
    ///      Here we create a mintable version for test convenience
    constructor() ERC20("Ethereum Bridge Token", "ETH") Ownable(msg.sender) {
        // Token starts with 0 supply; only owner can mint for testing
        // Real tokens would have their own supply mechanics
    }

    /// @notice Mint tokens for test setup (owner-only)
    /// @dev This function exists purely for test convenience.
    ///      Real canonical tokens either have fixed supply or their own mint logic.
    ///      The bridge itself never calls this - it only locks/unlocks existing tokens.
    /// @param _to Address to receive the newly minted tokens
    /// @param _amount Number of tokens to mint (with 18 decimals)
    function mint(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Cannot mint to zero address");  // Prevent accidental burns
        require(_amount > 0, "Amount must be greater than 0");      // Prevent zero-value operations
        
        // Use OpenZeppelin's internal _mint which handles supply tracking
        _mint(_to, _amount);
    }
    
}
