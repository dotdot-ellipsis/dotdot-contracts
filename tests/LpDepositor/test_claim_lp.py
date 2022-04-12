import brownie
import pytest
from brownie import chain



@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, token_3eps, token_abnb, alice, bob, staker, early_incentives, locker1, epx, advance_week, voter):
    advance_week()
    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    early_incentives.deposit(locker1, 10**24, {'from': locker1})
    chain.sleep(86400 * 4)
    voter.vote([token_3eps, token_abnb], [75, 25], {'from': locker1})


    token_3eps.mint(alice, 100 * 10**18, {'from': token_3eps.minter()})
    token_abnb.mint(alice, 100 * 10**18, {'from': token_abnb.minter()})
    token_3eps.approve(staker, 2**256-1, {'from': alice})
    token_abnb.approve(staker, 2**256-1, {'from': alice})

    # staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    # staker.deposit(bob, token_3eps, 5 * 10**18, {'from': alice})


def test_claim(staker, alice, token_3eps, advance_week, epx, ddd):
    advance_week()
    staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    chain.mine(timedelta=50000)
    expected = staker.claimable(alice, [token_3eps])[0]
    staker.claim(alice, [token_3eps], 0, {'from': alice})

    received = epx.balanceOf(alice)
    assert received > 0
    assert 0.9999 <= expected[0] / received <= 1
    assert 0.9999 <= expected[1] / ddd.balanceOf(alice) <= 1

    pending = staker.pendingBonderEpx()
    assert epx.balanceOf(staker) == pending
    assert pending / (pending + received) == 0.15
    assert ddd.balanceOf(alice) == received // staker.DDD_EARN_RATIO()
    assert staker.claimable(alice, [token_3eps])[0] == (0, 0)


def test_claim_multiple_actions(staker, alice, token_3eps, advance_week, epx, ddd):
    advance_week()

    # the total duration is less than 1 day so that `pendingBonderEpx` is not pushed
    staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    chain.mine(timedelta=3600)
    staker.withdraw(alice, token_3eps, 3 * 10**18, {'from': alice})
    chain.mine(timedelta=3600)
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})
    chain.mine(timedelta=3600)
    expected = staker.claimable(alice, [token_3eps])[0]
    staker.claim(alice, [token_3eps], 0, {'from': alice})

    received = epx.balanceOf(alice)
    assert received > 0
    assert 0.9999 <= expected[0] / received <= 1
    assert 0.9999 <= expected[1] / ddd.balanceOf(alice) <= 1

    pending = staker.pendingBonderEpx()
    assert epx.balanceOf(staker) == pending
    assert pending / (pending + received) == 0.15
    assert ddd.balanceOf(alice) == received // staker.DDD_EARN_RATIO()
    assert staker.claimable(alice, [token_3eps])[0] == (0, 0)


def test_claim_multiple_users(staker, alice, bob, token_3eps, advance_week, epx, ddd):
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})
    staker.deposit(bob, token_3eps, 3 * 10**18, {'from': alice})

    # advance 2 weeks so the incentives fully distribute
    advance_week(2)
    expected = staker.claimable(alice, [token_3eps])[0]
    expected2 = staker.claimable(bob, [token_3eps])[0]

    assert expected[0] * 3 == expected2[0]
    assert expected[1] * 3 == expected2[1]

    staker.claim(alice, [token_3eps], 0, {'from': alice})
    staker.claim(bob, [token_3eps], 0, {'from': bob})

    assert epx.balanceOf(alice) == expected[0]
    assert epx.balanceOf(alice) * 3 == epx.balanceOf(bob)

    # any pending bonder fees should have been pushed
    assert epx.balanceOf(staker) == 0


def test_claim_multiple_users_multiple_pools(staker, alice, bob, token_3eps, advance_week, epx, ddd, token_abnb):
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})
    staker.deposit(bob, token_3eps, 3 * 10**18, {'from': alice})
    staker.deposit(bob, token_abnb, 3 * 10**18, {'from': alice})

    # advance 2 weeks so the incentives fully distribute
    advance_week(2)
    expected = staker.claimable(alice, [token_3eps, token_abnb])
    expected2 = staker.claimable(bob, [token_3eps, token_abnb])

    assert expected[0][0] * 3 == expected2[0][0]
    assert expected[0][1] * 3 == expected2[0][1]
    assert expected[1] == (0, 0)
    assert (expected[0][0] + expected2[0][0]) / (expected[1][0] + expected2[1][0]) == 3

    staker.claim(alice, [token_3eps, token_abnb], 0, {'from': alice})
    staker.claim(bob, [token_3eps, token_abnb], 0, {'from': bob})

    assert epx.balanceOf(alice) == expected[0][0]

    assert epx.balanceOf(bob) == expected2[0][0] + expected2[1][0]


def test_claim_and_bond(staker, alice, token_3eps, advance_week, epx, ddd, bonded_distro):
    advance_week()
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})
    advance_week()

    expected = staker.claimable(alice, [token_3eps])[0]
    staker.claim(alice, [token_3eps], expected[0], {'from': alice})

    assert epx.balanceOf(alice) == 0
    assert bonded_distro.bondedBalance(alice) == expected[0]
    assert ddd.balanceOf(alice) == expected[1] * staker.DDD_LOCK_MULTIPLIER()
    assert staker.claimable(alice, [token_3eps])[0] == (0, 0)


def test_claim_and_bond_partial(staker, alice, token_3eps, advance_week, epx, ddd, bonded_distro):
    advance_week()
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})
    advance_week()

    expected = staker.claimable(alice, [token_3eps])[0]
    bond_amount = expected[0] // 2
    claim_amount = expected[0] - bond_amount
    staker.claim(alice, [token_3eps], bond_amount, {'from': alice})

    assert epx.balanceOf(alice) == claim_amount
    assert bonded_distro.bondedBalance(alice) == bond_amount

    assert ddd.balanceOf(alice) == (
        claim_amount // staker.DDD_EARN_RATIO() +
        bond_amount * staker.DDD_LOCK_MULTIPLIER() // staker.DDD_EARN_RATIO()
    )

    assert staker.claimable(alice, [token_3eps])[0] == (0, 0)



def test_claim_and_bond_max_uint256(staker, alice, token_3eps, advance_week, epx, ddd, bonded_distro):
    advance_week()
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})
    advance_week()

    expected = staker.claimable(alice, [token_3eps])[0]
    staker.claim(alice, [token_3eps], 2**256-1, {'from': alice})

    assert epx.balanceOf(alice) == 0
    assert bonded_distro.bondedBalance(alice) == expected[0]
    assert ddd.balanceOf(alice) == expected[1] * staker.DDD_LOCK_MULTIPLIER()
    assert staker.claimable(alice, [token_3eps])[0] == (0, 0)
