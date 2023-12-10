from brownie import *
from .utils import random_address


def register_candidate(consensus=None, fee_address=None, operator=None, commission=500, margin=None) -> str:
    """
    :param consensus:
    :param fee_address:
    :param operator:
    :param commission:
    :param margin:
    :return: consensus address
    """
    if consensus is None:
        consensus = random_address()
    if not operator:
        operator = accounts[0]
    if fee_address is None:
        fee_address = operator
    if margin is None:
        margin = CandidateHubMock[0].requiredMargin()

    CandidateHubMock[0].register(
        consensus, fee_address, commission,
        {'from': operator, 'value': margin}
    )
    return consensus


def get_exchangerate():
    p = Contract.from_abi('EarnProxy', EarnProxy[0].address, EarnMock[0].abi)
    return p.getCurrentExchangeRate()


def get_current_round():
    return CandidateHubMock[0].getRoundTag()


def turn_round(miners: list = None, tx_fee=100, round_count=1, trigger=None, before=None):
    p = Contract.from_abi('EarnProxy', EarnProxy[0].address, EarnMock[0].abi)
    if before is True:
        p.reBalance()
    if miners is None:
        miners = []
    tx = None
    for _ in range(round_count):
        for miner in miners:
            ValidatorSetMock[0].deposit(miner, {"value": tx_fee, "from": accounts[-1]})
        tx = CandidateHubMock[0].turnRound()
        if trigger is True:
            tx = p.afterTurnRound([], {'from': accounts[0]})
        if p.roundTag() != CandidateHubMock[0].getRoundTag():
            p.setLastOperateRound(CandidateHubMock[0].getRoundTag(), {'from': accounts[0]})
        chain.sleep(1)

    return tx
