pragma solidity 0.8.12;


interface IV1EpsStaker {

    struct LockedBalance {
        uint256 amount;
        uint256 unlockTime;
    }

    function lockedSupply() external view returns (uint256);
    function lockedBalances(
        address user
    ) external view returns (
        uint256 total,
        uint256 unlockable,
        uint256 locked,
        LockedBalance[] memory lockData
    );
}
