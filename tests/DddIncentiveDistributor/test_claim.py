import brownie
from brownie import ZERO_ADDRESS, chain
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, epx, early_incentives, alice, bob, locker1, fee1, fee2, deployer, ddd_distro, advance_week):
    advance_week()
    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    early_incentives.deposit(alice, 10**24, {'from': locker1})
    early_incentives.deposit(bob, 3 * 10**24, {'from': locker1})

    fee1._mint_for_testing(deployer, 10**24)
    fee1.approve(ddd_distro, 2**256-1, {'from': deployer})
    fee2._mint_for_testing(deployer, 10**24)
    fee2.approve(ddd_distro, 2**256-1, {'from': deployer})



def test_claimable_locker_incentive(ddd_distro, alice, bob, fee1, deployer, advance_week):
    ddd_distro.depositIncentive(ZERO_ADDRESS, fee1, 4 * 10**18, {'from': deployer})

    advance_week(2)

    assert ddd_distro.claimable(alice, ZERO_ADDRESS, [fee1]) == [10**18]
    assert ddd_distro.claimable(bob, ZERO_ADDRESS, [fee1]) == [3 * 10**18]


def test_claimable_voter_incentive(ddd_distro, alice, bob, fee1, deployer, advance_week, token_3eps, voter):
    ddd_distro.depositIncentive(token_3eps, fee1, 4 * 10**18, {'from': deployer})
    chain.sleep(86400 * 4)
    voter.vote([token_3eps], [100], {'from': alice})

    advance_week(2)

    assert ddd_distro.claimable(alice, token_3eps, [fee1]) == [4 * 10**18]
    assert ddd_distro.claimable(bob, token_3eps, [fee1]) == [0]


def test_claimable_voter_incentive_no_votes(ddd_distro, alice, bob, fee1, deployer, advance_week, token_3eps, voter):
    ddd_distro.depositIncentive(token_3eps, fee1, 4 * 10**18, {'from': deployer})
    advance_week(2)

    assert ddd_distro.claimable(alice, token_3eps, [fee1]) == [0]
    assert ddd_distro.claimable(bob, token_3eps, [fee1]) == [0]


def test_claimable_voter_incentive_no_votes_some_weeks(ddd_distro, alice, bob, fee1, deployer, advance_week, token_3eps, voter):
    ddd_distro.depositIncentive(token_3eps, fee1, 4 * 10**18, {'from': deployer})

    advance_week(1)
    ddd_distro.depositIncentive(token_3eps, fee1, 3 * 10**18, {'from': deployer})
    chain.sleep(86400 * 4)
    voter.vote([token_3eps], [100], {'from': alice})

    advance_week(1)
    ddd_distro.depositIncentive(token_3eps, fee1, 4 * 10**18, {'from': deployer})
    chain.sleep(86400 * 4)
    voter.vote([token_3eps], [300], {'from': alice})
    voter.vote([token_3eps], [100], {'from': bob})

    advance_week(2)
    assert ddd_distro.claimable(alice, token_3eps, [fee1]) == [6 * 10**18]
    assert ddd_distro.claimable(bob, token_3eps, [fee1]) == [10**18]



def test_locker_claims(ddd_distro, alice, bob, fee1, fee2, deployer, advance_week):
    ddd_distro.depositIncentive(ZERO_ADDRESS, fee1, 4 * 10**18, {'from': deployer})

    chain.sleep(86400)
    ddd_distro.claim(alice, ZERO_ADDRESS, [fee1, fee2], {'from': alice})
    assert fee1.balanceOf(alice) == 0

    # because locker fees have a -3 day week offset, `advance_week` starts us half way through
    # the next epoch
    advance_week()
    last = 0
    for i in range(3):
        chain.sleep(80000)
        ddd_distro.claim(alice, ZERO_ADDRESS, [fee1, fee2], {'from': alice})
        amount = fee1.balanceOf(alice)
        assert 10**18 > amount > last
        last = amount

    chain.sleep(120000)
    ddd_distro.claim(alice, ZERO_ADDRESS, [fee1, fee2], {'from': alice})
    assert fee1.balanceOf(alice) == 10**18

    advance_week()
    ddd_distro.claim(bob, ZERO_ADDRESS, [fee1], {'from': bob})
    assert fee1.balanceOf(bob) == 3 * 10**18


def test_voter_claims(ddd_distro, alice, bob, fee1, token_3eps, deployer, advance_week, voter):
    ddd_distro.depositIncentive(token_3eps, fee1, 4 * 10**18, {'from': deployer})

    chain.sleep(86400 * 4)
    voter.vote([token_3eps], [100], {'from': alice})
    voter.vote([token_3eps], [300], {'from': bob})
    chain.sleep(86400)
    ddd_distro.claim(alice, token_3eps, [fee1], {'from': alice})
    assert fee1.balanceOf(alice) == 0

    advance_week()
    last = 0
    for i in range(6):
        chain.sleep(86400)
        ddd_distro.claim(alice, token_3eps, [fee1], {'from': alice})
        amount = fee1.balanceOf(alice)
        assert 10**18 > amount > last
        last = amount

    advance_week()
    ddd_distro.depositIncentive(token_3eps, fee1, 4 * 10**18, {'from': deployer})
    ddd_distro.claim(alice, token_3eps, [fee1], {'from': alice})
    assert fee1.balanceOf(alice) == 10**18

    advance_week()
    ddd_distro.claim(alice, token_3eps, [fee1], {'from': alice})
    ddd_distro.claim(bob, token_3eps, [fee1], {'from': bob})
    assert fee1.balanceOf(bob) == 3 * 10**18

