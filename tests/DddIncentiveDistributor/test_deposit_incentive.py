import brownie
from brownie import ZERO_ADDRESS
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(fee1, fee2, deployer, ddd_distro):
    fee1._mint_for_testing(deployer, 10**24)
    fee1.approve(ddd_distro, 2**256-1, {'from': deployer})
    fee2._mint_for_testing(deployer, 10**24)
    fee2.approve(ddd_distro, 2**256-1, {'from': deployer})


def test_deposit_incentive(fee1, deployer, ddd_distro):
    ddd_distro.depositIncentive(ZERO_ADDRESS, fee1, 10**18, {'from': deployer})

    assert fee1.balanceOf(ddd_distro) == 10**18
    assert ddd_distro.incentiveTokensLength(ZERO_ADDRESS) == 1
    assert ddd_distro.incentiveTokens(ZERO_ADDRESS, 0) == fee1
    assert ddd_distro.weeklyIncentiveAmounts(ZERO_ADDRESS, fee1, ddd_distro.getWeek()) == 10**18


def test_incentive_multiple_deposits(fee1, deployer, ddd_distro):
    for i in range(1, 4):
        ddd_distro.depositIncentive(ZERO_ADDRESS, fee1, i * 10**18, {'from': deployer})

    assert fee1.balanceOf(ddd_distro) == 6 * 10**18
    assert ddd_distro.incentiveTokensLength(ZERO_ADDRESS) == 1
    assert ddd_distro.incentiveTokens(ZERO_ADDRESS, 0) == fee1
    assert ddd_distro.weeklyIncentiveAmounts(ZERO_ADDRESS, fee1, ddd_distro.getWeek()) == 6 * 10**18


def test_deposit_multiple_incentives(fee1, fee2, deployer, ddd_distro):
    ddd_distro.depositIncentive(ZERO_ADDRESS, fee1, 10**18, {'from': deployer})
    ddd_distro.depositIncentive(ZERO_ADDRESS, fee2, 2 * 10**18, {'from': deployer})

    assert fee1.balanceOf(ddd_distro) == 10**18
    assert fee2.balanceOf(ddd_distro) == 2 * 10**18
    assert ddd_distro.incentiveTokensLength(ZERO_ADDRESS) == 2
    assert ddd_distro.incentiveTokens(ZERO_ADDRESS, 0) == fee1
    assert ddd_distro.incentiveTokens(ZERO_ADDRESS, 1) == fee2
    assert ddd_distro.weeklyIncentiveAmounts(ZERO_ADDRESS, fee1, ddd_distro.getWeek()) == 10**18
    assert ddd_distro.weeklyIncentiveAmounts(ZERO_ADDRESS, fee2, ddd_distro.getWeek()) == 2 * 10**18


def test_deposit_bribe(fee1, deployer, ddd_distro, token_3eps):
    ddd_distro.depositIncentive(token_3eps, fee1, 10**18, {'from': deployer})

    assert fee1.balanceOf(ddd_distro) == 10**18
    assert ddd_distro.incentiveTokensLength(ZERO_ADDRESS) == 0
    assert ddd_distro.incentiveTokensLength(token_3eps) == 1
    assert ddd_distro.incentiveTokens(token_3eps, 0) == fee1
    assert ddd_distro.weeklyIncentiveAmounts(token_3eps, fee1, ddd_distro.getWeek()) == 10**18


def test_bribe_multiple_deposits(fee1, deployer, ddd_distro, token_3eps):
    for i in range(1, 4):
        ddd_distro.depositIncentive(token_3eps, fee1, i * 10**18, {'from': deployer})

    assert fee1.balanceOf(ddd_distro) == 6 * 10**18
    assert ddd_distro.incentiveTokensLength(ZERO_ADDRESS) == 0
    assert ddd_distro.incentiveTokensLength(token_3eps) == 1
    assert ddd_distro.incentiveTokens(token_3eps, 0) == fee1
    assert ddd_distro.weeklyIncentiveAmounts(token_3eps, fee1, ddd_distro.getWeek()) == 6 * 10**18


def test_deposit_multiple_weeks(fee1, fee2, deployer, ddd_distro, advance_week, token_3eps):
    week = ddd_distro.getWeek()
    ddd_distro.depositIncentive(ZERO_ADDRESS, fee1, 10**18, {'from': deployer})
    ddd_distro.depositIncentive(ZERO_ADDRESS, fee2, 2 * 10**18, {'from': deployer})
    advance_week()
    ddd_distro.depositIncentive(ZERO_ADDRESS, fee1, 10**18, {'from': deployer})
    ddd_distro.depositIncentive(token_3eps, fee1, 3 * 10**18, {'from': deployer})
    advance_week()
    ddd_distro.depositIncentive(ZERO_ADDRESS, fee2, 10**18, {'from': deployer})


    assert [ddd_distro.weeklyIncentiveAmounts(ZERO_ADDRESS, fee1, i) for i in range(week, week + 4)] == [10**18, 10**18, 0, 0]
    assert [ddd_distro.weeklyIncentiveAmounts(ZERO_ADDRESS, fee2, i) for i in range(week, week + 4)] == [2 * 10**18, 0, 10**18, 0]

    assert [ddd_distro.weeklyIncentiveAmounts(token_3eps, fee1, i) for i in range(week, week + 4)] == [0, 3 * 10**18, 0, 0]
    assert [ddd_distro.weeklyIncentiveAmounts(token_3eps, fee2, i) for i in range(week, week + 4)] == [0, 0, 0, 0]


def test_lp_token_not_approved(fee1, ddd_distro, deployer):
    with brownie.reverts("lpToken not approved for incentives"):
        ddd_distro.depositIncentive(fee1, fee1, 10**18, {'from': deployer})


def test_lp_token_not_approved_zero_amount(fee1, ddd_distro, deployer):
    with brownie.reverts("lpToken not approved for incentives"):
        ddd_distro.depositIncentive(fee1, fee1, 0, {'from': deployer})


def test_insufficient_balance(fee1, ddd_distro, deployer, token_3eps):
    with brownie.reverts():
        ddd_distro.depositIncentive(token_3eps, fee1, fee1.balanceOf(deployer) + 1, {'from': deployer})
