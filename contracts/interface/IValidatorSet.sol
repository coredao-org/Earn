// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IValidatorSet {
  function getValidators() external view returns (address[] memory);
}