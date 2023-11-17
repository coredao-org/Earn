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
    // Unique index redeem record
    uint256 identity;

    // Redeem action time
    uint256 redeemTime;

    // Redeem unlock time
    uint256 unlockTime;

    // Redeem amount
    uint256 amount;

    // Amount of st core
    uint256 stCore;
}