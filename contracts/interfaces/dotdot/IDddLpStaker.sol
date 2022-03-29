pragma solidity 0.8.12;

interface IDddLpStaker {
    function notifyFeeAmount(uint256 amount) external returns (bool);
}
