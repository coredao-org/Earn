// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IEarnErrors {
    // operator related errors
    error EarnZeroOperator(address operator);
    
    // protocol fee related errors
    error EarnProtocolFeePointMoreThanRateBase(uint256 protocolFeePoint);
    error EarnZeroProtocolFeeReceiver(address protocolFeeReceiver);

    // rebalance related errors
    error EarnReBalancDelegateFailed(address validator, uint256 amount);
    error EarnReBalancUnDelegateFailed(address validator, uint256 amount);

    // mint related errors
    error EarnZeroValidator(address validator);
    error EarnCanNotDelegateValidator(address validator);
    error EarnMintAmountTooSmall(address account, uint256 amount);
    error EarnDelegateFailedWhileMint(address account, address validator, uint256 amount);
    error EarnCallStCoreMintFailed(address account, uint256 amount, uint256 stCore);

    // redeem related errors
    error EarnSTCoreTooSmall(address account, uint256 stCore);
    error EarnCallStCoreBurnFailed(address account, uint256 amount, uint256 stCore);
    error EarnUnDelegateFailedCase1(address validator, uint256 amount);
    error EarnUnDelegateFailedCase2(address validator, uint256 amount);
    error EarnUnDelegateFailedCase3(address validator, uint256 amount);
    error EarnUnDelegateFailedCase4(address validator, uint256 amount);
    error EarnUnDelegateFailedCase5(address validator, uint256 amount);
    error EarnUnDelegateFailedFinally(address validator, uint256 amount);
    error EarnEmptyValidator();

    // withdraw related errors
    error EarnRedeemRecordIdMustGreaterThanZero(address account, uint256 id);
    error EarnEmptyRedeemRecord();
    error EarnRedeemRecordNotFound(address account, uint256 id);
    error EarnRedeemLocked(address account, uint256 unlockTime, uint256 blockTime);
    error EarnInsufficientBalance(uint256 balance, uint256 amount);
}


