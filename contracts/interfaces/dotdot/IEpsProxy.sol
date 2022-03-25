pragma solidity 0.8.12;

interface IEllipsisProxy {
    function lock(uint256 _amount) external returns (bool);
    function extendLock(uint256 _amount, uint256 _weeks) external returns (bool);
    function deposit(address _token, uint256 _amount) external returns (uint256);
    function withdraw(address _receiver, address _token, uint256 _amount) external returns (uint256);
    function claimEmissions(address _token) external returns (uint256);
    function claimFees(address[] calldata _tokens) external returns (bool);
    function vote(address[] calldata _tokens, uint256[] calldata _votes) external returns (bool);
    function createTokenApprovalVote(address _token) external returns (uint256 _voteIndex);
    function voteForTokenApproval(uint256 _voteIndex, uint256 _yesVotes) external returns (bool);
    function getReward(address _lpToken, address[] calldata _rewards) external returns (bool);
}