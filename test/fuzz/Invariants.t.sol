// SPDX-License-Identifier: MIT

// 1. The total supply of DSC should always be less than the total collateral value
// 2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (engine, dsc, helperConfig) = deployer.run();
        (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
        //targetContract(address(engine));
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value ", uint256(wethValue));
        console.log("wbtc value ", uint256(wbtcValue));
        console.log("Total Supply ", uint256(totalSupply));
        console.log("Times mint called: ", uint256(handler.timesMintIsCalled()));

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        // Forge inspect DSCEngine methods
        engine.getAccountCollateralValueInUsd(msg.sender);
        engine.getAccountInformation(msg.sender);
        engine.getAdditionalPrecision();
        engine.getAllCollateralTokens();
        engine.getCollateralAmountForUser(msg.sender, weth);
        engine.getCollateralToken(0);
        engine.getDscMinted(msg.sender);
        engine.getHealthFactor(msg.sender);
        engine.getLiquidationBonus();
        engine.getLiquidationPrecision();
        engine.getLiquidationThreshold();
        engine.getMinimumHealthFactor();
        engine.getPrecision();
        engine.getPriceFeedAddress(weth);
        //engine.getTokenAmountFromUsd(weth, usdAmountInWei);
        //engine.getUsdValue(weth, amount);
    }
}
