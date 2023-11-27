import time
from brownie import accounts, Wei
from .common import get_exchangerate
import brownie
import pytest
from web3 import Web3
from .common import register_candidate, turn_round
from .utils import get_tracker, expect_event, expect_query, encode_args_with_signature, expect_event_not_emitted

MIN_DELEGATE_VALUE = Wei(10000)
RATE_MULTIPLE = 1000000
BLOCK_REWARD = 0
PLEDGE_LIMIT = 0
ONE_ETHER = Web3.toWei(1, 'ether')
TX_FEE = 100


@pytest.fixture(scope="module", autouse=True)
def deposit_for_reward(validator_set):
    accounts[-2].transfer(validator_set.address, Web3.toWei(100000, 'ether'))


@pytest.fixture(scope="module", autouse=True)
def set_block_reward(validator_set):
    global BLOCK_REWARD
    block_reward = validator_set.blockReward()
    block_reward_incentive_percent = validator_set.blockRewardIncentivePercent()
    total_block_reward = block_reward + TX_FEE
    BLOCK_REWARD = int(total_block_reward * (100 - block_reward_incentive_percent) / 100)


@pytest.fixture(scope="module", autouse=True)
def set_agent_pledge_contract_address(candidate_hub, earn, pledge_agent, validator_set, stcore):
    round_time_tag = 7
    candidate_hub.setControlRoundTimeTag(True)
    candidate_hub.setRoundTag(round_time_tag)
    earn.setContractAddress(candidate_hub.address, pledge_agent.address, candidate_hub.getRoundTag())
    earn.updateOperator(accounts[0].address)


@pytest.fixture(scope="module", autouse=True)
def init_contracts_variable():
    global LOCK_DAY, INIT_DAY_INTERVAL, PLEDGE_LIMIT
    LOCK_DAY = 7
    INIT_DAY_INTERVAL = 86400
    PLEDGE_LIMIT = 100


@pytest.fixture()
def update_lock_time(earn):
    earn.setInitDayInterval(0)
    earn.setReduceTime(10)


def test_delegate_staking(earn, pledge_agent, stcore):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    tx = earn.mint(operators[0], {'value': ONE_ETHER * 30, 'from': accounts[0]})
    operator_address = tx.events['delegatedCoin']['agent']
    assert operator_address in operators
    validator_delegate = earn.getValidatorDelegate(operator_address)
    assert validator_delegate == ONE_ETHER * 30
    delegator_info0 = pledge_agent.getDelegator(operator_address, earn.address)
    expect_query(delegator_info0, {'deposit': 0,
                                   'newDeposit': ONE_ETHER * 30})
    expect_event(tx, "delegatedCoin", {
        "agent": operator_address,
        "delegator": earn.address,
        "amount": ONE_ETHER * 30,
        "totalAmount": ONE_ETHER * 30,
    })
    expect_event(tx, "Mint", {
        "account": accounts[0].address,
        "core": ONE_ETHER * 30,
        "stCore": ONE_ETHER * 30
    })
    expect_event(tx, "Transfer", {
        "from": '0x0000000000000000000000000000000000000000',
        "to": accounts[0].address,
        "value": ONE_ETHER * 30
    })
    assert stcore.totalSupply() == ONE_ETHER * 30
    assert stcore.balanceOf(accounts[0]) == ONE_ETHER * 30
    assert stcore.balanceOf(accounts[1]) == 0


def test_mint_non_validator(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    with brownie.reverts("Can not delegate to validator"):
        earn.mint(accounts[1], {'value': ONE_ETHER * 30, 'from': accounts[0]})


def test_mint_validator_reject_delegate(earn, candidate_hub):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    candidate_hub.refuseDelegate({'from': operators[1]})
    with brownie.reverts("Can not delegate to validator"):
        earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[0]})


def test_mint_invalid_validator(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    with brownie.reverts("Can not delegate to validator"):
        earn.mint('0x0000000000000000000000000000000000000000', {'value': ONE_ETHER * 30, 'from': accounts[0]})


def test_delegate_staking_core_exchange_rate(earn, stcore):
    operators = []
    consensuses = []
    total_supply = MIN_DELEGATE_VALUE
    total_reward = BLOCK_REWARD // 2
    total_delegate_amount = MIN_DELEGATE_VALUE
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[0]})
    turn_round(consensuses, round_count=2, trigger=True)
    total_delegate_amount += total_reward
    exchange_rate = total_delegate_amount * RATE_MULTIPLE // total_supply
    token_value = MIN_DELEGATE_VALUE * RATE_MULTIPLE // exchange_rate
    total_supply += token_value
    tx = earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    expect_event(tx, "Mint", {
        "account": accounts[1].address,
        "core": MIN_DELEGATE_VALUE,
        "stCore": token_value
    })
    assert stcore.totalSupply() == total_supply
    assert stcore.balanceOf(accounts[0]) == total_supply - token_value
    assert stcore.balanceOf(accounts[1]) == token_value


def test_delegate_staking_success(earn, pledge_agent, stcore):
    operators = []
    consensuses = []
    total_supply = MIN_DELEGATE_VALUE
    total_reward = BLOCK_REWARD // 2
    total_delegate_amount = MIN_DELEGATE_VALUE
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(consensuses, round_count=2, trigger=True)
    total_delegate_amount += total_reward
    exchange_rate = total_delegate_amount * RATE_MULTIPLE // total_supply
    token_value = MIN_DELEGATE_VALUE * RATE_MULTIPLE // exchange_rate
    total_supply += token_value
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    delegate_info = earn.getValidatorDelegate(operators[0])
    total_delegate_amount += MIN_DELEGATE_VALUE
    delegator_info0 = pledge_agent.getDelegator(operators[0], earn.address)
    expect_query(delegator_info0, {'deposit': MIN_DELEGATE_VALUE,
                                   'newDeposit': total_delegate_amount})
    assert delegate_info == total_delegate_amount
    assert stcore.totalSupply() == total_supply
    assert stcore.balanceOf(accounts[0]) == total_supply - token_value
    assert stcore.balanceOf(accounts[1]) == token_value


def test_invalid_delegate_amount(earn):
    operator = accounts[3]
    register_candidate(operator=operator)
    register_candidate(operator=accounts[-3])
    turn_round()
    earn.afterTurnRound([accounts[-3]])
    error_msg = encode_args_with_signature("EarnMintAmountTooSmall(address,uint256)", [str(accounts[0]), int(99)])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.mint(operator, {'value': 99})


def test_invalid_validator(earn):
    turn_round()
    with brownie.reverts("Can not delegate to validator"):
        earn.mint(accounts[0], {"value": ONE_ETHER * 30})


