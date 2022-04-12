import brownie
import pytest



@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, token_3eps, alice, bob, staker):
    token_3eps.mint(alice, 9 * 10**18, {'from': token_3eps.minter()})
    token_3eps.approve(staker, 2**256-1, {'from': alice})
    staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    staker.deposit(bob, token_3eps, 5 * 10**18, {'from': alice})


def test_withdraw(staker, alice, token_3eps, eps_staker, proxy):
    staker.withdraw(alice, token_3eps, 4 * 10**18, {'from': alice})

    assert token_3eps.balanceOf(alice) == 4 * 10**18
    assert staker.userBalances(alice, token_3eps) == 0
    assert eps_staker.userInfo(token_3eps, proxy)['depositAmount'] == 5 * 10**18
    assert staker.totalBalances(token_3eps) == 5 * 10**18


def test_withdraw_multiple(staker, alice, token_3eps, eps_staker, proxy, bob):
    staker.withdraw(alice, token_3eps, 10**18, {'from': alice})
    staker.withdraw(bob, token_3eps, 2 * 10**18, {'from': alice})
    staker.withdraw(bob, token_3eps, 3 * 10**18, {'from': bob})

    assert token_3eps.balanceOf(alice) == 10**18
    assert token_3eps.balanceOf(bob) == 5 * 10**18
    assert staker.userBalances(alice, token_3eps) == 10**18
    assert staker.userBalances(bob, token_3eps) == 2 * 10**18

    assert eps_staker.userInfo(token_3eps, proxy)['depositAmount'] == 3 * 10**18
    assert staker.totalBalances(token_3eps) == 3 * 10**18


def test_insufficient_balance(staker, alice, token_3eps):
    with brownie.reverts("Insufficient balance"):
        staker.withdraw(alice, token_3eps, 4 * 10**18 + 1, {'from': alice})

    staker.withdraw(alice, token_3eps, 4 * 10**18, {'from': alice})

    with brownie.reverts("Insufficient balance"):
        staker.withdraw(alice, token_3eps, 1, {'from': alice})
