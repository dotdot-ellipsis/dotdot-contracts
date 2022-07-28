pragma solidity 0.8.12;

import "./dependencies/SafeERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ellipsis/IIncentiveVoting.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";
import "./interfaces/dotdot/IDotDotVoting.sol";


contract TokenApprovalIncentives {
    using SafeERC20 for IERC20;

    ITokenLocker public immutable epsLocker;
    IIncentiveVoting public immutable epsVoter;

    ITokenLocker public immutable dddLocker;
    IDotDotVoting public immutable dddVoter;
    address public immutable proxy;

    uint256 public immutable startTime;

    uint256 constant WEEK = 86400 * 7;

    // vote ID -> eps/ddd vote ratio
    mapping(uint256 => uint256) voteRatio;
    // vote ID -> incentive -> rewards/ddd vote ratio
    mapping(uint256 => mapping(IERC20 => uint256)) public claimRatio;
    // vote ID -> incentive -> user -> deposited amount
    mapping(uint256 => mapping(IERC20 => mapping(address => uint256))) public userDeposits;
    // vote ID -> incentive -> total deposited
    mapping(uint256 => mapping(IERC20 => uint256)) public totalDeposits;
    // vote ID -> incentive -> user -> claimed amount
    mapping(uint256 => mapping(IERC20 => mapping(address => uint256))) public userClaims;
    // vote ID -> incentive -> total claimed
    mapping(uint256 => mapping(IERC20 => uint256)) public totalClaims;
    // vote ID -> list of incentive tokens
    mapping(uint256 => IERC20[]) incentives;

    event IncentiveAdded(
        uint256 indexed voteId,
        address indexed depositor,
        IERC20 indexed reward,
        uint256 amount
    );

    event IncentiveClaimed(
        uint256 indexed voteId,
        address indexed claimer,
        IERC20 indexed reward,
        uint256 amount
    );

    event IncentiveWithdrawn(
        uint256 indexed voteId,
        address indexed depositor,
        IERC20 indexed reward,
        uint256 amount
    );

    event VoteRatioSet(
        uint256 indexed voteId,
        uint256 ratio
    );

    event ClaimRatioSet(
        uint256 indexed voteId,
        IERC20 indexed reward,
        uint256 ratio
    );

    struct IncentiveData {
        IERC20 token;
        uint256 amount;
    }

    constructor(
        ITokenLocker _epsLocker,
        IIncentiveVoting _epsVoter,
        ITokenLocker _dddLocker,
        IDotDotVoting _dddVoter,
        address _proxy
    ) {
        epsLocker = _epsLocker;
        epsVoter = _epsVoter;

        dddLocker = _dddLocker;
        dddVoter = _dddVoter;
        proxy = _proxy;
        startTime = _dddVoter.startTime();
    }

    function getIncentives(uint256 _voteId) external view returns (IncentiveData[] memory) {
        IncentiveData[] memory data = new IncentiveData[](incentives[_voteId].length);
        for (uint256 i = 0; i < data.length; i++) {
            IERC20 token = incentives[_voteId][i];
            data[i] = IncentiveData({token: token, amount: totalDeposits[_voteId][token]});
        }
        return data;
    }

    function addIncentive(uint256 _voteId, IERC20 _reward, uint256 _amount) external {
        require(_amount > 0, "Cannot add zero");
        IIncentiveVoting.TokenApprovalVote memory vote = epsVoter.tokenApprovalVotes(_voteId);
        require(vote.startTime > block.timestamp - WEEK, "Vote has ended");
        require(vote.givenVotes < vote.requiredVotes, "Vote has already passed");

        if (voteRatio[_voteId] == 0) {
            uint256 epsVotes = epsLocker.weeklyWeightOf(proxy, vote.week) / 1e18;
            uint256 week = (vote.startTime - startTime) / WEEK - 1;
            uint256 dddVotes = dddLocker.weeklyTotalWeight(week) / 1e18;
            voteRatio[_voteId] = epsVotes / dddVotes;
            emit VoteRatioSet(_voteId, epsVotes / dddVotes);
        }

        uint256 amount = _reward.balanceOf(address(this));
        _reward.safeTransferFrom(msg.sender, address(this), _amount);
        amount = _reward.balanceOf(address(this)) - amount;

        userDeposits[_voteId][_reward][msg.sender] += amount;
        uint256 deposits = totalDeposits[_voteId][_reward];
        totalDeposits[_voteId][_reward] = deposits + amount;
        if (deposits == 0) {
            incentives[_voteId].push(_reward);
        }
        emit IncentiveAdded(_voteId, msg.sender, _reward, amount);
    }

    function claimIncentive(uint256 _voteId, IERC20 _reward) external {
        require(userClaims[_voteId][_reward][msg.sender] == 0, "Already claimed");
        uint256 deposits = totalDeposits[_voteId][_reward];
        require(deposits > 0, "No incentive given");
        uint256 votes = dddVoter.userTokenApprovalVotes(_voteId, msg.sender);
        require(votes > 0, "Did not vote");

        if (claimRatio[_voteId][_reward] == 0) {
            IIncentiveVoting.TokenApprovalVote memory vote = epsVoter.tokenApprovalVotes(_voteId);
            require(vote.givenVotes >= vote.requiredVotes, "Vote has not passed");
            uint256 totalVotes = epsVoter.userTokenApprovalVotes(_voteId, proxy) / voteRatio[_voteId];
            claimRatio[_voteId][_reward] = deposits / totalVotes;
            emit ClaimRatioSet(_voteId, _reward, deposits / totalVotes);
        }

        // When a vote is created in one epoch week, but the first DDD vote happens in the
        // following week, the reward ratio will be calculated incorrectly. In this case
        // we pay out until the rewards run out. The best way to mitigate this is to avoid
        // creating a token approval vote in the final hours of the epoch week.
        uint256 amount = votes * claimRatio[_voteId][_reward];
        uint256 claims = totalClaims[_voteId][_reward];
        if (claims == deposits) revert("Nothing left to claim");
        else if (claims + amount > deposits) amount = deposits - claims;

        userClaims[_voteId][_reward][msg.sender] = amount;
        totalClaims[_voteId][_reward] += amount;
        _reward.safeTransfer(msg.sender, amount);
        emit IncentiveClaimed(_voteId, msg.sender, _reward, amount);
    }

    function withdrawIncentive(uint256 _voteId, IERC20 _reward) external {
        IIncentiveVoting.TokenApprovalVote memory vote = epsVoter.tokenApprovalVotes(_voteId);
        require(vote.startTime < block.timestamp - WEEK, "Vote has not ended");
        require(vote.givenVotes < vote.requiredVotes, "Vote was successful");
        uint256 amount = userDeposits[_voteId][_reward][msg.sender];
        require(amount > 0, "Nothing to withdraw");

        userDeposits[_voteId][_reward][msg.sender] = 0;
        totalDeposits[_voteId][_reward] -= amount;
        _reward.safeTransfer(msg.sender, amount);
        emit IncentiveWithdrawn(_voteId, msg.sender, _reward, amount);
    }

}
