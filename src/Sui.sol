// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Wrapped token used on destination chain
/// @notice Ownership is expected to be transferred to the lock contract
///         so only the bridge can mint/burn supply.
/// @dev This token represents locked assets from the origin chain.
///      Supply mechanics:
///      - Mint: when users arrive from origin (after locking canonical tokens)
///      - Burn: when users leave for origin (before unlocking canonical tokens)
///      - Total supply should equal locked canonical tokens on origin
///      
///      Security model:
///      - Only bridge contract can mint/burn (prevents unauthorized creation)
///      - Users can transfer normally once they hold tokens
///      - Bridge maintains 1:1 backing with locked canonical tokens

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";  // Standard ERC20 implementation
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol"; // ERC20 interface
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";    // Access control for mint/burn

contract Sui is ERC20, Ownable {
    
    /// @notice Deploy the wrapped token representing locked assets on origin chain
    /// @dev Starts with 0 supply. Bridge will be made owner and control all minting/burning.
    ///      Token name/symbol can be anything; "Sui" here is just an example.
    constructor() ERC20("Sui", "SUI") Ownable(msg.sender) {
        // Empty constructor - all supply control happens via bridge
        // Initial owner is deployer, but ownership gets transferred to bridge
    }

    /// @notice Mint wrapped tokens when users arrive from origin chain
    /// @dev Only bridge can call this after verifying origin chain lock.
    ///      This creates new supply representing newly locked canonical tokens.
    /// @param _to User who locked tokens on origin and should receive wrapped tokens
    /// @param _amount Number of tokens to mint (should equal amount locked on origin)
    function mint(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Cannot mint to zero address");  // Prevent burning tokens
        require(_amount > 0, "Amount must be greater than 0");      // Prevent zero-ops
        
        // Mint increases total supply and gives tokens to user
        // Bridge should only call this after confirming origin lock
        _mint(_to, _amount);
    }
    
    /// @notice Burn wrapped tokens when users return to origin chain
    /// @dev Only bridge can call this when users want to unlock on origin.
    ///      This destroys supply, allowing equivalent amount to be unlocked on origin.
    /// @param _from User who wants to burn wrapped tokens and unlock on origin
    /// @param _amount Number of tokens to burn (will unlock equivalent on origin)
    function burn(address _from, uint256 _amount) external onlyOwner {
        require(_from != address(0), "Cannot burn from zero address");     // Sanity check
        require(_amount > 0, "Amount must be greater than 0");            // Prevent zero-ops
        require(balanceOf(_from) >= _amount, "Insufficient balance to burn"); // Prevent underflow
        
        // Burn decreases total supply and removes tokens from user
        // Bridge should only call this before initiating origin unlock
        _burn(_from, _amount);
    }
}
