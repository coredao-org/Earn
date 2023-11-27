// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import {ISTCoreErrors} from "./interface/IErrors.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract STCore is ERC20, Ownable{
    // Contract address of EARN
    address public earn;

    event SetEarnAddress(address indexed operator, address earn);

    constructor() ERC20("Liquid staked CORE", "stCORE") {}

    modifier onlyEarn() {
        require(msg.sender == earn, "Not Earn contract");
        _;
    }

    function mint(address account, uint256 amount) public onlyEarn {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public onlyEarn {
        _burn(account, amount);
    } 

    // Only owner can modify earn address
    function setEarnAddress(address _earn) public onlyOwner {
        if (_earn == address(0)) {
            revert ISTCoreErrors.STCoreZeroEarn(_earn);
        }
        earn = _earn;
        emit SetEarnAddress(msg.sender, _earn);
    }
}