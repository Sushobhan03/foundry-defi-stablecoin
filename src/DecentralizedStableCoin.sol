// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title A decentralized Stable Coin
/// @author Sushobhan Pathare
/// Collateral: Exogenous (ETH & BTC)
/// Minting: Algorithmic
/// Relative Stablility: Pegged to USD
///
/// This is the contract meant to be governed by DSCEngine. This contract is just the ERC20 implemetation of our stablecoin system.
///

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NoMintForZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    /// @notice Burns existing DSC
    /// @notice Overrides the Burn function from ERC20Burnable
    /// @notice Can be called only by the owner
    /// @param _amount Amount to burn
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    /// @notice Mints new DSC
    /// @notice Can be called only by the owner
    /// @param _to The address to which the DSC Stablecoin is supposed to be minted
    /// @param _amount The amount of Stablecoin to be minted
    /// @return bool Indicates if the mint was successful or not
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NoMintForZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
