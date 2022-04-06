import pytest
import brownie
from brownie import chain


def test_only_first_week(early_incentives, locker1):
    chain.mine(timestamp=early_incentives.startTime() + 604800)
    with brownie.reverts("Can only register during first week"):
        early_incentives.registerLegacyLocks(locker1, {'from': locker1})


def test_only_first_week(early_incentives, alice):
    with brownie.reverts("No legacy locks"):
        early_incentives.registerLegacyLocks(alice, {'from': alice})


def test_already_registered(early_incentives, locker1):
    early_incentives.registerLegacyLocks(locker1, {'from': locker1})
    with brownie.reverts("Already registered"):
        early_incentives.registerLegacyLocks(locker1, {'from': locker1})


def test_reserved_increases(early_incentives, epsv1_staker, locker1):
    amount = epsv1_staker.lockedBalances(locker1)['locked']
    early_incentives.registerLegacyLocks(locker1, {'from': locker1})
    assert early_incentives.reservedDeposits() == amount * 88


def test_weekly_totals(early_incentives, epsv1_staker, locker1):
    amount = epsv1_staker.lockedBalances(locker1)['locked']
    early_incentives.registerLegacyLocks(locker1, {'from': locker1})
    user_reserved = [early_incentives.userWeeklyReservedDeposits(locker1, i) for i in range(13)]
    total_reserved = [early_incentives.totalWeeklyReservedDeposits(i) for i in range(13)]

    assert sum(user_reserved) == sum(total_reserved) == amount * 88


def test_weekly_amounts(early_incentives, epsv1_staker, locker1):
    lock_amounts = epsv1_staker.lockedBalances(locker1)['lockData']
    early_incentives.registerLegacyLocks(locker1, {'from': locker1})
    user_reserved = [early_incentives.userWeeklyReservedDeposits(locker1, i) for i in range(13)]
    total_reserved = [early_incentives.totalWeeklyReservedDeposits(i) for i in range(13)]

    assert user_reserved == total_reserved

    for amount, unlock_time in lock_amounts:
        week = (unlock_time - chain[-1].timestamp) // 604800 + 1
        assert user_reserved[week] == amount * 88


def test_register_multiple(early_incentives, epsv1_staker, locker1, locker2):
    early_incentives.registerLegacyLocks(locker1, {'from': locker1})
    early_incentives.registerLegacyLocks(locker2, {'from': locker1})

    user1_reserved = [early_incentives.userWeeklyReservedDeposits(locker1, i) for i in range(13)]
    user2_reserved = [early_incentives.userWeeklyReservedDeposits(locker2, i) for i in range(13)]
    total_reserved = [early_incentives.totalWeeklyReservedDeposits(i) for i in range(13)]

    assert sum(user2_reserved) > 0
    assert sum(user1_reserved) + sum(user2_reserved) == sum(total_reserved)

    amount = epsv1_staker.lockedBalances(locker1)['locked'] + epsv1_staker.lockedBalances(locker2)['locked']
    assert early_incentives.reservedDeposits() == amount * 88


def test_reserved_amounts(early_incentives, epsv1_staker, locker1, locker2):
    early_incentives.registerLegacyLocks(locker1, {'from': locker1})
    early_incentives.registerLegacyLocks(locker2, {'from': locker1})

    user1_reserved = [early_incentives.userWeeklyReservedDeposits(locker1, i) for i in range(1, 13)][::-1]
    user2_reserved = [early_incentives.userWeeklyReservedDeposits(locker2, i) for i in range(1, 13)][::-1]
    total_reserved = [early_incentives.totalWeeklyReservedDeposits(i) for i in range(1, 13)][::-1]

    expected = early_incentives.depositCap() - epsv1_staker.lockedSupply() * 88
    assert early_incentives.maxDepositAmount(locker1) == (expected, 0)

    for i in range(12):
        chain.mine(timedelta=86400 * 7)
        early_incentives.updateReservedDeposits({'from': locker1})
        expected = early_incentives.depositCap() - sum(total_reserved)

        reserved = user1_reserved.pop()
        assert early_incentives.maxDepositAmount(locker1) == (expected + reserved, reserved)

        reserved = user2_reserved.pop()
        assert early_incentives.maxDepositAmount(locker2) == (expected + reserved, reserved)

        total_reserved.pop()
