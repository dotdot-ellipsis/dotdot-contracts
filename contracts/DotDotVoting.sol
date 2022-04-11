pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/dotdot/IEpsProxy.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";
import "./interfaces/ellipsis/IIncentiveVoting.sol";


contract DotDotVoting is Ownable {

    struct Vote {
        address token;
        uint256 votes;
    }
    struct TokenApprovalVote {
        uint256 week;
        uint256 ratio;
    }

    // user -> week -> votes used
    mapping(address => uint256[65535]) public userVotes;

    // user -> token -> week -> votes for pool
    mapping(address => mapping(address => uint256[65535])) public userTokenVotes;

    // token -> week -> votes received
    mapping(address => uint256[65535]) public tokenVotes;

    // week -> number of EPS votes per DDD vote
    uint256[65535] public epsVoteRatio;

    // vote ID -> user -> yes votes
    mapping(uint256 => mapping(address => uint256)) public userTokenApprovalVotes;
    // user -> timestamp of last created token approval vote
    mapping(address => uint256) public lastVote;

    mapping (uint256 => TokenApprovalVote) tokenApprovalVotes;

    uint256 constant WEEK = 86400 * 7;

    // new weeks within this contract begin on Thursday 00:00:00 UTC
    uint256 public startTime;

    IIncentiveVoting public immutable epsVoter;
    ITokenLocker public immutable epsLocker;

    ITokenLocker public dddLocker;
    address public fixedVoteLpToken;
    IEllipsisProxy public proxy;

    mapping(address => bool) public isApproved;

    event VotedForIncentives(
        address indexed voter,
        address[] tokens,
        uint256[] votes,
        uint256 userVotesUsed,
        uint256 totalUserVotes
    );
    event CreatedTokenApprovalVote(
        address indexed user,
        uint256 voteIndex,
        address token
    );
    event VotedForTokenApproval(
        address indexed voter,
        uint256 voteIndex,
        uint256 yesVotes
    );

    constructor(
        IIncentiveVoting _epsVoter,
        ITokenLocker _epsLocker
    ) {
        epsVoter = _epsVoter;
        epsLocker = _epsLocker;

        startTime = _epsVoter.startTime();
    }

    function setAddresses(
        ITokenLocker _dddLocker,
        address _fixedVoteLpToken,
        IEllipsisProxy _proxy
    ) external onlyOwner {
        dddLocker = _dddLocker;
        fixedVoteLpToken = _fixedVoteLpToken;
        proxy = _proxy;

        renounceOwnership();
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
        _voteData = new Vote[](epsVoter.approvedTokensLength());
        uint256 week = getWeek();
        uint256 totalVotes;
        for (uint i = 0; i < _voteData.length; i++) {
            address token = epsVoter.approvedTokens(i);
            uint256 votes = tokenVotes[token][week];
            totalVotes += votes;
            _voteData[i] = Vote({token: token, votes: votes});
        }
        return (totalVotes, _voteData);
    }

    /**
        @notice Get data on current votes `_user` has made in the active week
        @return _totalVotes Total number of votes from `_user` this week for all pools
        @return _voteData Dynamic array of (token address, votes for token)
     */
    function getUserCurrentVotes(address _user)
        external
        view
        returns (uint256 _totalVotes, Vote[] memory _voteData)
    {
        _voteData = new Vote[](epsVoter.approvedTokensLength());
        uint256 week = getWeek();
        for (uint i = 0; i < _voteData.length; i++) {
            address token = epsVoter.approvedTokens(i);
            _voteData[i] = Vote({token: token, votes: userTokenVotes[_user][token][week]});
        }
        return (userVotes[_user][week], _voteData);
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
        uint256 totalVotes = dddLocker.weeklyWeightOf(_user, week) / 1e18;
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

            if (epsVoter.isApproved(fixedVoteLpToken)) {
                // use 5% of the votes for EPX/dEPX pool
                address[] memory fixedVoteToken = new address[](1);
                fixedVoteToken[0] = fixedVoteLpToken;
                uint256[] memory fixedVote = new uint256[](1);
                fixedVote[0] = epsVotes / 20;
                proxy.vote(fixedVoteToken, fixedVote);
                epsVotes -= fixedVote[0];
            }
            uint256 dddVotes = dddLocker.weeklyTotalWeight(week) / 1e18;
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
        uint256 totalVotes = dddLocker.weeklyWeightOf(msg.sender, week) / 1e18;
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

    function minWeightForNewTokenApprovalVote() public view returns (uint256) {
        uint256 lockerWeek = epsLocker.getWeek();
        if (lockerWeek == 0) return 0;
        uint256 epsVotes = epsLocker.weeklyWeightOf(address(proxy), epsLocker.getWeek() - 1);
        uint256 dddVotes = dddLocker.weeklyTotalWeight(getWeek() - 1) / 1e18;
        uint256 ratio = epsVotes / dddVotes;
        return epsVoter.NEW_TOKEN_APPROVAL_VOTE_MIN_WEIGHT() / ratio;
    }

    function createTokenApprovalVote(address _token) external returns (uint256 _voteIndex) {
        require(epsVoter.isApproved(fixedVoteLpToken), "Cannot make vote until dEPX/EPX pool approved");
        require(lastVote[msg.sender] + 86400 * 30 < block.timestamp, "One new vote per 30 days");
        uint256 weight = dddLocker.weeklyWeightOf(msg.sender, getWeek() - 1);
        require(weight >= minWeightForNewTokenApprovalVote(), "User has insufficient DotDot lock weight");
        _voteIndex = proxy.createTokenApprovalVote(_token);
        lastVote[msg.sender] = block.timestamp;
        emit CreatedTokenApprovalVote(msg.sender, _voteIndex, _token);
    }

    function availableTokenApprovalVotes(address _user, uint256 _voteIndex) external view returns (uint256) {
        uint256 ratio = tokenApprovalVotes[_voteIndex].ratio;
        uint256 week = tokenApprovalVotes[_voteIndex].week;
        if (ratio == 0) {
            uint256 epsVotes = epsVoter.availableTokenApprovalVotes(address(proxy), _voteIndex);
            if (epsVotes == 0) return 0;
            week = getWeek() - 1;
            uint256 dddVotes = dddLocker.weeklyTotalWeight(week) / 1e18;
            ratio = epsVotes / dddVotes;
        }
        uint256 totalVotes = dddLocker.weeklyWeightOf(_user, week) / 1e18;
        uint256 usedVotes = userTokenApprovalVotes[_voteIndex][_user];
        return totalVotes - usedVotes;
    }

    /**
        @notice Vote in favor of approving a new token for protocol emissions
        @param _voteIndex Array index referencing the vote
     */
    function voteForTokenApproval(uint256 _voteIndex, uint256 _yesVotes) external {
        TokenApprovalVote storage vote = tokenApprovalVotes[_voteIndex];
        if (vote.ratio == 0) {
            uint256 epsVotes = epsVoter.availableTokenApprovalVotes(address(proxy), _voteIndex);
            require(epsVotes > 0, "Vote has closed or does not exist");
            vote.week = getWeek() - 1;
            uint256 dddVotes = dddLocker.weeklyTotalWeight(vote.week) / 1e18;
            vote.ratio = epsVotes / dddVotes;
        }

        uint256 totalVotes = dddLocker.weeklyWeightOf(msg.sender, vote.week) / 1e18;
        uint256 usedVotes = userTokenApprovalVotes[_voteIndex][msg.sender];
        if (_yesVotes == type(uint256).max) {
            _yesVotes = totalVotes - usedVotes;
        }
        usedVotes += _yesVotes;
        require(usedVotes <= totalVotes, "Exceeds available votes");

        userTokenApprovalVotes[_voteIndex][msg.sender] = usedVotes;
        proxy.voteForTokenApproval(_voteIndex, _yesVotes * vote.ratio);
        emit VotedForTokenApproval(msg.sender, _voteIndex, _yesVotes);
    }

    /**
        @notice Create a token approval vote for `fixedVoteLpToken` and vote
                with all available weight
        @dev This function is unguarded, but will revert within EPS if the the
             token is already approved or the last vote was made less than 1
             week ago.
     */
    function createFixedVoteApprovalVote() external {
        uint256 voteId = proxy.createTokenApprovalVote(fixedVoteLpToken);
        proxy.voteForTokenApproval(voteId, type(uint256).max);
        emit CreatedTokenApprovalVote(msg.sender, voteId, fixedVoteLpToken);
    }

}
