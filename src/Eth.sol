// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Example canonical token used on origin chain
/// @notice In production this would be a real token; here mint is restricted
///         to owner for test setup.

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Eth is ERC20, Ownable {
    
    constructor() ERC20("Ethereum Bridge Token", "ETH") Ownable(msg.sender) {

    }

    /// @notice Mint tokens for test setup (owner-only)
    function mint(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Cannot mint to zero address");
        require(_amount > 0, "Amount must be greater than 0");
        _mint(_to, _amount);
    }
    
}
