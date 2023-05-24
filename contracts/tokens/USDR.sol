// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IUSDR.sol";
import "./YieldToken.sol";

contract USDR is YieldToken, IUSDR {

    mapping (address => bool) public vaults;

    modifier onlyVault() {
        require(vaults[msg.sender], "USDR: forbidden");
        _;
    }

    constructor(address _vault) YieldToken("Rollup USD", "USDR", 0) {
        vaults[_vault] = true;
    }

    function addVault(address _vault) external override onlyGov {
        vaults[_vault] = true;
    }

    function removeVault(address _vault) external override onlyGov {
        vaults[_vault] = false;
    }

    function mint(address _account, uint256 _amount) external override onlyVault {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external override onlyVault {
        _burn(_account, _amount);
    }
}
