pragma solidity 0.8.4;

contract TestEarnProxy {
    address public earn;
    
    event tMint(bool success, bytes returnData);
    event tRedeem(bool success);
    event tWithdraw(bool success, bytes returnData);
    constructor(address earnAddress) public {
        earn = earnAddress;
    }
    function proxyMint(address agent) external payable {
        bytes memory payload = abi.encodeWithSignature("mint(address)", agent);
        (bool success, bytes memory returnData) = earn.call{value: msg.value}(payload);
        emit tMint(success, returnData);
    }

    function proxyRedeem(uint256 core) external payable {
        bytes memory payload = abi.encodeWithSignature("redeem(uint256)", core);
        (bool success, bytes memory returnData) = earn.call(payload);
        emit tRedeem(success);
    }

    function proxyWithdraw() external payable {
        bytes memory payload = abi.encodeWithSignature("withdraw()");
        (bool success, bytes memory returnData) = earn.call(payload);
        emit tWithdraw(success, returnData);
    }
}

contract WithdrawReentry is TestEarnProxy {
    bool public reentry;
    constructor(address _earnAddress) TestEarnProxy(_earnAddress) {
    }
    function setReentry(bool _reentry) external {
        reentry = _reentry;
    }

    receive() external payable {
        if (reentry == true) {
            bytes memory payload = abi.encodeWithSignature("withdraw()");
            (bool success, bytes memory returnData) = earn.call(payload);
            emit tWithdraw(success, returnData);
        }
    }
}


