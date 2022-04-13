import brownie
import pytest
from brownie import chain, ZERO_ADDRESS


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, token_abnb, alice, bob, staker, early_incentives, locker1, epx, advance_week, voter, fee1, deployer):
    advance_week(2)
    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    early_incentives.deposit(locker1, 10**26, {'from': locker1})
    chain.sleep(86400 * 4)
    voter.vote([token_abnb], [100], {'from': locker1})


    token_abnb.mint(alice, 100 * 10**18, {'from': token_abnb.minter()})
    token_abnb.approve(staker, 2**256-1, {'from': alice})

    token_abnb.addReward(fee1, deployer, 604800, {'from': token_abnb.owner()})
    fee1._mint_for_testing(deployer, 10**24)
    fee1.approve(token_abnb, 2**256-1, {'from': deployer})


def test_update_extra_rewards(staker, alice, token_abnb):
    assert staker.extraRewardsLength(token_abnb) == 0
    staker.updatePoolExtraRewards(token_abnb, {'from': alice})

    assert staker.extraRewardsLength(token_abnb) == token_abnb.rewardCount() > 1
    for i in range(token_abnb.rewardCount()):
        assert staker.extraRewards(token_abnb, i) == token_abnb.rewardTokens(i)


def test_claimable_extras(staker, alice, token_abnb, fee1, deployer, proxy):
    staker.updatePoolExtraRewards(token_abnb, {'from': alice})

    staker.deposit(alice, token_abnb, 10**18, {'from': alice})
    chain.sleep(10)
    token_abnb.notifyRewardAmount(fee1, 10**24, {'from': deployer})
    chain.mine(timedelta=86400 * 8)

    expected = token_abnb.earned(proxy, fee1)

    assert staker.claimableExtraRewards(alice, token_abnb)[-1] == (fee1, expected)

    staker.claimExtraRewards(alice, token_abnb, {'from': alice})
    assert staker.claimableExtraRewards(alice, token_abnb)[-1] == (fee1, 0)
    assert fee1.balanceOf(alice) == expected


def test_claimable_extras_multiple_actions(staker, alice, token_abnb, fee1, deployer, proxy):
    staker.updatePoolExtraRewards(token_abnb, {'from': alice})

    staker.deposit(alice, token_abnb, 10**18, {'from': alice})
    token_abnb.notifyRewardAmount(fee1, 10**24, {'from': deployer})
    chain.sleep(86400)
    staker.deposit(alice, token_abnb, 10**18, {'from': alice})
    chain.sleep(86400)
    staker.deposit(alice, token_abnb, 10**18, {'from': alice})
    chain.mine(timedelta=604800)

    expected = token_abnb.earned(proxy, fee1) + fee1.balanceOf(staker)

    assert staker.claimableExtraRewards(alice, token_abnb)[-1] == (fee1, expected)

    staker.claimExtraRewards(alice, token_abnb, {'from': alice})
    assert staker.claimableExtraRewards(alice, token_abnb)[-1] == (fee1, 0)
    assert fee1.balanceOf(alice) == expected
