pragma solidity 0.8.12;

import "./dependencies/SafeERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ellipsis/ILpStaker.sol";
import "./interfaces/dotdot/IEpsProxy.sol";
import "./interfaces/dotdot/IDepositToken.sol";


contract LpDepositor {
    using SafeERC20 for IERC20;

    struct Amounts {
        uint256 epx;
        uint256 ddd;
    }

    IERC20 public immutable EPX;
    IEllipsisLpStaking public immutable lpStaker;

    IEllipsisProxy public immutable proxy;
    address public immutable depositTokenImplementation;

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



    constructor(
        IERC20 _EPX,
        IEllipsisProxy _proxy,
        IEllipsisLpStaking _lpStaker,
        address _depositTokenImplementation
    ) {
        EPX = _EPX;
        proxy = _proxy;
        lpStaker = _lpStaker;
        depositTokenImplementation = _depositTokenImplementation;
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
                integral.ddd += 1e18 * (reward * 100 / 888) / total;
            }

            Amounts storage integralFor = rewardIntegralFor[_user][token];
            if (integralFor.epx < integral.epx) {
                pending[i].epx += balance * (integral.epx - integralFor.epx) / 1e18;
                pending[i].ddd += balance * (integral.ddd - integralFor.ddd) / 1e18;
            }
        }
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

    function claim(address _user, address[] calldata _tokens) external {
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
        if (claims.epx > 0) {
            // TODO
        }
        if (claims.ddd > 0) {
            // TODO
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
            //unclaimedSolidBonus += fee;

            integral.epx += 1e18 * reward / total;
            integral.ddd += 1e18 * (reward * 100 / 888) / total;
            rewardIntegral[pool] = integral;
        }
        if (user != address(0)) {
            Amounts memory integralFor = rewardIntegralFor[user][pool];
            if (integralFor.epx < integral.epx) {
                Amounts storage claims = unclaimedRewards[user][pool];
                claims.epx += balance * (integral.epx - integralFor.epx) / 1e18;
                claims.ddd += balance * (integral.ddd - integralFor.ddd) / 1e18;
                rewardIntegralFor[user][pool] = integral;
            }
        }
    }

}