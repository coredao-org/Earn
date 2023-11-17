// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IEarnErrors {
    error EarnInvalidValidator(address validator);

    error EarnInvalidDelegateAmount(address account, uint256 amount);

    error EarnDelegateFailed(address account, address validator, uint256 amount);

    error EarnMintFailed(address account, uint256 amount, uint256 stCore);

    error EarnInvalidExchangeAmount(address account, uint256 amount);

    error EarnBurnFailed(address account, uint256 amount, uint256 stCore);

    error EarnERC20InsufficientTotalSupply(address account, uint256 stCore, uint256 totalSupply);

    error EarnInvalidRedeemRecordId(address account, uint256 id);

    error EarnRedeemLocked(address account, uint256 unlockTime, uint256 blockTime);

    error EarnInsufficientBalance(uint256 balance, uint256 amount);

    error EarnUnDelegateFailed(address validator, uint256 amount);

    error EarnDelegateInfoNotExist(address validator, uint256 amount);

    error EarnInsufficientUndelegateAmount(address validator, uint256 amount);

    error EarnInvalidRegistry(address registry);
    
    error EarnInvalidExchangeRatesTarget();
}