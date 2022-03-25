pragma solidity 0.8.12;

import "./interfaces/IERC20.sol";
import "./interfaces/dotdot/IEpsProxy.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";
import "./interfaces/ellipsis/IIncentiveVoting.sol";

contract DotDotVoting {

    struct Vote {
        address token;
        uint256 votes;
    }

    // user -> week -> votes used
    mapping(address => uint256[65535]) public userVotes;

    // user -> token -> week -> votes for pool
    mapping(address => mapping(address => uint256[65535])) public userTokenVotes;

    // token -> week -> votes received
    mapping(address => uint256[65535]) public tokenVotes;

    // week -> number of EPS votes per DDD vote
    uint256[65535] public epsVoteRatio;

    uint256 constant WEEK = 86400 * 7;
    uint256 public startTime;

    IIncentiveVoting public immutable epsVoter;

    ITokenLocker public immutable dddLocker;
    address public immutable fixedVoteLpToken;
    IEllipsisProxy public immutable proxy;

    mapping(address => bool) public isApproved;
    address[] public approvedTokens;

    event VotedForIncentives(
        address indexed voter,
        address[] tokens,
        uint256[] votes,
        uint256 userVotesUsed,
        uint256 totalUserVotes
    );

    constructor(
        IIncentiveVoting _epsVoter,
        ITokenLocker _dddLocker,
        address _fixedVoteLpToken,
        IEllipsisProxy _proxy
    ) {
        epsVoter = _epsVoter;
        dddLocker = _dddLocker;
        fixedVoteLpToken = _fixedVoteLpToken;
        proxy = _proxy;

        startTime = _epsVoter.startTime();
    }

    function approvedTokensLength() external view returns (uint256) {
        return approvedTokens.length;
    }

    function votingOpen() public view returns (bool) {
        uint256 weekStart = block.timestamp / WEEK * WEEK;
        return block.timestamp - 86400 * 4 >= weekStart;
    }

    function getWeek() public view returns (uint256) {
        if (startTime >= block.timestamp) return 0;
        return (block.timestamp - startTime) / WEEK;
    }


    function weeklyVotes(address _user, address _token, uint256 _week) external view returns (uint256, uint256) {
        return (userTokenVotes[_user][_token][_week], tokenVotes[_token][_week]);
    }

    /**
        @notice Get data on the current votes made in the active week
        @return _totalVotes Total number of votes this week for all pools
        @return _voteData Dynamic array of (token address, votes for token)
     */
    function getCurrentVotes() external view returns (uint256 _totalVotes, Vote[] memory _voteData) {
        _voteData = new Vote[](approvedTokens.length);
        uint256 week = getWeek();
        uint256 totalVotes;
        for (uint i = 0; i < _voteData.length; i++) {
            address token = approvedTokens[i];
            uint256 votes = tokenVotes[token][week];
            totalVotes += votes;
            _voteData[i] = Vote({token: token, votes: votes});
        }
        return (totalVotes, _voteData);
    }

    /**
        @notice Get the amount of unused votes for for the current week being voted on
        @param _user Address to query
        @return uint Amount of unused votes
     */
    function availableVotes(address _user) external view returns (uint256) {
        if (!votingOpen()) return 0;
        uint256 week = getWeek();
        uint256 usedVotes = userVotes[_user][week];
        uint256 totalVotes = dddLocker.userWeight(_user) / 1e18;
        return totalVotes - usedVotes;
    }

    /**
        @notice Allocate votes toward LP tokens to receive emissions in the following week
        @dev Voting works identically to
        @param _tokens List of addresses of LP tokens to vote for
        @param _votes Votes to allocate to `_tokens`. Values are additive, they do
                        not include previous votes. For example, if you have already
                        allocated 100 votes and wish to allocate a total of 300,
                        the vote amount should be given as 200.
     */
    function vote(address[] calldata _tokens, uint256[] memory _votes) external {
        require(votingOpen(), "Voting period has not opened for this week");
        require(_tokens.length == _votes.length, "Input length mismatch");

        uint256 week = getWeek();
        uint256 ratio = epsVoteRatio[week];
        if (ratio == 0) {
            uint256 epsVotes = epsVoter.availableVotes(address(proxy));

            // use 5% of the votes for EPX/dEPX pool
            address[] memory fixedVoteToken = new address[](1);
            fixedVoteToken[0] = fixedVoteLpToken;
            uint256[] memory fixedVote = new uint256[](1);
            fixedVote[0] = epsVotes / 20;
            proxy.vote(fixedVoteToken, fixedVote);
            epsVotes -= fixedVote[0];

            uint256 dddVotes = dddLocker.totalWeight() / 1e18;
            ratio = epsVotes / dddVotes;
            epsVoteRatio[week] = ratio;
        }

        // update accounting for this week's votes
        uint256 usedVotes = userVotes[msg.sender][week];
        for (uint i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint256 amount = _votes[i];
            tokenVotes[token][week] += amount;
            userTokenVotes[msg.sender][token][week] += amount;
            usedVotes += amount;
            // multiply by ratio after updating internal accounting but prior to submitting
            _votes[i] = amount * ratio;
        }

        // make sure user has not exceeded available votes
        uint256 totalVotes = dddLocker.userWeight(msg.sender) / 1e18;
        require(usedVotes <= totalVotes, "Available votes exceeded");
        userVotes[msg.sender][week] = usedVotes;

        // submit votes
        proxy.vote(_tokens, _votes);

        emit VotedForIncentives(
            msg.sender,
            _tokens,
            _votes,
            usedVotes,
            totalVotes
        );
    }

}
