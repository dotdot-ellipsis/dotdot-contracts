import brownie
import pytest
from brownie import chain, ZERO_ADDRESS



@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, token_3eps, token_abnb, alice, bob, staker, early_incentives, locker1, epx, advance_week, voter):
    advance_week()
    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    early_incentives.deposit(locker1, 10**26, {'from': locker1})
    chain.sleep(86400 * 4)
    voter.vote([token_3eps, token_abnb], [75, 25], {'from': locker1})


    token_3eps.mint(alice, 100 * 10**18, {'from': token_3eps.minter()})
    token_abnb.mint(alice, 100 * 10**18, {'from': token_abnb.minter()})
    token_3eps.approve(staker, 2**256-1, {'from': alice})
    token_abnb.approve(staker, 2**256-1, {'from': alice})


def test_push_protocol_fees(staker, alice, token_3eps, advance_week, epx, ddd):
    advance_week()
    staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    chain.mine(timedelta=50000)
    staker.claim(alice, [token_3eps], 0, {'from': alice})

    pending_epx = staker.pendingFeeEpx()
    pending_ddd = staker.pendingFeeDdd()
    assert pending_epx > 0
    assert pending_ddd > 0

    tx = staker.pushPendingProtocolFees({'from': alice})

    assert staker.pendingFeeEpx() == 0
    assert staker.pendingFeeDdd() == 0
    assert staker.lastFeeTransfer() == tx.timestamp


def test_ddd_lp_staker(staker, alice, token_3eps, advance_week, ddd_lp_staker, ddd):
    advance_week()
    staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    chain.mine(timedelta=50000)
    staker.claim(alice, [token_3eps], 0, {'from': alice})

    initial = ddd.balanceOf(ddd_lp_staker)
    pending = staker.pendingFeeDdd()
    tx = staker.pushPendingProtocolFees({'from': alice})

    assert ddd.balanceOf(ddd_lp_staker) == initial + pending
    assert ddd_lp_staker.periodFinish() == tx.timestamp + 604800


def test_bonded_distro(staker, alice, token_3eps, advance_week, bonded_distro, ddd, epx):
    advance_week()
    staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    chain.mine(timedelta=50000)
    staker.claim(alice, [token_3eps], 0, {'from': alice})

    pending = staker.pendingFeeEpx()
    staker.pushPendingProtocolFees({'from': alice})

    assert ddd.balanceOf(bonded_distro) == pending // staker.DDD_EARN_RATIO()
    assert epx.balanceOf(bonded_distro) == pending * 2 // 3

    week = bonded_distro.getWeek()
    assert bonded_distro.weeklyFeeAmounts(ddd, week) == pending // staker.DDD_EARN_RATIO()
    assert bonded_distro.weeklyFeeAmounts(epx, week) == pending * 2 // 3


def test_ddd_distro(staker, alice, token_3eps, advance_week, ddd_distro, depx):
    advance_week()
    staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    chain.mine(timedelta=50000)
    staker.claim(alice, [token_3eps], 0, {'from': alice})

    pending = staker.pendingFeeEpx()
    staker.pushPendingProtocolFees({'from': alice})

    assert depx.balanceOf(ddd_distro) == pending // 3

    week = ddd_distro.getLockingWeek()
    assert ddd_distro.weeklyIncentiveAmounts(ZERO_ADDRESS, depx, week) == pending // 3


def test_ddd_distro_with_pool_approval(voter, staker, alice, token_3eps, advance_week, ddd_distro, depx, depx_pool):
    advance_week()
    voter.createFixedVoteApprovalVote({'from': alice})
    staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    chain.mine(timedelta=50000)
    staker.claim(alice, [token_3eps], 0, {'from': alice})

    pending = staker.pendingFeeEpx()
    staker.pushPendingProtocolFees({'from': alice})

    assert depx.balanceOf(ddd_distro) == pending // 3

    week = ddd_distro.getVotingWeek()
    assert ddd_distro.weeklyIncentiveAmounts(depx_pool, depx, week) == pending // 6

    week = ddd_distro.getLockingWeek()
    assert ddd_distro.weeklyIncentiveAmounts(ZERO_ADDRESS, depx, week) == pending // 6