def test_delegate_staking_failed(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.updateMintMinLimit(80)
    with brownie.reverts("deposit is too small"):
        earn.mint(operators[0], {'value': 99})


def test_multiple_users_mint(earn, stcore):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.afterTurnRound([operators[-1]])
    delegate_staking_information = [(operators[0], ONE_ETHER * 22, accounts[0]),
                                    (operators[1], ONE_ETHER * 11, accounts[0]),
                                    (operators[2], ONE_ETHER * 3, accounts[1]),
                                    (operators[1], ONE_ETHER * 6, accounts[2])]
    for index, delegate in enumerate(delegate_staking_information):
        amount = delegate[1]
        account = delegate[2]
        tx = earn.mint(operators[0], {'value': amount, 'from': account})
        assert 'delegatedCoin' in tx.events
        assert 'Transfer' in tx.events
        assert tx.events['delegatedCoin']['amount'] == amount
        assert tx.events['delegatedCoin']['delegator'] == earn.address
    assert stcore.totalSupply() == ONE_ETHER * 42
    assert stcore.balanceOf(accounts[0]) == ONE_ETHER * 33
    assert stcore.balanceOf(accounts[1]) == ONE_ETHER * 3
    assert stcore.balanceOf(accounts[2]) == ONE_ETHER * 6


def test_trigger_rewards_claim_and_reinvest(earn, pledge_agent, candidate_hub):
    operators = []
    consensuses = []
    delegate_amount = MIN_DELEGATE_VALUE * 3
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[1], {'value': delegate_amount})
    turn_round(consensuses, round_count=2)
    tx = earn.afterTurnRound([accounts[-3]])
    assert tx.events['claimedReward']['amount'] == tx.events['delegatedCoin']['amount'] == BLOCK_REWARD // 2
    delegator_info0 = pledge_agent.getDelegator(tx.events['delegatedCoin']['agent'], earn.address)
    assert tx.events['delegatedCoin']['totalAmount'] == delegate_amount + BLOCK_REWARD // 2 == delegator_info0[
        'newDeposit']
    expect_event(tx, "Delegate", {
        "validator": operators[1].address,
        "amount": BLOCK_REWARD // 2,
    })
    expect_event(tx, "CalculateExchangeRate", {
        "round": candidate_hub.getRoundTag(),
        "exchangeRate": (delegate_amount + BLOCK_REWARD // 2) * RATE_MULTIPLE / delegate_amount,
    })


def test_trigger_handle_staking_failure(earn, candidate_hub):
    operators = []
    consensuses = []
    delegate_amount = MIN_DELEGATE_VALUE * 3
    for operator in accounts[2:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': delegate_amount})
    turn_round(consensuses, trigger=True)
    candidate_hub.refuseDelegate({'from': operators[0]})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    turn_round(consensuses, round_count=3, trigger=True)
    delegate_info = earn.getValidatorDelegate(operators[1])
    assert earn.getValidatorDelegateMapLength() == 1
    assert delegate_info == delegate_amount + MIN_DELEGATE_VALUE + BLOCK_REWARD + BLOCK_REWARD // 2


def test_trigger_reward_too_small(earn, validator_set):
    operators = []
    block_reward0 = 8000
    block_reward1 = 200
    total_reward0 = (block_reward0 + 100) * 90 / 100
    total_reward1 = (block_reward1 + 100) * 90 / 100 // 2
    consensuses = []
    delegate_amount = MIN_DELEGATE_VALUE * 3
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': delegate_amount})
    turn_round(trigger=True)
    validator_set.updateBlockReward(block_reward0)
    earn.updatePledgeAgentLimit(4000)
    tracker0 = get_tracker(earn)
    tx = turn_round(consensuses, round_count=1, trigger=True)
    assert 'delegatedCoin' not in tx.events
    delegate_info = earn.getValidatorDelegate(operators[0])
    assert tracker0.delta() == total_reward0 // 2 == tx.events['claimedReward']['amount']
    assert delegate_info == delegate_amount
    validator_set.updateBlockReward(block_reward1)
    turn_round(consensuses, round_count=1, trigger=True)
    validator_set.updateBlockReward(block_reward0)
    assert get_exchangerate() == RATE_MULTIPLE
    tx1 = turn_round(consensuses, round_count=1, trigger=True)
    assert 'delegatedCoin' in tx1.events
    delegate_info = earn.getValidatorDelegate(operators[0])
    assert tracker0.delta() == -total_reward0 // 2
    assert tracker0.balance() == 0
    assert delegate_info == total_reward0 + delegate_amount + total_reward1
    assert tx1.events['delegatedCoin']['amount'] == total_reward0 + total_reward1
    assert get_exchangerate() == (total_reward0 + delegate_amount + total_reward1) * RATE_MULTIPLE / delegate_amount


def test_trigger_delegate_failed(earn, validator_set, candidate_hub):
    operators = []
    earn.updatePledgeAgentLimit(4000)
    block_reward0 = 8000
    total_reward0 = (block_reward0 + 100) * 90 / 100
    consensuses = []
    delegate_amount = MIN_DELEGATE_VALUE * 3
    for operator in accounts[2:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': delegate_amount})
    turn_round(trigger=True)
    validator_set.updateBlockReward(block_reward0)
    tx = turn_round(consensuses, round_count=1, trigger=True)
    assert earn.balance() == total_reward0 // 2
    expect_event_not_emitted(tx, "Delegate")
    earn.mint(operators[1], {'value': delegate_amount})
    candidate_hub.refuseDelegate({'from': operators[0]})
    tx = turn_round(consensuses, round_count=1, trigger=True)
    delegate_info = earn.getValidatorDelegate(operators[0])
    assert earn.balance() == 0
    assert delegate_info == 0
    expect_event(tx, "Delegate", {
        "validator": operators[1],
        "amount": delegate_amount + total_reward0
    })


def test_trigger_claim_reward_failed_delegate(earn):
    operators = []
    consensuses = []
    delegate_amount = MIN_DELEGATE_VALUE
    total_reward = BLOCK_REWARD // 2
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': delegate_amount})
    turn_round(trigger=True)
    earn.setAfterTurnRoundClaimReward(False)
    tx0 = turn_round(consensuses, round_count=1, trigger=True)
    expect_event_not_emitted(tx0, 'claimedReward')
    assert earn.balance() == 0
    tx1 = earn.mint(operators[0], {'value': delegate_amount})
    assert tx1.events['delegatedCoin']['amount'] == delegate_amount
    assert earn.balance() == tx1.events['claimedReward']['amount'] == BLOCK_REWARD // 2
    tx2 = turn_round(consensuses, trigger=True)
    assert earn.balance() == BLOCK_REWARD // 2
    assert tx1.events['claimedReward']['amount'] == tx2.events['delegatedCoin']['amount'] == BLOCK_REWARD // 2
    assert get_exchangerate() == (delegate_amount * 2 + total_reward) * RATE_MULTIPLE // (delegate_amount * 2)
    earn.setAfterTurnRoundClaimReward(True)
    tx3 = turn_round(consensuses, trigger=True)
    assert earn.balance() == 0
    assert tx3.events['claimedReward']['amount'] == BLOCK_REWARD // 2
    expect_event(tx3, "delegatedCoin", {
        "amount": BLOCK_REWARD,
        "totalAmount": delegate_amount * 2 + BLOCK_REWARD // 2 * 3
    })
    assert get_exchangerate() == (delegate_amount * 2 + total_reward * 3) * RATE_MULTIPLE // (delegate_amount * 2)


def test_trigger_claim_reward_failed_redeem(earn):
    operators = []
    consensuses = []
    delegate_amount = MIN_DELEGATE_VALUE
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': delegate_amount})
    turn_round(trigger=True)
    earn.setAfterTurnRoundClaimReward(False)
    tx0 = turn_round(consensuses, round_count=1, trigger=True)
    expect_event_not_emitted(tx0, 'claimedReward')
    assert earn.balance() == 0
    token_value = delegate_amount // 2
    tx1 = earn.redeem(token_value)
    expect_event_not_emitted(tx1, 'claimedReward')


def test_trigger_claim_reward_failed_withdraw(earn, update_lock_time):
    operators = []
    consensuses = []
    delegate_amount = MIN_DELEGATE_VALUE
    total_reward = BLOCK_REWARD // 2
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': delegate_amount})
    turn_round(trigger=True)
    earn.setAfterTurnRoundClaimReward(False)
    tx0 = turn_round(consensuses, round_count=1, trigger=True)
    expect_event_not_emitted(tx0, 'claimedReward')
    assert earn.balance() == 0
    token_value = delegate_amount // 2
    earn.redeem(token_value)
    tx1 = earn.withdraw()
    assert tx1.events['undelegatedCoin']['amount'] == token_value
    assert earn.balance() == tx1.events['claimedReward']['amount'] == BLOCK_REWARD // 2
    tx2 = turn_round(consensuses, trigger=True)
    assert earn.balance() == total_reward - total_reward // 2
    assert tx1.events['claimedReward']['amount'] == tx2.events['delegatedCoin']['amount'] == BLOCK_REWARD // 2
    assert get_exchangerate() == (delegate_amount + total_reward - delegate_amount // 2) * RATE_MULTIPLE // (
            delegate_amount // 2)
    earn.setAfterTurnRoundClaimReward(True)
    tx3 = turn_round(consensuses, trigger=True)
    total_amount = token_value + BLOCK_REWARD + total_reward - total_reward // 2
    assert earn.balance() == 0
    assert tx3.events['claimedReward']['amount'] == BLOCK_REWARD // 2
    expect_event(tx3, "delegatedCoin", {
        "amount": total_reward + (total_reward - total_reward // 2),
        "totalAmount": total_amount
    })
    assert get_exchangerate() == total_amount * RATE_MULTIPLE // token_value


def test_minimum_reinvestment_limit_in_trigger_reward(earn, validator_set):
    operators = []
    block_reward0 = 8000
    total_reward0 = (block_reward0 + 100) * 90 / 100
    consensuses = []
    earn.updatePledgeAgentLimit(4000)
    delegate_amount = MIN_DELEGATE_VALUE * 3
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': delegate_amount})
    turn_round(trigger=True)
    validator_set.updateBlockReward(block_reward0)
    tx = turn_round(consensuses, round_count=1, trigger=True)
    expect_event_not_emitted(tx, 'Delegate')
    assert earn.balance() == total_reward0 // 2
    tx1 = turn_round(consensuses, round_count=1, trigger=True)
    delegate_info = earn.getValidatorDelegate(operators[0])
    assert earn.balance() == 0
    assert delegate_info == delegate_amount + total_reward0
    assert 'Delegate' in tx1.events
    assert get_exchangerate() == (total_reward0 + delegate_amount) * RATE_MULTIPLE / delegate_amount


def test_trigger_calculate_exchange_rate_scenario_1(earn, pledge_agent, validator_set, candidate_hub):
    operators = []
    consensuses = []
    total_reward = BLOCK_REWARD // 4 * 2
    block_reward0 = 40000
    total_reward0 = (block_reward0 + 100) * 90 / 100 // 4 * 2
    total_supply = MIN_DELEGATE_VALUE * 4
    total_delegate_amount = MIN_DELEGATE_VALUE * 4
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[0]})
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(trigger=True)
    turn_round(consensuses, round_count=1, trigger=True)
    total_delegate_amount += total_reward
    assert get_exchangerate() == total_delegate_amount * RATE_MULTIPLE / total_supply
    validator_set.updateBlockReward(block_reward0)
    tx = turn_round(consensuses, round_count=1, trigger=True)
    total_delegate_amount += total_reward0
    assert get_exchangerate() == total_delegate_amount * RATE_MULTIPLE / total_supply
    expect_event(tx, "CalculateExchangeRate", {
        "round": candidate_hub.getRoundTag(),
        "exchangeRate": total_delegate_amount * RATE_MULTIPLE / total_supply,
    })


def test_trigger_calculate_exchange_rate_scenario_2(earn, pledge_agent, stcore):
    operators = []
    consensuses = []
    total_reward = BLOCK_REWARD // 2 // 2
    total_supply = MIN_DELEGATE_VALUE * 2
    total_delegate_amount = MIN_DELEGATE_VALUE * 2
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(trigger=True)
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(consensuses, round_count=1, trigger=True)
    added_amount = total_reward + MIN_DELEGATE_VALUE
    total_delegate_amount += added_amount
    total_supply += MIN_DELEGATE_VALUE
    assert get_exchangerate() == total_delegate_amount * RATE_MULTIPLE // total_supply
    turn_round(consensuses, round_count=1, trigger=True)
    total_delegate_amount += BLOCK_REWARD // 2 * 3 / 5
    assert int(stcore.totalSupply()) == total_supply
    assert get_exchangerate() == total_delegate_amount * RATE_MULTIPLE // total_supply


def test_trigger_calculate_exchange_rate_scenario_3(earn, pledge_agent, stcore):
    operators = []
    consensuses = []
    total_reward = BLOCK_REWARD // 2 // 2
    total_supply = MIN_DELEGATE_VALUE * 2
    total_delegate_amount = MIN_DELEGATE_VALUE * 2
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[0]})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(trigger=True)
    turn_round(consensuses, round_count=1, trigger=True)
    total_delegate_amount += total_reward
    exchange_rate = total_delegate_amount * RATE_MULTIPLE / total_supply
    assert get_exchangerate() == exchange_rate
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    stcore_value = MIN_DELEGATE_VALUE * RATE_MULTIPLE // exchange_rate
    total_supply += stcore_value
    turn_round(consensuses, round_count=1, trigger=True)
    total_delegate_amount += (total_reward + MIN_DELEGATE_VALUE)
    assert stcore.totalSupply() == total_supply
    assert get_exchangerate() == total_delegate_amount * RATE_MULTIPLE // total_supply


def test_trigger_calculate_exchange_rate_scenario_4(earn, pledge_agent, validator_set):
    operators = []
    consensuses = []
    block_reward0 = 360 * ONE_ETHER
    validator_set.updateBlockReward(block_reward0)
    tx_fee = 0.01 * ONE_ETHER
    total_reward0 = (block_reward0 + tx_fee) * 90 / 100 // 4
    total_supply = ONE_ETHER * 2000
    delegate_amount = ONE_ETHER * 1000
    total_delegate_amount = ONE_ETHER * 2000
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    pledge_agent.delegateCoin(operators[0], {'value': delegate_amount, 'from': accounts[1]})
    pledge_agent.delegateCoin(operators[0], {'value': delegate_amount, 'from': accounts[1]})
    earn.mint(operators[0], {'value': delegate_amount})
    earn.mint(operators[0], {'value': delegate_amount, 'from': accounts[1]})
    turn_round(trigger=True)
    turn_round(consensuses, round_count=1, tx_fee=tx_fee, trigger=True)
    total_delegate_amount += total_reward0
    exchange_rate = total_delegate_amount * RATE_MULTIPLE // total_supply
    assert get_exchangerate() == exchange_rate
    earn.mint(operators[0], {'value': delegate_amount})
    pledge_agent.delegateCoin(operators[0], {'value': delegate_amount, 'from': accounts[1]})
    turn_round(consensuses, round_count=1, tx_fee=tx_fee, trigger=True)
    stcore_value = delegate_amount * RATE_MULTIPLE // exchange_rate
    total_supply += stcore_value
    total_delegate_amount += delegate_amount + total_reward0
    assert get_exchangerate() == total_delegate_amount * RATE_MULTIPLE // total_supply


def test_redemption_successful(earn, stcore):
    operators = []
    consensuses = []
    total_reward = BLOCK_REWARD // 2
    total_supply = MIN_DELEGATE_VALUE * 2
    total_delegate_amount = MIN_DELEGATE_VALUE * 2
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(trigger=True)
    turn_round(consensuses, round_count=1, trigger=True)
    token_value = MIN_DELEGATE_VALUE
    total_delegate_amount += total_reward
    exchange_rate = total_delegate_amount * RATE_MULTIPLE // total_supply
    exchange_amount = token_value * exchange_rate // RATE_MULTIPLE
    assert stcore.totalSupply() == total_supply
    tx = earn.redeem(token_value)
    expect_event(tx, "Transfer", {
        "from": accounts[0],
        "to": '0x0000000000000000000000000000000000000000',
        "value": token_value,
    })
    expect_event_not_emitted(tx, 'UnDelegate')
    expect_event(tx, "Redeem", {
        "account": accounts[0].address,
        "stCore": token_value,
        "core": exchange_amount,
        "protocolFee": 0
    })
    assert earn.getValidatorDelegate(operators[0]) == total_delegate_amount
    assert earn.balance() == 0
    assert stcore.balanceOf(accounts[0]) == 0
    redeem_info = earn.getRedeemRecords(accounts[0])[0]
    interval = INIT_DAY_INTERVAL * LOCK_DAY
    redeem_time = redeem_info[0] // 1000
    now_time = time.time() // 1000
    assert redeem_time == now_time
    assert redeem_info[1] - redeem_info[0] == interval
    assert redeem_info[2] == exchange_amount
    assert redeem_info[3] == token_value


def test_coin_redemption_in_second_round_successful(earn, pledge_agent, stcore):
    operators = []
    consensuses = []
    total_supply = MIN_DELEGATE_VALUE * 2
    total_reward = BLOCK_REWARD // 2
    total_delegate_amount = MIN_DELEGATE_VALUE * 2
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(trigger=True)
    turn_round(consensuses, round_count=1, trigger=True)
    total_delegate_amount += total_reward // 2
    token_value = MIN_DELEGATE_VALUE // 2
    exchange_amount = token_value * get_exchangerate() / RATE_MULTIPLE
    assert stcore.totalSupply() == total_supply
    earn.redeem(token_value)
    redeem_info = earn.getRedeemRecords(accounts[0])[0]
    assert redeem_info[2] == exchange_amount
    assert redeem_info[3] == token_value


def test_withdraw_and_undelegate_from_single_validator(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(trigger=True)
    token_value = MIN_DELEGATE_VALUE
    tracker0 = get_tracker(accounts[0])
    earn.redeem(token_value)
    redeem_info = earn.getRedeemRecords(accounts[0])[0]
    assert redeem_info[2] == MIN_DELEGATE_VALUE
    assert redeem_info[3] == MIN_DELEGATE_VALUE
    earn.withdraw()
    assert tracker0.delta() == token_value
    assert earn.getValidatorDelegate(operators[0]) == 0


def test_withdraw_all_tokens_from_validators(earn, stcore, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[2:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    turn_round(trigger=True)
    token_value = MIN_DELEGATE_VALUE * 2
    assert stcore.totalSupply() == token_value
    earn.redeem(MIN_DELEGATE_VALUE)
    earn.redeem(MIN_DELEGATE_VALUE)
    redeem_info = earn.getRedeemRecords(accounts[0])[0]
    assert redeem_info[2] == MIN_DELEGATE_VALUE
    assert redeem_info[3] == MIN_DELEGATE_VALUE
    earn.withdraw()
    assert earn.getValidatorDelegate(operators[0]) == 0
    assert earn.getValidatorDelegate(operators[1]) == 0


def test_withdraw_and_undelegate_from_multiple_validators(earn, pledge_agent, stcore, update_lock_time):
    operators = []
    consensuses = []
    total_reward = BLOCK_REWARD // 4 * 2
    total_supply = MIN_DELEGATE_VALUE * 2
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    pledge_agent.delegateCoin(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(trigger=True)
    stcore.transfer(accounts[0], MIN_DELEGATE_VALUE, {'from': accounts[1]})
    turn_round(consensuses, round_count=1, trigger=True)
    token_value = MIN_DELEGATE_VALUE * 2
    assert stcore.totalSupply() == total_supply
    earn.redeem(token_value)
    redeem_info = earn.getRedeemRecords(accounts[0])[0]
    assert redeem_info[2] == token_value + total_reward
    assert redeem_info[3] == token_value
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert tracker0.delta() == token_value + total_reward
    assert earn.getValidatorDelegate(operators[0]) == earn.getValidatorDelegate(operators[1]) == 0


def test_withdraw_and_undelegate(earn, pledge_agent, update_lock_time):
    total_reward = BLOCK_REWARD // 4
    operators = []
    consensuses = []
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(trigger=True)
    turn_round(consensuses, round_count=1, trigger=True)
    token_value = MIN_DELEGATE_VALUE // 2
    tracker0 = get_tracker(accounts[0])
    exchange_amount = token_value * get_exchangerate() / RATE_MULTIPLE
    earn.redeem(token_value)
    earn.setUnDelegateValidatorState(False)
    earn.withdraw()
    assert tracker0.delta() == exchange_amount
    assert earn.getValidatorDelegate(operators[0]) == MIN_DELEGATE_VALUE + total_reward - exchange_amount


def test_redeem_below_min_limit(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    token_value = 99
    error_msg = encode_args_with_signature("EarnSTCoreTooSmall(address,uint256)",
                                           [accounts[0].address, token_value])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.redeem(token_value)


def test_redeem_without_mint(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    with brownie.reverts("ERC20: burn amount exceeds balance"):
        earn.redeem(MIN_DELEGATE_VALUE)


def test_redeem_no_investment(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    token_value = MIN_DELEGATE_VALUE
    with brownie.reverts("ERC20: burn amount exceeds balance"):
        earn.redeem(token_value)


def test_redeem_no_token(earn, stcore):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    stcore.transfer(accounts[1], MIN_DELEGATE_VALUE // 2)
    token_value = MIN_DELEGATE_VALUE
    with brownie.reverts("ERC20: burn amount exceeds balance"):
        earn.redeem(token_value)


def test_redeem_exceed_token_limit(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    token_value = MIN_DELEGATE_VALUE + 100
    with brownie.reverts("ERC20: burn amount exceeds balance"):
        earn.redeem(token_value)


def test_redeem_exceed_own_token_balance(earn, stcore):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    stcore.transfer(accounts[1], MIN_DELEGATE_VALUE // 2)
    token_value = MIN_DELEGATE_VALUE
    with brownie.reverts("ERC20: burn amount exceeds balance"):
        earn.redeem(token_value)


def test_redeem_all_tokens_single_user(earn, stcore, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(trigger=True)
    turn_round(consensuses, round_count=1, trigger=True)
    stcore.transfer(accounts[0], MIN_DELEGATE_VALUE, {'from': accounts[1]})
    token_value = MIN_DELEGATE_VALUE * 2
    earn.redeem(token_value)
    assert earn.getRedeemRecords(accounts[0])[0][2] == token_value + BLOCK_REWARD
    assert earn.getRedeemRecords(accounts[0])[0][3] == token_value


def test_redeem_without_rewards(earn, stcore, update_lock_time):
    operators = []
    consensuses = []
    total_supply = MIN_DELEGATE_VALUE * 2
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    tx = earn.redeem(MIN_DELEGATE_VALUE)
    expect_event(tx, "Redeem", {
        "account": accounts[0].address,
        "stCore": MIN_DELEGATE_VALUE,
        "core": MIN_DELEGATE_VALUE,
        "protocolFee": 0,
    }, idx=0)
    total_supply -= MIN_DELEGATE_VALUE
    turn_round(trigger=True)
    turn_round(consensuses, round_count=1, trigger=True)
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 3})
    token_value = MIN_DELEGATE_VALUE * 3 * RATE_MULTIPLE // get_exchangerate()
    earn.redeem(token_value)
    assert stcore.balanceOf(accounts[0]) == 0
    assert stcore.totalSupply() == total_supply
    redeem_info = earn.getRedeemRecords(accounts[0])[1]
    assert redeem_info[2] == token_value * get_exchangerate() // RATE_MULTIPLE
    assert redeem_info[3] == token_value
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert tracker0.delta() == token_value * get_exchangerate() // RATE_MULTIPLE + MIN_DELEGATE_VALUE


def test_withdraw_without_redemption_record(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    error_msg = encode_args_with_signature("EarnEmptyRedeemRecord()",
                                           [])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.withdraw()


def test_user_redeem_unlocked_token(earn, stcore, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    earn.redeem(MIN_DELEGATE_VALUE)
    assert len(earn.getRedeemRecords(accounts[0])) == 1
    tracker0 = get_tracker(accounts[0])
    tx = earn.withdraw()
    assert len(earn.getRedeemRecords(accounts[0])) == 0
    assert tracker0.delta() == MIN_DELEGATE_VALUE
    assert stcore.balanceOf(accounts[0]) == 0
    expect_event(tx, "Withdraw", {
        "account": accounts[0].address,
        "amount": MIN_DELEGATE_VALUE
    })


def test_multiple_users_unlock_tokens(earn, pledge_agent, update_lock_time):
    total_supply = MIN_DELEGATE_VALUE * 2
    operators = []
    consensuses = []
    total_reward = BLOCK_REWARD // 2
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    pledge_agent.delegateCoin(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(trigger=True)
    turn_round(consensuses, trigger=True)
    exchange_rate = (MIN_DELEGATE_VALUE * 2 + total_reward + total_reward // 2) * RATE_MULTIPLE // total_supply
    earn.redeem(MIN_DELEGATE_VALUE)
    earn.redeem(MIN_DELEGATE_VALUE // 2, {'from': accounts[1]})
    tracker0 = get_tracker(accounts[0])
    tracker1 = get_tracker(accounts[1])
    earn.withdraw({'from': accounts[1]})
    earn.withdraw()
    assert tracker0.delta() == MIN_DELEGATE_VALUE * exchange_rate // RATE_MULTIPLE
    assert tracker1.delta() == MIN_DELEGATE_VALUE // 2 * exchange_rate // RATE_MULTIPLE


def test_multiple_users_unlock_and_redeem_tokens_sequential(earn, update_lock_time):
    total_supply = MIN_DELEGATE_VALUE * 2
    total_delegate = MIN_DELEGATE_VALUE * 2
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(consensuses, round_count=2, trigger=True)
    total_delegate += BLOCK_REWARD
    exchange_reta = total_delegate * RATE_MULTIPLE // total_supply
    token_value = MIN_DELEGATE_VALUE // 2
    earn.redeem(token_value)
    total_supply -= token_value
    redeem_amount0 = token_value * exchange_reta // RATE_MULTIPLE
    total_delegate -= redeem_amount0
    turn_round(consensuses, trigger=True)
    total_delegate += BLOCK_REWARD
    exchange_reta = total_delegate * RATE_MULTIPLE // total_supply
    earn.redeem(token_value, {'from': accounts[1]})
    redeem_amount1 = token_value * exchange_reta // RATE_MULTIPLE
    tracker0 = get_tracker(accounts[0])
    tracker1 = get_tracker(accounts[1])
    earn.withdraw()
    earn.withdraw({'from': accounts[1]})
    assert tracker0.delta() == redeem_amount0
    assert tracker1.delta() == redeem_amount1


def test_unlock_before_current_block_time(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(consensuses, round_count=2, trigger=True)
    earn.setReduceTime(2)
    tx = earn.redeem(MIN_DELEGATE_VALUE)
    timestamp = tx.timestamp
    redeem_record = earn.getRedeemRecords(accounts[0])[0]
    tracker0 = get_tracker(accounts[0])
    assert redeem_record[0] == redeem_record[1] == timestamp - 2
    earn.withdraw()
    assert tracker0.delta() == MIN_DELEGATE_VALUE + BLOCK_REWARD // 2


def test_unlock_after_current_block_time(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(consensuses, round_count=2, trigger=True)
    tx = earn.redeem(MIN_DELEGATE_VALUE)
    timestamp = tx.timestamp
    redeem_record = earn.getRedeemRecords(accounts[0])[0]
    assert redeem_record[0] == timestamp
    assert redeem_record[1] == timestamp + INIT_DAY_INTERVAL * LOCK_DAY
    error_msg = encode_args_with_signature("EarnRedeemRecordNotFound(address)",
                                           [str(accounts[0].address)])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.withdraw()


def test_withdraw_success(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 3})
    token_value = MIN_DELEGATE_VALUE * 3 // 5
    earn.redeem(token_value)
    earn.redeem(token_value + 1)
    earn.redeem(token_value + 2)
    earn.redeem(token_value + 3)
    redeem_record = earn.getRedeemRecords(accounts[0])
    for index, record in enumerate(redeem_record):
        assert record[-2] == token_value + index
    tracker0 = get_tracker(accounts[0])
    tx = earn.withdraw()
    expect_event(tx, "Withdraw", {
        "account": accounts[0].address,
        "amount": token_value * 4 + 6
    })
    expect_event(tx, "UnDelegate", {
        "validator": operators[0].address,
        "amount": token_value * 4 + 6
    })
    assert tracker0.delta() == token_value * 4 + 6


def test_withdraw_undelegate_from_different_validators(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[2], {'value': MIN_DELEGATE_VALUE})
    token_value = MIN_DELEGATE_VALUE * 3 // 5
    earn.redeem(token_value)
    earn.redeem(token_value + 1)
    earn.redeem(token_value + 2)
    earn.redeem(token_value + 3)
    redeem_record = earn.getRedeemRecords(accounts[0])
    for index, record in enumerate(redeem_record):
        assert record[-2] == token_value + index
    tracker0 = get_tracker(accounts[0])
    tx = earn.withdraw()
    expect_event(tx, "UnDelegate", {
        "amount": MIN_DELEGATE_VALUE
    }, idx=0)
    expect_event(tx, "UnDelegate", {
        "amount": MIN_DELEGATE_VALUE
    }, idx=1)
    expect_event(tx, "UnDelegate", {
        "amount": token_value * 4 + 6 - MIN_DELEGATE_VALUE * 2
    }, idx=2)
    assert tracker0.delta() == token_value * 4 + 6


def test_partial_withdraw_success(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 3})
    token_value = MIN_DELEGATE_VALUE * 3 // 5
    earn.redeem(token_value)
    earn.redeem(token_value + 1)
    earn.setInitDayInterval(2)
    earn.redeem(token_value + 2)
    earn.redeem(token_value + 3)
    redeem_record = earn.getRedeemRecords(accounts[0])
    for index, record in enumerate(redeem_record):
        assert record[-2] == token_value + index
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert earn.toWithdrawAmount() == token_value * 2 + 5
    assert tracker0.delta() == token_value * 2 + 1


def test_withdraw_before_unlock_time(earn):
    operators = []
    consensuses = []
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 3})
    token_value = MIN_DELEGATE_VALUE * 3 // 5
    earn.redeem(token_value)
    earn.redeem(token_value + 1)
    earn.redeem(token_value + 2)
    earn.redeem(token_value + 3)
    error_msg = encode_args_with_signature("EarnRedeemRecordNotFound(address)",
                                           [str(accounts[0].address)])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.withdraw()


def test_redeem_multiple_rounds(earn, validator_set, update_lock_time):
    operators = []
    consensuses = []
    validator_set.updateBlockReward(0)
    for operator in accounts[2:3]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 3})
    turn_round(trigger=True)
    token_value = MIN_DELEGATE_VALUE * 3 // 5
    turn_round_count = 4
    total_redeem_amount = 0
    for i in range(turn_round_count):
        turn_round(consensuses, trigger=True, tx_fee=0)
        redeem_amount = token_value + i
        earn.redeem(redeem_amount)
        total_redeem_amount += redeem_amount
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert tracker0.delta() == total_redeem_amount


def test_rewards_during_lockup_period(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[2:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]}, )
    turn_round(trigger=True)
    earn.redeem(MIN_DELEGATE_VALUE, {'from': accounts[0]})
    turn_round(consensuses, round_count=2, trigger=True)
    earn.redeem(MIN_DELEGATE_VALUE, {'from': accounts[1]})
    tracker0 = get_tracker(accounts[0])
    tracker1 = get_tracker(accounts[1])
    earn.withdraw()
    earn.withdraw({'from': accounts[1]})
    assert tracker0.delta() == MIN_DELEGATE_VALUE
    assert tracker1.delta() == MIN_DELEGATE_VALUE + BLOCK_REWARD * 2


def test_generate_exchange_rates_and_store(earn):
    operators = []
    consensuses = []
    total_reward = BLOCK_REWARD // 2
    for operator in accounts[2:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(consensuses, round_count=5, trigger=True)
    assert earn.getCurrentExchangeRate() == (
            total_reward * 4 + MIN_DELEGATE_VALUE) * RATE_MULTIPLE // MIN_DELEGATE_VALUE
    rate = RATE_MULTIPLE
    for index, exchange_rate in enumerate(earn.getExchangeRates(6)):
        if index < 2:
            continue
        rate += total_reward * 100
        assert rate == exchange_rate


def test_redemption_no_stake_skip(earn, validator_set, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE + 1, 'from': accounts[1]})
    earn.mint(operators[2], {'value': MIN_DELEGATE_VALUE + 2, 'from': accounts[1]})
    turn_round(trigger=True)
    earn.setAfterTurnRoundClaimReward(False)
    turn_round(consensuses, trigger=True)
    earn.setUnDelegateValidatorState(False)
    earn.redeem(MIN_DELEGATE_VALUE)
    earn.withdraw()
    earn.setUnDelegateValidatorIndex(1)
    earn.redeem(MIN_DELEGATE_VALUE + 1, {'from': accounts[1]})
    earn.withdraw({'from': accounts[1]})
    assert earn.getValidatorDelegate(operators[1]) == 0
    assert earn.getValidatorDelegateMapLength() == 3


def test_withdraw_undelegate_scenario1(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    mint_amount = MIN_DELEGATE_VALUE + PLEDGE_LIMIT - 1
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    earn.redeem(MIN_DELEGATE_VALUE)
    earn.withdraw()
    assert earn.getValidatorDelegate(operators[0]) == PLEDGE_LIMIT + PLEDGE_LIMIT - 1
    assert earn.getValidatorDelegate(operators[1]) == MIN_DELEGATE_VALUE - PLEDGE_LIMIT


def test_withdraw_undelegate_scenario2(earn, update_lock_time):
    earn.updateMintMinLimit(PLEDGE_LIMIT)
    earn.updateRedeemMinLimit(PLEDGE_LIMIT)
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    mint_amount = MIN_DELEGATE_VALUE + PLEDGE_LIMIT - 1
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 2 - 1})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    tracker0 = get_tracker(accounts[0])
    earn.redeem(MIN_DELEGATE_VALUE)
    earn.withdraw()
    assert earn.getValidatorDelegate(operators[0]) == PLEDGE_LIMIT + PLEDGE_LIMIT - 1
    assert earn.getValidatorDelegate(operators[1]) == PLEDGE_LIMIT * 2 - 1
    assert earn.getValidatorDelegate(operators[2]) == 0
    assert tracker0.delta() == MIN_DELEGATE_VALUE


def test_withdraw_undelegate_scenario3(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    mint_amount = MIN_DELEGATE_VALUE + PLEDGE_LIMIT - 1
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 2 - 1})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT * 2 - 1})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    earn.redeem(MIN_DELEGATE_VALUE)
    error_msg = encode_args_with_signature("EarnUnDelegateFailedFinally(address,uint256)",
                                           [str(accounts[0].address), PLEDGE_LIMIT])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.withdraw()


def test_withdraw_undelegate_scenario4(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:7]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 2 - 1})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 2 - 1})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT * 2 - 1})
    earn.mint(operators[3], {'value': PLEDGE_LIMIT * 2 - 1})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    earn.setUnDelegateValidatorIndex(1)
    earn.redeem(PLEDGE_LIMIT)
    error_msg = encode_args_with_signature("EarnUnDelegateFailedFinally(address,uint256)",
                                           [str(accounts[0].address), PLEDGE_LIMIT])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.withdraw()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 2, 'from': accounts[2]})
    earn.withdraw()
    assert earn.getValidatorDelegate(operators[0]) == PLEDGE_LIMIT * 3 - 1


