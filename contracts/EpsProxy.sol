pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./dependencies/SafeERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ellipsis/IFeeDistributor.sol";
import "./interfaces/ellipsis/ILpStaker.sol";
import "./interfaces/ellipsis/IIncentiveVoting.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";
import "./interfaces/ellipsis/IRewardsToken.sol";


contract EllipsisProxy is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable EPX;
    ITokenLocker public immutable epsLocker;
    IEllipsisLpStaking public immutable lpStaker;
    IFeeDistributor public immutable feeDistributor;
    IIncentiveVoting public immutable voter;

    address public dEPX;
    address public lpDepositor;
    address public bondedDistributor;
    address public dddVoter;

    uint256 immutable MAX_LOCK_WEEKS;

    mapping(address => bool) isApproved;

    constructor(
        IERC20 _EPX,
        ITokenLocker _epsLocker,
        IEllipsisLpStaking _lpStaker,
        IFeeDistributor _feeDistributor,
        IIncentiveVoting _voter
    ) {
        EPX = _EPX;
        epsLocker = _epsLocker;
        lpStaker = _lpStaker;
        feeDistributor = _feeDistributor;
        voter = _voter;

        _epsLocker.setBlockThirdPartyActions(true);
        _lpStaker.setBlockThirdPartyActions(true);
        _feeDistributor.setBlockThirdPartyActions(true);

        MAX_LOCK_WEEKS = _epsLocker.MAX_LOCK_WEEKS();
        EPX.approve(address(_epsLocker), type(uint256).max);
    }

    function setAddresses(
        address _dEPX,
        address _lpDepositor,
        address _bondedDistributor,
        address _dddVoter
    ) external onlyOwner {
        dEPX = _dEPX;
        lpDepositor = _lpDepositor;
        bondedDistributor = _bondedDistributor;
        dddVoter = _dddVoter;

        lpStaker.setClaimReceiver(address(lpDepositor));
        feeDistributor.setClaimReceiver(address(bondedDistributor));

        renounceOwnership();
    }

    // TokenLocker

    /**
        @notice Lock EPX within the Ellipsis `TokenLocker` for the maximum number of weeks
        @param _amount Amount of EPX to lock. Must have a sufficient balance in this contract.
        @return bool Success
     */
    function lock(uint256 _amount) external returns (bool) {
        require(msg.sender == dEPX);
        epsLocker.lock(address(this), _amount, MAX_LOCK_WEEKS);
        return true;
    }

    /**
        @notice Extend an EPX token lock to the maximum number of weeks
        @dev Intentionally left unguarded, there is no harm possible from extending a lock.
        @param _amount Amount of EPX to extend.
        @param _weeks Current weeks-to-unlock to extend from
        @return bool Success
     */
    function extendLock(uint256 _amount, uint256 _weeks) external returns (bool) {
        epsLocker.extendLock(_amount, _weeks, MAX_LOCK_WEEKS);
        return true;
    }

    // EllipsisLpStaking


    function deposit(address _token, uint256 _amount) external returns (uint256) {
        require(msg.sender == lpDepositor);
        if (!isApproved[_token]) {
            IERC20(_token).safeApprove(address(lpStaker), type(uint256).max);
            isApproved[_token] = true;
        }
        return lpStaker.deposit(_token, _amount, true);
    }

    function withdraw(address _receiver, address _token, uint256 _amount) external returns (uint256) {
        require(msg.sender == lpDepositor);
        uint256 reward = lpStaker.withdraw(_token, _amount, true);
        IERC20(_token).transfer(_receiver, _amount);
        return reward;
    }

    function claimEmissions(address _token) external returns (uint256) {
        require(msg.sender == lpDepositor);
        address[] memory tokens = new address[](1);
        tokens[0] = _token;
        return lpStaker.claim(address(this), tokens);
    }

    // RewardsToken

    function getReward(IRewardsToken _lpToken, IERC20[] calldata _rewards) external returns (bool) {
        require(msg.sender == lpDepositor);
        _lpToken.getReward();
        for (uint i = 0; i < _rewards.length; i++) {
            uint256 balance = _rewards[i].balanceOf(address(this));
            if (balance > 0) _rewards[i].transfer(msg.sender, balance);
        }
        return true;
    }

    // FeeDistributor

    function claimFees(address[] calldata _tokens) external returns (bool) {
        require(msg.sender == bondedDistributor);
        feeDistributor.claim(address(this), _tokens);
        return true;
    }

    // IncentiveVoting

    function vote(address[] calldata _tokens, uint256[] calldata _votes) external returns (bool) {
        require(msg.sender == dddVoter);
        voter.vote(_tokens, _votes);
        return true;
    }

    function createTokenApprovalVote(address _token) external returns (uint256 _voteIndex) {
        // TODO
        return voter.createTokenApprovalVote(_token);
    }

    function voteForTokenApproval(uint256 _voteIndex) external returns (bool) {
        // TODO
        voter.voteForTokenApproval(_voteIndex);
        return true;
    }

}