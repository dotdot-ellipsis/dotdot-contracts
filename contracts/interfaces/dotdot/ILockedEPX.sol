pragma solidity 0.8.12;

import "../IERC20.sol";

interface ILockedEPX is IERC20 {
    function deposit(address _receiver, uint256 _amount, bool _bond) external returns (bool);
}