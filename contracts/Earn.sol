// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IAfterTurnRoundCallBack.sol";
import {IEarnErrors} from "./interface/IErrors.sol";
import "./lib/IterableAddressDelegateMapping.sol";
import "./lib/DelegateActionQueue.sol";
import "./lib/Structs.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Earn is IAfterTurnRoundCallBack, ReentrancyGuard {
    using IterableAddressDelegateMapping for IterableAddressDelegateMapping.Map;
    using DelegateActionQueue for DelegateActionQueue.Queue;

    // Exchange rate multiple
    uint16 constant private RATE_MULTIPLE = 10000; 

    // Address of system contract: CandidateHub
    address constant private CANDIDATE_HUB = 0x0000000000000000000000000000000000001005; 

    // Address of system contract: PledgeAgent
    address constant private PLEDGE_AGENT = payable(0x0000000000000000000000000000000000001007);

    address constant private REGISTRY = 0x0000000000000000000000000000000000001010;

    // Address of stcore contract: STCore
    address private STCORE; 

    // Exchange Rate per round 
    // uint256 public exchangeRate = RATE_MULTIPLE;
    uint256[] public exchangeRates;

    // Map of the amount pledged by the validator
    IterableAddressDelegateMapping.Map private validatorDelegateMap;
    DelegateActionQueue.Queue private delegateQueue; 

    // The time locked when user redeem Core
    uint16 public constant LOCK_DAY = 7;
    uint256 public constant INIT_DAY_INTERVAL = 86400;

    // Account redeem record
    uint256 public uniqueIndex = 1;
    mapping(address => RedeemRecord[]) private redeemRecords;

    constructor(address _stCore) {
        STCORE = _stCore;
        exchangeRates.push(RATE_MULTIPLE);
    }
    
    // Proxy user pledge, at the same time exchange STCore
    function delegateStaking(address validator) public payable nonReentrant {
        address account = msg.sender;
        uint256 amount = msg.value;

        // Determine the minimum amount to pledge
        if (amount < 1 ether) {
            revert IEarnErrors.EarnInvalidDelegateAmount(account, amount);
        }

        // Determines whether the validator is an empty address
        if (validator == address(0)) {
            revert IEarnErrors.EarnInvalidValidator(validator);    
        }

        // Call PLEDGE_AGENT delegate
        bool success = _delegate(validator, amount);
        if (!success) {
            revert IEarnErrors.EarnDelegateFailed(account, validator,amount);
        }

        // Record the amount pledged by validator
         DelegateInfo memory delegateInfo = DelegateInfo({
            amount: amount,
            earning: 0
        });
        validatorDelegateMap.set(validator, delegateInfo, true);

        // Exchange STCore, and mint to suer
        uint256 stCore = _exchangeSTCore(amount);
        bytes memory callData = abi.encodeWithSignature("mint(address,uint256)", account, stCore);
        (success, ) = STCORE.call(callData);
        if (!success) {
            revert IEarnErrors.EarnMintFailed(account, amount, stCore);
        }
    }

    // Triggered after turn round
    // Provider is responsible for the successful execution of the method. 
    // This method cannot revert
    function afterTurnRound() public override {
        if (msg.sender != REGISTRY) {
            revert IEarnErrors.EarnInvalidRegistry(msg.sender);
        }

        // Claim reward
        for (uint i = 0; i < validatorDelegateMap.size(); i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo storage delegateInfo = validatorDelegateMap.get(key);

            uint256 balanceBeforeClaim = address(this).balance;
            bool success = _claim(key);
            if (success) {
                // Claim reward success
                uint256 balanceAfterClaim = address(this).balance;
                uint256 _earning = balanceAfterClaim - balanceBeforeClaim;
                delegateInfo.earning += _earning;
            } 
        }

        // Reward re delegate
        for (uint i = 0; i < validatorDelegateMap.size(); i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo storage delegateInfo = validatorDelegateMap.get(key);

            if (delegateInfo.earning > 0) {
                if(delegateInfo.earning > 1 ether) {
                    // Delegate reward
                    uint256 delegateAmount = delegateInfo.earning;
                    bool success = _delegate(key, delegateAmount);
                    if (success) {
                        delegateInfo.amount += delegateAmount;
                        delegateInfo.earning -= delegateAmount;
                    } 
                } 
            }
        }

        // Calculate exchange rate
        uint256 totalSupply = IERC20(STCORE).totalSupply();
        if (totalSupply > 0) {
            uint256 _capital = 0;
            for (uint i = 0; i < validatorDelegateMap.size(); i++) {
                address key = validatorDelegateMap.getKeyAtIndex(i);
                DelegateInfo memory delegateInfo = validatorDelegateMap.get(key);
                _capital += delegateInfo.amount;
            }
            if (_capital > 0) {
                exchangeRates.push(_capital * RATE_MULTIPLE / totalSupply);
                // exchangeRate = _capital * RATE_MULTIPLE / totalSupply;
            }
        }
    }

    // Exchange STCore for Core
    function redeem(uint256 stCore) public nonReentrant {
         address account = msg.sender;

        // The amount exchanged must not be less than 1 ether
        if (stCore < 1 ether) {
            revert IEarnErrors.EarnInvalidExchangeAmount(account, stCore);
        }
       
        // Calculate exchanged core
        uint256 core = _exchangeCore(stCore);
        if (core <= 0) {
            revert IEarnErrors.EarnInvalidExchangeAmount(account, stCore);
        }

        // Burn STCore
        uint256 totalSupply = IERC20(STCORE).totalSupply();
        if (stCore > totalSupply) {
            revert IEarnErrors.EarnERC20InsufficientTotalSupply(account, stCore, totalSupply);
        }
        bytes memory callData = abi.encodeWithSignature("burn(address,uint256)", account, stCore);
        (bool success, ) = STCORE.call(callData);
        if (!success) {
            revert IEarnErrors.EarnBurnFailed(account, core, stCore);
        }

        // Execute un delegate stragety
        // This version implement by queue
        _unDelegateStratege(core);

        // Record the redemption record of the user with lock
        RedeemRecord memory redeemRecord = RedeemRecord({
            identity : uniqueIndex++,
            redeemTime: block.timestamp,
            unlockTime: block.timestamp + INIT_DAY_INTERVAL * LOCK_DAY,
            amount: core,
            stCore: stCore
        });
        RedeemRecord[] storage records = redeemRecords[account];
        records.push(redeemRecord);
    }

    // The user redeems the unlocked Core
    function withdraw(uint256 identity) public nonReentrant {
        address account = msg.sender;
        
        // The ID of the redemption record cannot be less than 1 
        if (identity < 1) {
            revert IEarnErrors.EarnInvalidRedeemRecordId(account, identity);
        }

        // Find user redeem records
        RedeemRecord[] storage records = redeemRecords[account];
        if (records.length <= 0) {
            revert IEarnErrors.EarnInvalidRedeemRecordId(account, identity);
        }

        bool findRecord = false;
        uint index = 0;
        uint256 amount = 0;
        for (uint i = 0; i < records.length; i++) {
            RedeemRecord memory record = records[i];
            if (record.identity == identity) {
                // Find redeem record
                if (!findRecord) {
                    findRecord = true;
                }
                if (record.unlockTime >= block.timestamp) {
                    // Redeem record lock not due，revert
                    revert IEarnErrors.EarnRedeemLocked(account, record.unlockTime, block.timestamp);
                }
                // Maturity, successful redemption
                index = i;
                amount = record.amount;
            }
        }

        // Redeem record not found
        if (!findRecord) {
            revert IEarnErrors.EarnInvalidRedeemRecordId(account, identity);
        }

        // Drop redeem record, and transfer core to user
        for (uint i = index; i < records.length - 1; i++) {
            records[i] = records[i + 1];
        }
        records.pop();
        if (address(this).balance < amount) {
            revert IEarnErrors.EarnInsufficientBalance(address(this).balance, amount);
        }
        payable(account).transfer(amount);
    }

    function getRedeemRecords() public view returns (RedeemRecord[] memory) {
        return redeemRecords[msg.sender];
    }

    function getRedeemAmount() public view returns (uint256 unlockedAmount, uint256 lockedAmount) {
        RedeemRecord[] memory records = redeemRecords[msg.sender];        
        for (uint i = 0; i < records.length; i++) {
            RedeemRecord memory record = records[i];
             if (record.unlockTime >= block.timestamp) {
                unlockedAmount += record.amount;
            } else {
                lockedAmount += record.amount;
            }
        }
    }

    function getExchangeRates(uint256 target) public view returns(uint256[] memory) {
         if (target < 1) {
            revert IEarnErrors.EarnInvalidExchangeRatesTarget();
        }

        uint size = exchangeRates.length;
        uint from = 0;
        uint count;
        if (target >= size) {
            count = size;
        } else {
            from = size - target;
            count = target;
        }

        uint256[] memory result = new uint[](count);
        for (uint i = from; i < size; i++) {
            result[i-from] = exchangeRates[i];
        }

        return result;
    }

    function getCurrentExchangeRate() public view  returns (uint256) {
        return exchangeRates[exchangeRates.length - 1];
    } 

    function getTotalDelegateAmount() public view returns (uint256) {
        uint256 amount = 0;
        for (uint i = 0; i < validatorDelegateMap.size(); i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo memory delegateInfo = validatorDelegateMap.get(key);
            amount += delegateInfo.amount;
        }
        return amount;
    }

    // Core exchange to STCore
    function _exchangeSTCore(uint256 core) internal view returns (uint256) {
        return core * RATE_MULTIPLE / exchangeRates[exchangeRates.length-1];
        // return core * RATE_MULTIPLE / exchangeRate;
    }

    // STCore exchange to Core
    function _exchangeCore(uint256 stCore) internal view returns(uint256) {
        return stCore * exchangeRates[exchangeRates.length-1] / RATE_MULTIPLE;
        // return stCore * exchangeRate / RATE_MULTIPLE;
    }

    // Undelegate stragety: queue version
    function _unDelegateStratege(uint256 amount) internal {
        uint256 unDelegateAmount = 0;

        while (true) {
            // The amount that the current cycle needs to process
            uint256 processAmount = amount - unDelegateAmount;

            DelegateAction memory action = delegateQueue.dequeue();
            if (processAmount == action.amount) {
                // Undelegate amount equal to dequeue amount
                bool success = _unDelegate(action.validator, action.amount);
                if (!success) {
                    revert IEarnErrors.EarnUnDelegateFailed(action.validator, action.amount);
                }
                _adjustDelegateMap(action.validator, action.amount);
                break;
            } else if (processAmount > action.amount){
                // Undelegate amount greatter than dequeue amount
                // Need to continue the cycle
                bool success = _unDelegate(action.validator, action.amount);
                if (!success) {
                    revert IEarnErrors.EarnUnDelegateFailed(action.validator, action.amount);
                }
                _adjustDelegateMap(action.validator, action.amount);
                unDelegateAmount += action.amount;
            } else if(processAmount < action.amount) {
                // Undelegate amount less than dequeue amount
                // Need to exit the cycle
                bool success = _unDelegate(action.validator, processAmount);
                if (!success) {
                    revert IEarnErrors.EarnUnDelegateFailed(action.validator, processAmount);
                }
                _adjustDelegateMap(action.validator, processAmount);

                // The remaining amount enqueue again
                DelegateAction memory reAction = DelegateAction({
                    validator: action.validator,
                    amount: action.amount - processAmount
                });
                delegateQueue.enqueue(reAction);
                break;
            }
        }
    }

    // Undelegate may generate income
    function _unDelegate(address validator, uint256 amount) internal returns (bool) {
        uint256 balanceBefore = address(this).balance;
        bytes memory callData = abi.encodeWithSignature("undelegateCoin(address,uint256)", validator, amount);
        (bool success, ) = PLEDGE_AGENT.call(callData);
        if (success) {
            uint256 balanceAfter = address(this).balance - amount;
            uint256 earning = balanceAfter - balanceBefore;
            if (earning > 0) {
                DelegateInfo memory delegateFailed = DelegateInfo({
                    amount: 0,
                    earning: earning
                });
                validatorDelegateMap.set(validator, delegateFailed, true);
            }
        }
        return success;
    }

    // Delegate may generate income
    function _delegate(address validator, uint256 amount) internal returns (bool) {
        uint256 balanceBefore = address(this).balance - amount;
        bytes memory callData = abi.encodeWithSignature("delegateCoin(address)", validator);
        (bool success, ) = PLEDGE_AGENT.call{value: amount}(callData);
        if (success) {
            uint256 balanceAfter = address(this).balance;
            uint256 earning = balanceAfter - balanceBefore;
            if (earning > 0) {
                DelegateInfo memory delegateFailed = DelegateInfo({
                    amount: 0,
                    earning: earning
                });
                validatorDelegateMap.set(validator, delegateFailed, true);
            }

            DelegateAction memory action = DelegateAction({
                validator: validator,
                amount: amount
            });
            delegateQueue.enqueue(action);
        }
        return success;
    }

    function _claim(address validator) internal returns (bool){
        address[] memory addresses = new address[](1);
        addresses[0] = validator;
        bytes memory callData = abi.encodeWithSignature("claimReward(address[])", addresses);
        (bool success, ) = PLEDGE_AGENT.call(callData);
        return success;
    }

    function _adjustDelegateMap(address validator, uint256 amount) internal {
        if (!validatorDelegateMap.exist(validator)) {
            revert IEarnErrors.EarnDelegateInfoNotExist(validator, amount);
        }

        DelegateInfo memory delegateInfo = validatorDelegateMap.get(validator);
        if (delegateInfo.amount == amount) {
            // The amount recorded by the validator is equal to undelegate amount
            validatorDelegateMap.remove(validator);
        } else if (delegateInfo.amount > amount) {
            // The amount recorded by the validator is greater than undelegate amount
            DelegateInfo memory unDelegateInfo = DelegateInfo({
                amount: amount,
                earning: 0
            });
            validatorDelegateMap.set(validator, unDelegateInfo, false);
        } else {
            // The amount recorded by the validator is less than undelegate amount, revert
            revert IEarnErrors.EarnInsufficientUndelegateAmount(validator, amount);
        }
    }

    // Invest or Donate
    receive() external payable {}
}