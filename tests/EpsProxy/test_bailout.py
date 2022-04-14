import brownie
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, token_3eps, alice, bob, charlie, staker):
    token_3eps.mint(alice, 4 * 10**18, {'from': token_3eps.minter()})
    token_3eps.approve(staker, 2**256-1, {'from': alice})
    staker.deposit(bob, token_3eps, 10**18, {'from': alice})
    staker.deposit(charlie, token_3eps, 2 * 10**18, {'from': alice})


@pytest.fixture(scope="module", autouse=True)
def deposit_token(setup, DepositToken, staker, token_3eps):
    return DepositToken.at(staker.depositTokens(token_3eps))


def test_bailout(EmergencyBailout, staker, alice, charlie, token_3eps, bob, proxy, deployer):
    proxy.emergencyWithdraw(token_3eps, {'from': deployer})

    bailout = EmergencyBailout.at(proxy.emergencyBailout(staker, token_3eps))

    assert token_3eps.balanceOf(bailout) == 3 * 10**18

    bailout.withdraw(alice, {'from': alice})
    bailout.withdraw(bob, {'from': bob})
    bailout.withdraw(charlie, {'from': alice})

    assert token_3eps.balanceOf(alice) == 10**18
    assert token_3eps.balanceOf(bob) == 10**18
    assert token_3eps.balanceOf(charlie) == 2 * 10**18


def test_lp_depositor_reverts(staker, alice, token_3eps, bob, proxy, deployer, deposit_token):
    proxy.emergencyWithdraw(token_3eps, {'from': deployer})

    with brownie.reverts("Emergency bailout"):
        staker.deposit(alice, token_3eps, 10**18, {'from': alice})

    with brownie.reverts("Emergency bailout"):
        staker.withdraw(bob, token_3eps, 10**18, {'from': bob})

    with brownie.reverts("Emergency bailout"):
        deposit_token.transfer(alice, 10**18, {'from': bob})

    with brownie.reverts("Emergency bailout"):
        staker.claim(bob, [token_3eps], 0, {'from': bob})


def test_cannot_bailout_twice(token_3eps, proxy, deployer):
    proxy.emergencyWithdraw(token_3eps, {'from': deployer})

    with brownie.reverts("Already initiated"):
        proxy.emergencyWithdraw(token_3eps, {'from': deployer})


def test_only_owner(token_3eps, proxy, alice, deployer):
    with brownie.reverts():
        proxy.emergencyWithdraw(token_3eps, {'from': alice})

    proxy.transferEmergencyAdmin(alice, {'from': deployer})

    with brownie.reverts():
        proxy.emergencyWithdraw(token_3eps, {'from': deployer})

    proxy.emergencyWithdraw(token_3eps, {'from': alice})


def test_set_emergency_admin(proxy, deployer, alice, bob):
    assert proxy.emergencyAdmin() == deployer
    proxy.transferEmergencyAdmin(alice, {'from': deployer})
    assert proxy.emergencyAdmin() == alice

    with brownie.reverts():
        proxy.transferEmergencyAdmin(bob, {'from': bob})
