//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    HelperConfig helperConfig;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant STARTING_BALANCE = 100 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant DSC_AMOUNT_TO_MINT = 1 ether;

    //Get to 85-90 on your own
    function setUp() public {
        deployer = new DeployDSC();
        (engine, dsc, helperConfig) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_BALANCE);
    }

    //////////////////////////////////////////
    // Constructor Tests /////////////////////
    //////////////////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenAddressesLengthDoesntMatchPriceFeedAddressesLengt() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testConstructorSetsPriceFeedsAndCollateralTokensCorrectly() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);

        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        DSCEngine newEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        // Check price feeds
        assertEq(newEngine.getPriceFeedAddress(weth), wethUsdPriceFeed);
        assertEq(newEngine.getPriceFeedAddress(wbtc), wbtcUsdPriceFeed);

        // Check collateral tokens array
        assertEq(newEngine.getCollateralToken(0), weth);
        assertEq(newEngine.getCollateralToken(1), wbtc);
    }

    //////////////////////////////////////////
    // Price Tests ///////////////////////////
    //////////////////////////////////////////

    function testGetUsdValue() public view {
        uint256 expectedValue = 4000e18;
        uint256 ethAmount = 2e18;
        uint256 actualValue = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedValue, actualValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 expectedValue = 0.1 ether;
        uint256 ethAmountInUsd = 200e18;
        uint256 actualValue = engine.getTokenAmountFromUsd(weth, ethAmountInUsd);
        assertEq(expectedValue, actualValue);
    }

    //////////////////////////////////////////
    // Deposit Collateral Tests //////////////
    //////////////////////////////////////////

    function testRevertsIfDepositAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__RequiredToBeMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedTokenCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ERC20Mock(ranToken).mint(USER, STARTING_BALANCE);
        vm.startPrank(USER);
        ERC20Mock(ranToken).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier collateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCollateralDepositedAndGetAccountCollateralValueInUsd() public collateralDeposited {
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 collateralValue = engine.getAccountCollateralValueInUsd(USER);
        assert(expectedCollateralValue == collateralValue);
    }

    function testCanDepositCollateralAndGetAccountInfo() public collateralDeposited {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedTotalCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedTotalCollateralValueInUsd, totalCollateralValueInUsd);
    }

    //////////////////////////////////////////////////////
    // Deposit Collateral and Mint DSC Tests /////////////
    //////////////////////////////////////////////////////

    function testDepositCollateralAndMintDscWorks() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        uint256 mintAmount = engine.getUsdValue(weth, AMOUNT_COLLATERAL / 2);
        console.log("Mint Amount: ", mintAmount);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, mintAmount);
        vm.stopPrank();

        uint256 dscBalance = dsc.balanceOf(USER);
        assertEq(dscBalance, mintAmount);
    }

    function testDepositCollateralAndMintRevertsIfZeroAmounts() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        // When collateral amount is 0
        vm.expectRevert(DSCEngine.DSCEngine__RequiredToBeMoreThanZero.selector);
        engine.depositCollateralAndMintDsc(weth, 0, 100);

        // When mint amount is 0
        vm.expectRevert(DSCEngine.DSCEngine__RequiredToBeMoreThanZero.selector);
        engine.depositCollateralAndMintDsc(weth, 100, 0);

        vm.stopPrank();
    }

    ////////////////////////////////////////////////
    // Redeem Collateral for DSC Tests /////////////
    ////////////////////////////////////////////////

    function testRedeemCollateralForDscWorks() public collateralDepositedAndDscMinted {
        uint256 redeemAmount = 1e18; // 1 WETH worth $2000
        uint256 burnAmount = engine.getUsdValue(weth, redeemAmount); // $2000
        uint256 initialWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 initialDscBalance = dsc.balanceOf(USER);

        vm.startPrank(USER);
        dsc.approve(address(engine), burnAmount);
        engine.redeemCollateralForDsc(weth, redeemAmount, burnAmount);
        vm.stopPrank();

        assertEq(ERC20Mock(weth).balanceOf(USER), initialWethBalance + redeemAmount); // User got collateral back
        assertEq(dsc.balanceOf(USER), initialDscBalance - burnAmount); // DSC was burned
    }

    //////////////////////////////////////////
    // Redeem Collateral Tests ///////////////
    //////////////////////////////////////////

    modifier collateralDepositedAndDscMinted() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        uint256 mintAmount = engine.getUsdValue(weth, AMOUNT_COLLATERAL / 3);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, mintAmount); //Deposit 10 ether = $20000, Mint 1 ether = $2000
        vm.stopPrank();
        _;
    }

    function testRedeemCollateralRevertsIfAmountZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__RequiredToBeMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public collateralDepositedAndDscMinted {
        uint256 redeemAmount = 3e18;
        uint256 startingBalance = ERC20Mock(weth).balanceOf(USER);

        vm.startPrank(USER);
        engine.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();

        uint256 newBalance = ERC20Mock(weth).balanceOf(USER);
        (, uint256 newCollateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 remainingCollateral = AMOUNT_COLLATERAL - redeemAmount;
        assertEq(newBalance, startingBalance + redeemAmount);
        assertEq(newCollateralValueInUsd, engine.getUsdValue(weth, remainingCollateral));
    }

    function testRevertsIfRedeemBreaksHealthFactor() public collateralDeposited {
        vm.startPrank(USER);
        // Mint close to max
        uint256 mintAmount = engine.getUsdValue(weth, AMOUNT_COLLATERAL / 2);
        engine.mintDsc(mintAmount);

        uint256 redeemAmount = 4e18;

        // Simulate post-redeem collateral value in USD
        uint256 remainingCollateral = AMOUNT_COLLATERAL - redeemAmount;
        uint256 remainingCollateralUsd = engine.getUsdValue(weth, remainingCollateral);

        // Expected health factor after redeem
        uint256 expectedHealthFactor = engine.calculateHealthFactor(mintAmount, remainingCollateralUsd);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));

        engine.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();
    }

    //////////////////////////////////
    // MintDSC Tests /////////////////
    //////////////////////////////////

    function testMintDscRevertsIfAmountZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__RequiredToBeMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testMintDscRevertsIfHealthFactorIsBroken() public collateralDeposited {
        uint256 mintAmount = engine.getUsdValue(weth, AMOUNT_COLLATERAL / 2);
        vm.startPrank(USER);

        // Drop price of collateral to reduce health factor
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(1e10); // $100 ETH

        // Try to mint too much DSC
        // Dynamically calculate expected health factor after minting
        uint256 collateralInUsd = engine.getAccountCollateralValueInUsd(USER);
        uint256 simulatedHealthFactor = engine.calculateHealthFactor(mintAmount, collateralInUsd);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, simulatedHealthFactor));
        engine.mintDsc(mintAmount); // more than allowed
        vm.stopPrank();
    }

    function testMintsDscSuccessfully() public collateralDeposited {
        uint256 dscAmountToMint = engine.getUsdValue(weth, (AMOUNT_COLLATERAL / 3));
        vm.startBroadcast(USER);
        engine.mintDsc(dscAmountToMint);
        vm.stopBroadcast();
        uint256 mintedDsc = dsc.balanceOf(USER);
        assert(mintedDsc == dscAmountToMint);
    }

    //////////////////////////////////
    // BurnDSC Tests /////////////////
    //////////////////////////////////

    function testBurnDscReducesDebtAndBurnsTokens() public collateralDepositedAndDscMinted {
        // Arrange
        uint256 burnAmount = 0.5 ether;
        uint256 burnAmountInUsd = engine.getUsdValue(weth, burnAmount);
        uint256 initialDscBalance = dsc.balanceOf(USER);

        vm.startPrank(USER);
        dsc.approve(address(engine), burnAmountInUsd);

        // Act
        engine.burnDsc(burnAmountInUsd);
        vm.stopPrank();

        // Assert
        uint256 newDscBalance = dsc.balanceOf(USER);

        assertEq(newDscBalance, initialDscBalance - burnAmountInUsd);
    }

    function testBurnDscEmitsDscBurnedEvent() public collateralDepositedAndDscMinted {
        uint256 burnAmount = 0.5 ether;
        uint256 burnAmountInUsd = engine.getUsdValue(weth, burnAmount);

        vm.prank(USER);
        dsc.approve(address(engine), burnAmountInUsd);

        vm.expectEmit(true, true, false, false);
        emit DSCEngine.DscBurned(USER, burnAmountInUsd);

        vm.prank(USER);
        engine.burnDsc(burnAmountInUsd);
    }

    function testBurnDscRevertsIfZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__RequiredToBeMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    // function test_burnDscFailsIfTransferFromFails() public {
    //     tokenAddresses.push(weth);
    //     tokenAddresses.push(wbtc);

    //     priceFeedAddresses.push(wethUsdPriceFeed);
    //     priceFeedAddresses.push(wbtcUsdPriceFeed);
    //     MockDSC fakeDsc = new MockDSC();
    //     DSCEngine faultyEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(fakeDsc)); // pass mock DSC

    //     // user mints some fake DSC to simulate balance
    //     fakeDsc.mint(USER, 100e18);

    //     vm.startPrank(USER);
    //     fakeDsc.approve(address(faultyEngine), type(uint256).max);

    //     // Should revert due to mocked transferFrom always failing
    //     vm.expectRevert();
    //     faultyEngine.redeemCollateral(weth, 10e18); // or any fn that internally calls _burnDsc
    //     vm.stopPrank();
    // }

    //////////////////////////////////
    // Liquidate Tests ///////////////
    //////////////////////////////////

    function testRevertsIfHealthFactorIsOk() public collateralDepositedAndDscMinted {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, DSC_AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testLiquidatesAndImprovesHealthFactor() public collateralDepositedAndDscMinted {
        // Arrange
        // Drop collateral price by half to make user undercollateralized
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(1e11);

        // Confirm health factor is below threshold
        uint256 healthFactorBefore = engine.getHealthFactor(USER);
        assertLt(healthFactorBefore, engine.getMinimumHealthFactor());

        // Liquidator gets DSC to cover the user’s debt
        (uint256 debtToCover,) = engine.getAccountInformation(USER);
        // Liquidate full debt

        vm.prank(address(engine));
        dsc.mint(LIQUIDATOR, debtToCover);

        //Act
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), debtToCover);
        engine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();

        //Assert: health factor improves and liquidator gets WETH
        uint256 healthFactorAfter = engine.getHealthFactor(USER);
        assertGt(healthFactorAfter, engine.getMinimumHealthFactor());

        uint256 wethReceived = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        assertGt(wethReceived, 0);

        // Confirm protocol's WETH collateral decreased
        uint256 totalWeth = engine.getCollateralAmountForUser(USER, address(weth));
        assertLt(totalWeth, AMOUNT_COLLATERAL);
    }

    function testRevertsIfLiquidatorHasInsufficientDSC() public collateralDepositedAndDscMinted {
        // Drop price
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(1e11);

        uint256 debtToCover = engine.getUsdValue(weth, AMOUNT_COLLATERAL / 3);

        // Liquidator doesn't have DSC
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), debtToCover); // approve but no balance
        vm.expectRevert();
        engine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    //////////////////////////////////
    // Health Factor Tests ///////////
    //////////////////////////////////

    function testHealthFactorIsMaxWhenNoDebt() public collateralDeposited {
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(healthFactor, type(uint256).max);
    }

    function testHealthFactorAboveOneWhenCollateralIsDoubleDebt() public collateralDepositedAndDscMinted {
        uint256 healthFactor = engine.getHealthFactor(USER);
        // With 10 ETH = $20,000 and 1 DSC = $2,000, health factor should be ~5
        assertGt(healthFactor, engine.getMinimumHealthFactor());
    }

    function testHealthFactorDropsBelowOneOnPriceDrop() public collateralDepositedAndDscMinted {
        // Simulate price drop: ETH from $2000 to $500
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(500e8);

        uint256 healthFactor = engine.getHealthFactor(USER);
        assertLt(healthFactor, engine.getMinimumHealthFactor());
    }

    function testCalculateHealthFactorReturnsExpectedValue() public view {
        uint256 hf = engine.calculateHealthFactor(100e18, 400e18); // Should yield 2.0
        // (400 * 50 / 100) * 1e18 / 100 = 2 * 1e18
        assertEq(hf, 2e18);
    }

    function testHealthFactorZeroCollateral() public view {
        uint256 hf = engine.calculateHealthFactor(100e18, 0); // All debt, no collateral
        assertEq(hf, 0);
    }

    /////////////////////////////////////////
    // View and Pure function tests /////////
    /////////////////////////////////////////

    function testGetPriceFeedAddress() public view {
        address actualPriceFeed = engine.getPriceFeedAddress(weth);
        assertEq(wethUsdPriceFeed, actualPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address collateralToken = engine.getCollateralToken(0);
        assertEq(collateralToken, weth);
    }

    function testGetCollateralAmountForUser() public collateralDeposited {
        uint256 amountCollateral = engine.getCollateralAmountForUser(USER, weth);
        assertEq(amountCollateral, AMOUNT_COLLATERAL);
    }

    function testGetDscMintedForUser() public collateralDepositedAndDscMinted {
        uint256 dscMinted = engine.getDscMinted(USER);
        assertEq(dscMinted, engine.getUsdValue(weth, AMOUNT_COLLATERAL / 3));
    }

    function test_getAccountCollateralValueInUsdReturnsCorrectValue() public collateralDeposited {
        uint256 collateralValue = engine.getAccountCollateralValueInUsd(USER);

        assertGt(collateralValue, 0);
    }

    function testGetAdditionalPrecision() public view {
        assertEq(engine.getAdditionalPrecision(), 1e10);
    }

    function testGetPrecision() public view {
        assertEq(engine.getPrecision(), 1e18);
    }

    function testGetLiquidationThreshold() public view {
        assertEq(engine.getLiquidationThreshold(), 50);
    }

    function testGetLiquidationPrecision() public view {
        assertEq(engine.getLiquidationPrecision(), 100);
    }

    function testGetMinHealthFactor() public view {
        assertEq(engine.getMinimumHealthFactor(), 1e18);
    }

    function testGetLiquidationBonus() public view {
        assertEq(engine.getLiquidationBonus(), 10);
    }

    function testCalculateHealthFactorZeroDebt() public view {
        uint256 hf = engine.calculateHealthFactor(0, 1000e18);
        assertEq(hf, type(uint256).max);
    }
}
