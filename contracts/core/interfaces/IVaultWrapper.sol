// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IVaultWrapper {
    function enableLeverage(address _vault) external;
    function disableLeverage(address _vault) external;
}
