import brownie
import pytest
from brownie import chain


@pytest.fixture(scope="module", autouse=True)
def setup(dotdot_setup, ddd, wbnb, ddd_pool, alice, staker, ddd_lp_staker):
    ddd.mint(ddd_pool, 10**19, {'from': staker})
    wbnb.deposit({'from': alice, 'value': "10 ether"})
    wbnb.transfer(ddd_pool, 10**19, {'from': alice})
    ddd_pool.mint(alice, {'from': alice})
    ddd_pool.approve(ddd_lp_staker, 2**256-1, {'from': alice})


@pytest.fixture(scope="module")
def treasury(ddd):
    return ddd


def test_initial_mint(ddd_lp_staker, ddd, staker, alice):
    assert ddd.balanceOf(ddd_lp_staker) == 0
    assert ddd_lp_staker.rewardRate() == 0
    assert ddd_lp_staker.startTime() == 0
    assert ddd_lp_staker.depositFee() == 200
    assert not ddd_lp_staker.initialMintCompleted()

    tx = ddd_lp_staker.deposit(alice, 10**18, False, {'from': alice})
    assert ddd.balanceOf(ddd_lp_staker) == 0
    assert ddd_lp_staker.rewardRate() == 0
    assert ddd_lp_staker.startTime() == tx.timestamp
    assert ddd_lp_staker.depositFee() == 200
    assert not ddd_lp_staker.initialMintCompleted()

    chain.sleep(ddd_lp_staker.INITIAL_DEPOSIT_GRACE_PERIOD() - 100)
    ddd_lp_staker.deposit(alice, 10**18, False, {'from': alice})
    assert ddd.balanceOf(ddd_lp_staker) == 0
    assert ddd_lp_staker.rewardRate() == 0
    assert ddd_lp_staker.startTime() == tx.timestamp
    assert ddd_lp_staker.depositFee() == 200
    assert not ddd_lp_staker.initialMintCompleted()

    chain.sleep(110)
    ddd_lp_staker.deposit(alice, 10**18, False, {'from': alice})
    assert ddd.balanceOf(ddd_lp_staker) == ddd_lp_staker.INITIAL_DDD_MINT_AMOUNT()
    assert ddd_lp_staker.rewardRate() == ddd_lp_staker.INITIAL_DDD_MINT_AMOUNT() // 604800
    assert ddd_lp_staker.startTime() == tx.timestamp
    assert ddd_lp_staker.depositFee() == 200
    assert ddd_lp_staker.initialMintCompleted()


def test_deposit(ddd_pool, alice, ddd_lp_staker, treasury):
    initial = ddd_pool.balanceOf(alice)
    ddd_lp_staker.deposit(alice, 10**18, False, {'from': alice})
    assert ddd_pool.balanceOf(alice) == initial - 10**18
    assert ddd_pool.balanceOf(ddd_lp_staker) == ddd_lp_staker.balanceOf(alice) == 10**18 * 0.98
    assert ddd_pool.balanceOf(treasury) == 10**18 * 0.02


def test_deposit_fee_decreases(ddd_pool, alice, ddd_lp_staker, treasury):
    fee = ddd_lp_staker.depositFee()
    while fee > 0:
        initial_alice = ddd_pool.balanceOf(alice)
        initial_deposit = ddd_lp_staker.balanceOf(alice)
        initial_treasury = ddd_pool.balanceOf(treasury)

        ddd_lp_staker.deposit(alice, 1000000, False, {'from': alice})

        assert ddd_pool.balanceOf(alice) == initial_alice - 1000000
        assert ddd_pool.balanceOf(ddd_lp_staker) == ddd_lp_staker.balanceOf(alice) == initial_deposit + 1000000 * ((10000 - fee) / 10000)
        assert ddd_pool.balanceOf(treasury) == initial_treasury + 1000000 * (fee / 10000)

        chain.mine(timedelta=86400 * 7 * 8 + 10)
        assert ddd_lp_staker.depositFee() < fee
        fee = ddd_lp_staker.depositFee()


