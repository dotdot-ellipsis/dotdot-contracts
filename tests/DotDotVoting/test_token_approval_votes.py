import brownie
from brownie import ZERO_ADDRESS, chain
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, voter, epx, early_incentives, alice, bob, locker1, advance_week):
    epx.approve(early_incentives, 2**256-1, {'from': locker1})
    early_incentives.deposit(alice, 10**25, {'from': locker1})
    early_incentives.deposit(bob, 3 * 10**25, {'from': locker1})
    advance_week(2)
    voter.createFixedVoteApprovalVote({'from': alice})
    chain.mine(timedelta=86400 * 8)


def test_create_vote(voter, eps_voter, alice, token_ust):
    tx = voter.createTokenApprovalVote(token_ust, {'from': alice})
    vote_index = tx.events['CreatedTokenApprovalVote']['voteIndex']

    assert voter.lastVote(alice) == tx.timestamp
    assert eps_voter.tokenApprovalVotes(vote_index)['token'] == token_ust


def test_min_weight(voter, token_ust, charlie):
    assert voter.minWeightForNewTokenApprovalVote() > 0
    with brownie.reverts("User has insufficient DotDot lock weight"):
        voter.createTokenApprovalVote(token_ust, {'from': charlie})


def test_time_restriction(voter, alice, token_ust):
    voter.createTokenApprovalVote(token_ust, {'from': alice})

    chain.sleep(86400 * 29)
    with brownie.reverts("One new vote per 30 days"):
        voter.createTokenApprovalVote(token_ust, {'from': alice})

    chain.sleep(86401)
    voter.createTokenApprovalVote(token_ust, {'from': alice})


def test_vote(voter, alice, token_ust, eps_voter, proxy, eps_locker):
    tx = voter.createTokenApprovalVote(token_ust, {'from': alice})
    vote_index = tx.events['CreatedTokenApprovalVote']['voteIndex']

    initial_eps = eps_voter.availableTokenApprovalVotes(proxy, vote_index)


    ddd_alice = voter.availableTokenApprovalVotes(alice, vote_index)
    ddd_total = ddd_alice * 4
    ratio = initial_eps // ddd_total
    assert ddd_alice > 0
    voter.voteForTokenApproval(vote_index, ddd_alice, {'from': alice})

    assert eps_voter.availableTokenApprovalVotes(proxy, vote_index) == initial_eps - (ddd_alice * ratio)


def test_vote_max(voter, alice, token_ust, eps_voter, proxy, eps_locker):
    tx = voter.createTokenApprovalVote(token_ust, {'from': alice})
    vote_index = tx.events['CreatedTokenApprovalVote']['voteIndex']

    initial_eps = eps_voter.availableTokenApprovalVotes(proxy, vote_index)


    ddd_alice = voter.availableTokenApprovalVotes(alice, vote_index)
    ddd_total = ddd_alice * 4
    ratio = initial_eps // ddd_total
    assert ddd_alice > 0
    voter.voteForTokenApproval(vote_index, 2**256-1, {'from': alice})

    assert eps_voter.availableTokenApprovalVotes(proxy, vote_index) == initial_eps - (ddd_alice * ratio)


def test_vote_partial(voter, alice, token_ust, eps_voter, proxy, eps_locker):
    tx = voter.createTokenApprovalVote(token_ust, {'from': alice})
    vote_index = tx.events['CreatedTokenApprovalVote']['voteIndex']

    initial_eps = eps_voter.availableTokenApprovalVotes(proxy, vote_index)


    ddd_alice = voter.availableTokenApprovalVotes(alice, vote_index)
    ddd_total = ddd_alice * 4
    ratio = initial_eps // ddd_total

    ddd_alice //= 5
    voter.voteForTokenApproval(vote_index, ddd_alice, {'from': alice})

    assert eps_voter.availableTokenApprovalVotes(proxy, vote_index) == initial_eps - (ddd_alice * ratio)


def test_vote_multiple(voter, alice, token_ust, eps_voter, proxy, eps_locker):
    tx = voter.createTokenApprovalVote(token_ust, {'from': alice})
    vote_index = tx.events['CreatedTokenApprovalVote']['voteIndex']

    initial_eps = eps_voter.availableTokenApprovalVotes(proxy, vote_index)
    initial_alice = ddd_alice = voter.availableTokenApprovalVotes(alice, vote_index)
    ddd_total = ddd_alice * 4
    ratio = initial_eps // ddd_total

    total_alice = 0
    for i in range(5):
        ddd_alice //= 2
        voter.voteForTokenApproval(vote_index, ddd_alice, {'from': alice})
        total_alice += ddd_alice

        assert eps_voter.availableTokenApprovalVotes(proxy, vote_index) == initial_eps - (total_alice * ratio)

    voter.voteForTokenApproval(vote_index, 2**256-1, {'from': alice})

    assert eps_voter.availableTokenApprovalVotes(proxy, vote_index) == initial_eps - (initial_alice * ratio)
