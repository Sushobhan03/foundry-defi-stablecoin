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

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Sushobhan Pathare
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all the collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 *
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////////////
    /// Errors //////////////
    /////////////////////////
    error DSCEngine__RequiredToBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__DSCMintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////////
    /// Types ///////////////
    /////////////////////////

    using OracleLib for AggregatorV3Interface;

    //////////////////////////////
    /// State Variables //////////
    /////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // This means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPricefeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscAmountMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////////
    /// Events ///////////////////
    /////////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    event DscBurned(address indexed user, uint256 indexed amount);

    //////////////////////////////
    /// Modifiers ////////////////
    /////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__RequiredToBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    //////////////////////////////
    /// Functions ////////////////
    /////////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Pricefeeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    //** External Functions *///
    ////////////////////////////

    /// @param tokenCollateralAddress The address of the token to be deposited as collateral
    /// @param amountCollateral The amount of collateral to be deposited
    /// @param dscAmountToMint The amount of decentralized stable coin to mint
    /// @notice This function will deposit your collateral and mint DSC in one transaction
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 dscAmountToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(dscAmountToMint);
    }

    /// @notice follows CEI
    /// @param tokenCollateralAddress The Address of the token to be deposited as collateral
    /// @param amountCollateral The amount of token to be deposited as collateral.
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /// @param tokenCollateralAddress The collateral address to be redeemed
    /// @param amountCollateral The amount of collateral to be redeemed
    /// @param amountDscToBurn The amount of DSC to be burned
    /// @notice This function burns DSC and redeems underlying collateral in a single transaction.
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral already checks Health Factor
    }

    /// @notice In order to redeem collateral:
    /// @notice 1. Health factor needs to be above 1 after the collateral gets redeemed
    /// @param tokenCollateralAddress The collateral address to be redeemed
    /// @param amountCollateral The amount of collateral to be redeemed
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /// @notice Follows CEI
    /// @param dscAmountToMint The amount of decentralized Stablecoin to mint
    /// @notice They must have more collateral value than the minimum threshold
    function mintDsc(uint256 dscAmountToMint) public moreThanZero(dscAmountToMint) nonReentrant {
        s_DSCMinted[msg.sender] += dscAmountToMint;
        //if they minted too much DSC ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, dscAmountToMint);
        if (!minted) {
            revert DSCEngine__DSCMintFailed();
        }
    }

    /// @notice Burns the given amount of DSC
    /// @param amountDscToBurn Amount of DSC to burn
    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think we hit this..
    }

    /// @notice If a user starts to approach undercollateralization, they get liquidated automatically
    /// @notice Liquidator takes the collateral and burns off the DSC
    /// @param tokenCollateralAddress The ERC20 address of the collateral that is supposed to be liquidated.
    /// @param user The user who's health factor is broken. The _healthFactor should be below than the MIN_HEALTH_FACTOR
    /// @param debtToCover The amount to DSC required to be burned in order to improve the user's health factor
    /// @notice You can partially liquidate a user
    /// @notice You will get a liquidation bonus for taking the user's funds
    /// @notice This function working assumes the protocol will be roughly 200% overcollateralised in order for this mechanism to work
    /// @notice A known bug would be if the protocol were 100% or less collateralised, then we wouldn't be able to incentive the liquidators
    /// For example, if the price of the collateral plummeted before anyone could be liquidated
    /// Folows, CEI: Checks, Effects, Interactions
    function liquidate(address tokenCollateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        //Burn their DSC (debt)
        //Take away their collateral
        //Bad user: $140ETH, $100DSC
        //debtToCover = $100
        //$100 of DSC == 0.05ETH (ETH price == $2000)

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(tokenCollateralAddress, debtToCover);
        // Also provide them with a 10% bonus
        // 0.05ETH * 0.1 = 0.005ETH
        // 0.055ETH
        // We give the liquidator $110 WETH for $100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(tokenCollateralAddress, totalCollateralToRedeem, user, msg.sender);

        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////////////////////////////
    //** Private & Internal View functions *///
    ///////////////////////////////////////////

    /// @dev Low-level internal function. Do not call unless the function calling it
    /// is checking for health factors being broken
    /// @param amountDscToBurn Amount of DSC to burn
    /// @param onBehalfOf The user who's DSC we are burning
    /// @param dscFrom The user from whom we are getting the DSC, in order to burn it
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        emit DscBurned(onBehalfOf, amountDscToBurn);
        //Here instead of burning DSC directly from the user's balance we transfer it to the DSC smart contract and then burn it.
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    /// @notice Redeems the deposited collateral
    /// @param tokenCollateralAddress Token address of the collateral
    /// @param amountCollateral Amount of collateral to be redeemed
    /// @param from User whose collaterall is to be redeemed
    /// @param to Address to which the collateral gets sent
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /// @notice Returns how close to liquidation the user is.
    /// If a user goes below 1, then they could get liquidated.
    /// totalDscMinted : Total DSC minted by any particular user
    /// totalCollateralValueInUsd : Total Collateral value deposited by any particular user
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, totalCollateralValueInUsd);
    }

    /// @notice 1. Checks if the user has a good health factor(i.e. they have enough collateral)
    /// @notice 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////////
    //** Public & External View functions *////
    ///////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // ($10e18 * 1e18) / ($2000 * 1e10)
        return (usdAmountInWei * PRECISION / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    /// @notice Loop through each collateral token, get the amount they have deposited and
    /// map it to the price, to get the USD value
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /// @param token The token address whose USD value we want to find out
    /// @param amount The amount of token
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //The returned value by Chainlink will be (ETH price)*1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // So, if $150 ETH, 150 * 50 = 7500 / 100 = 75
        // 75 / 100 DSC < 1 (not approved)
        // But, for $1000 ETH, 1000 * 50 = 50000 / 100 = 500
        // 500 / 100 DSC > 1 (approved)
        // Hence, for $150 ETH we can only mint upto $75 of DSC
        // So, double collateral is required
        // ✅ Defensive: if no debt, health factor is "infinite"

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        // Since the 1e18 coefficient of @collateralAdjustedForThreshold gets cancelled out by the 1e18 coefficient of @totalDscMinted we multiply an extra @PRECISION to maintain the unit
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        (totalDscMinted, totalCollateralValueInUsd) = _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAdditionalPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinimumHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getPriceFeedAddress(address token) public view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralToken(uint256 index) public view returns (address) {
        return s_collateralTokens[index];
    }

    function getAllCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralAmountForUser(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDscMinted(address user) external view returns (uint256) {
        return s_DSCMinted[user];
    }
}
