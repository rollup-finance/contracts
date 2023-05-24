// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IQuotePrice {
    // return base price base in unit of quote
    // path[0] is base
    // path[path.length-1] is quote
    function getPrice(address[] memory path) external view returns (uint256);
}
