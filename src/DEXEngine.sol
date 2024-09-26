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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// check the prices of each token against USD
// create a pool from available pairs

contract DEXEngine is ReentrancyGuard {
    using OracleLib for AggregatorV3Interface;

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
    mapping(address tokenAddresses => address priceFeedAdresses) private s_priceFeeds;

    event LiquidityAdded(
        address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB, uint256 liquidity
    );

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
     * @param tokenA first token in the liquidity pool pair
     * @param tokenB second token in the liquidity pool pair
     * @param amountA amount to deposit in the first token
     * @param amountB amount to deposit to the second token
     * @notice this function will deposit users collateral and mint LP tokens for the user
     */

    function depositLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB)
        public
        tokensDifferenceChecker(tokenA, tokenB)
        nonReentrant
    {
        uint256 valueA = getUsdValueOfToken(tokenA, amountA);
        uint256 valueB = getUsdValueOfToken(tokenB, amountB);

        if (valueA <= valueB * 99 / 100 && valueA >= valueB * 101 / 100) revert DEXEngine__ToleranceLevelBreached();
        bool successA = IERC20(tokenA).transferFrom(msg.sender, address(this), valueA); // here, we are transferring "amountCollateral" from msg.sender to "this" address
        bool successB = IERC20(tokenB).transferFrom(msg.sender, address(this), valueB); // here, we are transferring "amountCollateral" from msg.sender to "this" address

        if (!successA || !successB) {
            revert DEXEngine__TransferFailed();
        }

        Pool storage pool = liquidityPools[tokenA][tokenB];
        pool.reserveTokenA += amountA;
        pool.reserveTokenB += amountB;
        uint256 poolBalance = pool.reserveTokenA + pool.reserveTokenB;
        uint256 amountOfTokenDepositedByLp = amountA + amountB;
        pool.totalSupplyOfLpTokens = i_dexToken.totalSupply();

        if (pool.totalSupplyOfLpTokens == 0) {
            // mint dextoken for user and update the state
            mintDEXToken(poolBalance);
            pool.tokenBalanceOfLp[msg.sender] += poolBalance;
        } else {
            uint256 lpToken = (amountOfTokenDepositedByLp * pool.totalSupplyOfLpTokens) / poolBalance;
            mintDEXToken(lpToken);
            pool.tokenBalanceOfLp[msg.sender] += poolBalance;
        }
    }

    function mintDEXToken(uint256 amountDscToMint) public nonReentrant {
        bool minted = i_dexToken.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DEXEngine__MintFailed();
        }
    }

    function getUsdValueOfToken(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]); // get the priceFeed of the token via chainlink
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
