// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Destination-chain bridge for wrapped token
/// @notice Mints wrapped tokens when users arrive from origin and
///         burns them when users go back to origin. Tracks pending
///         credits that come from the origin chain via an operator.

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IBSUI is IERC20 {
    function mint(address _to, uint256 _amount) external;
    function burn(address _from, uint256 _amount) external;
}

contract LockSui is Ownable, ReentrancyGuard {
    IBSUI public immutable tokenAddress;
    
    mapping(address => uint256) public pendingBalances;
    
    event Burned(address indexed burner, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event BurnedOnOppositeChain(address indexed user, uint256 amount);
    
    /// @param _tokenAddress Address of the wrapped token contract. Ownership should be transferred to this contract.
    constructor(address _tokenAddress) Ownable(msg.sender) {
        require(_tokenAddress != address(0), "Invalid token address");
        tokenAddress = IBSUI(_tokenAddress);
    }
    
    /// @notice User burns wrapped tokens to move value back to the origin chain
    /// @param _amount Amount of wrapped tokens to burn
    function burn(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(tokenAddress.balanceOf(msg.sender) >= _amount, "Insufficient balance");
        
        tokenAddress.burn(msg.sender, _amount);
        emit Burned(msg.sender, _amount);
    }
    
    /// @notice User mints wrapped tokens after the operator credits them from origin-chain activity
    /// @param _amount Amount to withdraw from pending and mint
    function withdraw(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(pendingBalances[msg.sender] >= _amount, "Insufficient pending balance");
        
        pendingBalances[msg.sender] -= _amount;
        tokenAddress.mint(msg.sender, _amount);
        
        emit Withdrawn(msg.sender, _amount);
    }
    
    /// @notice Operator credits a user after confirming an origin-chain deposit
    /// @param userAccount The beneficiary to credit
    /// @param _amount The credited amount
    function burnedOnOppositeChain(address userAccount, uint256 _amount) external onlyOwner {
        require(userAccount != address(0), "Invalid user address");
        require(_amount > 0, "Amount must be greater than 0");
        
        pendingBalances[userAccount] += _amount;
        emit BurnedOnOppositeChain(userAccount, _amount);
    }
    
    /// @notice Emergency path to mint any pending amount directly to a user
    /// @param user The beneficiary whose pending balance is minted
    function emergencyWithdrawPending(address user) external onlyOwner {
        require(user != address(0), "Invalid user address");
        uint256 amount = pendingBalances[user];
        require(amount > 0, "No pending balance");
        
        pendingBalances[user] = 0;
        tokenAddress.mint(user, amount);
    }
}