def test_withdraw_undelegate_scenario5(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    redeem_amount = PLEDGE_LIMIT * 4
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 2})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 2 - 1})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT * 2})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    tracker0 = get_tracker(accounts[0])
    earn.redeem(redeem_amount)
    earn.withdraw()
    assert earn.getValidatorDelegate(operators[0]) == 0
    assert earn.getValidatorDelegate(operators[1]) == PLEDGE_LIMIT * 2 - 1
    assert earn.getValidatorDelegate(operators[2]) == 0
    assert tracker0.delta() == redeem_amount


def test_withdraw_undelegate_scenario6(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    redeem_amount = PLEDGE_LIMIT * 5
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 2})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 3 - 1})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT + 1})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    tracker0 = get_tracker(accounts[0])
    earn.redeem(redeem_amount)
    earn.withdraw()
    assert earn.getValidatorDelegate(operators[0]) == 0
    assert earn.getValidatorDelegate(operators[1]) == PLEDGE_LIMIT
    assert earn.getValidatorDelegate(operators[2]) == 0
    assert tracker0.delta() == redeem_amount


def test_withdraw_undelegate_scenario7(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    redeem_amount = PLEDGE_LIMIT * 5
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 5 - 1})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 3 - 1})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    tracker0 = get_tracker(accounts[0])
    earn.redeem(redeem_amount)
    earn.withdraw()
    assert earn.getValidatorDelegate(operators[0]) == PLEDGE_LIMIT
    assert earn.getValidatorDelegate(operators[1]) == PLEDGE_LIMIT * 3 - 1 - (PLEDGE_LIMIT + 1)
    assert earn.getValidatorDelegate(operators[2]) == PLEDGE_LIMIT
    assert tracker0.delta() == redeem_amount


