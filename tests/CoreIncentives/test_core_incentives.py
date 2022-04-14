import brownie
from brownie import chain
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, ddd, staker, deployer):
    ddd.mint(deployer, 2500000 * 10**18, {'from': staker})


def test_max_mintable_time(core_incentives):
    per_day = core_incentives.MAX_DAILY_MINT()
    start = core_incentives.startTime()
    for i in range(10):
        day = (chain[-1].timestamp - start) // 86400
        assert core_incentives.timeMintLimit() == per_day * day
        chain.mine(timedelta=86400)


def test_max_mintable_supply(core_incentives, ddd, staker, alice):
    pct = core_incentives.MINT_PCT()
    for i in range(10):
        supply = ddd.totalSupply()
        mintable = core_incentives.supplyMintLimit()
        assert (supply + mintable) // (100 // pct) == mintable
        ddd.mint(alice, 10**24, {'from': staker})


def test_claims_do_not_affect_max_mintable(core_incentives, core_receivers):
    time_limit = core_incentives.timeMintLimit()
    supply_limit = core_incentives.supplyMintLimit()

    for acct in core_receivers:
        core_incentives.claim(acct, 10**22, 4, {'from': acct})

        assert core_incentives.timeMintLimit() == time_limit
        assert core_incentives.supplyMintLimit() == supply_limit


def test_claim(core_incentives, locker, core_receivers, ddd):
    claimable = core_incentives.claimable(core_receivers[3])

    assert claimable == min(core_incentives.timeMintLimit(), core_incentives.supplyMintLimit()) * 4 // 10
    core_incentives.claim(core_receivers[3], claimable, 4, {'from': core_receivers[3]})

    assert ddd.balanceOf(core_incentives) == 0
    assert locker.getActiveUserLocks(core_receivers[3]) == [(4, claimable)]
    assert ddd.balanceOf(locker) == claimable


def test_claim_multiple(core_incentives, locker, core_receivers, ddd):
    amount = core_incentives.claimable(core_receivers[3]) // 4

    core_incentives.claim(core_receivers[3], amount, 4, {'from': core_receivers[3]})
    core_incentives.claim(core_receivers[3], amount * 2, 4, {'from': core_receivers[3]})
    core_incentives.claim(core_receivers[3], amount, 7, {'from': core_receivers[3]})

    assert ddd.balanceOf(core_incentives) == 0
    assert locker.getActiveUserLocks(core_receivers[3]) == [(4, amount * 3), (7, amount)]
    assert ddd.balanceOf(locker) == amount * 4
    assert core_incentives.claimable(core_receivers[3]) == 0


def test_claim_other_receiver(core_incentives, locker, core_receivers, ddd):
    claimable = [core_incentives.claimable(i) for i in core_receivers]
    amount = claimable[-1] // 4

    for i in range(3):
        core_incentives.claim(core_receivers[i], amount, 4, {'from': core_receivers[3]})
        assert locker.getActiveUserLocks(core_receivers[i]) == [(4, amount)]

    assert locker.getActiveUserLocks(core_receivers[3]) == []

    claimable[-1] -= amount * 3
    for i in range(4):
        assert core_incentives.claimable(core_receivers[i]) == claimable[i]


def test_zero_claims_all(core_incentives, locker, core_receivers):
    claimable = core_incentives.claimable(core_receivers[0])

    core_incentives.claim(core_receivers[0], 0, 9, {'from': core_receivers[0]})

    assert locker.getActiveUserLocks(core_receivers[0]) == [(9, claimable)]
    assert core_incentives.claimable(core_receivers[0]) == 0


def test_min_weeks(core_incentives, locker, core_receivers):
    with brownie.reverts("Must lock at least LOCK_WEEKS"):
        core_incentives.claim(core_receivers[0], 0, 3, {'from': core_receivers[0]})


def test_max_claimable(core_incentives, locker, core_receivers):
    claimable = core_incentives.claimable(core_receivers[0])

    with brownie.reverts("Exceeds claimable amount"):
        core_incentives.claim(core_receivers[0], claimable + 1, 4, {'from': core_receivers[0]})
