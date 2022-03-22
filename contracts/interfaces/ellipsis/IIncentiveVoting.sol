pragma solidity 0.8.12;

interface IIncentiveVoting {

    function startTime() external view returns (uint256);
    function availableVotes(address _user) external view returns (uint256);

    /**
        @notice Allocate votes toward LP tokens to receive emissions in the following week
        @param _tokens List of addresses of LP tokens to vote for
        @param _votes Votes to allocate to `_tokens`
     */
    function vote(address[] calldata _tokens, uint256[] calldata _votes) external;

    /**
        @notice Create a new vote to enable protocol emissions on a given token
        @param _token Token address to create a vote for
        @return _voteIndex uint Index value used to reference the vote
     */
    function createTokenApprovalVote(address _token) external returns (uint256 _voteIndex);

    /**
        @notice Vote in favor of approving a new token for protocol emissions
        @param _voteIndex Array index referencing the vote
     */
    function voteForTokenApproval(uint256 _voteIndex) external;


}