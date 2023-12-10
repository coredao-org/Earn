import time
import random
from copy import copy
from collections import defaultdict
import brownie
from brownie import accounts, history
from brownie.test import strategy
from .common import turn_round, register_candidate, get_exchangerate
from .utils import get_tracker, encode_args_with_signature
from web3 import Web3

RATE_MULTIPLE = 1000000
DAY_INTERVAL = 86000
DEDUCT_DURATION = 200
VALIDATOR_COUNT = 5
LOCK_DAY = 7


class Status:
    ACTIVE = 1
    REFUSED = 0


class Agent:
    def __init__(self, agents, redeem_record):
        self.agents_map = agents
        self.redeem_records = redeem_record

    def subtract_coin(self, subtract_agents=None):
        if subtract_agents is not None:
            for agent in subtract_agents:
                deduct_amount = subtract_agents[agent]
                self.agents_map[agent]['coin'] -= deduct_amount

    def add_coin(self, agent, amount, status=1):
        if str(agent) not in self.agents_map:
            self.agents_map[str(agent)] = {'status': status,
                                           'coin': amount}
        else:
            self.agents_map[str(agent)]['coin'] += amount
            self.agents_map[str(agent)]['status'] = status
        return self.agents_map

    def redeem_coin(self, delegator, tx, core, st_core, fee, unlock_time):
        record = {
            'redeemTime': tx.timestamp - DEDUCT_DURATION,
            'unlockTime': tx.timestamp + unlock_time - DEDUCT_DURATION,
            'amount': core,
            'stCore': st_core,
            'protocolFee': fee
        }
        if delegator not in self.redeem_records:
            self.redeem_records[delegator] = [record]
        else:
            self.redeem_records[delegator].append(record)

    def withdraw_coin(self, delegate, new_redeem_record):
        self.redeem_records[delegate] = new_redeem_record


class Token:
    def __init__(self, holder):
        self.holder = holder

    def mint_token(self, delegator, amount, rate):
        amount = amount * RATE_MULTIPLE // rate
        if delegator not in self.holder:
            self.holder[delegator] = amount
        else:
            self.holder[delegator] += amount

    def burn_token(self, delegator, amount):
        self.holder[delegator] -= amount


N = 0


