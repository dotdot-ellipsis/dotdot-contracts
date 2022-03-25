pragma solidity 0.8.12;

interface IBondedFeeDistributor {
    function notifyFeeAmounts(uint256 _epxAmount, uint256 _dddAmount) external returns (bool);
}