from brownie import chain
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(epx, locker1, depx):
    epx.approve(depx, 2**256-1, {'from': locker1})


def test_deposit(depx, epx, locker1, eps_locker, proxy):
    initial = epx.balanceOf(locker1)
    depx.deposit(locker1, 10**18, False, {'from': locker1})

    assert epx.balanceOf(locker1) == initial - 10**18
    assert depx.balanceOf(locker1) == 10**18
    assert depx.totalSupply() == 10**18
    assert eps_locker.getActiveUserLocks(proxy) == [(52, 10**18)]


def test_deposit_multiple(depx, epx, locker1, alice, eps_locker, proxy):
    initial = epx.balanceOf(locker1)

    depx.deposit(locker1, 10**18, False, {'from': locker1})
    depx.deposit(locker1, 2 * 10**18, False, {'from': locker1})
    depx.deposit(alice, 10**18, False, {'from': locker1})

    assert epx.balanceOf(locker1) == initial - 4 * 10**18
    assert depx.balanceOf(locker1) == 3 * 10**18
    assert depx.balanceOf(alice) == 10**18
    assert depx.totalSupply() == 4 * 10**18
    assert eps_locker.getActiveUserLocks(proxy) == [(52, 4 * 10**18)]


def test_deposit_and_bond(depx, epx, locker1, bonded_distro, eps_locker, proxy):
    initial = epx.balanceOf(locker1)
    depx.deposit(locker1, 10**18, True, {'from': locker1})

    assert epx.balanceOf(locker1) == initial - 10**18
    assert depx.balanceOf(locker1) == 0
    assert depx.balanceOf(bonded_distro) == 10**18
    assert bonded_distro.bondedBalance(locker1) == 10**18
    assert depx.totalSupply() == 10**18
    assert eps_locker.getActiveUserLocks(proxy) == [(52, 10**18)]


def test_deposit_multiple_weeks(depx, epx, locker1, eps_locker, proxy):
    initial = epx.balanceOf(locker1)

    for i in range(1, 11):
        chain.sleep(86400 * 7 * i)
        depx.deposit(locker1, 10**18, False, {'from': locker1})

    assert epx.balanceOf(locker1) == initial - 10**19
    assert depx.balanceOf(locker1) == 10**19
    assert depx.totalSupply() == 10**19
    assert eps_locker.getActiveUserLocks(proxy) == [(52, 10**19)]


def test_extend_lock(depx, locker1, eps_locker, proxy):
    depx.deposit(locker1, 10**18, False, {'from': locker1})
    chain.mine(timedelta=86400 * 14)
    assert eps_locker.getActiveUserLocks(proxy) == [(50, 10**18)]
    depx.extendLock({'from': locker1})
    assert eps_locker.getActiveUserLocks(proxy) == [(52, 10**18)]
