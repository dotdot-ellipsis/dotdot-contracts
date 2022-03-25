pragma solidity 0.8.12;

interface IDddIncentiveDistributor {
    function depositIncentive(address lpToken, address incentive, uint256 amount) external returns (bool);
}