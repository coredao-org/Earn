// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import {IEarnErrors} from "./interface/IErrors.sol";
import "./interface/ICandidateHub.sol";
import "./interface/ISTCore.sol";
import "./interface/IPledgeAgent.sol";

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

    // https://github.com/coredao-org/core-genesis-contract/blob/master/contracts/CandidateHub.sol
    uint256 public constant VALIDATOR_ACTIVE_STATUS = 17;

    // Address of stCORE contract: STCORE
    address public STCORE; 

    // Exchange rate (conversion rate between stCORE and CORE)
    // Exchange rate is calculated and updated at the beginning of each round
    uint256[] public exchangeRates;

    // Delegate records on each validator from the Earn contract
    IterableAddressDelegateMapping.Map private validatorDelegateMap;

    // Redemption period
    // It takes {lockDay} days for users to get CORE back from Earn after requesting redeem
    uint256 public lockDay = 7;

    // Redeem records are saved for each user
    // The records been withdrawn are removed to improve iteration performance
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

    // The operator address to trigger afterTurnRound() and rebalance methods
    address public operator;
    uint256 public roundTag;

    // Length limit of RedeemRecord[]
    // A user can keep up to {lastOperateRound} redeem records
    // This is introduced to avoid gas issue when users withdraw CORE from this contract
    uint256 public redeemCountLimit = 100;

    // Query limit of exchangeRates
    uint256 public exchangeRateQueryLimit = 365;

    // The amount of CORE which are requested for redumption but not yet undelegated from PledgeAgent
    uint256 public toWithdrawAmount = 0;

    /// --- EVENTS --- ///

    // User operations events
    event Mint(address indexed account, uint256 core, uint256 stCore);
    event Delegate(address indexed validator, uint256 amount);
    event UnDelegate(address indexed validator, uint256 amount);
    event Redeem(address indexed account, uint256 stCore, uint256 core, uint256 protocolFee);
    event Withdraw(address indexed account, uint256 amount, uint256 protocolFee);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    // Operator operations events
    event CalculateExchangeRate(uint256 round, uint256 exchangeRate);
    event ReBalance(address indexed from, address indexed to, uint256 amount);

    // Admin operations events
    event UpdateBalanceThreshold(address indexed caller, uint256 balanceThreshold);
    event UpdateMintMinLimit(address indexed caller, uint256 mintMinLimit);
    event UpdateRedeemMinLimit(address indexed caller, uint256 redeemMinLimit);
    event UpdatePledgeAgentLimit(address indexed caller, uint256 pledgeAgentLimit);
    event UpdateLockDay(address indexed caller, uint256 lockDay);
    event UpdateProtocolFeePoints(address indexed caller, uint256 protocolFeePoints);
    event UpdateProtocolFeeReveiver(address indexed caller, address protocolFeeReceiver);
    event UpdateOperator(address indexed caller, address operator);
    event UpdateRedeemCountLimit(address indexed caller, uint256 redeemCountLimit);
    event UpdateExchangeRateQueryLimit(address indexed caller, uint256 exchangeRateQueryLimit);

    function initialize(address _stCore, address _protocolFeeReceiver, address _operator) external initializer {
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
        roundTag = _currentRound();
    }

    function _authorizeUpgrade(address newImplementation) internal onlyOwner override {}

    /// --- MODIFIERS --- ///

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    modifier afterSettled() {
        require(roundTag == _currentRound(), "Turn round not triggered");
        _;
    }

    modifier canDelegate(address _validator) {
        require (ICandidateHub(CANDIDATE_HUB).canDelegate(_validator), "Can not delegate to validator");
        _;
    }
    
    /// --- USER INTERACTIONS --- ///

    // Mint stCORE using CORE 
    // The caller needs to pass in the validator address to delegate to
    // By doing so we treat existing validators/new comers equally
    function mint(address _validator) external payable afterSettled nonReentrant whenNotPaused canDelegate(_validator) {
        address account = msg.sender;
        uint256 amount = msg.value;

        // dues protection 
        if (amount < mintMinLimit) {
            revert IEarnErrors.EarnMintAmountTooSmall(account, amount);
        }

        // Delegate CORE to PledgeAgent
         _delegate(_validator, amount);

        // Update delegate records
        DelegateInfo memory delegateInfo = DelegateInfo({
            amount: amount,
            earning: 0
        });
        validatorDelegateMap.add(_validator, delegateInfo);

        // Mint stCORE and send to users
        uint256 stCore = _exchangeSTCore(amount);
        ISTCore(STCORE).mint(account, stCore);

        emit Mint(account, amount, stCore);
    }

    // Redeem stCORE to get back CORE
    function redeem(uint256 stCore) external afterSettled nonReentrant whenNotPaused{
        address account = msg.sender;
        RedeemRecord[] storage records = redeemRecords[account];
        
        if (records.length >= redeemCountLimit) {
            revert IEarnErrors.EarnRdeemCountOverLimit(account, records.length, redeemCountLimit);
        }

        // Dues protection
        if (stCore < redeemMinLimit) {
            revert IEarnErrors.EarnSTCoreTooSmall(account, stCore);
        }
       
        uint256 core = _exchangeCore(stCore);

        // Burn stCORE
        ISTCore(STCORE).burn(account, stCore);

        // Calculate protocol fee
        uint256 protocolFee = core * protocolFeePoints / RATE_BASE;

        // Update redeem records
        uint256 redeemAmount = core - protocolFee;
        RedeemRecord memory redeemRecord = RedeemRecord({
            redeemTime: block.timestamp,
            unlockTime: block.timestamp + DAY_INTERVAL * lockDay,
            amount: redeemAmount,
            stCore: stCore,
            protocolFee: protocolFee
        });
        records.push(redeemRecord);

        toWithdrawAmount += core;

        emit Redeem(account, stCore, redeemAmount, protocolFee);
    }

    // Withdraw CORE tokens after redemption period
    function withdraw() external afterSettled nonReentrant whenNotPaused{
        address account = msg.sender;
        
        // Find user redeem records
        RedeemRecord[] storage records = redeemRecords[account];
        if (records.length == 0) {
            revert IEarnErrors.EarnEmptyRedeemRecord();
        }

        uint256 accountAmount = 0;
        uint256 protocolFeeAmount = 0;
        for (uint256 i = records.length; i != 0; i--) {
            RedeemRecord memory record = records[i - 1];
             if (record.unlockTime < block.timestamp) {
                accountAmount += record.amount;
                protocolFeeAmount += record.protocolFee;
                if (i != records.length) {
                    records[i - 1] = records[records.length - 1];
                }
                records.pop();
            }
        }

        // No eligible records found
        if (accountAmount == 0) {
            revert IEarnErrors.EarnRedeemRecordNotFound(account);
        }

        // Amount of CORE to undelegate
        uint256 totalAmount = accountAmount + protocolFeeAmount;

        // Undelegate CORE from validators
        _unDelegateWithStrategy(totalAmount);

        // Check contract balance
        // This shall not happen, just a sanity check
        if (address(this).balance < totalAmount) {
            revert IEarnErrors.EarnInsufficientBalance(address(this).balance, totalAmount);
        }

        // Transfer CORE to user
        payable(account).sendValue(accountAmount);

        // Transfer CORE to porotocol fee receiver
        if (protocolFeeAmount != 0) {
            payable(protocolFeeReceiver).sendValue(protocolFeeAmount);
        }

        // Update toWithdrawAmount
        toWithdrawAmount -= totalAmount;

        emit Withdraw(account, accountAmount, protocolFeeAmount);
    }

    /// --- OPERATOR INTERACTIONS --- ///

    // Triggered right after turn round
    // Users are not allowed to operate before this method is executed successfully in each round
    // The Earn contract does following in this method
    //  1. Claim rewards from each validator
    //  2. Stake rewards back to corresponding validators (auto compounding)
    //  3. Update daily exchange rate
    // During the process, this method also moves delegates from inactive validators 
    //  to active (newly elected) validators
    // The operator can also pass in new elected validators to act as a fallback catch
    //  in the case where all existing validators are replaced in the new round
    function afterTurnRound(address[] memory newElectedValidators) external onlyOperator {
        // Amount of CORE to undelegate from validators not active in the new round
        uint256 unDelegateAmount;

        // Claim rewards
        for (uint i = validatorDelegateMap.size(); i != 0; i--) {
            address key = validatorDelegateMap.getKeyAtIndex(i - 1);
            DelegateInfo storage delegateInfo = validatorDelegateMap.get(key);

            uint256 balanceBeforeClaim = address(this).balance;
            _claim(key);
            uint256 balanceAfterClaim = address(this).balance;
            uint256 _earning = balanceAfterClaim - balanceBeforeClaim;
            delegateInfo.earning += _earning;

            // Check validator status
            if (!_isActive(key)) {
                // Undelegate from inactive validator
                _unDelegate(key, delegateInfo.amount);
                unDelegateAmount += (delegateInfo.amount + delegateInfo.earning);
                validatorDelegateMap.remove(key);
            }
     
        }

        // Delegate {unDelegateAmount} to a random chosen validator
        // If all validators staked by Earn in last round become inactive
        //  choose the first validator in the passed in array
        uint256 validatorSize = validatorDelegateMap.size();
        if (validatorSize == 0) {
            if (newElectedValidators.length > 0 && ICandidateHub(CANDIDATE_HUB).canDelegate(newElectedValidators[0])) {
                DelegateInfo memory backupDelegateInfo = DelegateInfo({
                    amount: 0,
                    earning: unDelegateAmount
                });
                validatorDelegateMap.add(newElectedValidators[0], backupDelegateInfo);
            } else {
                // should not happen
                revert IEarnErrors.EarnValidatorsAllOffline();
            }        
        } else {
            uint256 randomIndex = _randomIndex(validatorSize);
            address randomKey = validatorDelegateMap.getKeyAtIndex(randomIndex);
            // Add {unDelegateAmount} to the randomly chosen validator's earning
            //  which will be used to delegate to this validator in the follow step
            DelegateInfo memory randomDelegateInfo = DelegateInfo({
                amount: 0,
                earning: unDelegateAmount
            });
            validatorDelegateMap.add(randomKey, randomDelegateInfo);
        }

        // Delegate rewards
        // Auto compounding
        for (uint256 i = 0; i < validatorDelegateMap.size(); i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo storage delegateInfo = validatorDelegateMap.get(key);

            if(delegateInfo.earning > pledgeAgentLimit) {
                uint256 delegateAmount = delegateInfo.earning;
                _delegate(key, delegateAmount);
                delegateInfo.amount += delegateAmount;
                delegateInfo.earning -= delegateAmount;
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
            if (_capital > toWithdrawAmount) {
                uint256 rate = (_capital - toWithdrawAmount) * RATE_BASE / totalSupply;
                exchangeRates.push(rate);
                
                emit CalculateExchangeRate(currentRound, rate);
            }
        }

        // Update round tag
        roundTag = currentRound;
    }

    // This method can be triggered on a regular basis, e.g. hourly/daily/weekly/etc
    // The Earn contract rebalances staking on top/bottom validators in this method
    function reBalance() external afterSettled onlyOperator{
        if (validatorDelegateMap.size() <= 1) {
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
    function manualReBalance(address _from, address _to, uint256 _transferAmount) external afterSettled onlyOperator canDelegate(_to){
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
    function getRedeemRecords() external view returns (RedeemRecord[] memory) {
        return redeemRecords[msg.sender];
    }

    // @openissue change msg.sender to a passed in address
    function getRedeemAmount() external view returns (uint256 unlockedAmount, uint256 lockedAmount) {
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

    function getExchangeRates(uint256 target) external view returns(uint256[] memory _exchangeRates) {
        // Not allow to query too many rounds
        if (target > exchangeRateQueryLimit) {
            return _exchangeRates;
        }

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
    }

    function getCurrentExchangeRate() external view  returns (uint256) {
        return exchangeRates[exchangeRates.length - 1];
    } 

    function getTotalDelegateAmount() external view returns (uint256) {
        uint256 amount = 0;
        uint256 mapSize = validatorDelegateMap.size();
        for (uint256 i = 0; i < mapSize; i++) {
            address key = validatorDelegateMap.getKeyAtIndex(i);
            DelegateInfo memory delegateInfo = validatorDelegateMap.get(key);
            amount += delegateInfo.amount;
        }
        return amount;
    }

    /// --- INTERNAL METHODS --- ///

    // Get current round
    function _currentRound() private view returns (uint256) {
        return ICandidateHub(CANDIDATE_HUB).getRoundTag();
    }

    // Core to STCore
    function _exchangeSTCore(uint256 core) private view returns (uint256) {
        return core * RATE_BASE / exchangeRates[exchangeRates.length-1];
    }

    // STCore to Core
    function _exchangeCore(uint256 stCore) private view returns(uint256) {
        return stCore * exchangeRates[exchangeRates.length-1] / RATE_BASE;
    }

    // Delegate to validator
    // @openissue remove unnecessary code
    function _delegate(address validator, uint256 amount) private {
        uint256 balanceBefore = address(this).balance - amount;
        IPledgeAgent(PLEDGE_AGENT).delegateCoin{value: amount}(validator);
        uint256 balanceAfter = address(this).balance;
        uint256 earning = balanceAfter - balanceBefore;
        if (earning > 0) {
            // This shall not happen as all rewards are claimed in afterTurnRound()
            // Only for unexpected cases
            DelegateInfo memory unprocessedReward = DelegateInfo({
                amount: 0,
                earning: earning
            });
            validatorDelegateMap.add(validator, unprocessedReward);
        }
        emit Delegate(validator, amount);
    }

    // Undelegate CORE from validators with strategy
    // There is dues protection in PledageAgent, which are
    //  1. Can only delegate 1+ CORE
    //  2. Can only undelegate 1+ CORE AND can only leave 1+ CORE on validator after undelegate 
    // Internally, Earn delegates to/undelegates from validators on each mint/redeem action
    // As a result, to make the system solid. For any undelegate action from Earn it must result in
    //  1. The validator must be cleared or have 1+ CORE remaining after undelegate AND
    //  2. Earn contract must have 0 or 1+ CORE left to further undelegate
    // Otherwise, Earn might fail to undelegate further because of the dues protection from PledgeAgent
    function _unDelegateWithStrategy(uint256 amount) private {
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
                    _unDelegate(key, amount);
                    amount = 0;
                    validatorDelegateMap.substract(key, unDelegateInfo);
                    break;
                } else if (delegateInfo.amount > amount) {
                    if (delegateInfo.amount >= amount + pledgeAgentLimit) {
                    // Case 2: the amount available on the validator >= the amount needs to be undelegated + 1
                    // Undelegate all the tokens from the validator
                        DelegateInfo memory unDelegateInfo = DelegateInfo({
                            amount: amount,
                            earning: 0
                        });
                        _unDelegate(key, amount);
                        amount = 0;
                        validatorDelegateMap.substract(key, unDelegateInfo);
                        break;
                    } else {
                        // Case 3: the amount available on the validator >= the amount needs to be undelegated AND
                        //          the amount available on the validator <= the amount needs to be undelegated + 1
                        // In this case we need to make sure there are 1 CORE token left to further undelegate so both 
                        //   the validator and Earn are safe on the PledgeAgent dues protection
                        uint256 delegateAmount = amount - pledgeAgentLimit;
                        uint256 delegatorLeftAmount = delegateInfo.amount - delegateAmount;
                        if (delegateAmount > pledgeAgentLimit && delegatorLeftAmount > pledgeAgentLimit) {
                            DelegateInfo memory unDelegateInfo = DelegateInfo({
                                amount: delegateAmount,
                                earning: 0
                            });
                            _unDelegate(key, delegateAmount);
                            amount -= delegateAmount;
                            validatorDelegateMap.substract(key, unDelegateInfo);
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
                        _unDelegate(key, delegateInfo.amount);
                        amount -= delegateInfo.amount;
                        validatorDelegateMap.substract(key, unDelegateInfo);
                    } else {
                        // Case 5: the amount available on the validator >= the amount needs to be undelegated - 1 AND
                        //          the amount available on the validator <= the amount needs to be undelegated
                        // In this case we need to make sure there are 1 CORE token left on validator so both 
                        //   the validator and Earn are safe on the PledgeAgent dues protection
                        uint256 delegateAmount = delegateInfo.amount - pledgeAgentLimit;
                        uint256 accountLeftAmount = amount - delegateAmount;
                        if (delegateAmount > pledgeAgentLimit && accountLeftAmount > pledgeAgentLimit) {
                            DelegateInfo memory unDelegateInfo = DelegateInfo({
                                amount: delegateAmount,
                                earning: 0
                            });
                            _unDelegate(key, delegateAmount);
                            amount -= delegateAmount;
                            validatorDelegateMap.substract(key, unDelegateInfo);
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
    // @openissue remove unnecessary code
    function _unDelegate(address validator, uint256 amount) private {
        uint256 balanceBefore = address(this).balance;
        IPledgeAgent(PLEDGE_AGENT).undelegateCoin( validator, amount);
        uint256 balanceAfter = address(this).balance - amount;
        uint256 earning = balanceAfter - balanceBefore;
        if (earning > 0) {
            // This shall not happen as all rewards are claimed in afterTurnRound()
            // Only for unexpected cases
            DelegateInfo memory unprocessedReward = DelegateInfo({
                amount: 0,
                earning: earning
            });
            validatorDelegateMap.add(validator, unprocessedReward);
        }
        emit UnDelegate(validator, amount);
    }

    // @openissue remove unnecessary code
    function _transfer(address from, address to, uint256 amount) private {
        uint256 balanceBefore = address(this).balance;
        IPledgeAgent(PLEDGE_AGENT).transferCoin(from, to, amount);
        uint256 balanceAfter = address(this).balance;
        uint256 earning = balanceAfter - balanceBefore;
        if (earning > 0) {
            // This shall not happen as all rewards are claimed in afterTurnRound()
            // Only for unexpected cases
            DelegateInfo memory unprocessedReward = DelegateInfo({
                amount: 0,
                earning: earning
            });
            validatorDelegateMap.add(from, unprocessedReward);
        }
        emit Transfer(from, to, amount);
    }

    function _claim(address validator) private {
        address[] memory addresses = new address[](1);
        addresses[0] = validator;
        IPledgeAgent(PLEDGE_AGENT).claimReward(addresses);
    }

    function _randomIndex(uint256 length) private view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, msg.sender))) % length;
    }

    function _isActive(address validator) private view returns (bool) {
        uint256 indexPlus1 = ICandidateHub(CANDIDATE_HUB).operateMap(validator);
        if (indexPlus1 == 0) {
            return false;
        }
        Candidate memory candidate = ICandidateHub(CANDIDATE_HUB).candidateSet(indexPlus1 - 1);
        return candidate.status == VALIDATOR_ACTIVE_STATUS;
    }

    function _reBalanceTransfer(address _from, address _to, uint256 _fromAmount, uint256 _transferAmount) private {
        if (_transferAmount >= pledgeAgentLimit && (_fromAmount ==_transferAmount ||  _fromAmount - _transferAmount >= pledgeAgentLimit)) {
            _transfer(_from, _to, _transferAmount);
            DelegateInfo memory transferInfo = DelegateInfo({
                amount: _transferAmount,
                earning: 0
            });
            validatorDelegateMap.substract(_from, transferInfo);
            validatorDelegateMap.add(_to, transferInfo);

            emit ReBalance(_from, _to, _transferAmount);
        } else {
            revert IEarnErrors.EarnReBalanceInvalidTransferAmount(_from, _fromAmount, _transferAmount);
        }
    }

    /// --- ADMIN OPERATIONS --- ///

    function updateBalanceThreshold(uint256 _balanceThreshold) external onlyOwner {
        if (_balanceThreshold == 0) {
            revert IEarnErrors.EarnBalanceThresholdMustGreaterThanZero();
        }
        balanceThreshold = _balanceThreshold;
        emit UpdateBalanceThreshold(msg.sender, _balanceThreshold);
    }

    function updateMintMinLimit(uint256 _mintMinLimit) external onlyOwner {
        if (_mintMinLimit < 1 ether) {
            revert IEarnErrors.EarnMintMinLimitMustGreaterThan1Core();
        }
        mintMinLimit = _mintMinLimit;
        emit UpdateMintMinLimit(msg.sender, _mintMinLimit);
    }

    function updateRedeemMinLimit(uint256 _redeemMinLimit) external onlyOwner {
        if (_redeemMinLimit < 1 ether) {
            revert IEarnErrors.EarnRedeemMinLimitMustGreaterThan1Core();
        }
        redeemMinLimit = _redeemMinLimit;
        emit UpdateRedeemMinLimit(msg.sender, _redeemMinLimit);
    }

    function updatePledgeAgentLimit(uint256 _pledgeAgentLimit) external onlyOwner {
        if (_pledgeAgentLimit < 1 ether) {
            revert IEarnErrors.EarnPledgeAgentLimitMustGreaterThan1Core();
        }
        pledgeAgentLimit = _pledgeAgentLimit;
        emit UpdatePledgeAgentLimit(msg.sender, _pledgeAgentLimit);
    }

    function updateLockDay(uint256 _lockDay) external onlyOwner {
        if (_lockDay == 0) {
            revert IEarnErrors.EarnLockDayMustGreaterThanZero();
        }
        lockDay = _lockDay;
        emit UpdateLockDay(msg.sender, _lockDay);
    }

    function updateProtocolFeePoints(uint256 _protocolFeePoints) external onlyOwner {
        if (_protocolFeePoints > RATE_BASE) {
            revert IEarnErrors.EarnProtocolFeePointMoreThanRateBase(_protocolFeePoints);
        }
        protocolFeePoints = _protocolFeePoints;
        emit UpdateProtocolFeePoints(msg.sender, _protocolFeePoints);
    }

    function updateProtocolFeeReveiver(address _protocolFeeReceiver) external onlyOwner {
        if (_protocolFeeReceiver == address(0)) {
            revert IEarnErrors.EarnZeroProtocolFeeReceiver(_protocolFeeReceiver);
        }
        protocolFeeReceiver = _protocolFeeReceiver;
        emit UpdateProtocolFeeReveiver(msg.sender, _protocolFeeReceiver);
    }

    function updateOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) {
            revert IEarnErrors.EarnZeroOperator(_operator);
        }
        operator = _operator;
        emit UpdateOperator(msg.sender, _operator);
    }

    function updateRedeemCountLimit(uint256 _redeemCountLimit) external onlyOwner {
        if (_redeemCountLimit == 0) {
            revert IEarnErrors.EarnRedeemCountLimitMustGreaterThanZero();
        }
        redeemCountLimit = _redeemCountLimit;
        emit UpdateRedeemCountLimit(msg.sender, _redeemCountLimit);
    }

    function updateExchangeRateQueryLimit(uint256 _exchangeRateQueryLimit) external onlyOwner {
        if (_exchangeRateQueryLimit == 0) {
            revert IEarnErrors.EarnExchangeRateQueryLimitMustGreaterThanZero();
        }
        exchangeRateQueryLimit = _exchangeRateQueryLimit;
        emit UpdateExchangeRateQueryLimit(msg.sender, _exchangeRateQueryLimit);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {}
}