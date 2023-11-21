// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IAfterTurnRoundCallBack.sol";
import {IEarnErrors} from "./interface/IErrors.sol";
import "./lib/IterableAddressDelegateMapping.sol";
import "./lib/Structs.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interface/IValidatorSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract Earn is IAfterTurnRoundCallBack, ReentrancyGuard, Ownable, Pausable {
    using IterableAddressDelegateMapping for IterableAddressDelegateMapping.Map;
    using Address for address payable;

    // Exchange rate multiple
    uint16 constant private RATE_MULTIPLE = 10000; 

    // Address of system contract: ValidatorSet
    IValidatorSet constant private VALIDATOR_SET =  IValidatorSet(0x0000000000000000000000000000000000001000);

    // Address of system contract: PledgeAgent
    address constant private PLEDGE_AGENT = payable(0x0000000000000000000000000000000000001007);

    // Address of system contract: Registry
    address constant private REGISTRY = 0x0000000000000000000000000000000000001010;

    // Address of stcore contract: STCore
    address private STCORE; 

    // Exchange Rate per round 
    // uint256 public exchangeRate = RATE_MULTIPLE;
    uint256[] public exchangeRates;

    // Map of the amount pledged by the validator
    IterableAddressDelegateMapping.Map private validatorDelegateMap;

    // The time locked when user redeem Core
    uint256 public lockDay = 7;
    uint256 public constant INIT_DAY_INTERVAL = 86400;

    // Account redeem record
    uint256 public uniqueIndex = 1;
    mapping(address => RedeemRecord[]) private redeemRecords;

    uint256 public balanceThreshold = 10000 ether;
    uint256 public delegateMinLimit = 1 ether;
    uint256 public redeemMinLimit = 1 ether;
    uint256 public pledgeAgentLimit = 1 ether;

    constructor(address _stCore) {
        STCORE = _stCore;
        exchangeRates.push(RATE_MULTIPLE);
    }

    modifier onlyRegistry() {
        require(msg.sender == REGISTRY, "Not registry contract");
        _;
    }
    
    // Proxy user pledge, at the same time exchange STCore
    function mint() public payable nonReentrant whenNotPaused{
        address account = msg.sender;
        uint256 amount = msg.value;

        // Determine the minimum amount to pledge
        if (amount < delegateMinLimit) {
            revert IEarnErrors.EarnInvalidDelegateAmount(account, amount);
        }

        // Select validator at random
        address[] memory validatorSet = _getValidators();
        if (validatorSet.length == 0) {
            revert IEarnErrors.EarnEmptyValidatorSet();
        }
        uint256 index = _randomIndex(validatorSet.length);
        address validator = validatorSet[index];

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
    function afterTurnRound() public override onlyRegistry {
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
                if(delegateInfo.earning > pledgeAgentLimit) {
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
    function redeem(uint256 stCore) public nonReentrant whenNotPaused{
         address account = msg.sender;

        // The amount exchanged must not be less than 1 ether
        if (stCore < redeemMinLimit) {
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
        _unDelegateWithStrategy(core);

        // Record the redemption record of the user with lock
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

    // The user redeems the unlocked Core
    function withdraw(uint256 identity) public nonReentrant whenNotPaused{
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
                break;
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
        payable(account).sendValue(amount);
    }

    function beforeTurnRound() public onlyRegistry{
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

        // Transfer coin
        uint256 average = (max - min) / 2;
        _transfer(maxValidator, minValidator, average);
        DelegateInfo memory transferInfo = DelegateInfo({
            amount: average,
            earning: 0
        });
        validatorDelegateMap.set(maxValidator, transferInfo, false);
        validatorDelegateMap.set(minValidator, transferInfo, true);
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

    // Undelegate stragety
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

            // If delegate amount equals zero, indicates this item to be deleted later
            if (delegateInfo.amount > 0) {
                if (delegateInfo.amount == amount) {
                    // Delegate amount just covers undelegate amount
                    DelegateInfo memory unDelegateInfo = DelegateInfo({
                        amount: amount,
                        earning: 0
                    });
                    validatorDelegateMap.set(key, unDelegateInfo, false);
                    amount = 0;
                    _unDelegate(key, amount);
                    break;
                } else if (delegateInfo.amount > amount) {
                    // Delegate amount more than undelegate amount
                    if (delegateInfo.amount >= amount + pledgeAgentLimit) {
                        // Delegate amount fully covers undelegate amount
                        DelegateInfo memory unDelegateInfo = DelegateInfo({
                            amount: amount,
                            earning: 0
                        });
                        validatorDelegateMap.set(key, unDelegateInfo, false);
                        amount = 0;
                        _unDelegate(key, amount);
                        break;
                    } else {
                        uint256 delegateAmount = amount - pledgeAgentLimit;
                        uint256 delegatorLeftAmount = delegateInfo.amount - delegateAmount;
                        if (delegateAmount > pledgeAgentLimit && delegatorLeftAmount > pledgeAgentLimit) {
                            DelegateInfo memory unDelegateInfo = DelegateInfo({
                                amount: delegateAmount,
                                earning: 0
                            });
                            validatorDelegateMap.set(key, unDelegateInfo, false);
                            amount -= delegateAmount; // amount equals to 1 ether
                            _unDelegate(key, delegateAmount);
                        }
                    }
                } else {
                    // Delegate amount less than undelegate amount
                    if (amount >= delegateInfo.amount + pledgeAgentLimit) {
                        DelegateInfo memory unDelegateInfo = DelegateInfo({
                            amount: delegateInfo.amount,
                            earning: 0
                        });
                        validatorDelegateMap.set(key, unDelegateInfo, false);
                        amount -= delegateInfo.amount;
                        _unDelegate(key, delegateInfo.amount);
                    } else {
                        uint256 delegateAmount = delegateInfo.amount - pledgeAgentLimit;
                        uint256 accountLeftAmount = amount - delegateAmount;
                        if (delegateAmount > pledgeAgentLimit && accountLeftAmount > pledgeAgentLimit) {
                            DelegateInfo memory unDelegateInfo = DelegateInfo({
                                amount: delegateAmount,
                                earning: 0
                            });
                            validatorDelegateMap.set(key, unDelegateInfo, false);
                            amount -= delegateAmount;
                            _unDelegate(key, delegateAmount);
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

        // Undelegate failed
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

    // Undelegate may generate income
    function _unDelegate(address validator, uint256 amount) internal returns (bool) {
        uint256 balanceBefore = address(this).balance;
        bytes memory callData = abi.encodeWithSignature("undelegateCoin(address,uint256)", validator, amount);
        (bool success, ) = PLEDGE_AGENT.call(callData);
        if (success) {
            uint256 balanceAfter = address(this).balance - amount;
            uint256 earning = balanceAfter - balanceBefore;
            if (earning > 0) {
                DelegateInfo memory unprocessedReward = DelegateInfo({
                    amount: 0,
                    earning: earning
                });
                validatorDelegateMap.set(validator, unprocessedReward, true);
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
                DelegateInfo memory unprocessedReward = DelegateInfo({
                    amount: 0,
                    earning: earning
                });
                validatorDelegateMap.set(validator, unprocessedReward, true);
            }
        }
        return success;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 balanceBefore = address(this).balance;
        bytes memory callData = abi.encodeWithSignature("transferCoin(address,address,uint256)", from, to, amount);
        (bool success, ) = PLEDGE_AGENT.call(callData);
        if (success) {
             uint256 balanceAfter = address(this).balance;
            uint256 earning = balanceAfter - balanceBefore;
            if (earning > 0) {
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
        return VALIDATOR_SET.getValidators();
    }

    function voteBalanceThreshold(uint256 _balanceThreshold) public onlyOwner {
        balanceThreshold = _balanceThreshold;
    }

    function voteDelegateMinLimit(uint256 _delegateMinLimit) public onlyOwner {
        delegateMinLimit = _delegateMinLimit;
    }

    function voteRedeemMinLimit(uint256 _redeemMinLimit) public onlyOwner {
        redeemMinLimit = _redeemMinLimit;
    }

    function votePledgeAgentLimit(uint256 _pledgeAgentLimit) public onlyOwner {
        pledgeAgentLimit = _pledgeAgentLimit;
    }

    function voteLockDay(uint256 _lockDay) public onlyOwner {
        lockDay = _lockDay;
    }

    // Invest or Donate
    receive() external payable {}
}