import brownie
from brownie import chain
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, epx, depx, bonded_distro, locker1):
    epx.approve(depx, 2**256-1, {'from': locker1})
    depx.deposit(locker1, 10**18, True, {'from': locker1})
    chain.sleep(86400 * 4)
    depx.deposit(locker1, 2 * 10**18, True, {'from': locker1})


def test_zero_unbondable(bonded_distro, depx, locker1):
    assert bonded_distro.unbondableBalance(locker1) == 0

    with brownie.reverts("Insufficient unbondable balance"):
        bonded_distro.initiateUnbondingStream(10**17, {'from': locker1})


def test_insufficient_unbondable(bonded_distro, depx, locker1):
    chain.mine(timedelta=86400 * 4)
    assert bonded_distro.unbondableBalance(locker1) == 10**18

    with brownie.reverts("Insufficient unbondable balance"):
        bonded_distro.initiateUnbondingStream(10**18 + 1, {'from': locker1})


def test_insufficient_unbondable2(bonded_distro, depx, locker1):
    chain.mine(timedelta=86400 * 4)
    assert bonded_distro.unbondableBalance(locker1) == 10**18

    bonded_distro.initiateUnbondingStream(10**18, {'from': locker1})
    with brownie.reverts("Insufficient unbondable balance"):
        bonded_distro.initiateUnbondingStream(1, {'from': locker1})
