pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./dependencies/SafeERC20.sol";
import "./interfaces/IERC20.sol";


contract TokenLocker is Ownable {
    using SafeERC20 for IERC20;

    struct StreamData {
        uint256 start;
        uint256 amount;
        uint256 claimed;
    }

    struct LockData {
        uint128 weight;
        uint128 unlock;
    }

    // `weeklyTotalWeight` and `weeklyWeightOf` track the total lock weight for each week,
    // calculated as the sum of [number of tokens] * [weeks to unlock] for all active locks.
    // The array index corresponds to the number of the epoch week.
    uint128[65535] public weeklyTotalWeight;

    // `weeklyLockData` tracks the total lock weights and unlockable token balances for each user.
    mapping(address => LockData[65535]) weeklyLockData;

    // `withdrawnUntil` tracks the most recent week for which each user has withdrawn their
    // expired token locks. Unlock values in `weeklyLockData` with an index less than the related
    // value within `withdrawnUntil` have already been withdrawn.
    mapping(address => uint256) withdrawnUntil;

    // After a lock expires, a user calls to `initiateExitStream` and the withdrawable tokens
    // are streamed out linearly over the following week. This array is used to track data
    // related to the exit stream.
    mapping(address => StreamData) public exitStream;

    // when set to true, other accounts cannot call `lock` on behalf of an account
    mapping(address => bool) public blockThirdPartyActions;

    IERC20 public DDD;

    // new weeks within this contract begin on Monday 00:00:00 UTC
    uint256 public immutable startTime;

    uint256 constant WEEK = 86400 * 7;

    uint256 public immutable MAX_LOCK_WEEKS;

    event NewLock(address indexed user, uint256 amount, uint256 lockWeeks);
    event ExtendLock(
        address indexed user,
        uint256 amount,
        uint256 oldWeeks,
        uint256 newWeeks
    );
    event NewExitStream(
        address indexed user,
        uint256 startTime,
        uint256 amount
    );
    event ExitStreamWithdrawal(
        address indexed user,
        uint256 claimed,
        uint256 remaining
    );

    constructor(
        TokenLocker _epsLocker,
        uint256 _maxLockWeeks
    ) {
        MAX_LOCK_WEEKS = _maxLockWeeks;
        // start time is shifted 3 days earlier so that the week ends
        // at the same time that the dotdot voting period opens
        startTime = _epsLocker.startTime() - 86400 * 3;
    }

    function setAddresses(IERC20 _DDD) external onlyOwner {
        DDD = _DDD;
        renounceOwnership();
    }

    /**
        @notice Allow or block third-party calls to deposit, withdraw
                or claim rewards on behalf of the caller
     */
    function setBlockThirdPartyActions(bool _block) external {
        blockThirdPartyActions[msg.sender] = _block;
    }

    function getWeek() public view returns (uint256) {
        return (block.timestamp - startTime) / WEEK;
    }

    /**
        @notice Get the current lock weight for a user
     */
    function userWeight(address _user) external view returns (uint256) {
        return uint256(weeklyLockData[_user][getWeek()].weight);
    }

    /**
        @notice Get the lock weight for a user in a given week
     */
    function weeklyWeightOf(address _user, uint256 _week) external view returns (uint256) {
        return uint256(weeklyLockData[_user][_week].weight);
    }

    /**
        @notice Get the token balance that unlocks for a user in a given week
     */
    function weeklyUnlocksOf(address _user, uint256 _week) external view returns (uint256) {
        return uint256(weeklyLockData[_user][_week].unlock);
    }

    /**
        @notice Get the total balance held in this contract for a user,
                including both active and expired locks
     */
    function userBalance(address _user)
        external
        view
        returns (uint256 balance)
    {
        uint256 i = withdrawnUntil[_user] + 1;
        uint256 finish = getWeek() + MAX_LOCK_WEEKS + 1;
        while (i < finish) {
            balance += weeklyLockData[_user][i].unlock;
            i++;
        }
        return balance;
    }

    /**
        @notice Get the current total lock weight
     */
    function totalWeight() external view returns (uint256) {
        return weeklyTotalWeight[getWeek()];
    }

    /**
        @notice Get the user lock weight and total lock weight for the given week
     */
    function weeklyWeight(address _user, uint256 _week) external view returns (uint256, uint256) {
        return (weeklyLockData[_user][_week].weight, weeklyTotalWeight[_week]);
    }

    /**
        @notice Get data on a user's active token locks
        @param _user Address to query data for
        @return lockData dynamic array of [weeks until expiration, balance of lock]
     */
    function getActiveUserLocks(address _user)
        external
        view
        returns (uint256[2][] memory lockData)
    {
        uint256 length = 0;
        uint256 week = getWeek();
        uint256[] memory unlocks = new uint256[](MAX_LOCK_WEEKS);
        for (uint256 i = 0; i < MAX_LOCK_WEEKS; i++) {
            unlocks[i] = weeklyLockData[_user][i + week + 1].unlock;
            if (unlocks[i] > 0) length++;
        }
        lockData = new uint256[2][](length);
        uint256 x = 0;
        for (uint256 i = 0; i < MAX_LOCK_WEEKS; i++) {
            if (unlocks[i] > 0) {
                lockData[x] = [i + 1, unlocks[i]];
                x++;
            }
        }
        return lockData;
    }

    /**
        @notice Deposit tokens into the contract to create a new lock.
        @dev A lock is created for a given number of weeks. Minimum 1, maximum `MAX_LOCK_WEEKS`.
             A user can have more than one lock active at a time. A user's total "lock weight"
             is calculated as the sum of [number of tokens] * [weeks until unlock] for all
             active locks. Fees are distributed porportionally according to a user's lock
             weight as a percentage of the total lock weight. At the start of each new week,
             each lock's weeks until unlock is reduced by 1. Locks that reach 0 week no longer
             receive any weight, and tokens may be withdrawn by calling `initiateExitStream`.
        @param _user Address to create a new lock for (does not have to be the caller)
        @param _amount Amount of tokens to lock. This balance transfered from the caller.
        @param _weeks The number of weeks for the lock.
     */
    function lock(
        address _user,
        uint256 _amount,
        uint256 _weeks
    ) external returns (bool) {
        if (msg.sender != _user) {
            require(!blockThirdPartyActions[_user], "Cannot lock on behalf of this account");
        }
        require(_weeks > 0, "Min 1 week");
        require(_weeks <= MAX_LOCK_WEEKS, "Exceeds MAX_LOCK_WEEKS");
        require(_amount > 0, "Amount must be nonzero");

        DDD.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 start = getWeek();
        _increaseAmount(_user, start, _amount, _weeks, 0);

        uint256 end = start + _weeks;
        weeklyLockData[_user][end].unlock += uint128(_amount);

        emit NewLock(_user, _amount, _weeks);
        return true;
    }

    /**
        @notice Extend the length of an existing lock.
        @param _amount Amount of tokens to extend the lock for. When the value given equals
                       the total size of the existing lock, the entire lock is moved.
                       If the amount is less, then the lock is effectively split into
                       two locks, with a portion of the balance extended to the new length
                       and the remaining balance at the old length.
        @param _weeks The number of weeks for the lock that is being extended.
        @param _newWeeks The number of weeks to extend the lock until.
     */
    function extendLock(
        uint256 _amount,
        uint256 _weeks,
        uint256 _newWeeks
    ) external returns (bool) {
        require(_weeks > 0, "Min 1 week");
        require(_newWeeks <= MAX_LOCK_WEEKS, "Exceeds MAX_LOCK_WEEKS");
        require(_weeks < _newWeeks, "newWeeks must be greater than weeks");
        require(_amount > 0, "Amount must be nonzero");

        LockData[65535] storage data = weeklyLockData[msg.sender];
        uint256 start = getWeek();
        uint256 end = start + _weeks;
        data[end].unlock -= uint128(_amount);
        end = start + _newWeeks;
        data[end].unlock += uint128(_amount);

        _increaseAmount(msg.sender, start, _amount, _newWeeks, _weeks);
        emit ExtendLock(msg.sender, _amount, _weeks, _newWeeks);
        return true;
    }

    /**
        @notice Create an exit stream, to withdraw tokens in expired locks over 1 week
     */
    function initiateExitStream() external returns (bool) {
        StreamData storage stream = exitStream[msg.sender];
        uint256 streamable = streamableBalance(msg.sender);
        require(streamable > 0, "No withdrawable balance");

        uint256 amount = stream.amount - stream.claimed + streamable;
        exitStream[msg.sender] = StreamData({
            start: block.timestamp,
            amount: amount,
            claimed: 0
        });
        withdrawnUntil[msg.sender] = getWeek();

        emit NewExitStream(msg.sender, block.timestamp, amount);
        return true;
    }

    /**
        @notice Withdraw tokens from an active or completed exit stream
     */
    function withdrawExitStream() external returns (bool) {
        StreamData storage stream = exitStream[msg.sender];
        uint256 amount;
        if (stream.start > 0) {
            amount = claimableExitStreamBalance(msg.sender);
            if (stream.start + WEEK < block.timestamp) {
                delete exitStream[msg.sender];
            } else {
                stream.claimed = stream.claimed + amount;
            }
            DDD.safeTransfer(msg.sender, amount);
        }
        emit ExitStreamWithdrawal(
            msg.sender,
            amount,
            stream.amount - stream.claimed
        );
        return true;
    }

    /**
        @notice Get the amount of `DDD` in expired locks that is
                eligible to be released via an exit stream.
     */
    function streamableBalance(address _user) public view returns (uint256) {
        uint256 finishedWeek = getWeek();

        LockData[65535] storage data = weeklyLockData[_user];
        uint256 amount;

        for (
            uint256 last = withdrawnUntil[_user] + 1;
            last <= finishedWeek;
            last++
        ) {
            amount = amount + data[last].unlock;
        }
        return amount;
    }

    /**
        @notice Get the amount of tokens available to withdraw from the active exit stream.
     */
    function claimableExitStreamBalance(address _user)
        public
        view
        returns (uint256)
    {
        StreamData storage stream = exitStream[_user];
        if (stream.start == 0) return 0;
        if (stream.start + WEEK < block.timestamp) {
            return stream.amount - stream.claimed;
        } else {
            uint256 claimable = stream.amount * (block.timestamp - stream.start) / WEEK;
            return claimable - stream.claimed;
        }
    }

    /**
        @dev Increase the amount within a lock weight array over a given time period
     */
    function _increaseAmount(
        address _user,
        uint256 _start,
        uint256 _amount,
        uint256 _rounds,
        uint256 _oldRounds
    ) internal {
        uint256 oldEnd = _start + _oldRounds;
        uint256 end = _start + _rounds;
        LockData[65535] storage data = weeklyLockData[_user];
        for (uint256 i = _start; i < end; i++) {
            uint256 amount = _amount * (end - i);
            if (i < oldEnd) {
                amount -= _amount * (oldEnd - i);
            }
            weeklyTotalWeight[i] += uint128(amount);
            data[i].weight += uint128(amount);
        }
    }

}
