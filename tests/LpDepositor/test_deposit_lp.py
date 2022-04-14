import brownie
import pytest



@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, token_3eps, alice, bob, staker):
    token_3eps.mint(alice, 10**24, {'from': token_3eps.minter()})
    token_3eps.mint(bob, 10**24, {'from': token_3eps.minter()})
    token_3eps.approve(staker, 2**256-1, {'from': alice})
    token_3eps.approve(staker, 2**256-1, {'from': bob})


def test_deposit(staker, alice, token_3eps, eps_staker, proxy):
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})

    assert eps_staker.userInfo(token_3eps, proxy)['depositAmount'] == 10**18
    assert staker.userBalances(alice, token_3eps) == 10**18
    assert staker.totalBalances(token_3eps) == 10**18


def test_deploys_deposit_token(DepositToken, staker, alice, token_3eps):
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})

    token = DepositToken.at(staker.depositTokens(token_3eps))
    assert token.balanceOf(alice) == 10**18
    assert token.totalSupply() == 10**18


def test_multiple_deposits(staker, alice, token_3eps, eps_staker, proxy, bob):
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})
    staker.deposit(alice, token_3eps, 3 * 10**18, {'from': alice})
    staker.deposit(bob, token_3eps, 9 * 10**18, {'from': bob})
    staker.deposit(bob, token_3eps, 2 * 10**18, {'from': alice})

    assert token_3eps.balanceOf(alice) == 10**24 - 6 * 10**18
    assert token_3eps.balanceOf(bob) == 10**24 - 9 * 10**18
    assert eps_staker.userInfo(token_3eps, proxy)['depositAmount'] == 15 * 10**18
    assert staker.totalBalances(token_3eps) == 15 * 10**18

    assert staker.userBalances(alice, token_3eps) == 4 * 10**18
    assert staker.userBalances(bob, token_3eps) == 11 * 10**18


def test_insufficient_balance(staker, alice, token_3eps):
    with brownie.reverts():
        staker.deposit(alice, token_3eps, 10**24 + 1, {'from': alice})

    staker.deposit(alice, token_3eps, 10**24, {'from': alice})

    with brownie.reverts():
        staker.deposit(alice, token_3eps, 1, {'from': alice})