def test_deposit_with_claim(ddd, alice, ddd_lp_staker):
    ddd_lp_staker.deposit(alice, 10**18, True, {'from': alice})
    assert ddd.balanceOf(alice) == 0
    chain.sleep(ddd_lp_staker.INITIAL_DEPOSIT_GRACE_PERIOD() + 1)
    ddd_lp_staker.deposit(alice, 10**18, True, {'from': alice})

    chain.mine(timedelta=604801)
    expected = ddd_lp_staker.claimable(alice)
    ddd_lp_staker.deposit(alice, 10**18, True, {'from': alice})
    assert ddd.balanceOf(alice) == expected > 0


def test_withdraw_with_claim(ddd, alice, ddd_lp_staker):
    ddd_lp_staker.deposit(alice, 10**18, True, {'from': alice})
    chain.sleep(ddd_lp_staker.INITIAL_DEPOSIT_GRACE_PERIOD() + 1)
    ddd_lp_staker.deposit(alice, 10**18, True, {'from': alice})

    chain.mine(timedelta=604801)
    expected = ddd_lp_staker.claimable(alice)
    ddd_lp_staker.withdraw(alice, 10**17, True, {'from': alice})
    assert ddd.balanceOf(alice) == expected > 0


def test_claim(ddd, alice, ddd_lp_staker):
    ddd_lp_staker.deposit(alice, 10**18, True, {'from': alice})
    chain.sleep(ddd_lp_staker.INITIAL_DEPOSIT_GRACE_PERIOD() + 1)
    ddd_lp_staker.deposit(alice, 10**18, True, {'from': alice})

    chain.mine(timedelta=604801)
    expected = ddd_lp_staker.claimable(alice)
    ddd_lp_staker.claim(alice, {'from': alice})
    assert ddd.balanceOf(alice) == expected

    chain.mine(timedelta=86400)
    assert ddd_lp_staker.claimable(alice) == 0
    ddd_lp_staker.claim(alice, {'from': alice})
    assert ddd.balanceOf(alice) == expected


def test_deposit_exceeds_balance(ddd_pool, alice, ddd_lp_staker):
    initial = ddd_pool.balanceOf(alice)
    with brownie.reverts():
        ddd_lp_staker.deposit(alice, initial + 1, False, {'from': alice})

    ddd_lp_staker.deposit(alice, initial, False, {'from': alice})



def test_withdraw_exceeds_balance(alice, ddd_lp_staker):
    ddd_lp_staker.deposit(alice, 10**18, False, {'from': alice})

    amount = ddd_lp_staker.balanceOf(alice)

    with brownie.reverts():
        ddd_lp_staker.withdraw(alice, amount + 1, False, {'from': alice})

    ddd_lp_staker.withdraw(alice, amount, False, {'from': alice})


def test_userDeposits_deposit(alice, ddd_lp_staker):
    expected = []
    for i in range(1, 51):
        amount = i * 10000
        tx = ddd_lp_staker.deposit(alice, amount, False, {'from': alice})
        amount = amount * (10000 - ddd_lp_staker.depositFee()) // 10000
        timestamp = tx.timestamp // 86400 * 86400
        if expected and expected[-1][0] == timestamp:
            expected[-1][1] += amount
        else:
            expected.append([timestamp, amount])
        chain.sleep(10000 * i)

    assert ddd_lp_staker.userDeposits(alice) == expected


