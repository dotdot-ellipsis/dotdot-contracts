pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./dependencies/SafeERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/dotdot/IEmergencyBailout.sol";
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
    IFeeDistributor public immutable epsFeeDistributor;
    IIncentiveVoting public immutable epsVoter;

    address public dEPX;
    address public lpDepositor;
    address public bondedDistributor;
    address public dddVoter;
    address public bailoutImplementation;

    uint256 immutable MAX_LOCK_WEEKS;

    // Lp Depositor -> LP token -> emergency bailout deployment
    mapping(address => mapping(address => address)) public emergencyBailout;

    mapping(address => bool) isApproved;

    event EmergencyBailoutInitiated(
        address token,
        address lpDepositor,
        address bailout
    );

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
        epsFeeDistributor = _feeDistributor;
        epsVoter = _voter;

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
        address _dddVoter,
        address _bailout
    ) external onlyOwner {
        require(address(dEPX) == address(0), "Already set");
        dEPX = _dEPX;
        lpDepositor = _lpDepositor;
        bondedDistributor = _bondedDistributor;
        dddVoter = _dddVoter;
        bailoutImplementation = _bailout;

        lpStaker.setClaimReceiver(address(lpDepositor));
        epsFeeDistributor.setClaimReceiver(address(bondedDistributor));
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
        require(emergencyBailout[msg.sender][_token] == address(0), "Emergency bailout");
        if (!isApproved[_token]) {
            IERC20(_token).safeApprove(address(lpStaker), type(uint256).max);
            isApproved[_token] = true;
        }
        return lpStaker.deposit(_token, _amount, true);
    }

    function withdraw(address _receiver, address _token, uint256 _amount) external returns (uint256) {
        require(msg.sender == lpDepositor);
        require(emergencyBailout[msg.sender][_token] == address(0), "Emergency bailout");
        uint256 reward = lpStaker.withdraw(_token, _amount, true);
        IERC20(_token).transfer(_receiver, _amount);
        return reward;
    }

    function claimEmissions(address _token) external returns (uint256) {
        require(msg.sender == lpDepositor);
        require(emergencyBailout[msg.sender][_token] == address(0), "Emergency bailout");
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
        epsFeeDistributor.claim(address(this), _tokens);
        return true;
    }

    // IncentiveVoting

    function vote(address[] calldata _tokens, uint256[] calldata _votes) external returns (bool) {
        require(msg.sender == dddVoter);
        epsVoter.vote(_tokens, _votes);
        return true;
    }

    function createTokenApprovalVote(address _token) external returns (uint256 _voteIndex) {
        require(msg.sender == dddVoter);
        return epsVoter.createTokenApprovalVote(_token);
    }

    function voteForTokenApproval(uint256 _voteIndex, uint256 _yesVotes) external returns (bool) {
        require(msg.sender == dddVoter);
        epsVoter.voteForTokenApproval(_voteIndex, _yesVotes);
        return true;
    }

    /**
        @notice Triggers an emergency withdrawal for `_token`, deploys a bailout contract and
                transfers the balance to that contract. Interactions with `LpDepositor` related
                to `_token` will revert after calling this function and there is no undo, so
                this should only be done in an emergency situation.
     */
    function emergencyWithdraw(address _token) external onlyOwner {
        require(emergencyBailout[lpDepositor][_token] == address(0), "Already initiated");

        bytes20 targetBytes = bytes20(bailoutImplementation);
        address bailout;
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            bailout := create(0, clone, 0x37)
        }
        emergencyBailout[lpDepositor][_token] = bailout;

        IEmergencyBailout(bailout).initialize(_token, lpDepositor);
        lpStaker.emergencyWithdraw(_token);

        uint256 amount = IERC20(_token).balanceOf(address(this));
        require(amount > 0, "Bailout on empty pool");

        IERC20(_token).safeTransfer(bailout, amount);
        emit EmergencyBailoutInitiated(_token, bailout, lpDepositor);
    }

}
