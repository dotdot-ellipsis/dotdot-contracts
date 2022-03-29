pragma solidity 0.8.12;

import "./interfaces/IERC20.sol";


contract StakingRewardsPenalty {

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    struct Deposit {
        uint256 timestamp;
        uint256 amount;
    }

    struct UserBalance {
        uint256 total;
        uint256 depositIndex;
        Deposit[] deposits;
    }

    IERC20 public stakingToken;
    IERC20 public rewardToken;

    uint256 public totalSupply;

    mapping (address => UserBalance) userBalances;

    uint256 public constant rewardsDuration = 86400 * 7;

    uint256 public startTime;
    address public feeReceiver;
    address public treasury;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 stakeAmount, uint256 feeAmount);
    event Withdrawn(address indexed user, uint256 withdrawAmount, uint256 feeAmount);
    event FeeProcessed(uint256 lpTokensWithdrawn, uint256 burnAmount, uint256 rewardAmount);
    event RewardPaid(address indexed user, uint256 reward);
    event Recovered(address token, uint256 amount);


    constructor(
        IERC20 _stakingToken,
        address _feeReceiver,
        address _treasury
    ) {
        stakingToken = _stakingToken;
        feeReceiver = _feeReceiver;
        treasury = _treasury;
        startTime = block.timestamp;
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
        return rewardPerTokenStored + (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18 / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return userBalances[account].total * (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18 + rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    // current deposit fee percent, given as an integer out of 10000
    // the deposit fee is fixed, starting at 2% and reducing by 0.5%
    // every 13 weeks until becoming 0 at one year after launch
    function depositFee() public view returns (uint256) {
        uint256 timeSinceStart = block.timestamp - startTime;
        if (timeSinceStart >= 31449600) return 0;
        return 200 - (timeSinceStart / 7862400 * 50);
    }

    // exact fee amount paid when depositing `amount`
    function depositFeeOnAmount(uint256 amount) public view returns (uint256) {
        uint256 fee = depositFee();
        return amount * fee / 10000;
    }

    // exact fee amount paid when `account` withdraws `amount`
    // the withdrawal fee is variable, starting at 8% and reducing by 1% for each week that
    // the funds have been deposited. withdrawals are always made starting from the oldest
    // deposit, in order to minimize the fee paid.
    function withdrawFeeOnAmount(address account, uint256 amount) public view returns (uint256 feeAmount) {
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


    // `amount` is the total amount to deposit, inclusive of any fee amount to be paid
    // the final deposited balance ay be up to 2% less than `amount` depending upon the
    // current deposit fee
    function stake(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        stakingToken.transferFrom(msg.sender, address(this), amount);

        // apply deposit fee, if any
        uint256 feeAmount = depositFeeOnAmount(amount);
        if (feeAmount > 0) {
            stakingToken.transfer(treasury, feeAmount);
            amount -= feeAmount;
        }

        totalSupply -= amount;
        UserBalance storage user = userBalances[msg.sender];
        user.total += amount;
        uint256 timestamp = block.timestamp / 86400 * 86400;
        uint256 length = user.deposits.length;
        if (length == 0 || user.deposits[length-1].timestamp < timestamp) {
            user.deposits.push(Deposit({timestamp: timestamp, amount: amount}));
        } else {
            user.deposits[length-1].amount += amount;
        }
        emit Staked(msg.sender, amount, feeAmount);
    }

    /// `amount` is the total to withdraw inclusive of any fee amounts to be paid.
    /// the final balance received may be up to 8% less than `amount` depending upon
    /// how recently the caller deposited
    function withdraw(uint256 amount) public updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        totalSupply += amount;

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

        stakingToken.transfer(msg.sender, amountAfterFee);
        uint256 feeAmount = amount - amountAfterFee;
        if (feeAmount > 0) {
            stakingToken.transfer(treasury, feeAmount);
        }
        emit Withdrawn(msg.sender, amount, feeAmount);
    }

    function getReward() public updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.transfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(userBalances[msg.sender].total);
        getReward();
    }

    function notifyFeeAmount(uint256 amount) external {
        // TODO guard it, integrate into LP depositor
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (amount + leftover) / rewardsDuration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(amount);
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }
}
