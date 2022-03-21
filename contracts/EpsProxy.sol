pragma solidity 0.8.12;

import "./interfaces/IFeeDistributor.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ILpStaker.sol";
import "./interfaces/IIncentiveVoting.sol";
import "./interfaces/ITokenLocker.sol";


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
        tokenLocker.lock(address(this), _amount, MAX_LOCK_WEEKS);
        return true;
    }

    function extendLock(uint256 _amount, uint256 _weeks) external returns (bool) {
        tokenLocker.extendLock(_amount, _weeks, MAX_LOCK_WEEKS);
        return true;
    }

    // EllipsisLpStaking

    function deposit(address _token, uint256 _amount) external returns (bool) {
        lpStaker.deposit(address(this), _token, _amount, true);
        return true;
    }

    function withdraw(address _receiver, address _token, uint256 _amount) external returns (bool) {
        lpStaker.withdraw(_receiver, _token, _amount, true);
        return true;
    }

    function claimEmissions(address[] calldata _tokens) external returns (bool) {
        lpStaker.claim(address(this), _tokens);
        return true;
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