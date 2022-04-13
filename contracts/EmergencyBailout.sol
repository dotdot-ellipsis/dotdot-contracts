pragma solidity 0.8.12;

import "./interfaces/IERC20.sol";
import "./dependencies/SafeERC20.sol";
import "./interfaces/dotdot/ILpDepositor.sol";

/**
    @dev Redistributes LP tokens to depositors in the event of an emergency
        requiring withdrawal from Ellipsis via `LpStaker.emergencyWithdraw`
 */
contract EmergencyBailout {
    using SafeERC20 for IERC20;

    IERC20 public token;
    ILpDepositor public lpDepositor;

    mapping(address => bool) public hasWithdrawn;

    event Withdraw(
        address indexed caller,
        address indexed user,
        uint256 amount
    );

    /**
        @dev Initializes the contract after deployment via a minimal proxy
     */
    function initialize(IERC20 _token, ILpDepositor _lpDepositor) external returns (bool) {
        require(address(token) == address(0));
        token = _token;
        lpDepositor = _lpDepositor;
        return true;
    }

    function withdraw(address _user) external {
        require(!hasWithdrawn[_user], "Already withdrawn");
        hasWithdrawn[_user] = true;
        uint256 amount = lpDepositor.userBalances(_user, address(token));
        token.safeTransfer(_user, amount);
        emit Withdraw(msg.sender, _user, amount);
    }

}
