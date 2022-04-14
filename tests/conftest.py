from brownie import Contract, project, chain, ZERO_ADDRESS, interface
from brownie_tokens import ERC20
import pytest


START_TIME = 1649289600
MAX_LOCK_WEEKS = 16

DDD_EARN_RATIO = 20
DDD_LOCK_MULTIPLIER = 3
DDD_LP_PCT = 20
DDD_LP_INITIAL_MINT = 2_500_000 * 10**18
INITIAL_DEPOSIT_GRACE_PERIOD = 3600 * 6
DDD_MINT_RATIO = 500
EARLY_DEPOSIT_CAP = 25_000_000_000 * 10**18  # 25 billion, equivalent to 284m EPS

CORE_MINT_PCT = 20
MAX_DAILY_MINT = 250_000 * 10**18
CORE_LOCK_WEEKS = 4
RECEIVERS = {
    # address : alloc point
    "": 0,
}


@pytest.fixture(autouse=True)
def isolation_setup(dotdot_setup, fn_isolation):
    chain.snapshot()


@pytest.fixture(scope="module")
def ellipsis_setup(eps_voter, factory, epx, eps_locker, eps_staker, eps_fee_distro, token_3eps, token_abnb, eps_admin):
    eps_voter.setLpStaking(eps_staker, [token_3eps, token_abnb], {'from': eps_admin})
    factory.set_fee_receiver(eps_fee_distro, {'from': eps_admin})
    epx.addMinter(eps_staker, {'from': epx.owner()})
    token_abnb.setDepositContract(eps_staker, True, {'from': eps_admin})


@pytest.fixture(scope="module")
def dotdot_setup(ellipsis_setup, EmergencyBailout, DepositToken, bonded_distro, core_incentives, ddd_distro, ddd_lp_staker, ddd, voter, proxy, early_incentives, depx, staker, locker, ddd_pool, depx_pool, deployer):
    ddd.setMinters([staker, early_incentives, core_incentives, ddd_lp_staker], {'from': deployer})

    bonded_distro.setAddresses(depx, ddd, staker, proxy, {'from': deployer})
    core_incentives.setAddresses(ddd, locker, {'from': deployer})
    ddd_distro.setAddresses(locker, voter, {'from': deployer})
    ddd_lp_staker.setAddresses(ddd_pool, ddd, staker, ddd, {'from': deployer})
    voter.setAddresses(locker, depx_pool, proxy, {'from': deployer})

    bailout = EmergencyBailout.deploy({'from': deployer})
    proxy.setAddresses(depx, staker, bonded_distro, voter, bailout, {'from': deployer})
    early_incentives.setAddresses(depx, ddd, bonded_distro, locker, {'from': deployer})
    depx.setAddresses(bonded_distro, proxy, {'from': deployer})
    deposit_token = DepositToken.deploy({'from': deployer})
    staker.setAddresses(ddd, depx, proxy, bonded_distro, ddd_distro, ddd_lp_staker, deposit_token, depx_pool, {'from': deployer})
    locker.setAddresses(ddd, {'from': deployer})


@pytest.fixture(scope="session")
def wbnb():
    return Contract('0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c')


# account helpers

@pytest.fixture(scope="session")
def eps_admin(factory):
    return factory.admin()


@pytest.fixture(scope="session")
def locker1(accounts):
    return accounts.at('0xb01ea75e8eed3a073b39567c8e9b2c392b273531', True)


@pytest.fixture(scope="session")
def locker2(accounts):
    return accounts.at('0x5e2859ebd3ca946e5c4eb86dcc7b6501a2b52aba', True)


@pytest.fixture(scope="session")
def deployer(accounts):
    return accounts[0]

@pytest.fixture(scope="session")
def alice(accounts):
    return accounts[1]


@pytest.fixture(scope="session")
def bob(accounts):
    return accounts[2]


@pytest.fixture(scope="session")
def charlie(accounts):
    return accounts[3]


@pytest.fixture(scope="session")
def core_receivers(accounts):
    return accounts[4:8]


# Ellipsis core/factory deployments

@pytest.fixture(scope="session")
def factory():
    return Contract('0xf65BEd27e96a367c61e0E06C54e14B16b84a5870')


@pytest.fixture(scope="session")
def epsv1_staker():
    return Contract('0x4076CC26EFeE47825917D0feC3A79d0bB9a6bB5c')


@pytest.fixture(scope="session")
def swap_3eps():
    return Contract('0x160caed03795365f3a589f10c379ffa7d75d4e76')


@pytest.fixture(scope="session")
def token_3eps():
    return Contract('0xaF4dE8E872131AE328Ce21D909C74705d3Aaf452')


@pytest.fixture(scope="session")
def swap_abnb():
    return Contract('0xf0d17f404343D7Ba66076C818c9DC726650E2435')


@pytest.fixture(scope="session")
def token_abnb():
    return Contract('0xf71A0bCC3Ef8a8c5a28fc1BC245e394A8ce124ec')


@pytest.fixture(scope="session")
def token_ust():
    return Contract('0xD67625ad4104dA86c4D9CB054001E899B1b9061B')


