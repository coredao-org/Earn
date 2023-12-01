// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;
    
struct DelegateInfo {
    // Delegate amount
    uint256 amount;

    // Delegate earning
    uint256 earning;
}

struct DelegateAction {
    // Address of validator
    address validator;

    // Delegate amount
    uint256 amount;
}

struct RedeemRecord {
    // Redeem action time
    uint256 redeemTime;

    // Redeem unlock time
    uint256 unlockTime;

    // Redeem amount
    uint256 amount;

    // Amount of stCORE
    uint256 stCore;

    // Amount of protocol fee
    uint256 protocolFee;
}

// Candidate copy from system contract
struct Candidate {
    address operateAddr;
    address consensusAddr;
    address payable feeAddr;
    uint256 commissionThousandths;
    uint256 margin;
    uint256 status;
    uint256 commissionLastChangeRound;
    uint256 commissionLastRoundValue;
}