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
import "./interfaces/dotdot/IDddLpStaker.sol";
import "./interfaces/ellipsis/ILpStaker.sol";
import "./interfaces/ellipsis/IRewardsToken.sol";
import "./interfaces/ellipsis/IIncentiveVoting.sol";


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
    IIncentiveVoting public immutable epsVoter;

    IDddToken public DDD;
    ILockedEPX public dEPX;
    IBondedFeeDistributor public bondedDistributor;
    IDddIncentiveDistributor public dddIncentiveDistributor;
    IDddLpStaker public dddLpStaker;
    IEllipsisProxy public proxy;
    address public depositTokenImplementation;
    address public fixedVoteLpToken;

    // number of EPX an LP must earn via the protocol in order to receive 1 DDD
    uint256 public immutable DDD_EARN_RATIO;
    // DDD multiplier if LP locks entire earned EPX balance at time of claim
    uint256 public immutable DDD_LOCK_MULTIPLIER;
    // % of DDD minted for `dddLpStaker` relative to the amount earned by LPs
    uint256 public immutable DDD_LP_PERCENT;
    // one-time mint amount of DDD sent to `dddLpStaker`
    uint256 public immutable DDD_LP_INITIAL_MINT;

    uint256 public pendingBonderEpx;
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

    event Deposit(
        address indexed caller,
        address indexed receiver,
        address indexed token,
        uint256 amount
    );
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed token,
        uint256 amount
    );
    event ClaimedAndBonded(
        address indexed caller,
        address indexed receiver,
        uint256 bondAmount
    );
    event Claimed(
        address indexed caller,
        address indexed receiver,
        address[] tokens,
        uint256 epxAmount,
        uint256 dddAmount
    );
    event ClaimedExtraRewards(
        address indexed caller,
        address indexed receiver,
        address token
    );
    event ExtraRewardsUpdated(
        address indexed token,
        address[] rewards
    );
    event TransferDeposit(
        address indexed token,
        address indexed from,
        address indexed to,
        uint256 amount
    );

    constructor(
        IERC20 _EPX,
        IEllipsisLpStaking _lpStaker,
        IIncentiveVoting _epsVoter,
        uint256 _dddEarnRatio,
        uint256 _dddLockMultiplier,
        uint256 _dddLpPercent,
        uint256 _dddInitialMint
    ) {
        EPX = _EPX;
        lpStaker = _lpStaker;
        epsVoter = _epsVoter;
        DDD_EARN_RATIO = _dddEarnRatio;
        DDD_LOCK_MULTIPLIER = _dddLockMultiplier;
        DDD_LP_PERCENT = _dddLpPercent;
        DDD_LP_INITIAL_MINT = _dddInitialMint;
    }

    function setAddresses(
        IDddToken _DDD,
        ILockedEPX _dEPX,
        IEllipsisProxy _proxy,
        IBondedFeeDistributor _bondedDistributor,
        IDddIncentiveDistributor _dddIncentiveDistributor,
        IDddLpStaker _dddLpStaker,
        address _depositTokenImplementation,
        address _fixedVoteLpToken
    ) external onlyOwner {
        DDD = _DDD;
        dEPX = _dEPX;
        proxy = _proxy;

        bondedDistributor = _bondedDistributor;
        dddIncentiveDistributor = _dddIncentiveDistributor;
        dddLpStaker = _dddLpStaker;
        depositTokenImplementation = _depositTokenImplementation;
        fixedVoteLpToken = _fixedVoteLpToken;

        EPX.approve(address(_dEPX), type(uint256).max);
        _dEPX.approve(address(_dddIncentiveDistributor), type(uint256).max);
        _DDD.mint(address(dddLpStaker), DDD_LP_INITIAL_MINT);

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
        totalBalances[_token] = total + _amount;

        address depositToken = depositTokens[_token];
        if (depositToken == address(0)) {
            depositToken = _deployDepositToken(_token);
            depositTokens[_token] = depositToken;
        }
        IDepositToken(depositToken).mint(_user, _amount);
        emit Deposit(msg.sender, _user, _token, _amount);
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
        emit Withdraw(msg.sender, _receiver, _token, _amount);
    }

    /**
        @notice Claim pending EPX and DDD rewards
        @param _receiver Account to send claimed rewards to
        @param _tokens List of LP tokens to claim for
        @param _maxBondAmount Maximum amount of claimed EPX to convert to bonded dEPX.
                              Converting to bonded dEPX earns a multiplier on DDD rewards.
     */
    function claim(address _receiver, address[] calldata _tokens, uint256 _maxBondAmount) external {
        Amounts memory claims;
        uint256 balance = EPX.balanceOf(address(this));
        for (uint i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint256 reward = proxy.claimEmissions(token);
            _updateIntegrals(msg.sender, token, userBalances[msg.sender][token], totalBalances[token], reward);
            claims.epx += unclaimedRewards[msg.sender][token].epx;
            claims.ddd += unclaimedRewards[msg.sender][token].ddd;
            delete unclaimedRewards[msg.sender][token];
        }
        if (_maxBondAmount > 0) {
            // deposit and bond the claimable EPX, up to `_maxBondAmount`
            uint256 bondAmount = _maxBondAmount > claims.epx ? claims.epx : _maxBondAmount;
            dEPX.deposit(_receiver, bondAmount, true);
            emit ClaimedAndBonded(msg.sender, _receiver, bondAmount);
            // apply `DDD_LOCK_MULTIPLIER` to earned DDD, porportional to bonded EPX amount
            uint256 dddBonusBase = claims.ddd * bondAmount / claims.epx;
            claims.ddd = dddBonusBase * DDD_LOCK_MULTIPLIER + (claims.ddd - dddBonusBase);
            claims.epx -= bondAmount;
        }
        if (claims.epx > 0) {
            EPX.safeTransfer(_receiver, claims.epx);
        }
        if (claims.ddd > 0) {
            DDD.mint(_receiver, claims.ddd);
        }
        emit Claimed(msg.sender, _receiver, _tokens, claims.epx, claims.ddd);
    }

    /**
        @notice Claim all third-party incentives earned from `pool`
     */
    function claimExtraRewards(address _receiver, address pool) external {
        uint256 total = totalBalances[pool];
        uint256 balance = userBalances[msg.sender][pool];
        if (total > 0) _updateExtraIntegrals(msg.sender, pool, balance, total);
        uint256 length = extraRewards[msg.sender].length;
        for (uint i = 0; i < length; i++) {
            uint256 amount = unclaimedExtraRewards[msg.sender][pool][i];
            if (amount > 0) {
                unclaimedExtraRewards[msg.sender][pool][i] = 0;
                IERC20(extraRewards[pool][i]).safeTransfer(_receiver, amount);
            }
        }
        emit ClaimedExtraRewards(msg.sender, _receiver, pool);
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
        emit ExtraRewardsUpdated(pool, rewards);
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
        emit TransferDeposit(_token, _from, _to, _amount);
        return true;
    }

    /**
        @notice Transfer accrued EPX and DDD fees to dEPX bonders, DDD lockers and DDD Lp Stakers
        @dev Called once per day on normal interactions with the contract. With normal protocol
             use it should not be a requirement to explicitly call this function.
     */
    function pushPendingProtocolFees() public {
        lastBonderFeeTransfer = block.timestamp;
        uint256 pendingEpx = pendingBonderEpx;
        if (pendingEpx > 0) {
            pendingBonderEpx = 0;

            // mint DDD for dEPX bonders and DDD LPs
            uint256 pendingDdd = pendingEpx / DDD_EARN_RATIO;
            DDD.mint(address(bondedDistributor), pendingDdd);
            uint256 pendingDddLp = pendingDdd * 100 / (100 - DDD_LP_PERCENT) - pendingDdd;
            DDD.mint(address(dddLpStaker), pendingDddLp);

            // transfer 2/3 of EPX to dEPX bonders
            EPX.safeTransfer(address(bondedDistributor), pendingEpx / 3 * 2);

            // notify bonded distributor and DDD Lp Staker
            bondedDistributor.notifyFeeAmounts(pendingEpx / 3 * 2, pendingDdd);
            dddLpStaker.notifyFeeAmount(pendingDddLp);

            // 1/3 of EPX is converted to dEPX
            pendingEpx /= 3;
            dEPX.deposit(address(this), pendingEpx, false);
            if (epsVoter.isApproved(fixedVoteLpToken)) {
                // if `fixedVoteLpToken` is approved for emisisons, 1/2 of the
                // dEPX is used as a bribe for votes on that pool
                pendingEpx /= 2;
                dddIncentiveDistributor.depositIncentive(fixedVoteLpToken, address(dEPX), pendingEpx);
            }
            // remaining dEPX is given to all DDD lockers
            dddIncentiveDistributor.depositIncentive(address(0), address(dEPX), pendingEpx);
        }
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
            pendingBonderEpx += fee;

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
            pushPendingProtocolFees();
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