# Ellipsis v1 deployments

@pytest.fixture(scope="session")
def Ellipsis():
    return project.load('ellipsis-finance/ellipsis-v2@1.0.0')


@pytest.fixture(scope="session")
def epx():
    return Contract('0xAf41054C1487b0e5E2B9250C0332eCBCe6CE9d71')


@pytest.fixture(scope="module")
def eps_locker(Ellipsis, epx, epsv1_staker, eps_admin):
    return Ellipsis.TokenLocker.deploy(epx, epsv1_staker, START_TIME, 52, 88, {'from': eps_admin})


@pytest.fixture(scope="module")
def eps_voter(Ellipsis, eps_locker, eps_admin):
    return Ellipsis.IncentiveVoting.deploy(eps_locker, 254629629629629629584, 30, 250_000_000 * 10 ** 18, {'from': eps_admin})


@pytest.fixture(scope="module")
def eps_fee_distro(Ellipsis, eps_locker, eps_admin):
    return Ellipsis.FeeDistributor.deploy(eps_locker, {'from': eps_admin})


@pytest.fixture(scope="module")
def eps_staker(Ellipsis, epx, eps_voter, eps_locker, eps_admin):
    return Ellipsis.EllipsisLpStaking.deploy(epx, eps_voter, eps_locker, 66000000000000000000000000000, {'from': eps_admin})


# DotDot deployments

@pytest.fixture(scope="module")
def bonded_distro(BondedFeeDistributor, epx, eps_fee_distro, deployer):
    return BondedFeeDistributor.deploy(epx, eps_fee_distro, {'from': deployer})


@pytest.fixture(scope="module")
def core_incentives(CoreMinter, deployer, core_receivers):
    return CoreMinter.deploy(CORE_MINT_PCT, MAX_DAILY_MINT, CORE_LOCK_WEEKS, core_receivers, [1, 2, 3, 4], {'from': deployer})


@pytest.fixture(scope="module")
def ddd_distro(DddIncentiveDistributor, eps_voter, deployer):
    return DddIncentiveDistributor.deploy(eps_voter, {'from': deployer})


@pytest.fixture(scope="module")
def ddd_lp_staker(DddLpStaker, deployer):
    return DddLpStaker.deploy(DDD_LP_INITIAL_MINT, INITIAL_DEPOSIT_GRACE_PERIOD, {'from': deployer})


@pytest.fixture(scope="module")
def ddd(DotDot, deployer):
    return DotDot.deploy({'from': deployer})


@pytest.fixture(scope="module")
def voter(DotDotVoting, eps_voter, eps_locker, deployer):
    return DotDotVoting.deploy(eps_voter, eps_locker, {'from': deployer})


@pytest.fixture(scope="module")
def proxy(EllipsisProxy, epx, eps_locker, eps_staker, eps_fee_distro, eps_voter, deployer):
    return EllipsisProxy.deploy(epx, eps_locker, eps_staker, eps_fee_distro, eps_voter, deployer, {'from': deployer})


@pytest.fixture(scope="module")
def early_incentives(EpxDepositIncentives, epx, epsv1_staker, deployer):
    return EpxDepositIncentives.deploy(epx, epsv1_staker, EARLY_DEPOSIT_CAP, DDD_MINT_RATIO, START_TIME, {'from': deployer})


@pytest.fixture(scope="module")
def depx(LockedEPX, epx, eps_locker, deployer):
    return LockedEPX.deploy(epx, eps_locker, {'from': deployer})


@pytest.fixture(scope="module")
def staker(LpDepositor, epx, eps_staker, eps_voter, deployer):
    return LpDepositor.deploy(epx, eps_staker, eps_voter, DDD_EARN_RATIO, DDD_LOCK_MULTIPLIER, DDD_LP_PCT, {'from': deployer})


@pytest.fixture(scope="module")
def locker(TokenLocker, eps_locker, deployer):
    return TokenLocker.deploy(eps_locker, MAX_LOCK_WEEKS, {'from': deployer})


@pytest.fixture(scope="module")
def depx_pool(factory, deployer, epx, depx):
    tx = factory.deploy_plain_pool("DotDot dEPX/EPX", "dEPX/EPX", [depx, epx, ZERO_ADDRESS, ZERO_ADDRESS], 50, 4000000, 3, 3, {'from': deployer})
    return tx.events['PlainPoolDeployed']['lp_token']


@pytest.fixture(scope="module")
def ddd_pool(ddd, wbnb, deployer):
    pancake = Contract('0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73')
    pancake.createPair(ddd, wbnb, {'from': deployer})
    pair = pancake.getPair(ddd, wbnb)
    return interface.IUniswapV2Pair(pair)


@pytest.fixture(scope="module")
def fee1():
    return ERC20()


@pytest.fixture(scope="module")
def fee2():
    return ERC20()


@pytest.fixture(scope="session")
def advance_week():
    def fn(weeks=1):
        target = (chain[-1].timestamp // 604800 + weeks) * 604800
        chain.mine(timestamp=target)

    return fn
