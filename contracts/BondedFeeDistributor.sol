pragma solidity 0.8.12;

import "./dependencies/SafeERC20.sol";
import "./dependencies/Ownable.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/dotdot/IEpsProxy.sol";
import "./interfaces/ellipsis/IFeeDistributor.sol";


contract BondedFeeDistributor is Ownable {
    using SafeERC20 for IERC20;

    struct StreamData {
        uint256 start;
        uint256 amount;
        uint256 claimed;
    }
    struct Deposit {
        uint256 timestamp;
        uint256 amount;
    }
    struct DepositData {
        uint256 index;
        Deposit[] deposits;
    }

    // Fees are transferred into this contract as they are collected, and in the same tokens
    // that they are collected in. The total amount collected each week is recorded in
    // `weeklyFeeAmounts`. At the end of a week, the fee amounts are streamed out over
    // the following week based on each user's lock weight at the end of that week. Data
    // about the active stream for each token is tracked in `activeUserStream`

    // fee token -> week -> total amount received that week
    mapping(address => uint256[65535]) public weeklyFeeAmounts;
    // user -> fee token -> data about the active stream
    mapping(address => mapping(address => StreamData)) activeUserStream;


    // Weekly bonded balances are stored within a dynamic array, where the array index
    // represents the week. The final value is always the current balance. The length
    // will be less than that of `getWeek` if a user has not interacted in over a week.

    // user -> weekly bonded balance
    mapping(address => uint256[]) weeklyUserBalance;
    // weekly total bonded balance
    uint256[] totalBalance;

    // Deposited balances are "bonded" in order to receive fees. Each deposit cannot be
    // "unbonded" (withdrawn via a linear stream) for `MIN_BOND_DURATION` after bonding.

    // user -> deposit data
    mapping (address => DepositData) userDeposits;
    // users -> data on the active unbonding stream
    mapping (address => StreamData) exitStream;


    // array of all fee tokens that have been added
    address[] public feeTokens;
    // timestamp when a fee token was last claimed
    mapping(address => uint256) public lastClaim;
    // known balance of each token, used to calculate amounts when receiving new fees
    mapping(address => uint256) tokenBalance;

    // account earning rewards => receiver of rewards for this account
    // if receiver is set to address(0), rewards are paid to the earner
    // this is used to aid 3rd party contract integrations
    mapping (address => address) public claimReceiver;
    // when set to true, other accounts cannot call `claim` on behalf of an account
    mapping(address => bool) public blockThirdPartyActions;

    // Ellipsis contracts
    address public immutable EPX;
    IFeeDistributor public immutable epsFeeDistributor;

    // DotDot contracts
    IERC20 public dEPX;
    address public DDD;
    address public lpDepositor;
    IEllipsisProxy public proxy;

    uint256 public immutable startTime;

    uint256 constant WEEK = 86400 * 7;
    uint256 constant public MIN_BOND_DURATION = 86400 * 8;
    uint256 constant public UNBOND_STREAM_DURATION = 86400 * 15;

    event FeesClaimed(
        address caller,
        address indexed account,
        address indexed receiver,
        address indexed token,
        uint256 amount
    );

    constructor(address _EPX, IFeeDistributor _feeDistributor) {
        EPX = _EPX;
        epsFeeDistributor = _feeDistributor;
        startTime = _feeDistributor.startTime();
    }

    function setAddresses(
        IERC20 _dEPX,
        address _DDD,
        address _lpDepositor,
        IEllipsisProxy _proxy
    ) external onlyOwner {
        dEPX = _dEPX;
        DDD = _DDD;
        lpDepositor = _lpDepositor;
        proxy = _proxy;

        renounceOwnership();
    }

    function setClaimReceiver(address _receiver) external {
        claimReceiver[msg.sender] = _receiver;
    }

    function setBlockThirdPartyActions(bool _block) external {
        blockThirdPartyActions[msg.sender] = _block;
    }

    function getWeek() public view returns (uint256) {
        return (block.timestamp - startTime) / 604800;
    }

    function feeTokensLength() external view returns (uint) {
        return feeTokens.length;
    }

    /**
        @notice Get an array of claimable amounts of different tokens accrued from protocol fees
        @param _user Address to query claimable amounts for
        @param _tokens List of tokens to query claimable amounts of
     */
    function claimable(address _user, address[] calldata _tokens)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            (amounts[i], ) = _getClaimable(_user, _tokens[i]);
        }
        return amounts;
    }

    /**
        @notice The total amount of bonded tokens held in the contract for `_user`
        @dev Does not include any balance in an active unbonding stream
     */
    function bondedBalance(address _user) external view returns (uint256) {
        uint256 length = weeklyUserBalance[_user].length;
        if (length == 0) return 0;
        return weeklyUserBalance[_user][length-1];
    }

    /**
        @notice The amount of bonded tokens for `_user` which have passed the
                minimum bond duration and so could begin unbonding immediately.
     */
    function unbondableBalance(address _user) public view returns (uint256) {
        uint balance;
        DepositData storage data = userDeposits[_user];
        for (uint256 i = data.index; i < data.deposits.length; i++) {
            Deposit storage dep = data.deposits[i];
            if (dep.timestamp + MIN_BOND_DURATION > block.timestamp) break;
            balance += dep.amount;
        }
        return balance;
    }

    /**
        @notice Get info on the current unbonding stream for a user
        @return claimable Streamable balance that can currently be withdrawn
        @return total Total balance left in the stream
     */
    function streamingBalances(address _user) public view returns (uint256 claimable, uint256 total)
    {
        StreamData storage stream = exitStream[_user];
        if (stream.start == 0) return (0, 0);
        uint256 remaining = stream.amount - stream.claimed;
        if (stream.start + UNBOND_STREAM_DURATION < block.timestamp) {
            return (remaining, remaining);
        } else {
            uint256 claimable = stream.amount * (block.timestamp - stream.start) / UNBOND_STREAM_DURATION;
            return (claimable - stream.claimed, remaining);
        }
    }

    /**
        @notice Claim accrued protocol fees according to a locked balance in `TokenLocker`.
        @dev Fees are claimable up to the end of the previous week. Claimable fees from more
             than one week ago are released immediately, fees from the previous week are streamed.
        @param _user Address to claim for. Any account can trigger a claim for any other account.
        @param _tokens Array of tokens to claim for.
        @return claimedAmounts Array of amounts claimed.
     */
    function claim(address _user, address[] calldata _tokens)
        external
        returns (uint256[] memory claimedAmounts)
    {
        if (msg.sender != _user) {
            require(!blockThirdPartyActions[_user], "Cannot claim on behalf of this account");
        }

        _extendBalanceArray(weeklyUserBalance[_user]);
        _extendBalanceArray(totalBalance);

        address receiver = claimReceiver[_user];
        if (receiver == address(0)) receiver = _user;

        claimedAmounts = new uint256[](_tokens.length);
        address[] memory tokensToFetch = new address[](_tokens.length);
        uint256 toFetchLength;

        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];

            uint256 lastClaimed = lastClaim[token];
            if (lastClaimed + 86400 <= block.timestamp) {
                // once a day, claim new fees from Ellipsis
                tokensToFetch[toFetchLength] = token;
                toFetchLength++;
            }

            StreamData memory stream;
            (claimedAmounts[i], stream) = _getClaimable(_user, token);
            activeUserStream[_user][token] = stream;
            if (claimedAmounts[i] > 0) {
                tokenBalance[token] -= claimedAmounts[i];
                IERC20(token).safeTransfer(receiver, claimedAmounts[i]);
            }
            emit FeesClaimed(msg.sender, _user, receiver, token, claimedAmounts[i]);
        }

        if (toFetchLength > 0) {
            assembly { mstore(tokensToFetch, toFetchLength) }
            fetchEllipsisFees(tokensToFetch);
        }

        return claimedAmounts;
    }

    /**
        @notice Bond dEPX within the contract in order to receive fees
        @dev Bonded tokens cannot be withdrawn for `MIN_BOND_DURATION`
        @param _user Address to deposit tokens for
        @param _amount Amount of dEPX to deposit
     */
    function deposit(address _user, uint256 _amount) external returns (bool) {
        if (msg.sender != address(dEPX)) {
            // if the caller is dEPX we trust the balance was updated
            // and skip the transfer
            if (msg.sender != _user) {
                require(!blockThirdPartyActions[_user], "Cannot deposit on behalf of this account");
            }
            dEPX.safeTransferFrom(msg.sender, address(this), _amount);
        }

        uint256 balance = _extendBalanceArray(weeklyUserBalance[_user]);
        uint256 total = _extendBalanceArray(totalBalance);

        uint256 week = getWeek();
        weeklyUserBalance[_user][week] = balance + _amount;
        totalBalance[week] = total + _amount;

        DepositData storage data = userDeposits[_user];
        uint256 timestamp = block.timestamp / 86400 * 86400;
        uint256 length = data.deposits.length;
        if (length == 0 || data.deposits[length-1].timestamp < timestamp) {
            data.deposits.push(Deposit({timestamp: timestamp, amount: _amount}));
        } else {
            data.deposits[length-1].amount += _amount;
        }
        return true;
    }

    /**
        @notice Initiate an unbonding stream, allowing withdrawal of bonded tokens over the
                unbonding duration.
        @dev If there is already an active unbonding stream, any unclaimed balance is added
             to the new stream.
     */
    function initiateUnbondingStream(uint256 _amount) external returns (bool) {
        uint256 balance = _extendBalanceArray(weeklyUserBalance[msg.sender]);
        require(balance >= _amount, "Insufficient balance");
        uint256 total = _extendBalanceArray(totalBalance);

        uint256 week = getWeek();
        weeklyUserBalance[msg.sender][week] = balance - _amount;
        totalBalance[week] = total - _amount;

        uint256 remaining = _amount;
        DepositData storage data = userDeposits[msg.sender];
        for (uint256 i = data.index; ; i++) {
            Deposit memory dep = data.deposits[i];
            require(dep.timestamp + MIN_BOND_DURATION <= block.timestamp, "Insufficient unbondable balance");
            if (remaining >= dep.amount) {
                remaining -= dep.amount;
                delete data.deposits[i];
            } else {
                dep.amount -= remaining;
                remaining = 0;
            }
            if (remaining == 0) {
                data.index = i;
                break;
            }
        }

        StreamData storage stream = exitStream[msg.sender];
        exitStream[msg.sender] = StreamData({
            start: block.timestamp,
            amount: stream.amount - stream.claimed + _amount,
            claimed: 0
        });

        return true;
    }

    /**
        @notice Withdraw tokens that have finished unbonding.
     */
    function withdrawUnbondedTokens(address _receiver) external returns (bool) {
        StreamData storage stream = exitStream[msg.sender];
        uint256 amount;
        if (stream.start > 0) {
            (amount,) = streamingBalances(msg.sender);
            if (stream.start + UNBOND_STREAM_DURATION < block.timestamp) {
                delete exitStream[msg.sender];
            } else {
                stream.claimed = stream.claimed + amount;
            }
            dEPX.safeTransfer(_receiver, amount);
        }
        return true;
    }

    /**
        @notice Fetch fees from the Ellipsis fee distributor
        @dev Fees received within a week are distributed in the following week.
             When a user claims a fee token from this contract, an onward claim
             to Ellipsis is made if the last claim was more than one day ago.
             In theory, this should mean each fee token must be claimed using
             `fetchEllipsisFees` once to create an initial claimable amount
             for users. Subsequent calls will happen via regular user interactions.
     */
    function fetchEllipsisFees(address[] memory _tokens) public {
        proxy.claimFees(_tokens);
        uint256 week = getWeek();
        for (uint i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            require(token != address(dEPX), "Cannot distribute dEPX as a fee token");
            uint256 balance = tokenBalance[token];
            uint256 received = IERC20(token).balanceOf(address(this)) - balance;
            if (received > 0) {
                if (balance == 0 && lastClaim[token] == 0) feeTokens.push(token);
                weeklyFeeAmounts[token][week] += received;
                tokenBalance[token] = balance + received;
                lastClaim[token] = block.timestamp;
            }
        }
    }

    /**
        @notice Notify contract of newly received DDD and EPX fees
        @dev Only callable by `LpDepositor`. We trust the caller to supply the correct amounts.
     */
    function notifyFeeAmounts(uint256 _epxAmount, uint256 _dddAmount) external returns (bool) {
        require(msg.sender == lpDepositor);
        uint256 week = getWeek();

        weeklyFeeAmounts[EPX][week] += _epxAmount;
        tokenBalance[EPX] += _epxAmount;

        weeklyFeeAmounts[DDD][week] += _dddAmount;
        tokenBalance[DDD] += _dddAmount;

        return true;
    }

    function _getClaimable(address _user, address _token)
        internal
        view
        returns (uint256, StreamData memory)
    {
        uint256 claimableWeek = getWeek();
        uint256 balanceLength = weeklyUserBalance[_user].length;

        if (claimableWeek == 0 || balanceLength == 0) {
            // the first full week hasn't completed yet or the user has never made a deposit
            return (0, StreamData({start: startTime, amount: 0, claimed: 0}));
        }

        // the previous week is the claimable one
        claimableWeek -= 1;
        StreamData memory stream = activeUserStream[_user][_token];
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
            stream = _buildStreamData(_user, _token, claimableWeek);
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
        uint256 balance;
        uint256 total;
        uint256 totalLength = totalBalance.length;
        for (uint256 i = lastClaimWeek; i < claimableWeek; i++) {
            if (balanceLength > i) balance = weeklyUserBalance[_user][i];
            if (balance == 0) continue;
            if (totalLength > i) total = totalBalance[i];
            amount += weeklyFeeAmounts[_token][i] * balance / total;
        }

        // add a partial amount for the active week
        stream = _buildStreamData(_user, _token, claimableWeek);

        return (amount + stream.claimed, stream);
    }

    function _buildStreamData(
        address _user,
        address _token,
        uint256 _week
    ) internal view returns (StreamData memory) {
        uint256 start = startTime + _week * WEEK;
        uint256 length = weeklyUserBalance[_user].length;
        uint256 balance = length > _week ? weeklyUserBalance[_user][_week] : weeklyUserBalance[_user][length - 1];

        uint256 amount;
        uint256 claimed;
        if (balance > 0) {
            length = totalBalance.length;
            uint256 total = length > _week ? totalBalance[_week] : totalBalance[length - 1];
            amount = weeklyFeeAmounts[_token][_week] * balance / total;
            claimed = amount * (block.timestamp - 604800 - start) / WEEK;
        }
        return StreamData({start: start, amount: amount, claimed: claimed});
    }

    function _extendBalanceArray(uint256[] storage balances) internal returns (uint256) {
        uint256 week = getWeek();
        uint256 length = balances.length;
        uint256 value = 0;
        if (length > 0) {
            value = balances[length - 1];
        }
        while (length <= week) {
            balances.push(value);
            length++;
        }
        return value;
    }

}
