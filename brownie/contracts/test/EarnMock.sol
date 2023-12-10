pragma solidity 0.8.4;

import "../Earn.sol";

contract EarnMock is Earn {
    function developmentInit() external {
        balanceThreshold = balanceThreshold / 1e20;
        mintMinLimit = mintMinLimit / 1e16;
        redeemMinLimit = redeemMinLimit / 1e16;
        pledgeAgentLimit = pledgeAgentLimit / 1e16;
    }

    function setContractAddress(address candidateAddress, address pledgeAgentAddress, uint256 roundTag) external {
        CANDIDATE_HUB = candidateAddress;
        PLEDGE_AGENT = pledgeAgentAddress;
        roundTag = roundTag;
    }

    function transferTo(address payable recipient, uint256 amount) external {
        recipient.transfer(amount);
    }


    function setAfterTurnRoundClaimReward(bool claim) external {
        afterTurnRoundClaimReward = claim;
    }

    function setDayInterval(uint256 value) external {
        DAY_INTERVAL = value;
    }

    function setLastOperateRound(uint256 value) external {
        roundTag = value;
    }

    function setReduceTime(uint256 value) external {
        ReduceTime = value;
    }

    function setUnDelegateValidatorState(bool value) external {
        unDelegateValidatorState = value;
    }

    function setUnDelegateValidatorIndex(uint256 value) external {
        unDelegateValidatorIndex = value;
    }

    function getCurrentRound() external view returns (uint256) {
        return ICandidateHub(CANDIDATE_HUB).getRoundTag();
    }

    function testRandomIndex(uint256 length) external view returns (uint256) {
        return uint256(keccak256(abi.encode(msg.sender, roundTag))) % length;
    }

}