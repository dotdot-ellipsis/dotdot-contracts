pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./interfaces/dotdot/IDddToken.sol";
import "./interfaces/dotdot/IBondedFeeDistributor.sol";
import "./interfaces/dotdot/ILockedEPX.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";
import "./interfaces/ellipsis/IEpxToken.sol";
import "./interfaces/ellipsis/IV1EpsStaker.sol";


contract EpxDepositIncentives is Ownable {

    IEpxToken public immutable EPX;
    IV1EpsStaker public immutable epsV1Staker;

    ILockedEPX public dEPX;
    IDddToken public DDD;
    IBondedFeeDistributor public bondedDistributor;
    ITokenLocker public dddLocker;

    // timestamp when deposits are opened
    uint256 public immutable startTime;
    // maximum amount of EPX that may be deposited via this contract
    uint256 public immutable depositCap;
    // amount of EPX that has already been deposited via this contract
    uint256 public receivedDeposits;
    // amount of EPX that may only be deposited by legacy EPS lockers
    // who registered their balance within the first week
    uint256 public reservedDeposits;

    uint256[13] public totalWeeklyReservedDeposits;
    mapping(address => uint256[13]) public userWeeklyReservedDeposits;
    mapping(address => bool) public isRegistered;

    // amount of EPX to deposit in order to receive 1 locked DDD
    uint256 public immutable DDD_MINT_RATIO;
    uint256 public immutable EPS_MIGRATION_RATIO;
    uint256 constant WEEK = 86400 * 7;

    event Deposit(
        address indexed caller,
        address indexed receiver,
        uint256 epxReceived,
        uint256 dddMinted
    );
    event RegisteredLegacyLocks(
        address indexed caller,
        address indexed user,
        uint256 reservedAmount
    );

    constructor(
        IEpxToken _EPX,
        IV1EpsStaker _epsV1Staker,
        uint256 _maxDeposits,
        uint256 _mintRatio,
        uint256 _startTime
    ) {
        uint256 migrationRatio = _EPX.migrationRatio();
        require(_maxDeposits > _epsV1Staker.lockedSupply() * migrationRatio);
        require(_startTime / WEEK * WEEK == _startTime);

        EPX = _EPX;
        epsV1Staker = _epsV1Staker;
        depositCap = _maxDeposits;
        startTime = _startTime;

        DDD_MINT_RATIO = _mintRatio;
        EPS_MIGRATION_RATIO = migrationRatio;
    }

    function setAddresses(
        ILockedEPX _dEPX,
        IDddToken _DDD,
        IBondedFeeDistributor _bondedDistributor,
        ITokenLocker _dddLocker
    ) external onlyOwner {
        dEPX = _dEPX;
        DDD = _DDD;
        bondedDistributor = _bondedDistributor;
        dddLocker = _dddLocker;

        EPX.approve(address(_dEPX), type(uint256).max);
        _DDD.approve(address(_dddLocker), type(uint256).max);

        renounceOwnership();
    }

    function getWeek() public view returns (uint256) {
        return (block.timestamp - startTime) / WEEK;
    }

    /**
        @notice The maximum amount of EPX that may be deposited by `user`
        @dev Use `address(0)` as `user` to query the depositable amount
             for a user that did not register legacy locked balances
        @return total Maximum amount that this user may deposit, inclusive of the reserved amount
        @return reserved Deposit amount which is reserved specifically for `user`
     */
    function maxDepositAmount(address user) external view returns (uint256 total, uint256 reserved) {
        uint256 week = getWeek();
        if (week == 0) {
            uint256 lockedSupply = epsV1Staker.lockedSupply() * EPS_MIGRATION_RATIO;
            return (depositCap - lockedSupply - receivedDeposits, 0);
        } else {
            // subtract last week's total in case there was not a call to `updateReservedDeposits`
            // this week. Note that if there have been no calls for more than one week, this
            // view method will become inaccurate.
            uint256 totalReserved = reservedDeposits - totalWeeklyReservedDeposits[week - 1];

            uint256 userReserved = userWeeklyReservedDeposits[user][week];
            return (depositCap - totalReserved - receivedDeposits + userReserved, userReserved);
        }
    }

    /**
        @notice Deposit EPX to received bonded dEPX and locked DDD
        @param _receiver Address to receive bonded dEPX and locked DDD
        @param _amount Amount of EPX to transfer from the caller
     */
    function deposit(address _receiver, uint256 _amount) external {
        uint256 week = getWeek();
        if (week == 0) {
            // in the first week the full locked supply is considered reserved
            // we query `lockedSupply` very call because the return value includes
            // expired locks, and so is likely to change as the week progresses
            uint256 lockedSupply = epsV1Staker.lockedSupply() * EPS_MIGRATION_RATIO;
            require(receivedDeposits + lockedSupply + _amount <= depositCap);
        } else {
            // subsequent weeks give preference to users who registered
            // legacy locked positions during the first week
            updateReservedDeposits();
            uint256 reserved = userWeeklyReservedDeposits[msg.sender][week];
            if (reserved >= _amount) {
                reservedDeposits -= _amount;
                userWeeklyReservedDeposits[msg.sender][week] -= _amount;
                totalWeeklyReservedDeposits[week] -= _amount;
            } else {
                require(receivedDeposits + reservedDeposits + _amount - reserved <= depositCap);
                if (reserved > 0) {
                    reservedDeposits -= reserved;
                    userWeeklyReservedDeposits[msg.sender][week] = 0;
                    totalWeeklyReservedDeposits[week] -= reserved;
                }
            }
        }
        receivedDeposits += _amount;
        EPX.transferFrom(msg.sender, address(this), _amount);
        dEPX.deposit(_receiver, _amount, true);

        // locked DDD is split evenly between 4, 8, 12 and 16 week locks
        uint256 amount = _amount / DDD_MINT_RATIO / 4;
        DDD.mint(address(this), amount * 4);
        for (uint i = 4; i > 0; i--) {
            dddLocker.lock(_receiver, amount, i * 4);
        }
        emit Deposit(msg.sender, _receiver, _amount, amount * 4);
    }

    /**
        @notice Register EPSv1 locked balances within the contract
        @dev Must be called within the first week that this contract is active.
             Registered legacy lockers receive priority access to deposit EPX
             in the contract. For each lock, the priority period lasts for
             one week after that lock expires. If the user does not deposit
             within that period, the deposit amount becomes open for anyone.
        @param _user Address to register
     */
    function registerLegacyLocks(address _user) external {
        require(getWeek() == 0, "Can only register during first week");
        (,,uint256 totalLocked, IV1EpsStaker.LockedBalance[] memory lockData) = epsV1Staker.lockedBalances(_user);
        require(lockData.length > 0, "No legacy locks");
        require(!isRegistered[_user], "Already registered");


        totalLocked *= EPS_MIGRATION_RATIO;
        reservedDeposits += totalLocked;
        isRegistered[_user] = true;
        for(uint i = 0; i < lockData.length; i++) {
            uint256 amount = lockData[i].amount * EPS_MIGRATION_RATIO;
            uint256 week = (lockData[i].unlockTime - startTime) / WEEK;
            totalWeeklyReservedDeposits[week] += amount;
            userWeeklyReservedDeposits[_user][week] = amount;
        }
        emit RegisteredLegacyLocks(msg.sender, _user, totalLocked);
    }

    /**
        @notice Update the total reserved deposit amount
        @dev This function is called during the execution of `deposit`, under
             normal system use it is unlikely you will need to call it directly
     */
    function updateReservedDeposits() public {
        uint256 week = getWeek();
        uint256 released = 0;
        while (week != 0) {
            week--;
            uint256 amount = totalWeeklyReservedDeposits[week];
            if (amount == 0) break;
            released += amount;
            totalWeeklyReservedDeposits[week] = 0;
        }
        if (released > 0) {
            reservedDeposits -= released;
        }
    }

}