def test_withdraw_undelegate_scenario8(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    redeem_amount = PLEDGE_LIMIT * 6 - 2
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 5 - 1})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT + 1})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT * 2})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    earn.redeem(redeem_amount)
    error_msg = encode_args_with_signature("EarnUnDelegateFailedFinally(address,uint256)",
                                           [str(accounts[0].address), redeem_amount - (PLEDGE_LIMIT * 4 - 1)])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.withdraw()


def test_withdraw_undelegate_scenario9(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    redeem_amount = PLEDGE_LIMIT * 8 - 1
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 7})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 3 - 1})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    earn.redeem(redeem_amount)
    earn.withdraw()
    assert earn.getValidatorDelegate(operators[0]) == PLEDGE_LIMIT
    assert earn.getValidatorDelegate(operators[1]) == PLEDGE_LIMIT


def test_withdraw_undelegate_scenario10(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    redeem_amount = PLEDGE_LIMIT * 5
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 3})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    earn.redeem(redeem_amount)
    earn.withdraw()
    assert earn.getValidatorDelegate(operators[0]) == earn.getValidatorDelegate(operators[1]) == \
           earn.getValidatorDelegate(operators[2]) == 0


def test_cancel_delegation_after_multiple_redeems(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.setUnDelegateValidatorState(False)
    earn.setUnDelegateValidatorIndex(0)
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 5})
    turn_round(trigger=True)
    earn.redeem(PLEDGE_LIMIT)
    earn.redeem(PLEDGE_LIMIT)
    earn.redeem(PLEDGE_LIMIT)
    tracker0 = get_tracker(accounts[0])
    tx = earn.withdraw()
    expect_event(tx, "UnDelegate", {
        "validator": operators[0],
        "amount": PLEDGE_LIMIT * 3
    })
    assert tracker0.delta() == PLEDGE_LIMIT * 3
    assert earn.getValidatorDelegate(operators[0]) == PLEDGE_LIMIT * 2


