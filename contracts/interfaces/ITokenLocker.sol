pragma solidity 0.8.12;


interface ITokenLocker {

    function MAX_LOCK_WEEKS() external view returns (uint256);
    function getWeek() external view returns (uint256);

    /**
        @notice Get data on a user's active token locks
        @param _user Address to query data for
        @return lockData dynamic array of [weeks until expiration, balance of lock]
     */
    function getActiveUserLocks(address _user) external view returns (uint256[2][] memory lockData);

    /**
        @notice Allow or block third-party calls to deposit, withdraw
                or claim rewards on behalf of the caller
     */
    function setBlockThirdPartyActions(bool _block) external;

    /**
        @notice Deposit tokens into the contract to create a new lock.
        @param _user Address to create a new lock for (does not have to be the caller)
        @param _amount Amount of tokens to lock. This balance transfered from the caller.
        @param _weeks The number of weeks for the lock.
     */
    function lock(
        address _user,
        uint256 _amount,
        uint256 _weeks
    ) external returns (bool);

    /**
        @notice Extend the length of an existing lock.
        @param _amount Amount of tokens to extend the lock for.
        @param _weeks The number of weeks for the lock that is being extended.
        @param _newWeeks The number of weeks to extend the lock until.
     */
    function extendLock(
        uint256 _amount,
        uint256 _weeks,
        uint256 _newWeeks
    ) external returns (bool);

}
