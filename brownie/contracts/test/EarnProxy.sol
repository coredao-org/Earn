pragma solidity 0.8.4;

import "./EarnMock.sol"; 
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EarnProxy is ERC1967Proxy {
    constructor(address logic, bytes memory data) ERC1967Proxy(logic, data) {}
}