def test_withdraw_no_sufficient_balance_in_validators(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:7]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 2 - 1})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 2 - 1})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT * 2 - 1})
    earn.mint(operators[3], {'value': PLEDGE_LIMIT * 2 - 1})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    earn.setUnDelegateValidatorIndex(1)
    earn.redeem(PLEDGE_LIMIT)
    error_msg = encode_args_with_signature("EarnUnDelegateFailedFinally(address,uint256)",
                                           [str(accounts[0].address), PLEDGE_LIMIT])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.withdraw()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT})
    earn.redeem(PLEDGE_LIMIT)
    assert len(earn.getRedeemRecords(accounts[0])) == 2
    error_msg = encode_args_with_signature("EarnUnDelegateFailedFinally(address,uint256)",
                                           [str(accounts[0].address), PLEDGE_LIMIT * 2])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.withdraw()


def test_withdraw_multiple_fee_vouchers(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 3})
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 2})
    turn_round(trigger=True)
    tracker1 = get_tracker(accounts[1])
    earn.redeem(PLEDGE_LIMIT)
    earn.redeem(PLEDGE_LIMIT)
    protocol_fee = 200000
    earn.updateProtocolFeePoints(protocol_fee)
    earn.updateProtocolFeeReveiver(accounts[1])
    earn.redeem(PLEDGE_LIMIT)
    earn.redeem(PLEDGE_LIMIT)
    earn.redeem(PLEDGE_LIMIT)
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert tracker0.delta() == PLEDGE_LIMIT * 5 - PLEDGE_LIMIT * 3 * protocol_fee // RATE_MULTIPLE
    assert tracker1.delta() == PLEDGE_LIMIT * 3 * protocol_fee // RATE_MULTIPLE


