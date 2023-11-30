// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import {IEarnErrors} from "./interface/IErrors.sol";
import "./interface/ICandidateHub.sol";

import "./lib/IterableAddressDelegateMapping.sol";
import "./lib/Structs.sol";

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

// TODO 2. NatSpecs

contract Earn is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using IterableAddressDelegateMapping for IterableAddressDelegateMapping.Map;
    using Address for address payable;

    // Exchange rate base 
    // 10^6 is used to enhance precision in calculations
    uint256 private constant RATE_BASE = 1000000;

    // Address of system contract: CandidateHub
    address private constant CANDIDATE_HUB = 0x0000000000000000000000000000000000001005;

    // Address of system contract: PledgeAgent
    address private constant PLEDGE_AGENT = payable(0x0000000000000000000000000000000000001007);

    // The number of seconds in a day
    uint256 public constant DAY_INTERVAL = 86400;

    // Address of stCORE contract: STCORE
    address public STCORE; 

    // Exchange rate (conversion rate between stCORE and Core) of each round
    // Exchange rate is calculated and updated at the beginning of each round
    uint256[] public exchangeRates;

    // Delegate records on each validator from the Earn contract
    IterableAddressDelegateMapping.Map private validatorDelegateMap;

    // Redemption period
    // It takes {lockDay} days for users to get CORE back from Earn after requesting redeem
    uint256 public lockDay = 7;

    // Redeem records are saved for each user
    // The records been withdrawn are removed to improve iteration performance
    uint256 public uniqueIndex = 1;
    mapping(address => RedeemRecord[]) public redeemRecords;

    // The threshold to tigger rebalance
    uint256 public balanceThreshold = 10000 ether;

    // Dues protections
    uint256 public mintMinLimit = 1 ether;
    uint256 public redeemMinLimit = 1 ether;
    uint256 public pledgeAgentLimit = 1 ether;

    // Protocol fee percents and fee receiving address
    // Set 0 ~ 1000000
    // 1000000 = 100%
    uint256 public protocolFeePoints = 0;
    address public protocolFeeReceiver;

    // The operator address to trigger afterTurnRound() and reBalance() methods
    address public operator;
    uint256 public lastOperateRound;

    // Amount of CORE to undelegate from validators unelected in the new round
    uint256 public unDelegateAmount;

    /// --- EVENTS --- ///

    // User operations event
    event Mint(address indexed account, uint256 core, uint256 stCore);
    event Delegate(address indexed validator, uint256 amount);
    event UnDelegate(address indexed validator, uint256 amount);
    event Redeem(address indexed account, uint256 stCore, uint256 core, uint256 protocolFee);
    event Withdraw(address indexed account, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    // Operator operations event
    event CalculateExchangeRate(uint256 round, uint256 exchangeRate);
    event ReBalance(address indexed from, address indexed to, uint256 amount);

    // Admin operations event
    event UpdateBalanceThreshold(address indexed caller, uint256 balanceThreshold);
    event UpdateMintMinLimit(address indexed caller, uint256 mintMinLimit);
    event UpdateRedeemMinLimit(address indexed caller, uint256 redeemMinLimit);
    event UpdatePledgeAgentLimit(address indexed caller, uint256 pledgeAgentLimit);
    event UdpateLockDay(address indexed caller, uint256 lockDay);
    event UpdateProtocolFeePoints(address indexed caller, uint256 protocolFeePoints);
    event UpdateProtocolFeeReveiver(address indexed caller, address protocolFeeReceiver);
    event UpdateOperator(address indexed caller, address operator);

    function initialize(address _stCore, address _protocolFeeReceiver, address _operator) public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

         // stCORE should be none ZERO
        if (_stCore == address(0)) {
            revert IEarnErrors.EarnZeroSTCore(_stCore);
        }
        STCORE = _stCore;

        // protocol fee address should be none ZERO
        if (_protocolFeeReceiver == address(0)) {
            revert IEarnErrors.EarnZeroProtocolFeeReceiver(_protocolFeeReceiver);
        }
        protocolFeeReceiver = _protocolFeeReceiver;

        // operator address should be none ZERO
        if (_operator == address(0)) {
            revert IEarnErrors.EarnZeroOperator(_operator);
        }
        operator = _operator;

        exchangeRates.push(RATE_BASE);
        lastOperateRound = _currentRound();
    }

    function _authorizeUpgrade(address newImplementation) internal onlyOwner override {}

    /// --- MODIFIERS --- ///

    modifier onlyOperator() {
        require(msg.sender == operator, "Not Operator");
        _;
    }

    modifier afterSettled() {
        require(lastOperateRound == _currentRound(), "Turn round not triggered");
        _;
    }

    modifier canDelegate(address _validator) {
        require (ICandidateHub(CANDIDATE_HUB).canDelegate(_validator), "Invalid candidate");
        _;
    }
    
    /// --- USER INTERACTIONS --- ///

    // Mint stCORE using CORE 
    // The caller needs to pass in the validator address to delegate to
    // By doing so we treat existing validators/new comers equally
    function mint(address _validator) public payable afterSettled nonReentrant whenNotPaused canDelegate(_validator) {
        address account = msg.sender;
        uint256 amount = msg.value;

        // dues protection 
        if (amount < mintMinLimit) {
            revert IEarnErrors.EarnMintAmountTooSmall(account, amount);
        }

        // Delegate CORE to PledgeAgent
        bool success = _delegate(_validator, amount);
        if (!success) {
            revert IEarnErrors.EarnDelegateFailedWhileMint(account, _validator,amount);
        }

        // Update local records
        DelegateInfo memory delegateInfo = DelegateInfo({
            amount: amount,
            earning: 0
        });
        validatorDelegateMap.set(_validator, delegateInfo, true);

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

        // Calculate protocol fee and send to receiver address
        uint256 protocolFee = core * protocolFeePoints / RATE_BASE;
        if (protocolFee != 0) {
            payable(protocolFeeReceiver).sendValue(protocolFee);
        }

        // Update local records
        uint256 redeemAmount = core - protocolFee;
        RedeemRecord memory redeemRecord = RedeemRecord({
            identity : uniqueIndex++,
            redeemTime: block.timestamp,
            unlockTime: block.timestamp + DAY_INTERVAL * lockDay,
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
        if (identity == 0) {
            revert IEarnErrors.EarnRedeemRecordIdMustGreaterThanZero(account, identity);
        }

        // Find user redeem records
        RedeemRecord[] storage records = redeemRecords[account];
        if (records.length == 0) {
            revert IEarnErrors.EarnEmptyRedeemRecord();
        }

        // @openissue possible gas issues when iterating a large array
        bool findRecord = false;
        uint256 index = 0;
        uint256 amount = 0;
        for (uint256 i = 0; i < records.length; i++) {
            RedeemRecord memory record = records[i];
            if (record.identity == identity) {
                // Find redeem record
                findRecord = true;
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

        // Redeem record not found
        if (!findRecord) {
            revert IEarnErrors.EarnRedeemRecordNotFound(account, identity);
        }

        // Check contract balance
        // This shall not happen, just a sanity check
        if (address(this).balance < amount) {
            revert IEarnErrors.EarnInsufficientBalance(address(this).balance, amount);
        }

        // Drop redeem record
        for (uint256 i = index; i < records.length - 1; i++) {
            records[i] = records[i + 1];
        }
        records.pop();

        // Transfer CORE to user
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
    // During the process, this method also moves delegates from inactive validators to newly elected validators
    // The new elected validators can also be passed in as parameters to play as a back up role -
    //  in the extreme case where all existing validators are replaced by new ones 
    function afterTurnRound(address[] memory newElectedValidators) public onlyOperator {        
        // Validators to undelegate from
        uint256 deleteSize = 0;
        address[] memory deleteKeys = new address[](validatorDelegateMap.size());
        
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

                // Check validatos status
                if (!_isActive(key)) {
                    // Undelegate from inactive validator
                    // If success, record it and wait to be deleted
                    success = _unDelegate(key, delegateInfo.amount);
                    if (success) {
                        unDelegateAmount += (delegateInfo.amount + delegateInfo.earning);
                        deleteKeys[deleteSize] = key;
                        deleteSize++;
                    }
                }
            }   
        }

        // Remove inactive validators
        for (uint256 i = 0; i < deleteSize; i++) {
            validatorDelegateMap.remove(deleteKeys[i]);
        }

        // Delegate `unDelegateAmount` to a random chosen validator
        // If all validators staked by Earn in last round become inactive, choose the first validator from parameter
        uint256 validatorSize = validatorDelegateMap.size();
        if (validatorSize == 0) {
            if (newElectedValidators.length > 0 && ICandidateHub(CANDIDATE_HUB).canDelegate(newElectedValidators[0])) {
                // If all validators ineffective, delegate all amount to emergency validator
                DelegateInfo memory backupDelegateInfo = DelegateInfo({
                    amount: 0,
                    earning: unDelegateAmount
                });
                validatorDelegateMap.set(newElectedValidators[0], backupDelegateInfo, true);
                unDelegateAmount = 0;
            } else {
                // should not happen
                return;
            }        
        } else {
            uint256 randomIndex = _randomIndex(validatorSize);
            address randomKey = validatorDelegateMap.getKeyAtIndex(randomIndex);
            // Set {unDelegateAmount} to a random validator's earning, and wait to be delegated
            DelegateInfo memory randomDelegateInfo = DelegateInfo({
                amount: 0,
                earning: unDelegateAmount
            });
            validatorDelegateMap.set(randomKey, randomDelegateInfo, true);
            unDelegateAmount = 0;
        }

        // Delegate rewards
        // Auto compounding
        for (uint256 i = 0; i < validatorDelegateMap.size(); i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo storage delegateInfo = validatorDelegateMap.get(key);

            if(delegateInfo.earning > pledgeAgentLimit) {
                uint256 delegateAmount = delegateInfo.earning;
                bool success = _delegate(key, delegateAmount);
                if (success) {
                    delegateInfo.amount += delegateAmount;
                    delegateInfo.earning -= delegateAmount;
                } 
            } 
        }

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

        // Update round tag
        lastOperateRound = currentRound;
    }

    // This method can be triggered on a regular basis, e.g. hourly/daily/weekly/etc
    // This method cannot revert
    // The Earn contract rebalances staking on top/bottom validators in this method
    function reBalance() public afterSettled onlyOperator{
        if (validatorDelegateMap.size() == 0) {
            revert IEarnErrors.EarnEmptyValidator();
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
            revert IEarnErrors.EarnReBalanceNoNeed(maxValidator, minValidator);
        }

        if (max - min < balanceThreshold) {
            revert IEarnErrors.EarnReBalanceAmountDifferenceLessThanThreshold(maxValidator, minValidator, max, min, balanceThreshold);
        }

        // Transfer CORE to rebalance
        uint256 transferAmount = (max - min) / 2;

        // Call transfer logic
        _reBalanceTransfer(maxValidator, minValidator, max, transferAmount);
    }

    // This method is introduce to take necessary actions to improve earning
    // e.g. to transfer stakes from a jailed validator to another before turn round
    // e.g. to transfer stakes from a low APR validator to a high APR validator
    function manualReBalance(address _from, address _to, uint256 _transferAmount) public afterSettled onlyOperator canDelegate(_to){
        if (validatorDelegateMap.size() == 0) {
            revert IEarnErrors.EarnEmptyValidator();
        }

        DelegateInfo memory fromValidator = validatorDelegateMap.get(_from);

        if (fromValidator.amount < _transferAmount) {
            revert IEarnErrors.EarnReBalanceInsufficientAmount(_from, fromValidator.amount, _transferAmount);
        }
        
        // Call transfer logic
        _reBalanceTransfer(_from, _to, fromValidator.amount, _transferAmount);
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

    /// --- INTERNAL METHODS --- ///

    // Get current round
    function _currentRound() internal view returns (uint256) {
        return ICandidateHub(CANDIDATE_HUB).getRoundTag();
    }

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
                        // In this case we need to make sure there are 1 CORE token left on Earn side so both 
                        //   the validator and Earn are safe on the PledgeAgent dues protection
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
                        //   the validator and Earn are safe on the PledgeAgent dues protection
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

    function _transfer(address from, address to, uint256 amount) internal returns(bool) {
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
        return success;
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

    function _isActive(address validator) internal view returns (bool) {
        uint256 index = ICandidateHub(CANDIDATE_HUB).operateMap(validator);
        if (index == 0) {
            return false;
        }
        Candidate memory candidate = ICandidateHub(CANDIDATE_HUB).candidateSet(index - 1);
        return candidate.status == 17;
    }

    function _reBalanceTransfer(address _from, address _to, uint256 _fromAmount, uint256 _transferAmount) internal {
        if (_transferAmount >= pledgeAgentLimit && (_fromAmount ==_transferAmount ||  _fromAmount - _transferAmount >= pledgeAgentLimit)) {
            bool success = _transfer(_from, _to, _transferAmount);
            if (!success) {
                revert IEarnErrors.EarnReBalanceTransferFailed(_from, _to, _transferAmount);
            }
            DelegateInfo memory transferInfo = DelegateInfo({
                amount: _transferAmount,
                earning: 0
            });
            validatorDelegateMap.set(_from, transferInfo, false);
            validatorDelegateMap.set(_to, transferInfo, true);

            emit ReBalance(_from, _to, _transferAmount);
        } else {
             revert IEarnErrors.EarnReBalanceInvalidTransferAmount(_from, _fromAmount, _transferAmount);
        }
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
        if (_lockDay == 0) {
            revert IEarnErrors.EarnLockDayMustGreaterThanZero();
        }
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