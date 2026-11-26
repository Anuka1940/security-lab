// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "../interfaces/IERC20.sol";

/// @notice Lightweight mintable ERC-20 token for isolated unit tests.
contract TestToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory tokenName, string memory tokenSymbol, uint8 tokenDecimals) {
        name = tokenName;
        symbol = tokenSymbol;
        decimals = tokenDecimals;
    }

    function mintTo(address recipient, uint256 amount) external {
        totalSupply += amount;
        balanceOf[recipient] += amount;
        emit Transfer(address(0), recipient, amount);
    }

    function burnFrom(address holder, uint256 amount) external {
        balanceOf[holder] -= amount;
        totalSupply -= amount;
        emit Transfer(holder, address(0), amount);
    }

    function approve(address operator, uint256 value) external returns (bool) {
        allowance[msg.sender][operator] = value;
        emit Approval(msg.sender, operator, value);
        return true;
    }

    function transfer(address recipient, uint256 value) external returns (bool) {
        _move(msg.sender, recipient, value);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 value) external returns (bool) {
        uint256 currentAllowance = allowance[sender][msg.sender];
        if (currentAllowance != type(uint256).max) {
            allowance[sender][msg.sender] = currentAllowance - value;
        }
        _move(sender, recipient, value);
        return true;
    }

    function _move(address sender, address recipient, uint256 value) private {
        balanceOf[sender] -= value;
        balanceOf[recipient] += value;
        emit Transfer(sender, recipient, value);
    }
}
