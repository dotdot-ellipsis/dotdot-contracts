import brownie
from brownie import ZERO_ADDRESS, chain
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, epx, early_incentives, alice, bob, locker1, advance_week):
    advance_week()
    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    early_incentives.deposit(alice, 10**25, {'from': locker1})
    early_incentives.deposit(bob, 3 * 10**25, {'from': locker1})


def test_voting_period(voter, locker, alice):
    assert locker.getWeek() == voter.getWeek()
    assert not voter.votingOpen()
    with brownie.reverts("Voting period has not opened for this week"):
        voter.vote([], [], {'from': alice})

    chain.mine(timedelta=86400 * 3)
    assert locker.getWeek() == voter.getWeek()
    assert not voter.votingOpen()
    with brownie.reverts("Voting period has not opened for this week"):
        voter.vote([], [], {'from': alice})

    chain.mine(timedelta=86400)
    assert locker.getWeek() == voter.getWeek() + 1
    assert voter.votingOpen()
    voter.vote([], [], {'from': alice})


def test_available_votes(voter, locker, alice, bob):
    # prior to period open there are no available votes
    assert voter.availableVotes(alice) == 0
    assert voter.availableVotes(bob) == 0

    chain.mine(timedelta=86400*4)
    assert locker.getWeek() == voter.getWeek() + 1
    assert voter.availableVotes(alice) == locker.weeklyWeightOf(alice, voter.getWeek()) // 10**18
    assert voter.availableVotes(bob) == locker.weeklyWeightOf(bob, voter.getWeek()) // 10**18


def test_ratio(voter, locker, alice, eps_voter, proxy):
    chain.mine(timedelta=86400 * 4)
    voter.vote([], [], {'from': alice})

    eps_votes = eps_voter.availableVotes(proxy)
    ddd_votes = locker.weeklyTotalWeight(voter.getWeek()) // 10**18

    assert voter.epsVoteRatio(voter.getWeek()) == eps_votes // ddd_votes


def test_vote(voter, alice, eps_voter, proxy, token_3eps, token_abnb):
    chain.mine(timedelta=86400 * 4)
    available = voter.availableVotes(alice)
    voter.vote([token_3eps, token_abnb], [1000, 5000], {'from': alice})

    assert voter.availableVotes(alice) == available - 6000
    assert voter.userVotes(alice, voter.getWeek()) == 6000
    assert voter.userTokenVotes(alice, token_3eps, voter.getWeek()) == 1000
    assert voter.userTokenVotes(alice, token_abnb, voter.getWeek()) == 5000
    assert voter.tokenVotes(token_3eps, voter.getWeek()) == 1000
    assert voter.tokenVotes(token_abnb, voter.getWeek()) == 5000

    ratio = voter.epsVoteRatio(voter.getWeek())
    assert eps_voter.userTokenVotes(proxy, token_3eps, eps_voter.getWeek()) == 1000 * ratio
    assert eps_voter.userTokenVotes(proxy, token_abnb, eps_voter.getWeek()) == 5000 * ratio


def test_vote_same_token(voter, alice, eps_voter, proxy, token_3eps):
    chain.mine(timedelta=86400 * 4)
    available = voter.availableVotes(alice)
    voter.vote([token_3eps, token_3eps], [1000, 337], {'from': alice})

    assert voter.availableVotes(alice) == available - 1337
    assert voter.userVotes(alice, voter.getWeek()) == 1337
    assert voter.userTokenVotes(alice, token_3eps, voter.getWeek()) == 1337
    assert voter.tokenVotes(token_3eps, voter.getWeek()) == 1337

    ratio = voter.epsVoteRatio(voter.getWeek())
    assert eps_voter.userTokenVotes(proxy, token_3eps, eps_voter.getWeek()) == 1337 * ratio


def test_exceed_available_votes(voter, alice, token_3eps, token_abnb):
    chain.mine(timedelta=86400 * 4)
    available = voter.availableVotes(alice)
    with brownie.reverts("Available votes exceeded"):
        voter.vote([token_3eps, token_abnb], [available, 1], {'from': alice})

    with brownie.reverts("Available votes exceeded"):
        voter.vote([token_3eps], [available + 1], {'from': alice})

    with brownie.reverts("Available votes exceeded"):
        voter.vote([token_3eps, token_3eps], [available, 1], {'from': alice})


def test_ratio_with_fixed_vote(voter, locker, alice, eps_voter, proxy, advance_week, depx_pool):
    advance_week()
    voter.createFixedVoteApprovalVote({'from': alice})
    assert eps_voter.isApproved(depx_pool)

    chain.mine(timedelta=86400 * 4)

    eps_votes = eps_voter.availableVotes(proxy)
    fixed_vote = eps_votes // 20
    eps_votes -= fixed_vote
    ddd_votes = locker.weeklyTotalWeight(voter.getWeek()) // 10**18
    voter.vote([], [], {'from': alice})

    assert voter.epsVoteRatio(voter.getWeek()) == eps_votes // ddd_votes
    assert eps_voter.userTokenVotes(proxy, depx_pool, eps_voter.getWeek()) == fixed_vote
