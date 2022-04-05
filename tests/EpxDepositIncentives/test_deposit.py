# first week reserved locked supply
# subsequent weeks,


def test_max_deposit_first_week(early_incentives, epsv1_staker, alice):
    expected = early_incentives.depositCap() - epsv1_staker.lockedSupply() * 88
    assert early_incentives.maxDepositAmount(alice) == expected


def test_deposit_first_week(early_incentives, epx, locker1):
    amount = epx.balanceOf(locker1)
    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    early_incentives.deposit(locker1, amount, {'from': locker1})
