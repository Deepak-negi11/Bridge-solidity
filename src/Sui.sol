// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Wrapped token used on destination chain
/// @notice Ownership is expected to be transferred to the lock contract
///         so only the bridge can mint/burn supply.

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Sui is ERC20, Ownable {
    
    constructor() ERC20("Sui", "SUI") Ownable(msg.sender) {

    }

    /// @notice Mint wrapped tokens (bridge only)
    function mint(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Cannot mint to zero address");
        require(_amount > 0, "Amount must be greater than 0");
        _mint(_to, _amount);
    }
    
    /// @notice Burn wrapped tokens (bridge only)
    function burn(address _from, uint256 _amount) external onlyOwner {
        require(_from != address(0), "Cannot burn from zero address");
        require(_amount > 0, "Amount must be greater than 0");
        require(balanceOf(_from) >= _amount, "Insufficient balance to burn");
        _burn(_from, _amount);
    }
}
