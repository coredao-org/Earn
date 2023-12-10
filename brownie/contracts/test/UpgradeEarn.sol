pragma solidity 0.8.4;

import "./EarnMock.sol";

contract UpgradeEarn is EarnMock {
    bool public upgradeEarn;
    uint256 public upgradeNumber;

    function setUpgradeEarn(bool value) external {
        upgradeEarn = value;
    }

    function setUpgradeNumber(uint256 value) external {
        upgradeNumber = value;
    }

    function getUpgradeEarn() external view returns (bool) {
        return upgradeEarn;
    }

    function getUpgradeNumber() external view returns (uint256) {
        return upgradeNumber;
    }

}
