pragma solidity 0.8.12;

import "../IERC20.sol";


interface IEpxToken is IERC20 {
    function migrationRatio() external view returns (uint256);
}