pragma solidity 0.8.12;

import "./dependencies/Ownable.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/dotdot/IBondedFeeDistributor.sol";
import "./interfaces/dotdot/IEpsProxy.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";


contract LockedEPX is IERC20, Ownable {

    string public constant symbol = "dEPX";
    string public constant name = "DotDot Tokenized EPX Lock";
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    mapping(address => bool) public blockThirdPartyActions;

    IERC20 public immutable EPX;
    ITokenLocker public immutable epsLocker;

    IBondedFeeDistributor public bondedDistributor;
    IEllipsisProxy public proxy;

    uint256 constant WEEK = 604800;
    uint256 immutable MAX_LOCK_WEEKS;
    uint256 lastLockWeek;

    event Deposit(address indexed caller, address indexed receiver, uint256 amount, bool bond);
    event ExtendLocks(uint256 lastLockWeek);

    constructor(
        IERC20 _EPX,
        ITokenLocker _epsLocker
    ) {
        EPX = _EPX;

        epsLocker = _epsLocker;
        MAX_LOCK_WEEKS = _epsLocker.MAX_LOCK_WEEKS();
        lastLockWeek = block.timestamp / WEEK;
        emit Transfer(address(0), msg.sender, 0);
    }

    function setAddresses(
        IBondedFeeDistributor _bondedDistributor,
        IEllipsisProxy _proxy
    ) external onlyOwner {
        bondedDistributor = _bondedDistributor;
        proxy = _proxy;

        renounceOwnership();
    }

    function setBlockThirdPartyActions(bool _block) external {
        blockThirdPartyActions[msg.sender] = _block;
    }

    function approve(address _spender, uint256 _value) external override returns (bool) {
        allowance[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
        return true;
    }

    /** shared logic for transfer and transferFrom */
    function _transfer(address _from, address _to, uint256 _value) internal {
        require(balanceOf[_from] >= _value, "Insufficient balance");
        balanceOf[_from] -= _value;
        balanceOf[_to] += _value;
        emit Transfer(_from, _to, _value);
    }

    /**
        @notice Transfer tokens to a specified address
        @param _to The address to transfer to
        @param _value The amount to be transferred
        @return bool Success
     */
    function transfer(address _to, uint256 _value) public override returns (bool) {
        _transfer(msg.sender, _to, _value);
        return true;
    }

    /**
        @notice Transfer tokens from one address to another
        @param _from The address which you want to send tokens from
        @param _to The address which you want to transfer to
        @param _value The amount of tokens to be transferred
        @return bool Success
     */
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    )
        public
        override
        returns (bool)
    {
        uint256 allowed = allowance[_from][msg.sender];
        require(allowed >= _value, "Insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[_from][msg.sender] = allowed - _value;
        }
        _transfer(_from, _to, _value);
        return true;
    }

    /**
        @notice Lock EPX and receive dEPX
        @param _receiver Address to receive the minted dEPX
        @param _amount Amount of EPX to lock. The balance is transferred from the caller.
        @param _bond If true, minted dEPX is immediately deposited in `BondedFeeDistributor`
        @return bool Success
     */
    function deposit(address _receiver, uint256 _amount, bool _bond) external returns (bool) {
        if (msg.sender != _receiver) {
            require(!blockThirdPartyActions[_receiver], "Cannot deposit on behalf of this account");
        }
        extendLock();
        EPX.transferFrom(msg.sender, address(proxy), _amount);
        proxy.lock(_amount);
        totalSupply += _amount;
        if (_bond) {
            balanceOf[address(bondedDistributor)] += _amount;
            emit Transfer(address(0), address(bondedDistributor), _amount);
            bondedDistributor.deposit(_receiver, _amount);
        } else {
            balanceOf[_receiver] += _amount;
            emit Transfer(address(0), _receiver, _amount);
        }
        emit Deposit(msg.sender, _receiver, _amount, _bond);
        return true;
    }

    /**
        @notice Extend all dEPX locks to the maximum lock weeks
        @dev This function is called once per week by `deposit`, which in turn is called
             daily by `LpDepositor`. With normal protocol usage there should never be a
             requirement to manually extend locks.
     */
    function extendLock() public returns (bool) {
        if (lastLockWeek < block.timestamp / WEEK) {
            uint256[2][] memory locks = epsLocker.getActiveUserLocks(address(proxy));
            for (uint i = 0; i < locks.length; i++) {
                (uint256 week, uint256 amount) = (locks[i][0], locks[i][1]);
                if (week < MAX_LOCK_WEEKS) proxy.extendLock(amount, week);
            }
            lastLockWeek = block.timestamp / WEEK;
            emit ExtendLocks(block.timestamp / WEEK);
        }
        return true;
    }

}
