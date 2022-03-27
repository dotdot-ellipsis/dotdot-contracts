pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./dependencies/SafeERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/dotdot/IEpsProxy.sol";
import "./interfaces/dotdot/IDepositToken.sol";
import "./interfaces/dotdot/IDddToken.sol";
import "./interfaces/dotdot/ILockedEPX.sol";
import "./interfaces/dotdot/IBondedFeeDistributor.sol";
import "./interfaces/dotdot/IDddIncentiveDistributor.sol";
import "./interfaces/ellipsis/ILpStaker.sol";
import "./interfaces/ellipsis/IRewardsToken.sol";


contract LpDepositor is Ownable {
    using SafeERC20 for IERC20;

    struct Amounts {
        uint256 epx;
        uint256 ddd;
    }
    struct ExtraReward {
        address token;
        uint256 amount;
    }

    IERC20 public immutable EPX;
    IEllipsisLpStaking public immutable lpStaker;

    IDddToken public DDD;
    ILockedEPX public dEPX;
    IBondedFeeDistributor public bondedDistributor;
    IDddIncentiveDistributor public dddIncentiveDistributor;
    IEllipsisProxy public proxy;
    address public depositTokenImplementation;
    address public fixedVoteLpToken;

    // number of EPX an LP must earn via the protocol in order to receive 1 DDD
    uint256 public immutable DDD_EARN_RATIO;
    // DDD multiplier if LP locks entire earned EPX balance at time of claim
    uint256 public immutable DDD_LOCK_MULTIPLIER;

    uint256 public pendingBonderFee;
    uint256 public lastBonderFeeTransfer;

    // user -> pool -> deposit amount
    mapping(address => mapping(address => uint256)) public userBalances;
    // pool -> total deposit amount
    mapping(address => uint256) public totalBalances;
    // pool -> integrals
    mapping(address => Amounts) public rewardIntegral;
    // user -> pool -> integrals
    mapping(address => mapping(address => Amounts)) public rewardIntegralFor;
    // user -> pool -> claimable
    mapping(address => mapping(address => Amounts)) unclaimedRewards;
    // pool -> DDD deposit token
    mapping(address => address) public depositTokens;

    // pool -> third party rewards
    mapping(address => address[]) public extraRewards;
    // pool -> third party reward integrals
    mapping(address => uint256[]) extraRewardIntegral;
    // user -> pool -> third party reward integrals
    mapping(address => mapping(address => uint256[])) public extraRewardIntegralFor;
    // user -> pool -> unclaimed reward balances
    mapping(address => mapping(address => uint256[])) public unclaimedExtraRewards;

    constructor(
        IERC20 _EPX,
        IEllipsisLpStaking _lpStaker,
        uint256 _dddEarnRatio,
        uint256 _dddLockMultiplier
    ) {
        EPX = _EPX;
        lpStaker = _lpStaker;
        DDD_EARN_RATIO = _dddEarnRatio;
        DDD_LOCK_MULTIPLIER = _dddLockMultiplier;
    }

    function setAddresses(
        IDddToken _DDD,
        ILockedEPX _dEPX,
        IEllipsisProxy _proxy,
        IBondedFeeDistributor _bondedDistributor,
        IDddIncentiveDistributor _dddIncentiveDistributor,
        address _depositTokenImplementation,
        address _fixedVoteLpToken
    ) external onlyOwner {
        DDD = _DDD;
        dEPX = _dEPX;
        proxy = _proxy;

        bondedDistributor = _bondedDistributor;
        dddIncentiveDistributor = _dddIncentiveDistributor;
        depositTokenImplementation = _depositTokenImplementation;
        fixedVoteLpToken = _fixedVoteLpToken;

        EPX.approve(address(_dEPX), type(uint256).max);
        _dEPX.approve(address(_dddIncentiveDistributor), type(uint256).max);

        renounceOwnership();
    }

    function claimable(address _user, address[] calldata _tokens) external view returns (Amounts[] memory) {
        Amounts[] memory pending = new Amounts[](_tokens.length);
        uint256[] memory totalClaimable = lpStaker.claimableReward(_user, _tokens);
        for (uint i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            pending[i] = unclaimedRewards[_user][token];
            uint256 balance = userBalances[_user][token];
            if (balance == 0) continue;

            Amounts memory integral = rewardIntegral[token];
            uint256 total = totalBalances[token];
            if (total > 0) {
                uint256 reward = totalClaimable[i];
                reward -= reward * 15 / 100;
                integral.epx += 1e18 * reward / total;
                integral.ddd += 1e18 * (reward / DDD_EARN_RATIO) / total;
            }

            Amounts storage integralFor = rewardIntegralFor[_user][token];
            if (integralFor.epx < integral.epx) {
                pending[i].epx += balance * (integral.epx - integralFor.epx) / 1e18;
                pending[i].ddd += balance * (integral.ddd - integralFor.ddd) / 1e18;
            }
        }
    }

    function claimableExtraRewards(address user, address pool) external view returns (ExtraReward[] memory) {
        uint256 length = extraRewards[pool].length;
        uint256 total = totalBalances[pool];
        uint256 balance = userBalances[user][pool];
        ExtraReward[] memory rewards = new ExtraReward[](length);
        for (uint i = 0; i < length; i++) {
            address token = extraRewards[pool][i];
            uint256 amount = unclaimedExtraRewards[user][pool][i];
            if (balance > 0) {
                uint256 earned = IRewardsToken(token).earned(address(proxy), token);
                uint256 integral = extraRewardIntegral[pool][i] + 1e18 * earned;
                uint256 integralFor = extraRewardIntegralFor[user][pool][i];
                amount += balance * (integral - integralFor) / 1e18;
            }
            rewards[i] = ExtraReward({token: token, amount: amount});
        }
        return rewards;
    }

    function deposit(address _user, address _token, uint256 _amount) external {
        IERC20(_token).safeTransferFrom(msg.sender, address(proxy), _amount);

        uint256 balance = userBalances[_user][_token];
        uint256 total = totalBalances[_token];

        uint256 reward = proxy.deposit(_token, _amount);
        _updateIntegrals(_user, _token, balance, total, reward);

        userBalances[_user][_token] = balance + _amount;
        totalBalances[_token] += total + _amount;

        address depositToken = depositTokens[_token];
        if (depositToken == address(0)) {
            depositToken = _deployDepositToken(_token);
        }
        IDepositToken(depositToken).mint(_user, _amount);
    }

    function withdraw(address _receiver, address _token, uint256 _amount) external {
        uint256 balance = userBalances[msg.sender][_token];
        uint256 total = totalBalances[_token];

        userBalances[msg.sender][_token] = balance - _amount;
        totalBalances[_token] = total - _amount;

        address depositToken = depositTokens[_token];
        IDepositToken(depositToken).burn(msg.sender, _amount);

        uint256 reward = proxy.withdraw(_receiver, _token, _amount);
        _updateIntegrals(msg.sender, _token, balance, total, reward);
    }

    /**
        @notice Claim pending EPX and DDD rewards
        @param _user User to claim for
        @param _tokens List of LP tokens to claim for
        @param _maxBondAmount Maximum amount of claimed EPX to convert to bonded dEPX.
                              Converting to bonded dEPX earns a multiplier on DDD rewards.
     */
    function claim(address _user, address[] calldata _tokens, uint256 _maxBondAmount) external {
        Amounts memory claims;
        uint256 balance = EPX.balanceOf(address(this));
        for (uint i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint256 reward = proxy.claimEmissions(token);
            _updateIntegrals(_user, token, userBalances[_user][token], totalBalances[token], reward);
            claims.epx += unclaimedRewards[_user][token].epx;
            claims.ddd += unclaimedRewards[_user][token].ddd;
            delete unclaimedRewards[_user][token];
        }
        if (_maxBondAmount > 0) {
            // deposit and bond the claimable EPX, up to `_maxBondAmount`
            uint256 bondAmount = _maxBondAmount > claims.epx ? claims.epx : _maxBondAmount;
            dEPX.deposit(_user, bondAmount, true);
            // apply `DDD_LOCK_MULTIPLIER` to earned DDD, porportional to bonded EPX amount
            uint256 dddBonusBase = claims.ddd * bondAmount / claims.epx;
            claims.ddd = dddBonusBase * DDD_LOCK_MULTIPLIER + (claims.ddd - dddBonusBase);
            claims.epx -= bondAmount;
        }
        if (claims.epx > 0) {
            EPX.safeTransfer(_user, claims.epx);
        }
        if (claims.ddd > 0) {
            DDD.mint(_user, claims.ddd);
        }
    }

    /**
        @notice Claim all third-party incentives earned by `user` from `pool`
     */
    function claimExtraRewards(address user, address pool) external {
        uint256 total = totalBalances[pool];
        uint256 balance = userBalances[user][pool];
        if (total > 0) _updateExtraIntegrals(user, pool, balance, total);
        uint256 length = extraRewards[pool].length;
        for (uint i = 0; i < length; i++) {
            uint256 amount = unclaimedExtraRewards[user][pool][i];
            if (amount > 0) {
                unclaimedExtraRewards[user][pool][i] = 0;
                IERC20(extraRewards[pool][i]).safeTransfer(user, amount);
            }
        }
    }

    /**
        @notice Update the local cache of third-party rewards for a given LP token
        @dev Must be called each time a new incentive token is added to a pool, in
             order for the protocol to begin distributing that token.
     */
    function updatePoolExtraRewards(address pool) external {
        uint256 count = IRewardsToken(pool).rewardCount();
        address[] storage rewards = extraRewards[pool];
        for (uint256 i = rewards.length; i < count; i ++) {
            rewards.push(IRewardsToken(pool).rewardTokens(i));
        }
    }

    function transferDeposit(address _token, address _from, address _to, uint256 _amount) external returns (bool) {
        require(msg.sender == depositTokens[_token], "Unauthorized caller");
        require(_amount > 0, "Cannot transfer zero");

        uint256 total = totalBalances[_token];
        uint256 balance = userBalances[_from][_token];
        require(balance >= _amount, "Insufficient balance");


        uint256 reward = proxy.claimEmissions(_token);
        _updateIntegrals(_from, _token, balance, total, reward);
        userBalances[_from][_token] = balance - _amount;

        balance = userBalances[_to][_token];
        _updateIntegrals(_to, _token, balance, total - _amount, 0);
        userBalances[_to][_token] = balance + _amount;
        // emit TransferDeposit(_token, _from, _to, _amount);  TODO
        return true;
    }

    function _deployDepositToken(address pool) internal returns (address token) {
        // taken from https://solidity-by-example.org/app/minimal-proxy/
        bytes20 targetBytes = bytes20(depositTokenImplementation);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            token := create(0, clone, 0x37)
        }
        IDepositToken(token).initialize(pool);
        return token;
    }

    function _updateIntegrals(
        address user,
        address pool,
        uint256 balance,
        uint256 total,
        uint256 reward
    ) internal {
        Amounts memory integral = rewardIntegral[pool];
        if (reward > 0) {
            uint256 fee = reward * 15 / 100;
            reward -= fee;
            pendingBonderFee += fee;

            integral.epx += 1e18 * reward / total;
            integral.ddd += 1e18 * (reward / DDD_EARN_RATIO) / total;
            rewardIntegral[pool] = integral;
        }
        Amounts memory integralFor = rewardIntegralFor[user][pool];
        if (integralFor.epx < integral.epx) {
            Amounts storage claims = unclaimedRewards[user][pool];
            claims.epx += balance * (integral.epx - integralFor.epx) / 1e18;
            claims.ddd += balance * (integral.ddd - integralFor.ddd) / 1e18;
            rewardIntegralFor[user][pool] = integral;
        }

        if (total > 0 && extraRewards[pool].length > 0) {
            // if this token receives 3rd-party incentives, claim and update integrals
            _updateExtraIntegrals(user, pool, balance, total);
        } else if (lastBonderFeeTransfer + 86400 < block.timestamp) {
            // once a day, transfer pending rewards to dEPX bonders and DDD lockers
            // we only do this on updates to pools without extra incentives because each
            // operation can be gas intensive
            lastBonderFeeTransfer = block.timestamp;
            uint256 pending = pendingBonderFee;
            if (pending > 0) {
                pendingBonderFee = 0;
                // 2/3 of EPX and all DDD given to dEPX bonders
                EPX.safeTransfer(address(bondedDistributor), pending / 3 * 2);
                DDD.mint(address(bondedDistributor), pending / DDD_EARN_RATIO);
                bondedDistributor.notifyFeeAmounts(pending / 3 * 2, pending / DDD_EARN_RATIO);
                // 1/3 of EPX is converted to dEPX
                dEPX.deposit(address(this), pending / 3, false);
                // 1/2 of dEPX given to DDD lockers
                dddIncentiveDistributor.depositIncentive(address(0), address(dEPX), pending / 6);
                // 1/2 of dEPX as a bribe for the EPX/dEPX pool
                dddIncentiveDistributor.depositIncentive(fixedVoteLpToken, address(dEPX), pending / 6);
            }
        }
    }

    function _updateExtraIntegrals(
        address user,
        address pool,
        uint256 balance,
        uint256 total
    ) internal {
        address[] memory rewards = extraRewards[pool];
        uint256[] memory balances = new uint256[](rewards.length);
        for (uint i = 0; i < rewards.length; i++) {
            balances[i] = IERC20(rewards[i]).balanceOf(address(this));
        }
        proxy.getReward(pool, rewards);
        for (uint i = 0; i < rewards.length; i++) {
            uint256 delta = IERC20(rewards[i]).balanceOf(address(this)) - balances[i];
            uint256 integral;
            if (delta > 0) {
                integral = extraRewardIntegral[pool][i] + 1e18 * delta / total;
                extraRewardIntegral[pool][i] = integral;
            }
            uint256 integralFor = extraRewardIntegralFor[user][pool][i];
            if (integralFor < integral) {
                unclaimedExtraRewards[user][pool][i] += balance * (integral - integralFor) / 1e18;
                extraRewardIntegralFor[user][pool][i] = integralFor;
            }
        }
    }

}