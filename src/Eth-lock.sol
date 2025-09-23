// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Origin-chain vault for canonical token
/// @notice Locks canonical tokens on the origin chain and releases them
///         when the wrapped tokens are burned on the destination chain.
/// @dev This contract never mints/burns; it only holds and transfers
///      the canonical token. Cross-chain messages are represented by
///      the owner calling credit functions once verified off-chain.

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Locketh is Ownable, ReentrancyGuard {
    IERC20 public immutable tokenAddress;
    mapping(address => uint256) public balances;
    
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event BurnedOnOtherSide(address indexed user, uint256 amount);
    
    /// @param _tokenAddress Address of the canonical ERC20 token locked in this vault
    constructor(address _tokenAddress) Ownable(msg.sender) {
        require(_tokenAddress != address(0), "Invalid token address");
        tokenAddress = IERC20(_tokenAddress);
    }

    /// @notice Lock canonical tokens in the vault as part of bridging to the other chain
    /// @dev This is step 1 of ETH→SUI bridge. User calls this to lock tokens.
    ///      Later, operator will credit them on SUI side after verification.
    /// @param _amount Amount of tokens to deposit (must be approved first)
    function deposit(uint256 _amount) external nonReentrant {
        // Input validation: prevent zero-value operations
        require(_amount > 0, "Amount must be greater than 0");
        
        // Check user has approved this contract to spend their tokens
        // This is standard ERC20 pattern: approve() then transferFrom()
        require(tokenAddress.allowance(msg.sender, address(this)) >= _amount, "Insufficient allowance");
        
        // Transfer tokens from user to this vault contract
        // We check the return value to handle non-standard ERC20s
        bool success = tokenAddress.transferFrom(msg.sender, address(this), _amount);
        require(success, "Transfer failed");
        
        // Credit user's internal balance for future withdrawals
        // This acts as a "receipt" that user can later redeem
        balances[msg.sender] += _amount;
        
        // Emit event for off-chain monitoring and bridge operator
        emit Deposited(msg.sender, _amount);
    }
    
    /// @notice Withdraw previously locked canonical tokens (typically after a burn on the other chain)
    /// @dev This is step 3 of SUI→ETH bridge. User calls this after operator credits them.
    ///      Operator calls burnOnOtherSide() first to give user withdrawal credit.
    /// @param _amount Amount of tokens to withdraw
    function withdraw(uint256 _amount) external nonReentrant {
        // Input validation: prevent zero-value operations
        require(_amount > 0, "Amount must be greater than 0");
        
        // Check user has sufficient internal credit from deposits or operator credits
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        
        // Deduct from user's internal balance BEFORE external call (CEI pattern)
        balances[msg.sender] -= _amount;
        
        // Transfer tokens from vault back to user
        // Vault must have sufficient tokens from previous deposits
        bool success = tokenAddress.transfer(msg.sender, _amount);
        require(success, "Transfer failed");
        
        emit Withdrawn(msg.sender, _amount);
    }
    
    /// @notice Credit a user after verifying a burn of wrapped tokens on the other chain
    /// @dev Name kept for backward compatibility; semantically this credits unlock rights
    /// @param userAccount The user to credit on this chain
    /// @param _amount The amount that was burned on the other chain
    function burnOnOtherSide(address userAccount, uint256 _amount) external onlyOwner {
        require(userAccount != address(0), "Invalid user address");
        require(_amount > 0, "Amount must be greater than 0");
        
        balances[userAccount] += _amount;
        emit BurnedOnOtherSide(userAccount, _amount);
    }
    
    /// @notice Owner can pull all tokens in emergencies
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = tokenAddress.balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        
        bool success = tokenAddress.transfer(owner(), balance);
        require(success, "Emergency withdrawal failed");
    }
}
