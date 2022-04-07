import brownie
from brownie import chain
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, epx, depx, bonded_distro, locker1):
    epx.approve(depx, 2**256-1, {'from': locker1})
    depx.deposit(locker1, 10**20, False, {'from': locker1})
    depx.approve(bonded_distro, 2**256-1, {'from': locker1})


def test_initial_balances(bonded_distro, alice):
    assert bonded_distro.bondedBalance(alice) == 0
    assert bonded_distro.unbondableBalance(alice) == 0
    assert bonded_distro.streamingBalances(alice) == (0, 0)


def test_deposit(bonded_distro, depx, locker1):
    initial = depx.balanceOf(locker1)

    bonded_distro.deposit(locker1, 10**18, {'from': locker1})

    assert depx.balanceOf(locker1) == initial - 10**18
    assert depx.balanceOf(bonded_distro) == 10**18
    assert bonded_distro.bondedBalance(locker1) == 10**18
    assert bonded_distro.unbondableBalance(locker1) == 0


def test_multiple_deposits(bonded_distro, depx, locker1):
    initial = depx.balanceOf(locker1)

    bonded_distro.deposit(locker1, 10**18, {'from': locker1})
    bonded_distro.deposit(locker1, 4 * 10**18, {'from': locker1})

    assert depx.balanceOf(locker1) == initial - 5 * 10**18
    assert depx.balanceOf(bonded_distro) == 5 * 10**18
    assert bonded_distro.bondedBalance(locker1) == 5 * 10**18
    assert bonded_distro.unbondableBalance(locker1) == 0


def test_multiple_deposits_different_receiver(bonded_distro, depx, locker1, alice):
    initial = depx.balanceOf(locker1)

    bonded_distro.deposit(locker1, 10**18, {'from': locker1})
    bonded_distro.deposit(alice, 4 * 10**18, {'from': locker1})

    assert depx.balanceOf(locker1) == initial - 5 * 10**18
    assert depx.balanceOf(bonded_distro) == 5 * 10**18
    assert bonded_distro.bondedBalance(locker1) == 10**18
    assert bonded_distro.bondedBalance(alice) == 4 * 10**18


def test_deposits_over_time(bonded_distro, depx, locker1):
    initial = depx.balanceOf(locker1)

    bonded_distro.deposit(locker1, 4 * 10**18, {'from': locker1})
    chain.sleep(86400 * 4)
    bonded_distro.deposit(locker1, 3 * 10**18, {'from': locker1})
    chain.sleep(86400 * 5)
    bonded_distro.deposit(locker1, 2 * 10**18, {'from': locker1})

    assert depx.balanceOf(locker1) == initial - 9 * 10**18
    assert depx.balanceOf(bonded_distro) == 9 * 10**18
    assert bonded_distro.bondedBalance(locker1) == 9 * 10**18
    assert bonded_distro.unbondableBalance(locker1) == 4 * 10**18


def test_deposit_via_depx(bonded_distro, epx, depx, locker1):
    initial_epx = epx.balanceOf(locker1)
    initial_depx = depx.balanceOf(locker1)

    depx.deposit(locker1, 10**18, True, {'from': locker1})

    assert epx.balanceOf(locker1) == initial_epx - 10**18
    assert depx.balanceOf(locker1) == initial_depx

    assert depx.balanceOf(bonded_distro) == 10**18
    assert bonded_distro.bondedBalance(locker1) == 10**18
    assert bonded_distro.unbondableBalance(locker1) == 0


def test_insufficient_balance(bonded_distro, locker1, depx):
    initial = depx.balanceOf(locker1)

    with brownie.reverts():
        bonded_distro.deposit(locker1, initial + 1, {'from': locker1})
