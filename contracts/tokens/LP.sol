// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./MintableBaseToken.sol";

contract LP is MintableBaseToken {
    constructor(string memory _name, string memory symbol) MintableBaseToken(name, symbol, 0) {
    }

    function id() external view returns (string memory _name) {
        return symbol;
    }
}
