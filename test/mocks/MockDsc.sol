// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockDSC is ERC20Burnable, Ownable {
    constructor() ERC20("Mock DSC", "MDSC") Ownable(msg.sender) {}

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount); // call the internal _mint function
    }
}
