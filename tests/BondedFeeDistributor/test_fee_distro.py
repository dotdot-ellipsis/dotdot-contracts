import brownie
import pytest
from brownie import chain


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, epx, depx, locker1, fee1, fee2, eps_fee_distro, deployer, alice, bob, bonded_distro):
    epx.approve(depx, 2**256-1, {'from': locker1})
    depx.deposit(alice, 10**21, False, {'from': locker1})
    depx.deposit(bob, 10**21, False, {'from': locker1})
    depx.approve(bonded_distro, 2**256-1, {'from': alice})
    depx.approve(bonded_distro, 2**256-1, {'from': bob})

    fee1.approve(eps_fee_distro, 2**256-1, {'from': deployer})
    fee2.approve(eps_fee_distro, 2**256-1, {'from': deployer})
    fee1._mint_for_testing(deployer, 10**24)
    fee2._mint_for_testing(deployer, 10**24)


def test_fetch_fees(bonded_distro, eps_fee_distro, fee1, deployer, advance_week):
    eps_fee_distro.depositFee(fee1, 10**18, {"from": deployer})
    advance_week(2)

    assert bonded_distro.feeTokensLength() == 0
    bonded_distro.fetchEllipsisFees([fee1], {'from': deployer})

    week = bonded_distro.getWeek()
    assert bonded_distro.weeklyFeeAmounts(fee1, week) == 10**18
    assert bonded_distro.lastClaim(fee1) == chain[-1].timestamp
    assert bonded_distro.feeTokensLength() == 1
    assert bonded_distro.feeTokens(0) == fee1


def test_fetch_fees_via_claim(bonded_distro, eps_fee_distro, fee1, deployer, advance_week):
    eps_fee_distro.depositFee(fee1, 10**18, {"from": deployer})
    advance_week(2)

    assert bonded_distro.feeTokensLength() == 0
    bonded_distro.claim(deployer, [fee1], {'from': deployer})

    week = bonded_distro.getWeek()
    assert bonded_distro.weeklyFeeAmounts(fee1, week) == 10**18


def test_fetch_fees_multiple(bonded_distro, eps_fee_distro, fee1, deployer, advance_week):
    eps_fee_distro.depositFee(fee1, 10**18, {"from": deployer})
    advance_week(1)

    amount = 0
    week = bonded_distro.getWeek()
    for i in range(6):
        chain.sleep(86400)
        bonded_distro.fetchEllipsisFees([fee1], {'from': deployer})
        new_amount = bonded_distro.weeklyFeeAmounts(fee1, week)
        assert new_amount > amount
        amount = new_amount

    chain.sleep(86400 * 2)
    bonded_distro.fetchEllipsisFees([fee1], {'from': deployer})

    assert bonded_distro.weeklyFeeAmounts(fee1, week) == amount
    assert bonded_distro.weeklyFeeAmounts(fee1, week + 1) + amount == 10 ** 18
    assert bonded_distro.lastClaim(fee1) == chain[-1].timestamp
    assert bonded_distro.feeTokensLength() == 1
    assert bonded_distro.feeTokens(0) == fee1


def test_fetch_via_claim_multiple(bonded_distro, eps_fee_distro, fee1, deployer, advance_week):
    eps_fee_distro.depositFee(fee1, 10**18, {"from": deployer})
    advance_week(1)

    tx = bonded_distro.claim(deployer, [fee1], {'from': deployer})
    last_claim = tx.timestamp

    for i in range(3):
        chain.sleep(10000)
        bonded_distro.claim(deployer, [fee1], {'from': deployer})
        assert bonded_distro.lastClaim(fee1) == last_claim

    chain.sleep(56401)
    tx = bonded_distro.claim(deployer, [fee1], {'from': deployer})
    assert bonded_distro.lastClaim(fee1) == tx.timestamp


def test_claimable(bonded_distro, eps_fee_distro, alice, fee1, fee2, deployer, advance_week):
    eps_fee_distro.depositFee(fee1, 10**18, {"from": deployer})

    # at +1 week, fees are streaming from eps to dotdot
    # weeklyFeeAmount should be increasing but the user claimable stays 0
    advance_week(1)

    assert bonded_distro.claimable(alice, [fee1, fee2]) == [0, 0]

    bonded_distro.deposit(alice, 10**18, {'from': alice})
    assert bonded_distro.claimable(alice, [fee1, fee2]) == [0, 0]

    chain.sleep(86400)
    bonded_distro.fetchEllipsisFees([fee1], {'from': deployer})
    assert bonded_distro.claimable(alice, [fee1, fee2]) == [0, 0]

    chain.sleep(86400)
    bonded_distro.claim(alice, [fee1], {'from': alice})
    assert bonded_distro.claimable(alice, [fee1, fee2]) == [0, 0]
    expected = bonded_distro.weeklyFeeAmounts(fee1, bonded_distro.getWeek())

    # at +2 weeks fees begin to stream to the user
    # at +3 weeks the stream should be complete
    advance_week(2)
    assert bonded_distro.claimable(alice, [fee1, fee2]) == [expected, 0]

    bonded_distro.fetchEllipsisFees([fee1], {'from': deployer})
    assert bonded_distro.claimable(alice, [fee1, fee2]) == [expected, 0]

    bonded_distro.claim(alice, [fee1], {'from': deployer})
    assert bonded_distro.claimable(alice, [fee1, fee2]) == [0, 0]
    assert fee1.balanceOf(alice) == expected


def test_depx_as_claimable(bonded_distro, eps_fee_distro, alice, depx, deployer, advance_week, bob):
    depx.approve(eps_fee_distro, 2**256-1, {'from': bob})
    eps_fee_distro.depositFee(depx, 10**18, {"from": bob})

    # at +1 week, fees are streaming from eps to dotdot
    # weeklyFeeAmount should be increasing but the user claimable stays 0
    advance_week(1)

    assert bonded_distro.claimable(alice, [depx]) == [0]

    bonded_distro.deposit(alice, 2 * 10**18, {'from': alice})
    assert bonded_distro.claimable(alice, [depx]) == [0]

    chain.sleep(86400)
    bonded_distro.fetchEllipsisFees([depx], {'from': deployer})
    assert bonded_distro.claimable(alice, [depx]) == [0]

    chain.sleep(86400)
    bonded_distro.claim(alice, [depx], {'from': alice})
    assert bonded_distro.claimable(alice, [depx]) == [0]
    expected = bonded_distro.weeklyFeeAmounts(depx, bonded_distro.getWeek())

    # at +2 weeks fees begin to stream to the user

    advance_week(1)
    chain.sleep(86400 * 2)
    bonded_distro.initiateUnbondingStream(10**18, {'from': alice})
    eps_fee_distro.depositFee(depx, 10**18, {"from": bob})

    # at +3 weeks the stream should be complete
    advance_week(1)
    assert bonded_distro.claimable(alice, [depx]) == [expected,]
    bonded_distro.deposit(alice, depx.balanceOf(alice), {'from': alice})
    bonded_distro.withdrawUnbondedTokens(bob, {'from': alice})

    bonded_distro.fetchEllipsisFees([depx], {'from': deployer})
    assert bonded_distro.claimable(alice, [depx]) == [expected]

    bonded_distro.claim(alice, [depx], {'from': deployer})
    assert bonded_distro.claimable(alice, [depx]) == [0]
    assert depx.balanceOf(alice) == expected
