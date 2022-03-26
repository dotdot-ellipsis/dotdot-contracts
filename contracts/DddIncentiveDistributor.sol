pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./dependencies/SafeERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/dotdot/IDotDotVoting.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";


contract DddIncentiveDistributor is Ownable {
    using SafeERC20 for IERC20;

    struct StreamData {
        uint256 start;
        uint256 amount;
        uint256 claimed;
    }

    // lp token -> bribe token -> week -> total amount received that week
    mapping(address => mapping(address => uint256[65535])) public weeklyIncentiveAmounts;
    // user -> lp token -> bribe token -> data about the active stream
    mapping(address => mapping(address => mapping(address => StreamData))) activeUserStream;

    // lp token -> array of all fee tokens that have been added
    mapping(address => address[]) public incentiveTokens;
    // private mapping for tracking which addresses were added to `feeTokens`
    mapping(address => mapping(address => bool)) seenTokens;

    // account earning rewards => receiver of rewards for this account
    // if receiver is set to address(0), rewards are paid to the earner
    // this is used to aid 3rd party contract integrations
    mapping (address => address) public claimReceiver;

    // when set to true, other accounts cannot call `claim` on behalf of an account
    mapping(address => bool) public blockThirdPartyActions;

    ITokenLocker public dddLocker;
    IDotDotVoting public dddVoter;

    uint256 public startTime;
    uint256 constant WEEK = 86400 * 7;

    // TODO events
    event FeesReceived(
        address indexed caller,
        address indexed token,
        uint256 indexed week,
        uint256 amount
    );
    event FeesClaimed(
        address caller,
        address indexed account,
        address indexed receiver,
        address indexed token,
        uint256 amount
    );

    function setAddresses(ITokenLocker _dddLocker, IDotDotVoting _dddVoter) external onlyOwner {
        dddLocker = _dddLocker;
        dddVoter = _dddVoter;
        startTime = _dddVoter.startTime();

        renounceOwnership();
    }

    function setClaimReceiver(address _receiver) external {
        claimReceiver[msg.sender] = _receiver;
    }

    function setBlockThirdPartyActions(bool _block) external {
        blockThirdPartyActions[msg.sender] = _block;
    }

    function getWeek() public view returns (uint256) {
        if (startTime == 0) return 0;
        return (block.timestamp - startTime) / 604800;
    }

    function incentiveTokensLength(address _lpToken) external view returns (uint) {
        return incentiveTokens[_lpToken].length;
    }

    /**
        @notice Deposit incentives into the contract
        @dev Incentives received in a week will be paid out the following week. An
             incentive can be given to all DDD lockers (a "fee"), or to lockers that
             voted for a specific LP token in the current week (a "bribe").
        @param _lpToken The LP token to incentivize voting for. Set to address(0) if
                        you are depositing a fee to distribute to all token lockers.
        @param _incentive Address of the incentive token
        @param _amount Amount of the token to deposit
        @return bool Success
     */
    function depositIncentive(address _lpToken, address _incentive, uint256 _amount)
        external
        returns (bool)
    {
        if (_amount > 0) {
            if (!seenTokens[_lpToken][_incentive]) {
                // TODO validate that this is actually an approved pool
                seenTokens[_lpToken][_incentive] = true;
                incentiveTokens[_lpToken].push(_incentive);
            }
            uint256 received = IERC20(_incentive).balanceOf(address(this));
            IERC20(_incentive).safeTransferFrom(msg.sender, address(this), _amount);
            received = IERC20(_incentive).balanceOf(address(this)) - received;
            uint256 week = getWeek();
            weeklyIncentiveAmounts[_lpToken][_incentive][week] += received;
            //emit FeesReceived(msg.sender, _bribe, week, _amount);
        }
        return true;
    }

    /**
        @notice Get an array of claimable amounts of different tokens accrued from protocol fees
        @param _user Address to query claimable amounts for
        @param _tokens List of tokens to query claimable amounts of
     */
    function claimable(address _user, address _lpToken, address[] calldata _tokens)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            (amounts[i], ) = _getClaimable(_user, _lpToken, _tokens[i]);
        }
        return amounts;
    }

    /**
        @notice Claim an available fee or bribe.
        @dev Incentives are claimable up to the end of the previous week. Incentives earned more
             than one week ago are released immediately, those from the previous week are streamed.
        @param _user Address to claim for
        @param _lpToken LP token that was voted on to earn the incentive. Set to address(0)
                        to claim general fees for all token lockers.
        @param _tokens Array of tokens to claim
        @return claimedAmounts Array of amounts claimed
     */
    function claim(address _user, address _lpToken, address[] calldata _tokens)
        external
        returns (uint256[] memory claimedAmounts)
    {
        if (msg.sender != _user) {
            require(!blockThirdPartyActions[_user], "Cannot claim on behalf of this account");
        }
        address receiver = claimReceiver[_user];
        if (receiver == address(0)) receiver = _user;
        claimedAmounts = new uint256[](_tokens.length);
        StreamData memory stream;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            (claimedAmounts[i], stream) = _getClaimable(_user, _lpToken, token);
            activeUserStream[_user][_lpToken][token] = stream;
            IERC20(token).safeTransfer(receiver, claimedAmounts[i]);
            //emit FeesClaimed(msg.sender, _user, receiver, token, claimedAmounts[i]);
        }
        return claimedAmounts;
    }

    function _getClaimable(address _user, address _lpToken, address _token)
        internal
        view
        returns (uint256, StreamData memory)
    {
        uint256 claimableWeek = getWeek();

        if (claimableWeek == 0) {
            // the first full week hasn't completed yet
            return (0, StreamData({start: startTime, amount: 0, claimed: 0}));
        }

        // the previous week is the claimable one
        claimableWeek -= 1;
        StreamData memory stream = activeUserStream[_user][_lpToken][_token];
        uint256 lastClaimWeek;
        if (stream.start == 0) {
            lastClaimWeek = 0;
        } else {
            lastClaimWeek = (stream.start - startTime) / WEEK;
        }

        uint256 amount;
        if (claimableWeek == lastClaimWeek) {
            // special case: claim is happening in the same week as a previous claim
            uint256 previouslyClaimed = stream.claimed;
            stream = _buildStreamData(_user, _lpToken, _token, claimableWeek);
            amount = stream.claimed - previouslyClaimed;
            return (amount, stream);
        }

        if (stream.start > 0) {
            // if there is a partially claimed week, get the unclaimed amount and increment
            // `lastClaimWeeek` so we begin iteration on the following week
            amount = stream.amount - stream.claimed;
            lastClaimWeek += 1;
        }

        // iterate over weeks that have passed fully without any claims
        for (uint256 i = lastClaimWeek; i < claimableWeek; i++) {
            (uint256 userWeight, uint256 totalWeight) = _getWeights(_user, _lpToken, i);
            if (userWeight == 0) continue;
            amount += weeklyIncentiveAmounts[_lpToken][_token][i] * userWeight / totalWeight;
        }

        // add a partial amount for the active week
        stream = _buildStreamData(_user, _lpToken, _token, claimableWeek);

        return (amount + stream.claimed, stream);
    }

    function _buildStreamData(
        address _user,
        address _lpToken,
        address _token,
        uint256 _week
    ) internal view returns (StreamData memory) {
        uint256 start = startTime + _week * WEEK;
        (uint256 userWeight, uint256 totalWeight) = _getWeights(_user, _lpToken, _week);
        uint256 amount;
        uint256 claimed;
        if (userWeight > 0) {
            amount = weeklyIncentiveAmounts[_lpToken][_token][_week] * userWeight / totalWeight;
            claimed = amount * (block.timestamp - 604800 - start) / WEEK;
        }
        return StreamData({start: start, amount: amount, claimed: claimed});
    }

    function _getWeights(address _user, address _lpToken, uint256 _week)
        internal
        view
        returns (uint256 userWeight, uint256 totalWeight)
    {
        if (_lpToken == address(0)) {
            return dddLocker.weeklyWeight(_user, _week);
        } else {
            return dddVoter.weeklyVotes(_user, _lpToken, _week);
        }
    }
}
