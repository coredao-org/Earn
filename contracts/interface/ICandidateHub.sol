// SPDX-License-Identifier: MIT
pragma solidity 0.8.4; 

interface ICandidateHub {
  function canDelegate(address agent) external view returns(bool);
  function getRoundTag() external view returns(uint256);
}