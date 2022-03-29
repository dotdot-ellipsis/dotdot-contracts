pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./interfaces/IERC20.sol";


contract DddLpStaker is Ownable {

    struct Deposit {
        uint256 timestamp;
        uint256 amount;
    }

    struct UserBalance {
        uint256 total;
        uint256 depositIndex;
        Deposit[] deposits;
    }

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 constant WEEK = 604800;
    uint256 public constant rewardsDuration = WEEK;

    uint256 public totalSupply;
    uint256 public immutable startTime;

    IERC20 public stakingToken;
    IERC20 public rewardToken;
    address public lpDepositor;
    address public treasury;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping (address => UserBalance) userBalances;

    event FeeAdded(uint256 reward);
    event Deposited(address indexed caller, address indexed receiver, uint256 stakeAmount, uint256 feeAmount);
    event Withdrawn(address indexed user, address indexed receiver, uint256 withdrawAmount, uint256 feeAmount);
    event FeeClaimed(address indexed user, address indexed receiver, uint256 reward);

    constructor() {
        startTime = block.timestamp;
    }

    function setAddresses(
        IERC20 _stakingToken,
        address _lpDepositor,
        address _treasury
    ) external onlyOwner {
        lpDepositor = _lpDepositor;
        stakingToken = _stakingToken;
        treasury = _treasury;

        renounceOwnership();
    }

    function balanceOf(address account) external view returns (uint256) {
        return userBalances[account].total;
    }

    function userDeposits(address account) external view returns (Deposit[] memory deposits) {
        UserBalance storage user = userBalances[account];
        deposits = new Deposit[](user.deposits.length - user.depositIndex);

        for (uint256 i = 0; i < deposits.length; i++) {
            deposits[i] = user.deposits[user.depositIndex + i];
        }
        return deposits;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        uint256 duration = lastTimeRewardApplicable() - lastUpdateTime;
        return rewardPerTokenStored + duration * rewardRate * 1e18 / totalSupply;
    }

    function claimable(address account) public view returns (uint256) {
        uint256 delta = rewardPerToken() - userRewardPerTokenPaid[account];
        return userBalances[account].total * delta / 1e18 + rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    /**
        @notice The current deposit fee percent as an integer out of 10000
        @dev The deposit fee is fixed, starting at 2% and reducing by 0.25%
             every 8 weeks until reaching 0
     */
    function depositFee() public view returns (uint256) {
        uint256 timeSinceStart = block.timestamp - startTime;
        if (timeSinceStart >= WEEK * 8 * 8) return 0;
        return 200 - (timeSinceStart / (WEEK * 8) * 25);
    }

    /**
        @notice Fee amount paid when depositing `amount` based on the current deposit fee
     */
    function depositFeeOnAmount(uint256 amount) public view returns (uint256) {
        uint256 fee = depositFee();
        return amount * fee / 10000;
    }

    /**
        @notice Fee amount paid for `account` to deposit `amount`
        @dev The withdrawal fee is variable, starting at 8% and reducing by 1% each week
             that the funds have been deposited. Withdrawals are always made starting from
             the oldest deposit, in order to minimize the fee paid.
     */
    function withdrawFeeOnAmount(address account, uint256 amount) external view returns (uint256 feeAmount) {
        UserBalance storage user = userBalances[account];
        require(user.total >= amount, "Amount exceeds user deposit");

        uint256 remaining = amount;
        uint256 timestamp = block.timestamp / 86400 * 86400;
        for (uint256 i = user.depositIndex; ; i++) {
            Deposit storage dep = user.deposits[i];
            uint256 weeklyAmount = dep.amount;
            if (weeklyAmount > remaining) {
                weeklyAmount = remaining;
            }
            uint256 weeksSinceDeposit = (timestamp - dep.timestamp) / 604800;
            if (weeksSinceDeposit < 8) {
                // for balances deposited less than 8 weeks ago, a withdrawal
                // fee is applied starting at 8% and decreasing by 1% every week
                uint feeMultiplier = 8 - weeksSinceDeposit;
                feeAmount += weeklyAmount * feeMultiplier / 100;
            }
            remaining -= weeklyAmount;
            if (remaining == 0) {
                return feeAmount;
            }
        }
        revert();
    }

    /**
        @notice Deposit LP tokens
        @dev `amount` is the total amount to transfer from the caller, inclusive of
             the deposit fee. the final deposited balance may be up to 2% less than
             the given amount.
        @param receiver Address to credit for the deposit
        @param amount Amount to deposit (inclusive of fee)
        @param claim If true, also claims any pending rewards. Cannot be true when
                     the caller is not the receiver.
     */
    function deposit(address receiver, uint256 amount, bool claim) external {
        if (claim) require (msg.sender == receiver, "Cannot trigger claim for another user");
        require(amount > 0, "Cannot stake 0");
        _updateReward(receiver, receiver, claim);
        stakingToken.transferFrom(msg.sender, address(this), amount);

        // apply deposit fee, if any
        uint256 feeAmount = depositFeeOnAmount(amount);
        if (feeAmount > 0) {
            stakingToken.transfer(treasury, feeAmount);
            amount -= feeAmount;
        }

        totalSupply += amount;
        UserBalance storage user = userBalances[receiver];
        user.total += amount;
        uint256 timestamp = block.timestamp / 86400 * 86400;
        uint256 length = user.deposits.length;
        if (length == 0 || user.deposits[length-1].timestamp < timestamp) {
            user.deposits.push(Deposit({timestamp: timestamp, amount: amount}));
        } else {
            user.deposits[length-1].amount += amount;
        }
        emit Deposited(msg.sender, receiver, amount, feeAmount);
    }

    /**
        @notice Withdraw LP tokens
        @dev `amount` is the total amount to deduct from the caller's balance,
             inclusive of the withdrawal fee. the final received amount may be
             up to 8% less than the given amount.
        @param receiver Address to send the withdrawn tokens to
        @param amount Amount to withdraw (inclusive of fee)
        @param claim If true, also claims any pending rewards
     */
    function withdraw(address receiver, uint256 amount, bool claim) public {
        require(amount > 0, "Cannot withdraw 0");
        _updateReward(msg.sender, receiver, claim);
        totalSupply -= amount;

        UserBalance storage user = userBalances[msg.sender];
        user.total -= amount;

        uint256 amountAfterFee = 0;
        uint256 remaining = amount;
        uint256 timestamp = block.timestamp / 86400 * 86400;
        for (uint256 i = user.depositIndex; ; i++) {
            Deposit storage dep = user.deposits[i];
            uint256 weeklyAmount = dep.amount;
            if (weeklyAmount > remaining) {
                weeklyAmount = remaining;
            }
            uint256 weeksSinceDeposit = (timestamp - dep.timestamp) / 604800;
            if (weeksSinceDeposit < 8) {
                // for balances deposited less than 8 weeks ago, a withdrawal
                // fee is applied starting at 8% and decreasing by 1% every week
                uint feeMultiplier = 100 - (8 - weeksSinceDeposit);
                amountAfterFee += weeklyAmount * feeMultiplier / 100;
            } else {
                amountAfterFee += weeklyAmount;
            }
            remaining -= weeklyAmount;
            dep.amount -= weeklyAmount;
            if (remaining == 0) {
                user.depositIndex = i;
                break;
            }
        }

        stakingToken.transfer(receiver, amountAfterFee);
        uint256 feeAmount = amount - amountAfterFee;
        if (feeAmount > 0) {
            stakingToken.transfer(treasury, feeAmount);
        }
        emit Withdrawn(msg.sender, receiver, amount, feeAmount);
    }

    /**
        @notice Claim pending rewards for the caller
        @param receiver Address to transfer claimed rewards to
     */
    function claim(address receiver) external {
        _updateReward(msg.sender, receiver, true);
    }

    /**
        @notice Claim pending rewards and withdraw all tokens
        @param receiver Address to transfer LP tokens and rewards to
     */
    function exit(address receiver) external {
        withdraw(receiver, userBalances[msg.sender].total, true);
    }

    function notifyFeeAmount(uint256 amount) external returns (bool) {
        require(msg.sender == lpDepositor);
        rewardPerTokenStored = rewardPerToken();

        if (block.timestamp >= periodFinish) {
            rewardRate = amount / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (amount + leftover) / rewardsDuration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit FeeAdded(amount);

        return true;
    }

    function _updateReward(address account, address receiver, bool claim) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        uint256 pending = claimable(account);
        if (pending > 0) {
            if (claim) {
                rewardToken.transfer(receiver, pending);
                emit FeeClaimed(account, receiver, pending);
                pending = 0;
            }
            rewards[account] = pending;
        }
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