def test_withdraw_multiple_redeems_with_fees(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    protocol_fee = 200000
    earn.updateProtocolFeePoints(protocol_fee)
    earn.updateProtocolFeeReveiver(accounts[1])
    redeem_amount = PLEDGE_LIMIT * 5
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 3})
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 2})
    turn_round(trigger=True)
    tracker1 = get_tracker(accounts[1])
    for i in range(5):
        earn.redeem(PLEDGE_LIMIT)
        assert earn.getRedeemRecords(accounts[0])[i][4] == PLEDGE_LIMIT * protocol_fee // RATE_MULTIPLE
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert tracker0.delta() == PLEDGE_LIMIT * 4
    assert tracker1.delta() == redeem_amount * protocol_fee // RATE_MULTIPLE


def test_unlocked_amount_deducted_proportionally(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    protocol_fee = 200000
    earn.updateProtocolFeePoints(protocol_fee)
    earn.updateProtocolFeeReveiver(accounts[1])
    redeem_amount = PLEDGE_LIMIT * 5
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 3})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    tracker1 = get_tracker(accounts[1])
    earn.redeem(redeem_amount)
    actual_redeem_amount = redeem_amount - redeem_amount * protocol_fee // RATE_MULTIPLE
    assert earn.getRedeemRecords(accounts[0])[0][2] == actual_redeem_amount
    assert earn.getRedeemRecords(accounts[0])[0][4] == redeem_amount * protocol_fee // RATE_MULTIPLE
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert tracker0.delta() == actual_redeem_amount
    assert tracker1.delta() == redeem_amount * protocol_fee // RATE_MULTIPLE


def test_unlocked_amount_protocol_success(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    protocol_fee = 200000
    earn.updateProtocolFeePoints(protocol_fee)
    earn.updateProtocolFeeReveiver(accounts[1])
    redeem_amount = MIN_DELEGATE_VALUE
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(consensuses, round_count=2, trigger=True)
    tracker1 = get_tracker(accounts[1])
    earn.redeem(redeem_amount)
    total_delegate_amount = redeem_amount + BLOCK_REWARD // 2
    actual_redeem_amount = total_delegate_amount - total_delegate_amount * protocol_fee // RATE_MULTIPLE
    assert earn.getRedeemRecords(accounts[0])[0][2] == actual_redeem_amount
    tracker0 = get_tracker(accounts[0])
    tx = earn.withdraw()
    assert tracker0.delta() == actual_redeem_amount
    expect_event(tx, "Withdraw", {
        "account": accounts[0].address,
        "amount": actual_redeem_amount
    })
    assert tracker1.delta() == total_delegate_amount * protocol_fee // RATE_MULTIPLE


def test_re_balance_success(earn):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 4})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT + 1})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT})
    turn_round(trigger=True)
    tx = earn.reBalance()
    expect_event(tx, "ReBalance", {
        "from": operators[0],
        "to": operators[2],
        "amount": (PLEDGE_LIMIT * 4 - PLEDGE_LIMIT) // 2
    })
    assert earn.getValidatorDelegate(operators[0]) == earn.getValidatorDelegate(operators[2]) == PLEDGE_LIMIT * 5 // 2


def test_remove_validator_from_map_logic(earn, candidate_hub, stcore):
    operators = []
    consensuses = []
    for operator in accounts[3:7]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 2})
    earn.mint(operators[2], {'value': PLEDGE_LIMIT * 3})
    earn.mint(operators[3], {'value': PLEDGE_LIMIT * 4})
    turn_round(trigger=True)
    candidate_hub.refuseDelegate({'from': operators[1]})
    turn_round(trigger=True)
    assert earn.getValidatorDelegateMapLength() == 3
    assert earn.getValidatorDelegateAddress(0) == operators[0]
    assert earn.getValidatorDelegateAddress(1) == operators[3]
    assert earn.getValidatorDelegateAddress(2) == operators[2]
    candidate_hub.refuseDelegate({'from': operators[0]})
    turn_round(trigger=True)
    assert earn.getValidatorDelegateAddress(0) == operators[2]
    assert earn.getValidatorDelegateAddress(1) == operators[3]


def test_no_remove_validator_with_zero_balance(earn, candidate_hub, stcore):
    operators = []
    consensuses = []
    for operator in accounts[3:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT})
    earn.redeem(PLEDGE_LIMIT)
    turn_round(trigger=True)
    assert earn.getValidatorDelegateMapLength() == 1
    assert earn.getValidatorDelegateAddress(0) == operators[0]


@pytest.mark.parametrize("diff", [1000, 999, 996, 1002])
def test_re_balance_no_transfer(earn, diff):
    balance_threshold = 1000
    earn.updateBalanceThreshold(balance_threshold)
    operators = []
    consensuses = []
    mint_amount = MIN_DELEGATE_VALUE * 3
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': mint_amount - 1})
    earn.mint(operators[2], {'value': mint_amount - diff})
    turn_round(trigger=True)
    if diff < balance_threshold:
        error_msg = encode_args_with_signature(
            "EarnReBalanceAmountDifferenceLessThanThreshold(address,address,uint256,uint256,uint256)",
            [str(operators[0].address), str(operators[2].address), mint_amount, mint_amount - diff, balance_threshold])
        with brownie.reverts(f"typed error: {error_msg}"):
            earn.reBalance()
    else:
        earn.reBalance()
        validator_delegate0 = earn.getValidatorDelegate(operators[0])
        validator_delegate1 = earn.getValidatorDelegate(operators[2])
        assert validator_delegate0 == mint_amount - diff // 2
        assert validator_delegate1 == mint_amount - diff + diff // 2


def test_re_balance_two_validators(earn):
    operators = []
    consensuses = []
    mint_amount = MIN_DELEGATE_VALUE * 3
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    turn_round(trigger=True, before=True)
    validator_delegate0 = earn.getValidatorDelegate(operators[0])
    assert validator_delegate0 == mint_amount - MIN_DELEGATE_VALUE


def test_re_balance_reward_claim(earn):
    operators = []
    consensuses = []
    mint_amount = MIN_DELEGATE_VALUE * 3
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    earn.setAfterTurnRoundClaimReward(False)
    turn_round(consensuses, round_count=2, trigger=True)
    tx = earn.reBalance()
    expect_event(tx, "Transfer", {
        "from": operators[0],
        "to": operators[1],
        "amount": MIN_DELEGATE_VALUE
    })
    assert earn.balance() == BLOCK_REWARD
    tx = turn_round(consensuses, trigger=True)
    assert 'Delegate' in tx.events
    assert tx.events['Delegate'][0]['amount'] == BLOCK_REWARD
    expect_event(tx, "Delegate", {
        "amount": BLOCK_REWARD
    })


def test_re_balance_failed_undelegate_less(earn):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 4})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT * 2 + 2})
    turn_round(consensuses, trigger=True)
    error_msg = encode_args_with_signature(
        "EarnReBalanceInvalidTransferAmount(address,uint256,uint256)",
        [str(operators[0].address), PLEDGE_LIMIT * 4, PLEDGE_LIMIT - 1])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.reBalance()


def test_rebalance_equal_validator_balances(earn):
    operators = []
    consensuses = []
    mint_amount = MIN_DELEGATE_VALUE * 3
    for operator in accounts[3:7]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': mint_amount})
    earn.mint(operators[2], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[3], {'value': MIN_DELEGATE_VALUE})
    turn_round(consensuses, trigger=True)
    tx = earn.reBalance()
    expect_event(tx, "Transfer", {
        "from": operators[0],
        "to": operators[2],
        "amount": MIN_DELEGATE_VALUE
    })


def test_manual_re_balance_failed_remain_less(earn):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 3})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT})
    turn_round(consensuses, trigger=True)
    error_msg = encode_args_with_signature(
        "EarnReBalanceInvalidTransferAmount(address,uint256,uint256)",
        [str(operators[0].address), PLEDGE_LIMIT * 3, PLEDGE_LIMIT * 3 - 1])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.manualReBalance(operators[0], operators[1], PLEDGE_LIMIT * 3 - 1)


def test_manual_rebalance_success(earn):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 3})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT})
    turn_round(consensuses, trigger=True)
    tx = earn.manualReBalance(operators[0], operators[1], PLEDGE_LIMIT * 2)
    expect_event(tx, "Transfer", {
        "from": operators[0],
        "to": operators[1],
        "amount": PLEDGE_LIMIT * 2
    })
    assert earn.getValidatorDelegate(operators[0]) == PLEDGE_LIMIT
    assert earn.getValidatorDelegate(operators[1]) == PLEDGE_LIMIT * 3


def test_manual_rebalance_amount_zero(earn):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': PLEDGE_LIMIT * 3})
    earn.mint(operators[1], {'value': PLEDGE_LIMIT})
    turn_round(consensuses, trigger=True)
    error_msg = encode_args_with_signature(
        "EarnReBalanceInvalidTransferAmount(address,uint256,uint256)",
        [str(operators[0].address), PLEDGE_LIMIT * 3, 0])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.manualReBalance(operators[0], operators[1], 0)


