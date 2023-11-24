// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IValidatorSet.sol";
import {IEarnErrors} from "./interface/IErrors.sol";
import "./interface/ICandidateHub.sol";

import "./lib/IterableAddressDelegateMapping.sol";
import "./lib/Structs.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract Earn is ReentrancyGuard, Ownable, Pausable {
    using IterableAddressDelegateMapping for IterableAddressDelegateMapping.Map;
    using Address for address payable;

    // Exchange rate base
    uint256 constant private RATE_BASE = 1000000; 

    // Address of system contract: CandidateHub
    address constant private CANDIDATE_HUB = 0x0000000000000000000000000000000000001005; 

    // Address of system contract: PledgeAgent
    address constant private PLEDGE_AGENT = payable(0x0000000000000000000000000000000000001007);

    // Address of stCORE contract: STCORE
    address public STCORE; 

    // Exchange rate (conversion rate) of each round
    // Exchange rate is calculated and updated at the beginning of each round
    uint256[] public exchangeRates;

    // Delegate records on each validator from the Earn contract
    IterableAddressDelegateMapping.Map private validatorDelegateMap;

    // redemption period
    // It takes 7 days for users to get CORE back from Earn after requesting redeem
    uint256 public lockDay = 7;
    uint256 public constant INIT_DAY_INTERVAL = 86400;

    // Redeem records are saved for each user
    // The records been withdrawn are removed to improve iteration performance
    uint256 public uniqueIndex = 1;
    mapping(address => RedeemRecord[]) private redeemRecords;

    // The threshold to tigger rebalance in beforeTurnRound()
    uint256 public balanceThreshold = 10000 ether;

    // Dues protections
    uint256 public mintMinLimit = 1 ether;
    uint256 public redeemMinLimit = 1 ether;
    uint256 public pledgeAgentLimit = 1 ether;

    // Protocal fee foints and fee receiver
    // Set 0 ~ 1000000
    // 100000 = 10%
    uint256 public protocolFeePoints = 0;
    address public protocolFeeReceiver;

    // Operate afterRound and rebalance
    address public operator;
    uint256 public lastOperateRound;

    constructor(address _stCore) {
        STCORE = _stCore;
        exchangeRates.push(RATE_BASE);
        lastOperateRound = _currentRound();
    }

    /// --- MODIFIERS --- ///

    modifier onlyOperator() {
        require(msg.sender == operator, "Not Operator");
        _;
    }

    modifier afterSettled() {
        require(lastOperateRound == _currentRound(), "Wait to after round");
        _;
    }
    
    /// --- USER INTERACTIONS --- ///

    // Mint stCORE using CORE 
    function mint(address validator) public payable afterSettled nonReentrant whenNotPaused{
        address account = msg.sender;
        uint256 amount = msg.value;

        // dues protection 
        if (amount < mintMinLimit) {
            revert IEarnErrors.EarnInvalidDelegateAmount(account, amount);
        }

        // validator address protection
        if (validator == address(0)) {
            revert IEarnErrors.EarnInvalidValidator(validator);
        }

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
    function redeem(uint256 stCore) public afterSettled nonReentrant whenNotPaused{
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

        // Calculate protocal fee
        uint256 protocalFee = core * protocolFeePoints / RATE_BASE;
        // Transfer protocalFee to fee receiver
        if (protocalFee > 0) {
            if (protocolFeeReceiver == address(0)) {
                revert IEarnErrors.EarnInvalidProtocalFeeReceiver(address(0));
            }
            payable(protocolFeeReceiver).sendValue(protocalFee);
        }

        // Update local records
        RedeemRecord memory redeemRecord = RedeemRecord({
            identity : uniqueIndex++,
            redeemTime: block.timestamp,
            unlockTime: block.timestamp + INIT_DAY_INTERVAL * lockDay,
            amount: core - protocalFee,
            stCore: stCore
        });
        RedeemRecord[] storage records = redeemRecords[account];
        records.push(redeemRecord);
    }

    // Withdraw/claim CORE tokens after redemption period
    function withdraw(uint256 identity) public afterSettled nonReentrant whenNotPaused{
        address account = msg.sender;
        
        // The ID of the redeem record must not be less than 1 
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
                    // In redemption period, revert
                    revert IEarnErrors.EarnRedeemLocked(account, record.unlockTime, block.timestamp);
                }
                // Passed redemption period, eligible to withdraw
                index = i;
                amount = record.amount;
                break;
            }
        }

        // redeem record not found
        if (!findRecord) {
            revert IEarnErrors.EarnInvalidRedeemRecordId(account, identity);
        }

        // Drop redeem record, and transfer CORE to user
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
    function afterTurnRound() public onlyOperator {
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

        // set last operate round to current round tag
        lastOperateRound = _currentRound();
    }

    // Triggered right before turn round
    // This method cannot revert
    // The Earn contract rebalances staking on top/bottom validators in this method
    function reBalance() public afterSettled onlyOperator{
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
        if (average >= pledgeAgentLimit && max - average >= pledgeAgentLimit) {
            _unDelegate(maxValidator, average);
            _delegate(minValidator, average);

            DelegateInfo memory transferInfo = DelegateInfo({
                amount: average,
                earning: 0
            });
            validatorDelegateMap.set(maxValidator, transferInfo, false);
            validatorDelegateMap.set(minValidator, transferInfo, true);
        }
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


    // Get current round
    function _currentRound() internal view returns (uint256) {
        return ICandidateHub(CANDIDATE_HUB).getRoundTag();
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
                    bool success = _unDelegate(key, amount);
                    if (!success) {
                        revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                    }
                    amount = 0;
                    validatorDelegateMap.set(key, unDelegateInfo, false);
                    break;
                } else if (delegateInfo.amount > amount) {
                    if (delegateInfo.amount >= amount + pledgeAgentLimit) {
                    // Case 2: the amount available on the validator >= the amount needs to be undelegated + 1
                    // Undelegate all the tokens from the validator
                        DelegateInfo memory unDelegateInfo = DelegateInfo({
                            amount: amount,
                            earning: 0
                        });
                        bool success = _unDelegate(key, amount);
                        if (!success) {
                            revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                        }
                        amount = 0;
                        validatorDelegateMap.set(key, unDelegateInfo, false);
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
                            bool success = _unDelegate(key, delegateAmount);
                            if (!success) {
                                revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                            }
                            amount -= delegateAmount; // amount equals to 1 ether
                            validatorDelegateMap.set(key, unDelegateInfo, false);
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
                        bool success = _unDelegate(key, delegateInfo.amount);
                        if (!success) {
                            revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                        }
                        amount -= delegateInfo.amount;
                        validatorDelegateMap.set(key, unDelegateInfo, false);
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
                            bool success = _unDelegate(key, delegateAmount);
                            if (!success) {
                                revert IEarnErrors.EarnUnDelegateFailed(msg.sender, amount);
                            }
                            amount -= delegateAmount;
                            validatorDelegateMap.set(key, unDelegateInfo, false);
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

    /// --- ADMIN OPERATIONS --- ///

    function updateBalanceThreshold(uint256 _balanceThreshold) public onlyOwner {
        balanceThreshold = _balanceThreshold;
    }

    function updateMintMinLimit(uint256 _mintMinLimit) public onlyOwner {
        mintMinLimit = _mintMinLimit;
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

    function updateProtocolFeePoints(uint256 _protocolFeePoints) public onlyOwner {
        if (_protocolFeePoints > RATE_BASE) {
            revert IEarnErrors.EarnProtocalFeePointMoreThanRateBase(_protocolFeePoints);
        }
        protocolFeePoints = _protocolFeePoints;
    }

    function updateProtocolFeeReveiver(address _protocolFeeReceiver) public onlyOwner {
        // validator address protection
        if (_protocolFeeReceiver == address(0)) {
            revert IEarnErrors.EarnInvalidProtocalFeeReceiver(_protocolFeeReceiver);
        }
        protocolFeeReceiver = _protocolFeeReceiver;
    }

    function updateOperator(address _operator) public onlyOwner {
        if (_operator == address(0)) {
            revert IEarnErrors.EarnInvalidOperator(_operator);
        }
        operator = _operator;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    receive() external payable {}
}