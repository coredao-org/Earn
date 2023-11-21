// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IAfterTurnRoundCallBack.sol";
import "./interface/IValidatorSet.sol";
import "./interface/IBeforeTurnRoundCallback.sol";
import {IEarnErrors} from "./interface/IErrors.sol";

import "./lib/IterableAddressDelegateMapping.sol";
import "./lib/Structs.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract Earn is IBeforeTurnRoundCallBack, IAfterTurnRoundCallBack, ReentrancyGuard, Ownable, Pausable {
    using IterableAddressDelegateMapping for IterableAddressDelegateMapping.Map;
    using Address for address payable;

    // Exchange rate base
    uint16 constant private RATE_BASE = 10000; 

    // Address of system contract: ValidatorSet
    IValidatorSet constant private VALIDATOR_SET = IValidatorSet(0x0000000000000000000000000000000000001000);

    // Address of system contract: PledgeAgent
    address constant private PLEDGE_AGENT = payable(0x0000000000000000000000000000000000001007);

    // Address of system contract: Registry
    address constant private REGISTRY = 0x0000000000000000000000000000000000001010;

    // Address of stCORE contract: STCORE
    address private STCORE; 

    // Exchange rate (conversion rate) of each round
    // Exchange rate is calculated and updated at the beginning of each round
    uint256[] public exchangeRates;

    // Delegation records on each validator from the Earn contract
    IterableAddressDelegateMapping.Map private validatorDelegateMap;

    // Redemption period
    // It takes 7 days for users to get CORE back from Earn after requesting redemption
    uint256 public lockDay = 7;
    uint256 public constant INIT_DAY_INTERVAL = 86400;

    // Redemption records are saved for each user
    // The records been withdrawn are removed to improve iteration performance
    uint256 public uniqueIndex = 1;
    mapping(address => RedeemRecord[]) private redeemRecords;

    // The threshold to tigger rebalance in beforeTurnRound()
    uint256 public balanceThreshold = 10000 ether;
    uint256 public delegateMinLimit = 1 ether;
    uint256 public redeemMinLimit = 1 ether;
    uint256 public pledgeAgentLimit = 1 ether;

    constructor(address _stCore) {
        STCORE = _stCore;
        exchangeRates.push(RATE_BASE);
    }

    /// --- MODIFIERS --- ///

    modifier onlyRegistry() {
        require(msg.sender == REGISTRY, "Not REGISTRY contract");
        _;
    }
    
    /// --- USER INTERACTIONS --- ///

    // Mint stCORE using CORE 
    function mint() public payable nonReentrant whenNotPaused{
        address account = msg.sender;
        uint256 amount = msg.value;

        // dues protection 
        if (amount < delegateMinLimit) {
            revert IEarnErrors.EarnInvalidDelegateAmount(account, amount);
        }

        // Select a validator randomly
        address[] memory validatorSet = _getValidators();
        if (validatorSet.length == 0) {
            revert IEarnErrors.EarnEmptyValidatorSet();
        }
        uint256 index = _randomIndex(validatorSet.length);
        address validator = validatorSet[index];

        // Delegate CORE to PledgeAgent
        bool success = _delegate(validator, amount);
        if (!success) {
            revert IEarnErrors.EarnDelegateFailed(account, validator,amount);
        }

        // Update local records
         DelegateInfo memory delegateInfo = DelegateInfo({
            amount: amount,
            earning: 0
        });
        validatorDelegateMap.set(validator, delegateInfo, true);

        // Mint stCORE and send to users
        uint256 stCore = _exchangeSTCore(amount);
        bytes memory callData = abi.encodeWithSignature("mint(address,uint256)", account, stCore);
        (success, ) = STCORE.call(callData);
        if (!success) {
            revert IEarnErrors.EarnMintFailed(account, amount, stCore);
        }
    }

    // Redeem stCORE to get back CORE
    function redeem(uint256 stCore) public nonReentrant whenNotPaused{
         address account = msg.sender;

        // Dues protection
        if (stCore < redeemMinLimit) {
            revert IEarnErrors.EarnInvalidExchangeAmount(account, stCore);
        }
       
        uint256 core = _exchangeCore(stCore);
        if (core <= 0) {
            revert IEarnErrors.EarnInvalidExchangeAmount(account, stCore);
        }

        // Burn stCORE
        uint256 totalSupply = IERC20(STCORE).totalSupply();
        if (stCore > totalSupply) {
            // Should not happen
            revert IEarnErrors.EarnERC20InsufficientTotalSupply(account, stCore, totalSupply);
        }
        bytes memory callData = abi.encodeWithSignature("burn(address,uint256)", account, stCore);
        (bool success, ) = STCORE.call(callData);
        if (!success) {
            revert IEarnErrors.EarnBurnFailed(account, core, stCore);
        }

        // Undelegate CORE from validators
        _unDelegateWithStrategy(core);

        // Update local records
        RedeemRecord memory redeemRecord = RedeemRecord({
            identity : uniqueIndex++,
            redeemTime: block.timestamp,
            unlockTime: block.timestamp + INIT_DAY_INTERVAL * lockDay,
            amount: core,
            stCore: stCore
        });
        RedeemRecord[] storage records = redeemRecords[account];
        records.push(redeemRecord);
    }

    // Withdraw/claim CORE tokens after redemption period
    function withdraw(uint256 identity) public nonReentrant whenNotPaused{
        address account = msg.sender;
        
        // The ID of the redemption record must not be less than 1 
        if (identity < 1) {
            revert IEarnErrors.EarnInvalidRedeemRecordId(account, identity);
        }

        // Find user redemption records
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
                // Find redemption record
                if (!findRecord) {
                    findRecord = true;
                }
                if (record.unlockTime >= block.timestamp) {
                    // In redemption period, revert
                    revert IEarnErrors.EarnRedeemLocked(account, record.unlockTime, block.timestamp);
                }
                // Passed redemption period, eligible to withdraw
                index = i;
                amount = record.amount;
                break;
            }
        }

        // redemption record not found
        if (!findRecord) {
            revert IEarnErrors.EarnInvalidRedeemRecordId(account, identity);
        }

        // Drop redemption record, and transfer CORE to user
        for (uint i = index; i < records.length - 1; i++) {
            records[i] = records[i + 1];
        }
        records.pop();
        if (address(this).balance < amount) {
            revert IEarnErrors.EarnInsufficientBalance(address(this).balance, amount);
        }
        payable(account).sendValue(amount);
    }

    /// --- SYSTEM HOOKS --- ///

    // Triggered right after turn round
    // This method cannot revert
    // The Earn contract does following in this method
    //  1. Claim rewards from each validator
    //  2. Stake rewards back to corresponding validators (auto compounding)
    //  3. Update daily exchange rate
    function afterTurnRound() public override onlyRegistry {
        // Claim rewards
        for (uint i = 0; i < validatorDelegateMap.size(); i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo storage delegateInfo = validatorDelegateMap.get(key);

            uint256 balanceBeforeClaim = address(this).balance;
            bool success = _claim(key);
            if (success) {
                uint256 balanceAfterClaim = address(this).balance;
                uint256 _earning = balanceAfterClaim - balanceBeforeClaim;
                delegateInfo.earning += _earning;
            } 
        }

        // Delegate rewards
        // Auto compounding
        for (uint i = 0; i < validatorDelegateMap.size(); i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo storage delegateInfo = validatorDelegateMap.get(key);

            if (delegateInfo.earning > 0) {
                if(delegateInfo.earning > pledgeAgentLimit) {
                    uint256 delegateAmount = delegateInfo.earning;
                    bool success = _delegate(key, delegateAmount);
                    if (success) {
                        delegateInfo.amount += delegateAmount;
                        delegateInfo.earning -= delegateAmount;
                    } 
                } 
            }
        }

        // Update exchange rate
        uint256 totalSupply = IERC20(STCORE).totalSupply();
        if (totalSupply > 0) {
            uint256 _capital = 0;
            for (uint i = 0; i < validatorDelegateMap.size(); i++) {
                address key = validatorDelegateMap.getKeyAtIndex(i);
                DelegateInfo memory delegateInfo = validatorDelegateMap.get(key);
                _capital += delegateInfo.amount;
            }
            if (_capital > 0) {
                exchangeRates.push(_capital * RATE_BASE / totalSupply);
            }
        }
    }

    // Triggered right before turn round
    // This method cannot revert
    // The Earn contract rebalances staking on top/bottom validators in this method
    function beforeTurnRound() public override onlyRegistry{
        if (validatorDelegateMap.size() == 0) {
            return;
        }

        address key = validatorDelegateMap.getKeyAtIndex(0);
        DelegateInfo memory delegateInfo = validatorDelegateMap.get(key);

        // Find max and min delegate amount of validator
        uint256 max = delegateInfo.amount;
        address maxValidator = key;
        uint256 min = delegateInfo.amount;
        address minValidator = key;
        for (uint i = 1; i < validatorDelegateMap.size(); i++) {
            key = validatorDelegateMap.getKeyAtIndex(i);
            delegateInfo = validatorDelegateMap.get(key);
            if (delegateInfo.amount > max) {
                max = delegateInfo.amount;
                maxValidator = key;
            } else if (delegateInfo.amount < min) {
                min = delegateInfo.amount;
                minValidator = key;
            }
        }

        if (minValidator == maxValidator) {
            return;
        }

        if (max - min < balanceThreshold) {
            return;
        }

        // Transfer CORE to rebalance
        uint256 average = (max - min) / 2;
        _transfer(maxValidator, minValidator, average);
        DelegateInfo memory transferInfo = DelegateInfo({
            amount: average,
            earning: 0
        });
        validatorDelegateMap.set(maxValidator, transferInfo, false);
        validatorDelegateMap.set(minValidator, transferInfo, true);
    }

    /// --- VIEW METHODS ---///
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

    /// --- INTERNAL METHODS --- ///

    // Core to STCore
    function _exchangeSTCore(uint256 core) internal view returns (uint256) {
        return core * RATE_BASE / exchangeRates[exchangeRates.length-1];
    }

    // STCore to Core
    function _exchangeCore(uint256 stCore) internal view returns(uint256) {
        return stCore * exchangeRates[exchangeRates.length-1] / RATE_BASE;
    }

    // Delegate to validator
    function _delegate(address validator, uint256 amount) internal returns (bool) {
        uint256 balanceBefore = address(this).balance - amount;
        bytes memory callData = abi.encodeWithSignature("delegateCoin(address)", validator);
        (bool success, ) = PLEDGE_AGENT.call{value: amount}(callData);
        if (success) {
            uint256 balanceAfter = address(this).balance;
            uint256 earning = balanceAfter - balanceBefore;
            if (earning > 0) {
                // This shall not happen as all rewards are claimed in afterTurnRound()
                // Only for unexpected cases
                DelegateInfo memory unprocessedReward = DelegateInfo({
                    amount: 0,
                    earning: earning
                });
                validatorDelegateMap.set(validator, unprocessedReward, true);
            }
        }
        return success;
    }

    // Undelegate CORE from validators with strategy
    // There is dues protection in PledageAgent, which are
    //  1. Can only delegate 1+ CORE
    //  2. Can only undelegate 1+ CORE AND can only leave 1+ CORE on validator after undelegate 
    // Internally, Earn delegate/undelegate to validators on each mint/redeem action
    // As a result, to make the system solid. For any undelegate action from Earn it must result in
    //  1. The validator must be cleared or have 1+ CORE remaining after undelegate AND
    //  2. Earn contract must have 0 or 1+ CORE on any validator after undelegate
    // Otherwise, Earn might fail to undelegate further because of the dues protection from PledgeAgent
    function _unDelegateWithStrategy(uint256 amount) internal {
        // Random validator position
        uint256 length = validatorDelegateMap.size();
        if (length == 0) {
            revert IEarnErrors.EarnEmptyValidator();
        }
        uint256 fromIndex = _randomIndex(length);

        bool reachedEnd = false;
        uint256 index = fromIndex;
        while(!(index == fromIndex && reachedEnd) && amount > 0) {
            address key = validatorDelegateMap.getKeyAtIndex(index);
            DelegateInfo storage delegateInfo = validatorDelegateMap.get(key);

            if (delegateInfo.amount > 0) {
                if (delegateInfo.amount == amount) {
                    // Case 1: the amount available on the validator == the amount needs to be undelegated
                    // Undelegate all the tokens from the validator
                    DelegateInfo memory unDelegateInfo = DelegateInfo({
                        amount: amount,
                        earning: 0
                    });
                    validatorDelegateMap.set(key, unDelegateInfo, false);
                    bool success = _unDelegate(key, amount);
                    if (!success) {
                        revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                    }
                    amount = 0;
                    break;
                } else if (delegateInfo.amount > amount) {
                    if (delegateInfo.amount >= amount + pledgeAgentLimit) {
                    // Case 2: the amount available on the validator >= the amount needs to be undelegated + 1
                    // Undelegate all the tokens from the validator
                        DelegateInfo memory unDelegateInfo = DelegateInfo({
                            amount: amount,
                            earning: 0
                        });
                        validatorDelegateMap.set(key, unDelegateInfo, false);
                        bool success = _unDelegate(key, amount);
                        if (!success) {
                            revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                        }
                        amount = 0;
                        break;
                    } else {
                        // Case 3: the amount available on the validator >= the amount needs to be undelegated AND
                        //          the amount available on the validator <= the amount needs to be undelegated + 1
                        // In this case we need to make sure there are 1 CORE token left on user side so both 
                        //   the validator and user are safe on the PledgeAgent dues protection
                        uint256 delegateAmount = amount - pledgeAgentLimit;
                        uint256 delegatorLeftAmount = delegateInfo.amount - delegateAmount;
                        if (delegateAmount > pledgeAgentLimit && delegatorLeftAmount > pledgeAgentLimit) {
                            DelegateInfo memory unDelegateInfo = DelegateInfo({
                                amount: delegateAmount,
                                earning: 0
                            });
                            validatorDelegateMap.set(key, unDelegateInfo, false);
                            bool success = _unDelegate(key, delegateAmount);
                            if (!success) {
                                revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                            }
                            amount -= delegateAmount; // amount equals to 1 ether
                        }
                    }
                } else {
                    if (amount >= delegateInfo.amount + pledgeAgentLimit) {
                        // Case 4: the amount available on the validator <= the amount needs to be undelegated - 1
                        // Clear the validator and move to the next one
                        DelegateInfo memory unDelegateInfo = DelegateInfo({
                            amount: delegateInfo.amount,
                            earning: 0
                        });
                        validatorDelegateMap.set(key, unDelegateInfo, false);
                        bool success = _unDelegate(key, delegateInfo.amount);
                        if (!success) {
                            revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                        }
                        amount -= delegateInfo.amount;
                    } else {
                        // Case 5: the amount available on the validator >= the amount needs to be undelegated - 1 AND
                        //          the amount available on the validator <= the amount needs to be undelegated
                        // In this case we need to make sure there are 1 CORE token left on validator side so both 
                        //   the validator and user are safe on the PledgeAgent dues protection
                        uint256 delegateAmount = delegateInfo.amount - pledgeAgentLimit;
                        uint256 accountLeftAmount = amount - delegateAmount;
                        if (delegateAmount > pledgeAgentLimit && accountLeftAmount > pledgeAgentLimit) {
                            DelegateInfo memory unDelegateInfo = DelegateInfo({
                                amount: delegateAmount,
                                earning: 0
                            });
                            validatorDelegateMap.set(key, unDelegateInfo, false);
                            bool success = _unDelegate(key, delegateAmount);
                            if (!success) {
                                revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                            }
                            amount -= delegateAmount;
                        }
                    }
                }
            }

            if (index == length - 1) {
                index = 0;
                reachedEnd = true;
            } else {
                index++;
            }
        }

        // Earn protocol is insolvency
        // In theory this could not happen if Earn is funded before open to public
        if (amount > 0) {
             revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
        }

        // Remove empty validator
        uint256 deleteSize = 0;
        address[] memory deleteKeys = new address[](validatorDelegateMap.size());
        for (uint i = 0; i < validatorDelegateMap.size(); i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo memory delegateInfo = validatorDelegateMap.get(key);
            if (delegateInfo.amount == 0 && delegateInfo.earning == 0) {
                deleteKeys[deleteSize] = key;
                deleteSize++;
            }
        }
        for (uint i = 0; i < deleteSize; i++) {
            validatorDelegateMap.remove(deleteKeys[i]);
        }
    }

    // Undelegate from a validator
    function _unDelegate(address validator, uint256 amount) internal returns (bool) {
        uint256 balanceBefore = address(this).balance;
        bytes memory callData = abi.encodeWithSignature("undelegateCoin(address,uint256)", validator, amount);
        (bool success, ) = PLEDGE_AGENT.call(callData);
        if (success) {
            uint256 balanceAfter = address(this).balance - amount;
            uint256 earning = balanceAfter - balanceBefore;
            if (earning > 0) {
                // This shall not happen as all rewards are claimed in afterTurnRound()
                // Only for unexpected cases
                DelegateInfo memory unprocessedReward = DelegateInfo({
                    amount: 0,
                    earning: earning
                });
                validatorDelegateMap.set(validator, unprocessedReward, true);
            }
        }
        return success;
    }

    // Transfer delegates between validators
    function _transfer(address from, address to, uint256 amount) internal {
        uint256 balanceBefore = address(this).balance;
        bytes memory callData = abi.encodeWithSignature("transferCoin(address,address,uint256)", from, to, amount);
        (bool success, ) = PLEDGE_AGENT.call(callData);
        if (success) {
             uint256 balanceAfter = address(this).balance;
            uint256 earning = balanceAfter - balanceBefore;
            if (earning > 0) {
                // This shall not happen as all rewards are claimed in afterTurnRound()
                // Only for unexpected cases
                DelegateInfo memory unprocessedReward = DelegateInfo({
                    amount: 0,
                    earning: earning
                });
                validatorDelegateMap.set(from, unprocessedReward, true);
            }
        }
    }

    function _claim(address validator) internal returns (bool){
        address[] memory addresses = new address[](1);
        addresses[0] = validator;
        bytes memory callData = abi.encodeWithSignature("claimReward(address[])", addresses);
        (bool success, ) = PLEDGE_AGENT.call(callData);
        return success;
    }

    function _randomIndex(uint256 length) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp))) % length;
    }

    function _getValidators() internal view returns (address[] memory) {
        return VALIDATOR_SET.getOperates();
    }

    /// --- ADMIN OPERATIONS --- ///

    function updateBalanceThreshold(uint256 _balanceThreshold) public onlyOwner {
        balanceThreshold = _balanceThreshold;
    }

    function updateDelegateMinLimit(uint256 _delegateMinLimit) public onlyOwner {
        delegateMinLimit = _delegateMinLimit;
    }

    function updateRedeemMinLimit(uint256 _redeemMinLimit) public onlyOwner {
        redeemMinLimit = _redeemMinLimit;
    }

    function updatePledgeAgentLimit(uint256 _pledgeAgentLimit) public onlyOwner {
        pledgeAgentLimit = _pledgeAgentLimit;
    }

    function udpateLockDay(uint256 _lockDay) public onlyOwner {
        lockDay = _lockDay;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    receive() external payable {}
}