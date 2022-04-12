from brownie import chain


def test_max_deposit_first_week(early_incentives, epsv1_staker, alice):
    expected = early_incentives.depositCap() - epsv1_staker.lockedSupply() * 88
    assert early_incentives.maxDepositAmount(alice) == (expected, 0)


def test_deposit_first_week(early_incentives, bonded_distro, epx, epsv1_staker, locker, locker1):
    amount = epx.balanceOf(locker1)
    reserved = early_incentives.reservedDeposits()
    initial_max = early_incentives.depositCap() - epsv1_staker.lockedSupply() * 88

    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    early_incentives.deposit(locker1, amount, {'from': locker1})

    assert early_incentives.receivedDeposits() == amount
    assert early_incentives.reservedDeposits() == reserved
    assert early_incentives.maxDepositAmount(locker1) == (initial_max - amount, 0)

    assert bonded_distro.bondedBalance(locker1) == amount

    expected_ddd = amount // early_incentives.DDD_MINT_RATIO() // 4
    assert locker.getActiveUserLocks(locker1) == [(4, expected_ddd), (8, expected_ddd), (12, expected_ddd), (16, expected_ddd)]


def test_multi_deposits_first_week(early_incentives, bonded_distro, epx, epsv1_staker, locker, locker1):
    initial_amount = epx.balanceOf(locker1)
    reserved = early_incentives.reservedDeposits()
    initial_max = early_incentives.depositCap() - epsv1_staker.lockedSupply() * 88

    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    expected_ddd = 0
    amount = 0
    for i in (2, 5, 10):
        deposit_amount = initial_amount // i
        amount += deposit_amount
        expected_ddd += deposit_amount // early_incentives.DDD_MINT_RATIO() // 4
        early_incentives.deposit(locker1, deposit_amount, {'from': locker1})

    assert epx.balanceOf(locker1) == initial_amount - amount
    assert early_incentives.receivedDeposits() == amount
    assert early_incentives.reservedDeposits() == reserved
    assert early_incentives.maxDepositAmount(locker1) == (initial_max - amount, 0)
    assert bonded_distro.bondedBalance(locker1) == amount
    assert locker.getActiveUserLocks(locker1) == [(4, expected_ddd), (8, expected_ddd), (12, expected_ddd), (16, expected_ddd)]


def test_deposit_with_reserved(early_incentives, bonded_distro, epx, epsv1_staker, locker, locker1):
    early_incentives.registerLegacyLocks(locker1, {'from': locker1})
    chain.mine(timedelta=86400 * 7)

    amount = epx.balanceOf(locker1)
    reserved = early_incentives.reservedDeposits()

    total, user_reserved = early_incentives.maxDepositAmount(locker1)
    amount = user_reserved // 3

    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    early_incentives.deposit(locker1, amount, {'from': locker1})

    assert early_incentives.receivedDeposits() == amount
    assert early_incentives.reservedDeposits() == reserved - amount
    assert early_incentives.maxDepositAmount(locker1) == (total - amount, user_reserved - amount)
    assert bonded_distro.bondedBalance(locker1) == amount

    expected_ddd = amount // early_incentives.DDD_MINT_RATIO() // 4
    assert locker.getActiveUserLocks(locker1) == [(4, expected_ddd), (8, expected_ddd), (12, expected_ddd), (16, expected_ddd)]



def test_multi_deposit_with_reserved(early_incentives, bonded_distro, epx, epsv1_staker, locker, locker1):
    early_incentives.registerLegacyLocks(locker1, {'from': locker1})
    chain.mine(timedelta=86400 * 7)

    initial_amount = epx.balanceOf(locker1)
    reserved = early_incentives.reservedDeposits()

    total, user_reserved = early_incentives.maxDepositAmount(locker1)

    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    expected_ddd = 0
    amount = 0
    for i in [2, 3, 2, 5]:
        deposit_amount = user_reserved // i
        amount += deposit_amount
        expected_ddd += deposit_amount // early_incentives.DDD_MINT_RATIO() // 4
        early_incentives.deposit(locker1, deposit_amount, {'from': locker1})
        assert early_incentives.maxDepositAmount(locker1) == (total - amount, max(user_reserved - amount, 0))
        assert early_incentives.reservedDeposits() == reserved - min(user_reserved, amount)

    assert epx.balanceOf(locker1) == initial_amount - amount
    assert early_incentives.receivedDeposits() == amount
    assert bonded_distro.bondedBalance(locker1) == amount
    assert locker.getActiveUserLocks(locker1) == [(4, expected_ddd), (8, expected_ddd), (12, expected_ddd), (16, expected_ddd)]


def test_deposit_updates_reserved_amounts(early_incentives, epx, locker1, alice):
    early_incentives.registerLegacyLocks(locker1, {'from': locker1})
    initial_reserved = early_incentives.reservedDeposits()


    user_reserved = [early_incentives.userWeeklyReservedDeposits(locker1, i) for i in range(4)]
    chain.mine(timedelta=86400 * 7 * 4)

    epx.transfer(alice, 10**18, {'from': locker1})
    epx.approve(early_incentives, 2**256-1, {'from': alice})
    early_incentives.deposit(alice, 10**18, {'from': alice})

    assert early_incentives.reservedDeposits() == initial_reserved - sum(user_reserved)
