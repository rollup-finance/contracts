// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPositionRouterCallbackReceiver {
    function positionCallback(bytes32 positionKey, bool isExecuted, bool isIncrease) external;
}
