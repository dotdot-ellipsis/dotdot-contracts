pragma solidity 0.8.12;

import "./interfaces/IERC20.sol";
import "./interfaces/ellipsis/IFeeDistributor.sol";
import "./interfaces/ellipsis/ILpStaker.sol";
import "./interfaces/ellipsis/IIncentiveVoting.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";


contract EllipsisProxy {

    IERC20 public immutable EPX;
    ITokenLocker public immutable tokenLocker;
    IEllipsisLpStaking public immutable lpStaker;
    IFeeDistributor public immutable feeDistributor;
    IIncentiveVoting public immutable voter;

    uint256 immutable MAX_LOCK_WEEKS;


    constructor(
        IERC20 _EPX,
        ITokenLocker _tokenLocker,
        IEllipsisLpStaking _lpStaker,
        IFeeDistributor _feeDistributor,
        IIncentiveVoting _voter
    ) {
        EPX = _EPX;
        tokenLocker = _tokenLocker;
        lpStaker = _lpStaker;
        feeDistributor = _feeDistributor;
        voter = _voter;

        _tokenLocker.setBlockThirdPartyActions(true);
        _lpStaker.setBlockThirdPartyActions(true);
        _feeDistributor.setBlockThirdPartyActions(true);

        EPX.approve(address(_tokenLocker), type(uint256).max);

        MAX_LOCK_WEEKS = _tokenLocker.MAX_LOCK_WEEKS();

        // TODO
        // _lpStaker.setClaimReceiver(address(this));
        // _feeDistributor.setClaimReceiver(address(this));
    }

    // TokenLocker

    function lock(uint256 _amount) external returns (bool) {
        // TODO guard
        tokenLocker.lock(address(this), _amount, MAX_LOCK_WEEKS);
        return true;
    }

    function extendLock(uint256 _amount, uint256 _weeks) external returns (bool) {
        tokenLocker.extendLock(_amount, _weeks, MAX_LOCK_WEEKS);
        return true;
    }

    // EllipsisLpStaking

    function deposit(address _token, uint256 _amount) external returns (uint256) {
        // TODO approval, guard
        return lpStaker.deposit(_token, _amount, true);
    }

    function withdraw(address _receiver, address _token, uint256 _amount) external returns (uint256) {
        // TODO guard
        uint256 reward = lpStaker.withdraw(_token, _amount, true);
        IERC20(_token).transfer(_receiver, _amount);
        return reward;
    }

    function claimEmissions(address _token) external returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = _token;
        return lpStaker.claim(address(this), tokens);
    }

    // FeeDistributor

    function claimFees(address[] calldata _tokens) external returns (bool) {
        feeDistributor.claim(address(this), _tokens);
        return true;
    }

    // IncentiveVoting

    function vote(address[] calldata _tokens, uint256[] calldata _votes) external returns (bool) {
        voter.vote(_tokens, _votes);
        return true;
    }

    function createTokenApprovalVote(address _token) external returns (uint256 _voteIndex) {
        return voter.createTokenApprovalVote(_token);
    }

    function voteForTokenApproval(uint256 _voteIndex) external returns (bool) {
        voter.voteForTokenApproval(_voteIndex);
        return true;
    }

}