import brownie
import pytest



@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, token_3eps, alice, bob, staker):
    token_3eps.mint(alice, 12 * 10**18, {'from': token_3eps.minter()})
    token_3eps.approve(staker, 2**256-1, {'from': alice})
    staker.deposit(alice, token_3eps, 4 * 10**18, {'from': alice})
    staker.deposit(bob, token_3eps, 5 * 10**18, {'from': alice})


@pytest.fixture(scope="module", autouse=True)
def deposit_token(setup, DepositToken, staker, token_3eps):
    return DepositToken.at(staker.depositTokens(token_3eps))


def test_deposits(deposit_token, staker, alice, token_3eps, bob):
    staker.deposit(alice, token_3eps, 10**18, {'from': alice})
    staker.deposit(bob, token_3eps, 2 * 10**18, {'from': alice})

    assert deposit_token.totalSupply() == 12 * 10**18
    assert deposit_token.balanceOf(alice) == 5 * 10**18
    assert deposit_token.balanceOf(bob) == 7 * 10**18


def test_withdraw(staker, alice, token_3eps, deposit_token, bob):
    staker.withdraw(alice, token_3eps, 10**18, {'from': alice})
    staker.withdraw(bob, token_3eps, 2 * 10**18, {'from': alice})
    staker.withdraw(bob, token_3eps, 3 * 10**18, {'from': bob})

    assert deposit_token.balanceOf(alice) == 10**18
    assert deposit_token.balanceOf(bob) == 2 * 10**18
    assert deposit_token.totalSupply() == 3 * 10**18


def test_transfer(deposit_token, alice, charlie, token_3eps, eps_staker, staker, proxy):
    deposit_token.transfer(charlie, 10**18, {'from': alice})

    assert deposit_token.balanceOf(alice) == 3 * 10**18
    assert deposit_token.balanceOf(charlie) == 10**18

    assert eps_staker.userInfo(token_3eps, proxy)['depositAmount'] == 9 * 10**18
    assert staker.totalBalances(token_3eps) == 9 * 10**18
    assert deposit_token.totalSupply() == 9 * 10**18

    assert staker.userBalances(alice, token_3eps) == 3 * 10**18
    assert staker.userBalances(charlie, token_3eps) == 10**18


def test_transferFrom(deposit_token, alice, bob, charlie, token_3eps, eps_staker, staker, proxy):
    deposit_token.approve(bob, 2**256-1, {'from': alice})
    deposit_token.transferFrom(alice, charlie, 10**18, {'from': bob})

    assert deposit_token.balanceOf(alice) == 3 * 10**18
    assert deposit_token.balanceOf(bob) == 5 * 10**18
    assert deposit_token.balanceOf(charlie) == 10**18

    assert eps_staker.userInfo(token_3eps, proxy)['depositAmount'] == 9 * 10**18
    assert staker.totalBalances(token_3eps) == 9 * 10**18
    assert deposit_token.totalSupply() == 9 * 10**18

    assert staker.userBalances(alice, token_3eps) == 3 * 10**18
    assert staker.userBalances(bob, token_3eps) == 5 * 10**18
    assert staker.userBalances(charlie, token_3eps) == 10**18


def test_transfer_zero(deposit_token, alice, charlie):
    deposit_token.transfer(charlie, 0, {'from': alice})

    assert deposit_token.balanceOf(alice) == 4 * 10**18
    assert deposit_token.balanceOf(charlie) == 0
    assert deposit_token.totalSupply() == 9 * 10**18


def test_insufficient_balance(deposit_token, alice, charlie):
    with brownie.reverts("Insufficient balance"):
        deposit_token.transfer(charlie, 4 * 10**18 + 1, {'from': alice})

    deposit_token.transfer(charlie, 4 * 10**18, {'from': alice})


def test_transferDeposit_guarded(staker, alice, bob, token_3eps):
    with brownie.reverts("Unauthorized caller"):
        staker.transferDeposit(token_3eps, alice, bob, 10**18, {'from': alice})
