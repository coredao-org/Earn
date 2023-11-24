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

    // Protocol fee foints and fee receiver
    // Set 0 ~ 1000000
    // 100000 = 10%
    uint256 public protocolFeePoints = 0;
    address public protocolFeeReceiver;

    // Operate afterRound and rebalance
    address public operator;
    uint256 public lastOperateRound;

    // User operations event
    event Mint(address account, uint256 core, uint256 stCore);
    event Delegate(address validator, uint256 amount);
    event UnDelegate(address validator, uint256);
    event Transfer(address from, address to, uint256 amount);
    event Redeem(address account, uint256 stCore, uint256 core, uint256 protocolFee);
    event Withdraw(address account, uint256 amount);

    // Operator operations event
    event CalculateExchangeRate(uint256 round, uint256 exchangeRate);
    event ReBalance(address from, address to, uint256 amount);

    // Admin operations event
    event UpdateBalanceThreshold(address caller, uint256 balanceThreshold);
    event UpdateMintMinLimit(address caller, uint256 mintMinLimit);
    event UpdateRedeemMinLimit(address caller, uint256 redeemMinLimit);
    event UpdatePledgeAgentLimit(address caller, uint256 pledgeAgentLimit);
    event UdpateLockDay(address caller, uint256 lockDay);
    event UpdateProtocolFeePoints(address caller, uint256 protocolFeePoints);
    event UpdateProtocolFeeReveiver(address caller, address protocolFeeReceiver);
    event UpdateOperator(address caller, address _operator);

    constructor(address _stCore, address _protocolFeeReceiver, address _operator) {
        // protocol fee receiver address protection
        if (_protocolFeeReceiver == address(0)) {
            revert IEarnErrors.EarnZeroProtocolFeeReceiver(_protocolFeeReceiver);
        }

        // operator address protection
        if (_operator == address(0)) {
            revert IEarnErrors.EarnZeroOperator(_operator);
        }

        STCORE = _stCore;
        exchangeRates.push(RATE_BASE);
        lastOperateRound = _currentRound();
        protocolFeeReceiver = _protocolFeeReceiver;
        operator = _operator;
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
            revert IEarnErrors.EarnMintAmountTooSmall(account, amount);
        }

        // validator address protection
        if (validator == address(0)) {
            revert IEarnErrors.EarnZeroValidator(validator);
        }

        // check validator can be delegated
        if (!ICandidateHub(CANDIDATE_HUB).canDelegate(validator)) {
            revert IEarnErrors.EarnCanNotDelegateValidator(validator);
        }

        // Delegate CORE to PledgeAgent
        bool success = _delegate(validator, amount);
        if (!success) {
            revert IEarnErrors.EarnDelegateFailedWhileMint(account, validator,amount);
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
            revert IEarnErrors.EarnCallStCoreMintFailed(account, amount, stCore);
        }

        emit Mint(account, amount, stCore);
    }

    // Redeem stCORE to get back CORE
    function redeem(uint256 stCore) public afterSettled nonReentrant whenNotPaused{
         address account = msg.sender;

        // Dues protection
        if (stCore < redeemMinLimit) {
            revert IEarnErrors.EarnSTCoreTooSmall(account, stCore);
        }
       
        uint256 core = _exchangeCore(stCore);

        // Burn stCORE
        bytes memory callData = abi.encodeWithSignature("burn(address,uint256)", account, stCore);
        (bool success, ) = STCORE.call(callData);
        if (!success) {
            revert IEarnErrors.EarnCallStCoreBurnFailed(account, core, stCore);
        }

        // Undelegate CORE from validators
        _unDelegateWithStrategy(core);

        // Calculate protocol fee
        uint256 protocolFee = core * protocolFeePoints / RATE_BASE;
        // Transfer protocolFee to fee receiver
        if (protocolFee != 0) {
            payable(protocolFeeReceiver).sendValue(protocolFee);
        }

        // Update local records
        uint256 redeemAmount = core - protocolFee;
        RedeemRecord memory redeemRecord = RedeemRecord({
            identity : uniqueIndex++,
            redeemTime: block.timestamp,
            unlockTime: block.timestamp + INIT_DAY_INTERVAL * lockDay,
            amount: redeemAmount,
            stCore: stCore
        });
        RedeemRecord[] storage records = redeemRecords[account];
        records.push(redeemRecord);

        emit Redeem(account, stCore, redeemAmount, protocolFee);
    }

    // Withdraw/claim CORE tokens after redemption period
    function withdraw(uint256 identity) public afterSettled nonReentrant whenNotPaused{
        address account = msg.sender;
        
        // The ID of the redeem record must not be less than 1 
        if (identity < 1) {
            revert IEarnErrors.EarnRedeemRecordIdMustGreaterThanZero(account, identity);
        }

        // Find user redeem records
        RedeemRecord[] storage records = redeemRecords[account];
        if (records.length == 0) {
            revert IEarnErrors.EarnEmptyRedeemRecord();
        }

        bool findRecord = false;
        uint256 index = 0;
        uint256 amount = 0;
        for (uint256 i = 0; i < records.length; i++) {
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
            revert IEarnErrors.EarnRedeemRecordNotFound(account, identity);
        }

        // check contract balance
        if (address(this).balance < amount) {
            revert IEarnErrors.EarnInsufficientBalance(address(this).balance, amount);
        }

        // Drop redeem record, and transfer CORE to user
        for (uint256 i = index; i < records.length - 1; i++) {
            records[i] = records[i + 1];
        }
        records.pop();

        // transfer balance to user
        payable(account).sendValue(amount);

        emit Withdraw(account, amount);
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
        for (uint256 i = 0; i < validatorDelegateMap.size(); i++) {
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
        for (uint256 i = 0; i < validatorDelegateMap.size(); i++) {
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

        // get current round
        uint256 currentRound = _currentRound();

        // Update exchange rate
        uint256 totalSupply = IERC20(STCORE).totalSupply();
        if (totalSupply > 0) {
            uint256 _capital = 0;
            for (uint256 i = 0; i < validatorDelegateMap.size(); i++) {
                address key = validatorDelegateMap.getKeyAtIndex(i);
                DelegateInfo memory delegateInfo = validatorDelegateMap.get(key);
                _capital += delegateInfo.amount;
            }
            if (_capital > 0) {
                uint256 rate = _capital * RATE_BASE / totalSupply;
                exchangeRates.push(rate);
                
                emit CalculateExchangeRate(currentRound, rate);
            }
        }

        // set last operate round to current round tag
        lastOperateRound = currentRound;
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
        for (uint256 i = 1; i < validatorDelegateMap.size(); i++) {
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
        uint256 transferAmount = (max - min) / 2;
        if (transferAmount >= pledgeAgentLimit && max - transferAmount >= pledgeAgentLimit) {
            bool success = _unDelegate(maxValidator, transferAmount);
            if (!success) {
                revert IEarnErrors.EarnReBalancUnDelegateFailed(maxValidator, transferAmount);
            }

            success = _delegate(minValidator, transferAmount);
            if (!success) {
                revert IEarnErrors.EarnReBalancDelegateFailed(minValidator, transferAmount);
            }

            DelegateInfo memory transferInfo = DelegateInfo({
                amount: transferAmount,
                earning: 0
            });
            validatorDelegateMap.set(maxValidator, transferInfo, false);
            validatorDelegateMap.set(minValidator, transferInfo, true);

            emit ReBalance(maxValidator, minValidator, transferAmount);
        }
    }

    /// --- VIEW METHODS ---///
    function getRedeemRecords() public view returns (RedeemRecord[] memory) {
        return redeemRecords[msg.sender];
    }

    function getRedeemAmount() public view returns (uint256 unlockedAmount, uint256 lockedAmount) {
        RedeemRecord[] storage records = redeemRecords[msg.sender];
        for (uint256 i = 0; i < records.length; i++) {
            RedeemRecord memory record = records[i];
             if (record.unlockTime >= block.timestamp) {
                unlockedAmount += record.amount;
            } else {
                lockedAmount += record.amount;
            }
        }
    }

    function getExchangeRates(uint256 target) public view returns(uint256[] memory _exchangeRates) {
         if (target < 1) {
            return _exchangeRates;
        }

        uint256 size = exchangeRates.length;
        uint256 from = 0;
        uint256 count;
        if (target >= size) {
            count = size;
        } else {
            from = size - target;
            count = target;
        }

        _exchangeRates = new uint256[](count);
        for (uint256 i = from; i < size; i++) {
            _exchangeRates[i-from] = exchangeRates[i];
        }

        return _exchangeRates;
    }

    function getCurrentExchangeRate() public view  returns (uint256) {
        return exchangeRates[exchangeRates.length - 1];
    } 

    function getTotalDelegateAmount() public view returns (uint256) {
        uint256 amount = 0;
        for (uint256 i = 0; i < validatorDelegateMap.size(); i++) {
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
            emit Delegate(validator, amount);
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
                        revert IEarnErrors.EarnUnDelegateFailedCase1(msg.sender, amount);
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
                            revert IEarnErrors.EarnUnDelegateFailedCase2(msg.sender, amount);
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
                                revert IEarnErrors.EarnUnDelegateFailedCase3(msg.sender, amount);
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
                            revert IEarnErrors.EarnUnDelegateFailedCase4(msg.sender, amount);
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
                                revert IEarnErrors.EarnUnDelegateFailedCase5(msg.sender, amount);
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
             revert IEarnErrors.EarnUnDelegateFailedFinally(msg.sender, amount);
        }

        // Remove empty validator
        uint256 deleteSize = 0;
        address[] memory deleteKeys = new address[](validatorDelegateMap.size());
        for (uint256 i = 0; i < validatorDelegateMap.size(); i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo memory delegateInfo = validatorDelegateMap.get(key);
            if (delegateInfo.amount == 0 && delegateInfo.earning == 0) {
                deleteKeys[deleteSize] = key;
                deleteSize++;
            }
        }
        for (uint256 i = 0; i < deleteSize; i++) {
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
            emit UnDelegate(validator, amount);
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
            emit Transfer(from, to, amount);
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
        emit UpdateBalanceThreshold(msg.sender, _balanceThreshold);
    }

    function updateMintMinLimit(uint256 _mintMinLimit) public onlyOwner {
        mintMinLimit = _mintMinLimit;
        emit UpdateMintMinLimit(msg.sender, _mintMinLimit);
    }

    function updateRedeemMinLimit(uint256 _redeemMinLimit) public onlyOwner {
        redeemMinLimit = _redeemMinLimit;
        emit UpdateRedeemMinLimit(msg.sender, _redeemMinLimit);
    }

    function updatePledgeAgentLimit(uint256 _pledgeAgentLimit) public onlyOwner {
        pledgeAgentLimit = _pledgeAgentLimit;
        emit UpdatePledgeAgentLimit(msg.sender, _pledgeAgentLimit);
    }

    function udpateLockDay(uint256 _lockDay) public onlyOwner {
        lockDay = _lockDay;
        emit UdpateLockDay(msg.sender, _lockDay);
    }

    function updateProtocolFeePoints(uint256 _protocolFeePoints) public onlyOwner {
        if (_protocolFeePoints > RATE_BASE) {
            revert IEarnErrors.EarnProtocolFeePointMoreThanRateBase(_protocolFeePoints);
        }
        protocolFeePoints = _protocolFeePoints;
        emit UpdateProtocolFeePoints(msg.sender, _protocolFeePoints);
    }

    function updateProtocolFeeReveiver(address _protocolFeeReceiver) public onlyOwner {
        // validator address protection
        if (_protocolFeeReceiver == address(0)) {
            revert IEarnErrors.EarnZeroProtocolFeeReceiver(_protocolFeeReceiver);
        }
        protocolFeeReceiver = _protocolFeeReceiver;
        emit UpdateProtocolFeeReveiver(msg.sender, _protocolFeeReceiver);
    }

    function updateOperator(address _operator) public onlyOwner {
        if (_operator == address(0)) {
            revert IEarnErrors.EarnZeroOperator(_operator);
        }
        operator = _operator;
        emit UpdateOperator(msg.sender, _operator);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    receive() external payable {}
}