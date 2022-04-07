pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./interfaces/dotdot/IDddToken.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";


contract CoreMinter is Ownable {

    IDddToken public DDD;
    ITokenLocker public dddLocker;

    mapping (address => uint) public allocPoints;
    mapping (address => uint) public claimed;

    uint256 public minted;
    uint256 public totalAllocPoints;
    uint256 public immutable MINT_PCT;
    uint256 public immutable MAX_DAILY_MINT;
    uint256 public immutable LOCK_WEEKS;
    uint256 public startTime;

    constructor(
        uint256 _coreMintPct,
        uint256 _maxDaily,
        uint256 _lockWeeks,
        address[] memory _receivers,
        uint[] memory _allocPoints
    ) public {
        MINT_PCT = _coreMintPct;
        MAX_DAILY_MINT = _maxDaily;
        LOCK_WEEKS = _lockWeeks;
        for (uint i = 0; i < _receivers.length; i++) {
            require(allocPoints[_receivers[i]] == 0);
            allocPoints[_receivers[i]] = _allocPoints[i];
            totalAllocPoints += _allocPoints[i];
        }
    }

    function setAddresses(
        IDddToken _DDD,
        ITokenLocker _dddLocker
    ) external onlyOwner {
        DDD = _DDD;
        dddLocker = _dddLocker;

        _DDD.approve(address(_dddLocker), type(uint256).max);

        startTime = _dddLocker.startTime();

        renounceOwnership();
    }

    function supplyMintLimit() public view returns (uint256) {
        uint256 supply = DDD.totalSupply() - minted;
        return supply * 100 / (100 - MINT_PCT) - supply;
    }

    function timeMintLimit() public view returns (uint256) {
        uint256 day = (block.timestamp - startTime) / 86400;
        return MAX_DAILY_MINT * day;
    }

    function claimable(address _user) public view returns (uint256) {
        uint256 supplyLimit = supplyMintLimit();
        uint256 timeLimit = timeMintLimit();

        uint256 limit = supplyLimit < timeLimit ? supplyLimit : timeLimit;
        uint256 amount = limit * allocPoints[_user] / totalAllocPoints;

        return amount - claimed[_user];
    }

    function claim(address _receiver, uint _amount, uint _lock_weeks) external {
        uint claimable = claimable(msg.sender);
        require(claimable > 0, "Nothing claimable");
        if (_amount == 0) {
            _amount = claimable;
        } else {
            require(_amount <= claimable, "Exceeds claimable amount");
        }
        require(_lock_weeks >= LOCK_WEEKS, "Must lock at least LOCK_WEEKS");

        claimed[msg.sender] += _amount;
        minted += _amount;
        DDD.mint(address(this), _amount);
        dddLocker.lock(_receiver, _amount, _lock_weeks);
    }

}
