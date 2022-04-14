import brownie
from brownie import ZERO_ADDRESS, chain


def test_already_set(proxy, deployer, depx, staker, bonded_distro, voter):
    with brownie.reverts("Already set"):
        proxy.setAddresses(depx, staker, bonded_distro, voter, deployer, {'from': deployer})


def test_set_pending(proxy, deployer, accounts, depx, staker, bonded_distro, voter):
    tx = proxy.setPendingAddresses(accounts[0], accounts[1], accounts[2], accounts[3], {'from': deployer})

    assert proxy.dEPX() == depx
    assert proxy.lpDepositor() == staker
    assert proxy.bondedDistributor() == bonded_distro
    assert proxy.dddVoter() == voter

    assert proxy.pendingdEPX() == accounts[0]
    assert proxy.pendingLpDepositor() == accounts[1]
    assert proxy.pendingBondedDistributor() == accounts[2]
    assert proxy.pendingDddVoter() == accounts[3]
    assert proxy.newAddressDeadline() == tx.timestamp + 86400 * 7


def test_apply_pending(proxy, deployer, accounts):
    tx = proxy.setPendingAddresses(accounts[0], accounts[1], accounts[2], accounts[3], {'from': deployer})
    chain.sleep(86400 * 7 + 1)
    proxy.applyPendingAddresses({'from': deployer})

    assert proxy.dEPX() == accounts[0]
    assert proxy.lpDepositor() == accounts[1]
    assert proxy.bondedDistributor() == accounts[2]
    assert proxy.dddVoter() == accounts[3]

    assert proxy.pendingdEPX() == ZERO_ADDRESS
    assert proxy.pendingLpDepositor() == ZERO_ADDRESS
    assert proxy.pendingBondedDistributor() == ZERO_ADDRESS
    assert proxy.pendingDddVoter() == ZERO_ADDRESS
    assert proxy.newAddressDeadline() == 0


def test_reject(proxy, deployer, accounts, depx, staker, bonded_distro, voter):
    proxy.setPendingAddresses(accounts[0], accounts[1], accounts[2], accounts[3], {'from': deployer})
    proxy.rejectPendingAddresses({'from': deployer})

    assert proxy.dEPX() == depx
    assert proxy.lpDepositor() == staker
    assert proxy.bondedDistributor() == bonded_distro
    assert proxy.dddVoter() == voter

    assert proxy.pendingdEPX() == ZERO_ADDRESS
    assert proxy.pendingLpDepositor() == ZERO_ADDRESS
    assert proxy.pendingBondedDistributor() == ZERO_ADDRESS
    assert proxy.pendingDddVoter() == ZERO_ADDRESS
    assert proxy.newAddressDeadline() == 0


def test_time_delay(proxy, deployer, accounts):
    tx = proxy.setPendingAddresses(accounts[0], accounts[1], accounts[2], accounts[3], {'from': deployer})
    chain.sleep(86400 * 7 - 100)
    with brownie.reverts():
        proxy.applyPendingAddresses({'from': deployer})

    chain.sleep(101)
    proxy.applyPendingAddresses({'from': deployer})


def test_only_owner(proxy, deployer, accounts, alice):
    with brownie.reverts():
        proxy.setPendingAddresses(accounts[0], accounts[1], accounts[2], accounts[3], {'from': alice})

    proxy.setPendingAddresses(accounts[0], accounts[1], accounts[2], accounts[3], {'from': deployer})
    chain.sleep(86400 * 7 + 1)

    with brownie.reverts():
        proxy.applyPendingAddresses({'from': alice})

    with brownie.reverts():
        proxy.rejectPendingAddresses({'from': alice})
