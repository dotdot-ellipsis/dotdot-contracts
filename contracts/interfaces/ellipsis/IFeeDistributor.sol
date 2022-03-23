pragma solidity 0.8.12;


interface IFeeDistributor {

    function startTime() external view returns (uint256);

    /**
        @notice Set the claim receiver address for the caller
        @param _receiver Claim receiver address
     */
    function setClaimReceiver(address _receiver) external;

    /**
        @notice Allow or block third-party calls to deposit, withdraw
                or claim rewards on behalf of the caller
     */
    function setBlockThirdPartyActions(bool _block) external;

    /**
        @notice Claim accrued protocol fees
        @param _user Address to claim for
        @param _tokens Array of tokens to claim for
        @return claimedAmounts Array of amounts claimed
     */
    function claim(address _user, address[] calldata _tokens) external returns (uint256[] memory claimedAmounts);
}