class StateMachine:
    st_balance_threshold = strategy('uint256', min_value=10000, max_value=30000)
    st_mint_amount = strategy('uint256', min_value=100000, max_value=300000)
    st_redeem_amount = strategy('uint256', min_value=10000, max_value=30000)
    st_fee_points = strategy('uint256', min_value=0, max_value=10)

    def __init__(self, earn, stcore, candidate_hub, pledge_agent, validator_set, btc_light_client, slash_indicator):
        accounts.default = accounts[0]
        self.candidate_hub = candidate_hub
        self.pledge_agent = pledge_agent
        self.validator_set = validator_set
        self.slash_indicator = slash_indicator
        self.btc_light_client = btc_light_client
        self.earn = earn
        self.st_core = stcore
        self.earn.setContractAddress(candidate_hub.address, pledge_agent.address, candidate_hub.getRoundTag())
        self.earn.setAfterTurnRoundClaimReward(True)
        self.operating = accounts[-10:-8]
        self.earn.setReduceTime(DEDUCT_DURATION)
        self.candidate_hub.setValidatorCount(VALIDATOR_COUNT)
        accounts[-2].transfer(self.validator_set.address, Web3.toWei(100000, 'ether'))

    def initialize(self, st_balance_threshold):
        random.seed(time.time_ns())
        self.earn.updateOperator(accounts[0].address)
        self.to_withdraw_amount = 0
        self.refused_validators = []
        self.paused = 0
        self.protocol_fee_points = 0
        self.rate = RATE_MULTIPLE
        self.balance_threshold = st_balance_threshold
        self.earn.updateBalanceThreshold(self.balance_threshold)
        self.pledge_limit = self.earn.pledgeAgentLimit()

    def setup(self):
        global N
        N += 1
        print(f"Scenario {N}")
        self.agents = {}
        self.trackers = {}
        self.balance_delta = defaultdict(int)
        self.token_holder = {}
        self.redeem_record = {}
        self.new_elected_validators = []
        self.candidate_hub.setControlRoundTimeTag(True)
        self.candidate_hub.setRoundTag(LOCK_DAY)
        for operator in accounts[-8:-2]:
            register_candidate(consensus=operator, operator=operator)
        turn_round()
        random_num = random.randint(0, 1)
        if random_num == 0:
            self.new_elected_validators.append(random.choice(self.candidate_hub.getCanDelegateCandidates()))
        self.earn.setUnDelegateValidatorState(False)
        self.earn.setUnDelegateValidatorIndex(0)

    def rule_mint_coin(self, st_mint_amount):
        delegator = random.choice(self.operating)
        self.__add_tracker(delegator)
        candidates = self.validator_set.getValidators()
        value = st_mint_amount
        agent = random.choice(candidates)
        msg = 'success'
        if self.paused == 1:
            msg = 'Pausable: paused'
            with brownie.reverts(msg):
                self.earn.mint(agent, {'value': value, 'from': delegator})
        elif agent in self.refused_validators:
            msg = 'Can not delegate to validator'
            with brownie.reverts(msg):
                self.earn.mint(agent, {'value': value, 'from': delegator})
        else:
            self.earn.mint(agent, {'value': value, 'from': delegator})
            self.__mint_coin(delegator, value, agent)

        print(f"[END MINT COIN] >>>  state:{msg}  delegator:{delegator}   agent:{agent}  amount:{value}")

    def rule_redeem_coin(self, st_redeem_amount):
        delegator = random.choice(self.operating)
        value = st_redeem_amount
        msg = 'success'
        if self.paused == 1:
            msg = 'Pausable: paused'
            with brownie.reverts(msg):
                self.earn.redeem(value, {'from': delegator})
        elif value > self.token_holder.get(delegator, 0):
            msg = 'ERC20: burn amount exceeds balance'
            with brownie.reverts(msg):
                self.earn.redeem(value, {'from': delegator})
        else:
            st_unlock_time = random.choice([0, 100])
            self.earn.setDayInterval(st_unlock_time)
            unlock_time = st_unlock_time * LOCK_DAY
            tx = self.earn.redeem(value, {'from': delegator})
            core = value * self.rate // RATE_MULTIPLE
            protocol_fee = core * self.protocol_fee_points // RATE_MULTIPLE
            self.__redeem_coin(delegator, tx, core - protocol_fee, value, protocol_fee, unlock_time)
        print(f"[END REDEEM COIN] >>>   state:{msg}  delegator:{delegator}  redeem_amount:{value}")

    def rule_withdraw_coin(self):
        account_amount = 0
        protocol_fee_amount = 0
        block_high_time = 0
        subtract_agents = {}
        delegator = random.choice(self.operating)
        msg = 'success'
        if len(self.redeem_record.get(delegator, [])) == 0:
            msg = "EarnEmptyRedeemRecord()"
            error_msg = encode_args_with_signature(msg, [])
            with brownie.reverts(f"typed error: {error_msg}"):
                self.earn.withdraw({'from': delegator})
        else:
            redeem_array = self.redeem_record[delegator]
            copy_redeem_array = copy(redeem_array)
            for index in range(len(redeem_array) - 1, -1, -1):
                record = redeem_array[index]
                block_high_time = history[-1].timestamp
                if record['unlockTime'] < block_high_time:
                    account_amount += record['amount']
                    protocol_fee_amount += record['protocolFee']
                    copy_redeem_array[index], copy_redeem_array[-1] = copy_redeem_array[-1], copy_redeem_array[index]
                    copy_redeem_array.pop()
            if account_amount == 0:
                msg = "EarnRedeemRecordNotFound(address)"
                error_msg = encode_args_with_signature(msg, [delegator.address])
                with brownie.reverts(f"typed error: {error_msg}"):
                    self.earn.withdraw({'from': delegator})
            else:
                redeem_amount, subtract_agents = self.__trial_withdraw_coin(account_amount + protocol_fee_amount)
                if redeem_amount > 0:
                    msg = "EarnUnDelegateFailedFinally(address,uint256)"
                    error_msg = encode_args_with_signature(msg, [str(delegator), redeem_amount])
                    with brownie.reverts(f"typed error: {error_msg}"):
                        self.earn.withdraw({'from': delegator})
                else:
                    self.earn.withdraw({'from': delegator})
                    Agent(self.agents, self.redeem_record).subtract_coin(subtract_agents=subtract_agents)
                    Agent(self.agents, self.redeem_record).withdraw_coin(delegator, copy_redeem_array)
                    self.__withdraw_coin(delegator, account_amount, protocol_fee_amount)
        print(
            f"[END  WITHDRAW COIN] >>> state:{msg}  withdraw amount:{account_amount}  "
            f"fee amount:{protocol_fee_amount}  subtract_agents:{subtract_agents} block_high_time:{block_high_time}")

    def rule_after_turn_round(self):
        del_validator = []
        candidates = self.validator_set.getValidators()
        turn_round(candidates)
        active_count = 0
        for agent in self.agents:
            if self.agents[agent]['status'] == Status.ACTIVE:
                active_count += 1
            else:
                del_validator.append(agent)
        msg = 'success'
        amount = None
        validator = None
        if active_count == 0 and (len(self.new_elected_validators) == 0 or self.candidate_hub.canDelegate(
                self.new_elected_validators[0]) is False):
            msg = "EarnValidatorsAllOffline()"
            error_msg = encode_args_with_signature(msg, [])
            with brownie.reverts(f"typed error: {error_msg}"):
                self.earn.afterTurnRound(self.new_elected_validators)
        else:
            tx = self.earn.afterTurnRound(self.new_elected_validators)
            if 'Delegate' in tx.events:
                amount = tx.events['Delegate']['amount']
                validator = tx.events['Delegate']['validator']
                Agent(self.agents, self.redeem_record).add_coin(validator, amount)
            self.__after_turn_round(del_validator)
        print(
            f"[END AFTER TURN ROUND] >>> state:{msg} validator:{validator}  delegate_amount:{amount}  del_validator:{del_validator} ")

    def rule_re_balance(self):
        msg = 'success'
        re_balance_data = {}
        if len(self.agents) <= 1:
            msg = 'EarnEmptyValidator()'
            error_msg = encode_args_with_signature(msg, [])
            with brownie.reverts(f"typed error: {error_msg}"):
                self.earn.reBalance()
        else:
            first_address = list(self.agents.keys())[0]
            first_agent_coin = self.agents[first_address]['coin']
            max_coin = first_agent_coin
            min_coin = first_agent_coin
            max_validator = first_address
            min_validator = first_address
            for validator in list(self.agents.keys())[1:]:
                validator_coin = self.agents[validator]['coin']
                if validator_coin > max_coin:
                    max_coin = validator_coin
                    max_validator = validator
                elif validator_coin < min_coin:
                    min_coin = validator_coin
                    min_validator = validator
            if max_validator == min_validator:
                msg = "EarnReBalanceNoNeed(address,address)"
                error_msg = encode_args_with_signature(msg, [max_validator, min_validator])
                with brownie.reverts(f"typed error: {error_msg}"):
                    self.earn.reBalance()
            elif max_coin - min_coin < self.balance_threshold:
                msg = "EarnReBalanceAmountDifferenceLessThanThreshold(address,address,uint256,uint256,uint256)"
                error_msg = encode_args_with_signature(msg, [max_validator, min_validator, max_coin, min_coin,
                                                             self.balance_threshold])
                with brownie.reverts(f"typed error: {error_msg}"):
                    self.earn.reBalance()
            else:
                transfer_amount = (max_coin - min_coin) // 2
                if min_validator in self.refused_validators:
                    msg = "InactiveAgent(address)"
                    error_msg = encode_args_with_signature(msg, [min_validator])
                    with brownie.reverts(f"typed error: {error_msg}"):
                        self.earn.reBalance()
                elif transfer_amount > self.pledge_limit:
                    tx = self.earn.reBalance()
                    if 'ReBalance' in tx.events:
                        self.__re_balance(transfer_amount, max_validator, min_validator)
                re_balance_data['max_validator'] = max_validator
                re_balance_data['max_coin'] = max_coin
                re_balance_data['min_validator'] = min_validator
                re_balance_data['min_coin'] = min_coin
                re_balance_data['transfer_amount'] = transfer_amount
        print(f"[END RE BALANCE] >>>  state:{msg}  re_balance_data:{re_balance_data}")

    def rule_pause(self):
        msg = 'success'
        if self.paused == 0:
            self.earn.pause()
            self.__pause(1)
        else:
            msg = "Pausable: paused"
            with brownie.reverts(msg):
                self.earn.pause()
        print(f"[END RULE PAUSE] >>> paused {self.paused}  state:{msg}")

    def rule_unpause(self):
        msg = 'success'
        if self.paused == 1:
            self.earn.unpause()
            self.__pause(0)

        else:
            msg = f"Pausable: not paused"
            with brownie.reverts(msg):
                self.earn.unpause()
        print(f"[END RULE UNPAUSE] >>> paused {self.paused}   state:{msg}")

    def rule_refuse_delegate(self):
        candidates = self.candidate_hub.getCanDelegateCandidates()
        if len(candidates) < 2:
            return
        candidate = random.choice(candidates)
        self.candidate_hub.refuseDelegate({'from': candidate})
        self.__refuse_delegate(candidate)
        print(f"[END  REFUSE DELEGATE] >>>  candidate:{candidate}")

    def rule_accept_delegate(self):
        candidates = self.candidate_hub.getCanDelegateCandidates()
        if len(candidates) < 2:
            return
        candidate = random.choice(candidates)
        self.candidate_hub.acceptDelegate({'from': candidate})
        self.__accept_delegate(candidate)
        print(f"[END  ACCEPT DELEGATE] >>> candidate:{candidate}")

    def rule_update_protocol_fee_points(self, st_fee_points):
        st_fee_points = st_fee_points * 100000
        self.earn.updateProtocolFeePoints(st_fee_points)
        self.__update_protocol_fee_points(st_fee_points)
        print(f"[END UPDATE FEE POINTS] >>> st_fee_points:{self.protocol_fee_points}")

    def invariant(self):
        print('{}start invariant{}'.format('-' * 30, '-' * 30))
        assert self.earn.getValidatorDelegateMapLength() == len(self.agents)
        for i in range(0, self.earn.getValidatorDelegateMapLength()):
            address = self.earn.getValidatorDelegateAddress(i)
            print(
                f'agents：index:{i} address:{address}  current:{self.agents[address]}  contract:{self.earn.getValidatorDelegateIndex(i)} {self.earn.getIsActive(address)}')
        for address in self.token_holder:
            print(
                f'holder: address:{address}  current:{self.token_holder[address]}  contract:{self.st_core.balanceOf(address)}')
        for address in self.redeem_record:
            print(
                f'redeemRecord: address:{address}  current:{self.redeem_record.get(str(address), [])}  contract:{self.earn.getRedeemRecords(address)}')
        for address in self.balance_delta:
            print(
                f'balanceDelta: address:{address}  current:{self.balance_delta.get(address)}  contract:{self.trackers[address].current_balance()}')
        print(f'newElectedValidators：{self.new_elected_validators}')
        print(f'reFusedValidators:{self.refused_validators}')
        print(f'balanceThreshold: current:{self.balance_threshold}  contract:{self.earn.balanceThreshold()}')
        print(f'protocolFeePoints:  current:{self.protocol_fee_points}  contract:{self.earn.protocolFeePoints()}')
        print(f'exchangeRate:  current:{self.rate}  contract:{get_exchangerate()}')
        print(f'toWithdrawAmount: current:{self.to_withdraw_amount}   contract:{self.earn.toWithdrawAmount()}')
        assert self.earn.balanceThreshold() == self.balance_threshold
        assert self.protocol_fee_points == self.earn.protocolFeePoints()
        assert self.rate == get_exchangerate()
        assert self.to_withdraw_amount == self.earn.toWithdrawAmount()
        for i in range(0, self.earn.getValidatorDelegateMapLength()):
            address = self.earn.getValidatorDelegateAddress(i)
            assert self.agents[address]['coin'] == self.earn.getValidatorDelegateIndex(i)
        for i in self.token_holder:
            assert self.st_core.balanceOf(i) == self.token_holder[i]
        for record in self.redeem_record:
            actual_redeem_record = self.earn.getRedeemRecords(record)
            for index, value in enumerate(self.redeem_record[record]):
                assert value['amount'] == actual_redeem_record[index][2], 'amount'
                assert value['stCore'] == actual_redeem_record[index][3], 'stCore'
                assert value['protocolFee'] == actual_redeem_record[index][4], 'protocolFee'
        print('{}end invariant{}'.format('-' * 30, '-' * 30))

    def teardown(self):
        print(f"{'@' * 51} teardown {'@' * 51}")
        trackers = self.trackers
        print('check balance start')
        for address in trackers:
            expect_amount = self.balance_delta[address]
            actual_amount = trackers[address].delta()
            print(f"assert balance: {address} -> expect_amount:{expect_amount}  actual_amount: {actual_amount}")
            assert expect_amount == actual_amount, 'check balance error'

    def __update_protocol_fee_points(self, st_fee_points):
        self.protocol_fee_points = st_fee_points

    def __pause(self, status):
        self.paused = status

    def __refuse_delegate(self, operator):
        # modify state
        if operator in self.agents:
            self.agents[operator]['status'] = Status.REFUSED
        if operator not in self.refused_validators:
            self.refused_validators.append(operator)

    def __accept_delegate(self, operator):
        # modify state
        if operator in self.agents:
            self.agents[operator]['status'] = Status.ACTIVE
        if operator in self.refused_validators:
            self.refused_validators.remove(operator)

    def __mint_coin(self, delegator, amount, agent):
        self.balance_delta[delegator] -= amount
        Token(self.token_holder).mint_token(delegator, amount, self.rate)
        Agent(self.agents, self.redeem_record).add_coin(agent, amount, status=Status.ACTIVE)

    def __redeem_coin(self, delegator, tx, core, st_core, fee, unlock_time):
        Token(self.token_holder).burn_token(delegator, st_core)
        Agent(self.agents, self.redeem_record).redeem_coin(delegator, tx, core, st_core, fee, unlock_time)
        self.to_withdraw_amount += core + fee

    def __withdraw_coin(self, delegator, amount, protocol_fee_amount):
        self.balance_delta[delegator] += amount
        self.to_withdraw_amount -= amount + protocol_fee_amount

    def __re_balance(self, transfer_amount, max_validator, min_validator):
        new_agents = {max_validator: transfer_amount}
        # Validators with fewer coins will receive an increase, while those with more coins will be deducted.
        Agent(self.agents, self.redeem_record).subtract_coin(subtract_agents=new_agents)
        Agent(self.agents, self.redeem_record).add_coin(min_validator, transfer_amount)

    def __after_turn_round(self, del_validator):
        # Delete inactive validators
        for validator in del_validator:
            i = list(self.agents.keys()).index(validator)
            j = -1
            tups = list(self.agents.items())
            tups[i], tups[j] = tups[j], tups[i]
            tups.pop()
            self.agents = dict(tups)
        # Calculate exchange rate
        total_supply = 0
        for delegator in self.token_holder:
            total_supply += self.token_holder[delegator]
        if total_supply > 0:
            _capital = 0
            for agent in self.agents:
                _capital += self.agents[agent]['coin']
            self.rate = (_capital - self.to_withdraw_amount) * RATE_MULTIPLE // total_supply
        return self.rate

    def __add_tracker(self, address):
        if address not in self.trackers:
            self.trackers[address] = get_tracker(address)

    def __trial_withdraw_coin(self, amount):
        pledge_limit = self.pledge_limit
        redeem_amount = amount
        deduction = {}
        for agent in self.agents:
            validator_amount = self.agents[agent]['coin']
            if validator_amount == 0:
                continue
            if redeem_amount == validator_amount:
                redeem_amount = 0
                deduction[agent] = validator_amount
                break
            elif redeem_amount < validator_amount:
                if validator_amount >= redeem_amount + pledge_limit:
                    deduction[agent] = redeem_amount
                    redeem_amount = 0
                    break
                else:
                    undelegate_amount = redeem_amount - pledge_limit
                    if undelegate_amount > pledge_limit:
                        redeem_amount -= undelegate_amount
                        deduction[agent] = undelegate_amount

            else:
                if redeem_amount >= validator_amount + pledge_limit:
                    redeem_amount -= validator_amount
                    deduction[agent] = validator_amount

                else:
                    if (validator_amount - pledge_limit) > pledge_limit:
                        redeem_amount -= (validator_amount - pledge_limit)
                        deduction[agent] = validator_amount - pledge_limit

        return redeem_amount, deduction


def test_stateful(state_machine, earn, stcore,
                  candidate_hub, pledge_agent,
                  validator_set, btc_light_client,
                  slash_indicator):
    state_machine(
        StateMachine,
        earn,
        stcore,
        candidate_hub,
        pledge_agent,
        validator_set,
        btc_light_client,
        slash_indicator,
        settings={"max_examples": 500, "stateful_step_count": 50}
    )
