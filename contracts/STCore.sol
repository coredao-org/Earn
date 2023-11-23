// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract STCore is ERC20, Ownable{
    // Contract address of EARN
    address private EARN;

    constructor() ERC20("Liquid staked CORE", "stCORE") {
    }

    modifier onlyEarn() {
        require(msg.sender == EARN, "Not EARN contract");
        _;
    }

    function mint(address account, uint256 amount) public onlyEarn{
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public onlyEarn{
        _burn(account, amount);
    } 

    // Only owner can modify earn address
    function setEarnAddress(address _earn) public onlyOwner {
        EARN = _earn;
    }
}