pragma solidity 0.8.12;

interface IEmergencyBailout {

    function initialize(address _token, address _lpDepositor) external returns (bool);
}
