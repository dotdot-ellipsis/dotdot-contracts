from brownie import accounts, Contract, ZERO_ADDRESS
from brownie import (
    BondedFeeDistributor,
    CoreMinter,
    DddIncentiveDistributor,
    DddLpStaker,
    DotDot,
    DepositToken,
    DotDotVoting,
    EllipsisProxy,
    EpxDepositIncentives,
    LockedEPX,
    LpDepositor,
    TokenLocker,
)

START_TIME = 0
MAX_LOCK_WEEKS = 16

DDD_EARN_RATIO = 20
DDD_LOCK_MULTIPLIER = 3
DDD_LP_PCT = 20
DDD_LP_INITIAL_MINT = 2_500_000
DDD_MINT_RATIO = 500
EARLY_DEPOSIT_CAP = 25_000_000_000 * 10**18  # 25 billion, equivalent to 284m EPS

CORE_MINT_PCT = 20
MAX_DAILY_MINT = 250_000
CORE_LOCK_WEEKS = 4
RECEIVERS = {
    # address : alloc point
    "": 0,
}


EPX_TOKEN = ""
EPS_FEE_DISTRIBUTOR = ""
EPS_LOCKER = ""
EPS_VOTER = ""
EPS_LP_STAKER = ""
EPS_V1_STAKER = "0x4076CC26EFeE47825917D0feC3A79d0bB9a6bB5c"


EPS_FACTORY = "0xf65BEd27e96a367c61e0E06C54e14B16b84a5870"
PANCAKE_FACTORY = "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73"
WBNB = "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c"


def main():
    deployer = accounts.add()

    bonded_distributor = BondedFeeDistributor.deploy(EPX_TOKEN, EPS_FEE_DISTRIBUTOR, {'from': deployer})
    ddd_distributor = DddIncentiveDistributor.deploy({'from': deployer})
    ddd_lp_staker = DddLpStaker.deploy({'from': deployer})
    token = DotDot.deploy({'from': deployer})

    deposit_token = DepositToken.deploy({'from': deployer})
    voter = DotDotVoting.deploy(EPS_VOTER, EPS_LOCKER, {'from': deployer})
    proxy = EllipsisProxy.deploy(EPX_TOKEN, EPS_LOCKER, EPS_LP_STAKER, EPS_FEE_DISTRIBUTOR, EPS_VOTER, {'from': deployer})
    early_incentives = EpxDepositIncentives.deploy(EPX_TOKEN, EPS_V1_STAKER, EARLY_DEPOSIT_CAP, DDD_MINT_RATIO, START_TIME, {'from': deployer})
    depx = LockedEPX.deploy(EPX_TOKEN, EPS_LOCKER, {'from': deployer})
    staker = LpDepositor.deploy(EPX_TOKEN, EPS_LP_STAKER, EPS_VOTER, DDD_EARN_RATIO, DDD_LOCK_MULTIPLIER, DDD_LP_PCT, DDD_LP_INITIAL_MINT, {'from': deployer})
    locker = TokenLocker.deploy(EPS_LOCKER, MAX_LOCK_WEEKS, {'from': deployer})

    receivers = list(RECEIVERS)
    alloc_point = [RECEIVERS[i] for i in receivers]
    core_minter = CoreMinter.deploy(CORE_MINT_PCT, MAX_DAILY_MINT, CORE_LOCK_WEEKS, receivers, alloc_point, {'from': deployer})

    # deploy dEPX/EPX Ellipsis pool
    factory = Contract(EPS_FACTORY)
    tx = factory.deploy_plain_pool("DotDot dEPX/EPX", "dEPX/EPX", [depx, EPX_TOKEN, ZERO_ADDRESS, ZERO_ADDRESS], 50, 4000000, 3, 3, {'from': deployer})
    depx_pool = tx.events['PlainPoolDeployed']['lp_token']

    # deploy DDD/WBNB pancake pool
    factory = Contract(PANCAKE_FACTORY)
    factory.createPair(token, WBNB, {'from': deployer})
    ddd_pool = factory.getPair(token, WBNB)
    assert ddd_pool != ZERO_ADDRESS

    token.setMinters([staker, early_incentives, core_minter], {'from': deployer})

    bonded_distributor.setAddresses(depx, token, staker, proxy, {'from': deployer})
    core_minter.setAddresses(token, locker, {'from': deployer})
    ddd_distributor.setAddresses(locker, voter, {'from': deployer})
    ddd_lp_staker.setAddresses(ddd_pool, staker, token, {'from': deployer})
    voter.setAddresses(locker, depx_pool, proxy, {'from': deployer})
    proxy.setAddresses(depx, staker, bonded_distributor, voter, {'from': deployer})
    early_incentives.setAddresses(depx, bonded_distributor, locker, {'from': deployer})
    depx.setAddresses(bonded_distributor, proxy, {'from': deployer})
    staker.setAddresses(token, depx, proxy, bonded_distributor, ddd_distributor, ddd_lp_staker, deposit_token, depx_pool, {'from': deployer})
    locker.setAddresses(token, {'from': deployer})
