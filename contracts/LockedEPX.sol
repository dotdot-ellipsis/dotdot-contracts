pragma solidity 0.8.12;

import "./interfaces/IERC20.sol";
import "./interfaces/dotdot/IEpsProxy.sol";
import "./interfaces/ellipsis/ITokenLocker.sol";


contract EllipsisToken2 is IERC20 {

    string public constant symbol = "";
    string public constant name = "";
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    IERC20 public immutable EPX;
    ITokenLocker public immutable tokenLocker;

    IEllipsisProxy public immutable proxy;

    uint256 constant WEEK = 604800;
    uint256 immutable MAX_LOCK_WEEKS;
    uint256 lastLockWeek;

    constructor(
        IERC20 _EPX,
        IEllipsisProxy _proxy,
        ITokenLocker _tokenLocker
    ) {
        EPX = _EPX;
        proxy = _proxy;
        tokenLocker = _tokenLocker;
        MAX_LOCK_WEEKS = _tokenLocker.MAX_LOCK_WEEKS();
        lastLockWeek = block.timestamp / WEEK;
        emit Transfer(address(0), msg.sender, 0);
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
        @return Success boolean
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
        @return Success boolean
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

    function deposit(address _receiver, uint256 _amount) external returns (bool) {
        extendLock();
        EPX.transferFrom(msg.sender, address(proxy), _amount);
        proxy.lock(_amount);
        balanceOf[_receiver] += _amount;
        totalSupply += _amount;
        emit Transfer(address(0), _receiver, _amount);
        return true;
    }

    function extendLock() public returns (bool) {
        if (lastLockWeek < block.timestamp / WEEK) {
            uint256[2][] memory locks = tokenLocker.getActiveUserLocks(address(this));
            for (uint i = 0; i < locks.length; i++) {
                (uint256 week, uint256 amount) = (locks[i][0], locks[i][1]);
                if (week < MAX_LOCK_WEEKS) proxy.extendLock(amount, week);
            }
            lastLockWeek = block.timestamp / WEEK;
        }
        return true;
    }

}