def test_mint_validator_unregister(earn, candidate_hub):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    candidate_hub.unregister({'from': operators[0]})
    turn_round()
    with brownie.reverts("Can not delegate to validator"):
        earn.mint(operators[0], {'value': PLEDGE_LIMIT * 3})


def test_redeem_exceed_total_rewards_and_principal(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(trigger=True)
    earn.setUnDelegateValidatorState(False)
    earn.setValidatorDelegateMap(operators[0], 1, False)
    earn.redeem(MIN_DELEGATE_VALUE)
    error_msg = encode_args_with_signature("EarnUnDelegateFailedFinally(address,uint256)",
                                           [accounts[0].address, PLEDGE_LIMIT + 1])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.withdraw()


def test_multiple_users_redeem_generate_records(earn):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE, 'from': accounts[1]})
    turn_round(trigger=True)
    earn.redeem(MIN_DELEGATE_VALUE, {'from': accounts[0]})
    earn.redeem(MIN_DELEGATE_VALUE, {'from': accounts[1]})
    account0_redeem_record = earn.getRedeemRecords(accounts[0])
    account1_redeem_record = earn.getRedeemRecords(accounts[1])
    assert len(account0_redeem_record) == len(account1_redeem_record) == 1


def test_redeem_full_map_iteration(earn, candidate_hub, pledge_agent, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:9]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    for operator in accounts[3:9]:
        earn.mint(operator, {'value': MIN_DELEGATE_VALUE})
    earn.setValidatorDelegateMap(operators[0], MIN_DELEGATE_VALUE, False)
    earn.setValidatorDelegateMap(operators[1], MIN_DELEGATE_VALUE, False)
    earn.setValidatorDelegateMap(operators[4], MIN_DELEGATE_VALUE, False)
    turn_round(consensuses)
    earn.setContractAddress(candidate_hub.address, pledge_agent.address, candidate_hub.getRoundTag())
    earn.setUnDelegateValidatorState(False)
    earn.setUnDelegateValidatorIndex(3)
    earn.redeem(MIN_DELEGATE_VALUE // 2, {'from': accounts[0]})
    earn.withdraw()
    assert earn.getValidatorDelegateIndex(3) == MIN_DELEGATE_VALUE - MIN_DELEGATE_VALUE // 2
    earn.setUnDelegateValidatorIndex(3)
    earn.redeem(MIN_DELEGATE_VALUE * 2.5, {'from': accounts[0]})
    earn.withdraw()
    assert earn.getValidatorDelegateIndex(3) == 0
    assert earn.getValidatorDelegateIndex(5) == 0
    assert earn.getValidatorDelegateIndex(2) == 0


def test_re_balance_no_validators(earn):
    turn_round()
    error_msg = encode_args_with_signature("EarnEmptyValidator()",
                                           [])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.reBalance()


def test_re_balance_generates_rewards(earn):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 4})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE * 2, 'from': accounts[1]})
    turn_round(trigger=True)
    earn.setAfterTurnRoundClaimReward(False)
    turn_round(consensuses, trigger=True)
    earn.reBalance()
    earn.setAfterTurnRoundClaimReward(True)
    tx = turn_round(consensuses, trigger=True)
    expect_event(tx, "Delegate", {
        "amount": BLOCK_REWARD * 2
    })


def test_after_turn_round_remove_validator(earn, pledge_agent, candidate_hub, validator_set):
    candidate_hub.setValidatorCount(1)
    operators = []
    consensuses = []
    for index, operator in enumerate(accounts[2:5]):
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    pledge_agent.delegateCoin(operators[2], {'value': 100})
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 4})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE * 2, 'from': accounts[1]})
    assert earn.getValidatorDelegateMapLength() == 2
    tx = turn_round(trigger=True)
    assert consensuses[0] in validator_set.getValidators()
    expect_event(tx, "undelegatedCoin", {
        "agent": operators[1],
        "amount": MIN_DELEGATE_VALUE * 2
    })
    expect_event(tx, "Delegate", {
        "validator": operators[0],
        "amount": MIN_DELEGATE_VALUE * 2
    })
    assert earn.getValidatorDelegateMapLength() == 1


def test_after_turn_round_remove_validator_clear_assets(earn, candidate_hub):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 4})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE * 2, 'from': accounts[1]})
    earn.mint(operators[2], {'value': MIN_DELEGATE_VALUE * 2, 'from': accounts[1]})
    turn_round(trigger=True)
    assert earn.getValidatorDelegateMapLength() == 3
    candidate_hub.refuseDelegate({'from': operators[1]})
    turn_round(consensuses, trigger=True)
    assert earn.getValidatorDelegateMapLength() == 2
    assert earn.getValidatorDelegate(operators[0]) + earn.getValidatorDelegate(
        operators[2]) == BLOCK_REWARD * 1.5 + MIN_DELEGATE_VALUE * 8


def test_after_turn_round_no_active_validators(earn, pledge_agent, candidate_hub):
    candidate_hub.setValidatorCount(1)
    operators = []
    consensuses = []
    for operator in [accounts[3], accounts[-4]]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    pledge_agent.delegateCoin(operators[0], {'value': MIN_DELEGATE_VALUE * 3, 'from': accounts[0]})
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 3})
    turn_round(trigger=True)
    candidate_hub.refuseDelegate({'from': operators[0]})
    turn_round(consensuses)
    earn.afterTurnRound([accounts[-4]])
    delegate_info0 = earn.getValidatorDelegate(accounts[-4])
    delegate_info1 = earn.getValidatorDelegate(accounts[-5])
    assert delegate_info0 == MIN_DELEGATE_VALUE * 3 + BLOCK_REWARD // 4
    assert delegate_info1 == 0


def test_is_active_success(earn, candidate_hub, stcore, validator_set, pledge_agent, slash_indicator):
    candidate_hub.setValidatorCount(3)
    operators = []
    consensuses = []
    for operator in accounts[3:7]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    pledge_agent.delegateCoin(operators[1], {'value': MIN_DELEGATE_VALUE, 'from': accounts[0]})
    pledge_agent.delegateCoin(operators[2], {'value': MIN_DELEGATE_VALUE, 'from': accounts[0]})
    pledge_agent.delegateCoin(operators[3], {'value': MIN_DELEGATE_VALUE, 'from': accounts[0]})
    turn_round()
    assert earn.getIsActive(operators[0]) == False
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[2], {'value': MIN_DELEGATE_VALUE})
    candidate_hub.refuseDelegate({'from': operators[2]})
    assert earn.getIsActive(operators[2]) == False
    candidate_hub.unregister({'from': operators[0]})
    turn_round(trigger=True)
    assert earn.getIsActive(operators[0]) == False
    assert earn.getIsActive(operators[1]) == True
    assert consensuses[1], consensuses[3] in validator_set.getValidators()
    assert len(validator_set.getValidators()) == 2
    felony_threshold = slash_indicator.felonyThreshold()
    for _ in range(felony_threshold):
        slash_indicator.slash(consensuses[1])
    misdemeanor_threshold = slash_indicator.misdemeanorThreshold()
    for _ in range(misdemeanor_threshold):
        slash_indicator.slash(consensuses[3])
    assert earn.getIsActive(operators[3]) == True
    assert earn.getIsActive(operators[1]) == False


def test_after_turn_round_multiple_address_refuse_delegate(earn, candidate_hub):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 4})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE * 3, 'from': accounts[1]})
    earn.mint(operators[2], {'value': MIN_DELEGATE_VALUE * 2, 'from': accounts[1]})
    turn_round(trigger=True)
    candidate_hub.refuseDelegate({'from': operators[1]})
    candidate_hub.refuseDelegate({'from': operators[2]})
    turn_round(consensuses, trigger=True)
    assert earn.getValidatorDelegateMapLength() == 1
    assert earn.getValidatorDelegate(operators[0]) == MIN_DELEGATE_VALUE * 9 + BLOCK_REWARD // 2 * 3


def test_after_turn_round_refuse_delegate(earn, candidate_hub):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE * 4})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE * 3, 'from': accounts[1]})
    turn_round(trigger=True)
    candidate_hub.refuseDelegate({'from': operators[0]})
    candidate_hub.refuseDelegate({'from': operators[1]})
    candidate_hub.refuseDelegate({'from': operators[2]})
    error_msg = encode_args_with_signature("EarnValidatorsAllOffline()",
                                           [])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.afterTurnRound([operators[2]])


def test_after_turn_round_candidate_reinvest(earn, pledge_agent, candidate_hub, stcore, validator_set):
    operators = []
    consensuses = []
    candidate_hub.setValidatorCount(2)
    for operator in accounts[3:7]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[2], {'value': MIN_DELEGATE_VALUE * 4})
    earn.mint(operators[3], {'value': MIN_DELEGATE_VALUE * 3, 'from': accounts[1]})
    turn_round(trigger=True)
    candidate_hub.refuseDelegate({'from': operators[2]})
    candidate_hub.refuseDelegate({'from': operators[3]})
    candidate_hub.setValidatorCount(1)
    pledge_agent.delegateCoin(operators[1], {'value': 100, 'from': accounts[1]})
    turn_round(consensuses)
    earn.afterTurnRound([operators[0], operators[1]])
    assert earn.getIsActive(operators[0]) is False
    assert consensuses[0] not in validator_set.getValidators()
    turn_round(consensuses, round_count=2, trigger=True)
    assert earn.getValidatorDelegate(operators[0]) == MIN_DELEGATE_VALUE * 7 + BLOCK_REWARD + BLOCK_REWARD // 2


