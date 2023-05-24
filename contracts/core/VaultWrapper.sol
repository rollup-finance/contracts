// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../access/Governable.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultWrapper.sol";

contract VaultWrapper is Governable, IVaultWrapper {
    uint256 public marginFeeBasisPoints;
    uint256 public maxMarginFeeBasisPoints;
    bool public shouldToggleIsLeverageEnabled;

    constructor(uint256 _marginFeeBasisPoints, uint256 _maxMarginFeeBasisPoints) {
        marginFeeBasisPoints = _marginFeeBasisPoints;
        maxMarginFeeBasisPoints = _maxMarginFeeBasisPoints;
    }

    // set shouldToggleIsLeverageEnabled
    function setShouldToggleIsLeverageEnabled(bool _shouldToggleIsLeverageEnabled) external onlyGov {
        shouldToggleIsLeverageEnabled = _shouldToggleIsLeverageEnabled;
    }

    // set marginFeeBasisPoints and maxMarginFeeBasisPoints
    function setMarginFeeBasisPoints(uint256 _marginFeeBasisPoints, uint256 _maxMarginFeeBasisPoints) external onlyGov {
        require(_marginFeeBasisPoints <= _maxMarginFeeBasisPoints, "VaultWrapper: invalid basis points");

        marginFeeBasisPoints = _marginFeeBasisPoints;
        maxMarginFeeBasisPoints = _maxMarginFeeBasisPoints;
    }

    // enable leverage
    function enableLeverage(address _vault) external override {
        IVault vault = IVault(_vault);

        if (shouldToggleIsLeverageEnabled) {
            vault.setIsLeverageEnabled(true); // require permission to set isLeverageEnabled for Vault
        }

        vault.setFees( // require permission to set fees for Vault
            vault.taxBasisPoints(),
            vault.stableTaxBasisPoints(),
            vault.mintBurnFeeBasisPoints(),
            vault.swapFeeBasisPoints(),
            vault.stableSwapFeeBasisPoints(),
            marginFeeBasisPoints,
            vault.liquidationFeeUsd(),
            vault.minProfitTime(),
            vault.hasDynamicFees()
        );
    }

    // disable leverage
    function disableLeverage(address _vault) external override {
        IVault vault = IVault(_vault);

        if (shouldToggleIsLeverageEnabled) {
            vault.setIsLeverageEnabled(false);
        }

        vault.setFees(
            vault.taxBasisPoints(),
            vault.stableTaxBasisPoints(),
            vault.mintBurnFeeBasisPoints(),
            vault.swapFeeBasisPoints(),
            vault.stableSwapFeeBasisPoints(),
            maxMarginFeeBasisPoints,
            vault.liquidationFeeUsd(),
            vault.minProfitTime(),
            vault.hasDynamicFees()
        );
    }

}