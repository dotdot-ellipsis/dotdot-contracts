// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;


interface IEllipsisLpStaking {

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
        @notice Get the current number of unclaimed rewards for a user on one or more token
        @param _user User to query pending rewards for
        @param _tokens Array of token addresses to query
        @return uint256[] Unclaimed rewards
     */
    function claimableReward(address _user, address[] calldata _tokens) external view returns (uint256[] memory);

    /**
        @notice Deposit LP tokens into the contract
        @param _receiver Address to deposit for.
        @param _token LP token address to deposit.
        @param _amount Amount of tokens to deposit.
        @param _claimRewards If true, also claim pending rewards on the token.
     */
    function deposit(address _receiver, address _token, uint256 _amount, bool _claimRewards) external;

    /**
        @notice Withdraw LP tokens from the contract
        @param _receiver Address to send the withdrawn tokens to.
        @param _token LP token address to withdraw.
        @param _amount Amount of tokens to withdraw.
        @param _claimRewards If true, also claim pending rewards on the token.
     */
    function withdraw(address _receiver, address _token, uint256 _amount, bool _claimRewards) external;

    function claim(address _user, address[] calldata _tokens) external;

}
