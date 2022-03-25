pragma solidity 0.8.12;

import "../IERC20.sol";

interface IDddToken is IERC20 {
    function mint(address _to, uint256 _value) external returns (bool);
}