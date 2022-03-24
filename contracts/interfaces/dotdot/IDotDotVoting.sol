pragma solidity 0.8.12;

interface IDotDotVoting {
    function startTime() external view returns (uint256);
    function weeklyVotes(address _user, address _token, uint256 _week) external view returns (uint256, uint256);
}