def test_re_balance_with_reward_to_reinvest(earn, pledge_agent):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    balance_threshold = 6000
    earn.updateBalanceThreshold(balance_threshold)
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE // 2})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE // 2, 'from': accounts[1]})
    turn_round(trigger=True)
    error_msg = encode_args_with_signature(
        "EarnReBalanceNoNeed(address,address)",
        [str(operators[0].address), str(operators[0].address)])
    with brownie.reverts(f"typed error: {error_msg}"):
        earn.reBalance()
    turn_round(consensuses, trigger=True)
    tx = earn.reBalance()
    total_reward = BLOCK_REWARD // 2
    assert earn.getValidatorDelegate(operators[0]) == MIN_DELEGATE_VALUE // 2 + total_reward
    assert earn.getValidatorDelegate(operators[1]) == MIN_DELEGATE_VALUE // 2 + total_reward


def test_investments_by_user(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    mint_amount = MIN_DELEGATE_VALUE * 10
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': mint_amount, 'from': accounts[1]})
    turn_round(consensuses, round_count=3, trigger=True)
    redeem_amount = mint_amount // 2
    earn.redeem(redeem_amount)
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert tracker0.delta(()) == BLOCK_REWARD // 2 + redeem_amount


def test_mint_redeem_immediately(earn, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    mint_amount = MIN_DELEGATE_VALUE * 10
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': mint_amount, 'from': accounts[1]})
    turn_round(consensuses, round_count=3, trigger=True)
    redeem_amount = mint_amount // 2
    earn.redeem(redeem_amount)
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert tracker0.delta(()) == BLOCK_REWARD // 2 + redeem_amount


def test_mint_redeem_withdraw(earn, update_lock_time):
    operators = []
    consensuses = []
    total_reward = BLOCK_REWARD // 2
    for operator in accounts[2:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    turn_round(consensuses, round_count=2, trigger=True)
    earn.redeem(MIN_DELEGATE_VALUE)
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    assert tracker0.delta() == MIN_DELEGATE_VALUE + total_reward


@pytest.mark.parametrize("reward", [-1, 0, 1])
def test_reinvest_all_rewards(earn, validator_set, reward):
    operators = []
    consensuses = []
    earn.updatePledgeAgentLimit(BLOCK_REWARD + reward)
    for operator in accounts[2:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    earn.mint(operators[1], {'value': MIN_DELEGATE_VALUE})
    tx = turn_round(consensuses, round_count=2, trigger=True)
    if reward > 0:
        expect_event_not_emitted(tx, 'Delegate')
    else:
        expect_event(tx, "Delegate", {
            "amount": BLOCK_REWARD
        })


@pytest.mark.parametrize("reward", [-1, 0, 1])
def test_reinvest_rewards(earn, validator_set, reward):
    operators = []
    consensuses = []
    earn.updatePledgeAgentLimit(BLOCK_REWARD // 2 + reward)
    for operator in accounts[2:4]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    earn.mint(operators[0], {'value': MIN_DELEGATE_VALUE})
    tx = turn_round(consensuses, round_count=2, trigger=True)
    if reward > 0:
        expect_event_not_emitted(tx, 'Delegate')
    else:
        expect_event(tx, "Delegate", {
            "amount": BLOCK_REWARD // 2
        })


def test_multiple_investors_claim_rewards(earn, stcore, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    mint_amount = MIN_DELEGATE_VALUE * 10
    earn.mint(operators[0], {'value': 100})
    earn.mint(operators[0], {'value': mint_amount})
    turn_round(consensuses, round_count=3, trigger=True)
    earn.mint(operators[1], {'value': mint_amount, 'from': accounts[1]})
    token_value = mint_amount * RATE_MULTIPLE // get_exchangerate()
    turn_round(consensuses, round_count=3, trigger=True)
    earn.redeem(mint_amount)
    earn.redeem(token_value, {'from': accounts[1]})
    exchange_rate = (BLOCK_REWARD * 3.5 + mint_amount * 2 + 100) * RATE_MULTIPLE // (token_value + mint_amount + 100)
    tracker0 = get_tracker(accounts[0])
    tracker1 = get_tracker(accounts[1])
    earn.withdraw()
    earn.withdraw({'from': accounts[1]})
    assert tracker0.delta(()) == mint_amount * exchange_rate // RATE_MULTIPLE
    assert tracker1.delta(()) == token_value * exchange_rate // RATE_MULTIPLE


def test_withdraw_redeem_token(earn, stcore, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:6]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    mint_amount = MIN_DELEGATE_VALUE * 10
    earn.mint(operators[0], {'value': mint_amount // 2})
    earn.mint(operators[1], {'value': mint_amount, 'from': accounts[1]})
    turn_round(consensuses, round_count=2, trigger=True)
    earn.redeem(mint_amount // 2)
    turn_round(consensuses, round_count=3, trigger=True)
    earn.redeem(mint_amount, {'from': accounts[1]})
    tracker0 = get_tracker(accounts[0])
    tracker1 = get_tracker(accounts[1])
    earn.withdraw()
    earn.withdraw({'from': accounts[1]})
    total_pledge = BLOCK_REWARD + mint_amount * 1.5
    total_token = mint_amount * 1.5
    exchange_rate0 = total_pledge * RATE_MULTIPLE // total_token
    actual_reward0 = mint_amount // 2 * exchange_rate0 // RATE_MULTIPLE
    total_token -= mint_amount
    total_pledge += BLOCK_REWARD * 3
    assert tracker0.delta() == actual_reward0
    assert tracker1.delta() == total_pledge - actual_reward0


def test_mint_with_slash(earn, stcore, slash_indicator, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    mint_amount = MIN_DELEGATE_VALUE * 10
    earn.mint(operators[0], {'value': mint_amount // 2})
    earn.mint(operators[1], {'value': mint_amount, 'from': accounts[1]})
    turn_round(consensuses, round_count=2, trigger=True)
    felony_threshold = slash_indicator.felonyThreshold()
    for _ in range(felony_threshold):
        slash_indicator.slash(consensuses[0])
    misdemeanor_threshold = slash_indicator.misdemeanorThreshold()
    for _ in range(misdemeanor_threshold):
        slash_indicator.slash(consensuses[1])
    earn.redeem(mint_amount // 2)
    turn_round(consensuses, round_count=3, trigger=True)
    earn.redeem(mint_amount, {'from': accounts[1]})
    tracker0 = get_tracker(accounts[0])
    tracker1 = get_tracker(accounts[1])
    earn.withdraw()
    earn.withdraw({'from': accounts[1]})
    total_pledge = BLOCK_REWARD + mint_amount * 1.5
    total_token = mint_amount * 1.5
    exchange_rate0 = total_pledge * RATE_MULTIPLE // total_token
    actual_reward0 = mint_amount // 2 * exchange_rate0 // RATE_MULTIPLE
    total_token -= mint_amount
    total_pledge += BLOCK_REWARD // 2 * 3
    assert tracker0.delta() == actual_reward0
    assert tracker1.delta() == total_pledge - actual_reward0


def test_repeated_redeem_and_withdraw(earn, stcore, slash_indicator, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    mint_amount = MIN_DELEGATE_VALUE * 10
    earn.mint(operators[0], {'value': mint_amount})
    earn.mint(operators[1], {'value': mint_amount // 2, 'from': accounts[1]})
    turn_round(consensuses, round_count=2, trigger=True)
    earn.redeem(mint_amount // 2)
    turn_round(consensuses, round_count=3, trigger=True)
    earn.redeem(mint_amount // 2)
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    total_pledge = BLOCK_REWARD + mint_amount * 1.5
    total_token = mint_amount * 1.5
    exchange_rate0 = total_pledge * RATE_MULTIPLE // total_token
    actual_reward0 = mint_amount // 2 * exchange_rate0 // RATE_MULTIPLE
    total_token -= mint_amount // 2
    total_pledge += BLOCK_REWARD * 3 - actual_reward0
    exchange_rate1 = total_pledge * RATE_MULTIPLE // total_token
    actual_reward1 = mint_amount // 2 * exchange_rate1 // RATE_MULTIPLE
    assert tracker0.delta() == actual_reward0 + actual_reward1


def test_no_reward_round_withdraw(earn, stcore, slash_indicator, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    total_reward = BLOCK_REWARD // 2
    mint_amount = MIN_DELEGATE_VALUE * 10
    earn.mint(operators[0], {'value': mint_amount})
    turn_round(consensuses, round_count=2, trigger=True)
    earn.setAfterTurnRoundClaimReward(False)
    turn_round(consensuses, trigger=True)
    earn.redeem(mint_amount)
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    total_pledge = total_reward + mint_amount
    assert tracker0.delta() == total_pledge


def test_withdraw_low_exchange_rate(earn, stcore, validator_set, update_lock_time):
    operators = []
    consensuses = []
    for operator in accounts[3:5]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    turn_round()
    validator_set.updateBlockReward(0)
    mint_amount = MIN_DELEGATE_VALUE * 10
    earn.mint(operators[0], {'value': mint_amount})
    earn.setValidatorDelegateMap(operators[0], MIN_DELEGATE_VALUE, False)
    turn_round(consensuses, round_count=2, tx_fee=0, trigger=True)
    earn.setAfterTurnRoundClaimReward(False)
    turn_round(consensuses, trigger=True)
    earn.redeem(mint_amount)
    tracker0 = get_tracker(accounts[0])
    earn.withdraw()
    total_pledge = mint_amount - MIN_DELEGATE_VALUE
    assert tracker0.delta() == total_pledge
