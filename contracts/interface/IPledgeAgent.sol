// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IPledgeAgent {
    function delegateCoin(address agent) external payable;
    function undelegateCoin(address agent, uint256 amount) external;
    function transferCoin(address sourceAgent, address targetAgent, uint256 amount) external;
    function claimReward(address[] calldata agentList) external returns (uint256, bool);
}