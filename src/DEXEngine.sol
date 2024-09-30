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

pragma solidity ^0.8.24;

import {DEXToken} from "./DEXToken.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";

// check the prices of each token against USD
// create a pool from available pairs

contract DEXEngine is ReentrancyGuard {
    using OracleLib for AggregatorV3Interface;
    using SafeTransferLib for ERC20;

    error DEXEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DEXEngine__TransferFailed();
    error DEXEngine__ToleranceLevelBreached(); // this means the values are apart by a wide range
    error DEXEngine__MintFailed();

    struct Pool {
        uint256 reserveTokenA; // how much is in the reserve of the first token
        uint256 reserveTokenB; // reserve for the second token
        uint256 totalSupplyOfLpTokens; // total supply of the lpTokens based on the reserve
        mapping(address lp => uint256 amount) tokenBalanceOfLp; // address of each liquidity provider to amount
    }

    // now we want to create a mapping of liquidity pools
    mapping(address tokenAAddress => mapping(address tokenBAddress => Pool pool)) liquidityPools;

    uint256 constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 constant PRECISION = 1e18;

    DEXToken private immutable i_dexToken;
    mapping(address tokenAddress => address priceFeedAdress) private s_priceFeeds;

    event LiquidityAdded(address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB);

    modifier tokensDifferenceChecker(address tokenA, address tokenB) {
        require(tokenA != tokenB, "Tokens must be different");
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dexTokenAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DEXEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }

        i_dexToken = DEXToken(dexTokenAddress);
    }
    
    /**
     *
     * @param tokenAAddress first token in the liquidity pool pair
     * @param tokenBAddress second token in the liquidity pool pair
     * @param amountA amount to deposit in the first token
     * @param amountB amount to deposit to the second token
     * @notice this function will deposit users collateral and mint LP tokens for the user
     */


    function depositLiquidity(address tokenAAddress, address tokenBAddress, uint256 amountA, uint256 amountB)
        public
        tokensDifferenceChecker(tokenAAddress, tokenBAddress)
        nonReentrant
    {

        (tokenAAddress, tokenBAddress, amountA, amountB) = _orderTokensLexicographically(tokenAAddress, tokenBAddress, amountA, amountB);

        uint256 valueA = getUsdValueOfToken(tokenAAddress, amountA);
        uint256 valueB = getUsdValueOfToken(tokenBAddress, amountB);

        if (valueA <= valueB * 99 / 100 || valueA >= valueB * 101 / 100) revert DEXEngine__ToleranceLevelBreached();

        Pool storage pool = liquidityPools[tokenAAddress][tokenBAddress];
        pool.reserveTokenA += amountA;
        pool.reserveTokenB += amountB;
        uint256 poolBalance = getPoolValueInUsd(tokenAAddress, tokenBAddress);
        uint256 amountOfTokensDepositedByLpInUsd = valueA + valueB;
        pool.totalSupplyOfLpTokens = i_dexToken.totalSupply();

        if (pool.totalSupplyOfLpTokens == 0) {
            // mint dextoken for user and update the state
            mintDEXToken(amountOfTokensDepositedByLpInUsd);
            pool.tokenBalanceOfLp[msg.sender] += amountOfTokensDepositedByLpInUsd;
        } else {
            uint256 lpToken = (amountOfTokensDepositedByLpInUsd * pool.totalSupplyOfLpTokens) / poolBalance;
            mintDEXToken(lpToken);
            pool.tokenBalanceOfLp[msg.sender] += lpToken;
        }

        ERC20 tokenA = ERC20(tokenAAddress);
        ERC20 tokenB = ERC20(tokenAAddress);

        tokenA.safeTransferFrom(msg.sender, address(this), amountA); 
        tokenB.safeTransferFrom(msg.sender, address(this), amountB); 

        emit LiquidityAdded(tokenAAddress, tokenBAddress, amountA, amountB);
    }

    function mintDEXToken(uint256 amountDscToMint) internal nonReentrant {
        bool minted = i_dexToken.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DEXEngine__MintFailed();
        }
    }
    /**
     * @notice we want a situation where we want to check if the user has lp tokens 
     * the user also gets an allocation proportional to his lp token
     * burns the user's lp token
     * 
     */

    function withdrawLiquidity() public nonReentrant {

    }

    // this will return in e18
    function getUsdValueOfToken(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]); // get the priceFeed of the token via chainlink
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getPoolValueInUsd(address tokenA, address tokenB) public view returns (uint256) {
    // Convert each reserve to USD using Chainlink price feeds
    uint256 reserveAInUsd = getUsdValueOfToken(tokenA, liquidityPools[tokenA][tokenB].reserveTokenA);
    uint256 reserveBInUsd = getUsdValueOfToken(tokenB, liquidityPools[tokenA][tokenB].reserveTokenB);

    // Sum the USD values to get the total pool value
    uint256 totalPoolValueInUsd = reserveAInUsd + reserveBInUsd;
    return totalPoolValueInUsd;
    }

    function getTotalSupplyOfLpTokensInAPool() public view returns (uint256) {

    }

    function _orderTokensLexicographically(address tokenA, address tokenB, uint256 amountA, uint256 amountB) private pure returns (address tokenAAddress, address tokenBAddress, uint256 tokenAAmount, uint256 tokenBAmount) {
        if (tokenA > tokenB) {
          (tokenA, tokenB) = (tokenB, tokenA);  // Swap the tokens if they are out of order
          (amountA, amountB) = (amountB, amountA);  // Swap the amounts to match the tokens
          return (tokenA, tokenB, amountA, amountB);
        }
    }
}
