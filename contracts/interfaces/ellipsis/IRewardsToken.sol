pragma solidity 0.8.12;

import "../IERC20.sol";


interface IRewardsToken is IERC20 {
    function rewardCount() external view returns (uint256);
    function rewardTokens(uint256 idx) external view returns (address);
    function earned(address account, address _rewardsToken) external view returns (uint256);
    function getReward() external;
}