def test_userDeposits_withdraw_exact(alice, ddd_lp_staker, ddd_pool):
    expected = []
    for i in range(1, 51):
        amount = i * 10000
        tx = ddd_lp_staker.deposit(alice, amount, False, {'from': alice})
        amount = amount * (10000 - ddd_lp_staker.depositFee()) // 10000
        timestamp = tx.timestamp // 86400 * 86400
        if expected and expected[-1][0] == timestamp:
            expected[-1][1] += amount
        else:
            expected.append([timestamp, amount])
        chain.mine(timedelta=10000 * i)

    for timestamp, amount in expected:
        weeks = (chain.time() - timestamp) // 604800
        fee = 0
        if weeks < 8:
            fee = amount * (8 - weeks) // 100

        assert ddd_lp_staker.withdrawFeeOnAmount(alice, amount) == fee

        initial = ddd_pool.balanceOf(alice)
        ddd_lp_staker.withdraw(alice, amount, False, {'from': alice})
        assert abs(ddd_pool.balanceOf(alice) - (initial + amount - fee)) < 2

    assert ddd_lp_staker.balanceOf(alice) == 0
    assert ddd_lp_staker.userDeposits(alice) == [[expected[-1][0], 0]]


def test_userDeposits_withdraw_partial(alice, ddd_lp_staker, ddd_pool):
    expected = []
    for i in range(1, 51):
        amount = i * 10000
        tx = ddd_lp_staker.deposit(alice, amount, False, {'from': alice})
        amount = amount * (10000 - ddd_lp_staker.depositFee()) // 10000
        timestamp = tx.timestamp // 86400 * 86400
        if expected and expected[-1][0] == timestamp:
            expected[-1][1] += amount
        else:
            expected.append([timestamp, amount])
        chain.mine(timedelta=10000 * i)

    total = ddd_lp_staker.balanceOf(alice)

    expected = expected[::-1]
    final_timestamp = expected[0][0]
    for i in range(10):
        remaining = total // 10
        fee = 0
        while remaining:
            if expected[-1][1] > remaining:
                expected[-1][1] -= remaining
                amount = remaining
                weeks = (chain.time() - expected[-1][0]) // 604800
            else:
                amount = expected[-1][1]
                weeks = (chain.time() - expected[-1][0]) // 604800
                del expected[-1]
            if weeks < 8:
                fee += amount * (8 - weeks) // 100
            remaining -= amount

        assert abs(ddd_lp_staker.withdrawFeeOnAmount(alice, total // 10) - fee) < 5

        initial = ddd_pool.balanceOf(alice)
        ddd_lp_staker.withdraw(alice, total // 10, False, {'from': alice})
        assert abs(ddd_pool.balanceOf(alice) - (initial + total // 10 - fee)) < 5

    assert ddd_lp_staker.balanceOf(alice) == 0
    assert ddd_lp_staker.userDeposits(alice) == [[final_timestamp, 0]]



def test_userDeposits_withdraw_all(alice, ddd_lp_staker, ddd_pool):
    expected = []
    for i in range(1, 51):
        amount = i * 10000
        tx = ddd_lp_staker.deposit(alice, amount, False, {'from': alice})
        amount = amount * (10000 - ddd_lp_staker.depositFee()) // 10000
        timestamp = tx.timestamp // 86400 * 86400
        if expected and expected[-1][0] == timestamp:
            expected[-1][1] += amount
        else:
            expected.append([timestamp, amount])
        chain.mine(timedelta=10000 * i)

    total = sum(i[1] for i in expected)
    assert total == ddd_lp_staker.balanceOf(alice)

    fee = 0
    for timestamp, amount in expected:
        weeks = (chain.time() - timestamp) // 604800
        if weeks < 8:
            fee += amount * (8 - weeks) // 100

    assert ddd_lp_staker.withdrawFeeOnAmount(alice, total) == fee


    initial = ddd_pool.balanceOf(alice)
    ddd_lp_staker.withdraw(alice, total, False, {'from': alice})
    assert abs(ddd_pool.balanceOf(alice) - (initial + total - fee)) < 5

    assert ddd_lp_staker.balanceOf(alice) == 0
    assert ddd_lp_staker.userDeposits(alice) == [[expected[-1][0], 0]]
