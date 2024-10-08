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
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    error DEXEngine__NeedsMoreThanZero();
    error DEXEngine__TransferFailed();
    error DEXEngine__ToleranceLevelBreached(); // this means the values are apart by a wide range
    error DEXEngine__MintFailed();
    error DEXEngine__PoolDoesNotExists();
    error DEXEngine__NeedsMoreThanZeroLpTokens();

    struct Pool {
        uint256 baseTokenReserve; // how much is in the reserve of the first token
        uint256 quoteTokenReserve; // reserve for the second token
        uint256 totalSupplyOfLpTokens; // total supply of the lpTokens based on the reserve (thia would be in usd value?)
        mapping(address lp => uint256 amount) tokenBalanceOfLp; // address of each liquidity provider to amount
    }

    address[] s_baseTokens;
    address s_quoteToken;

    mapping(address quoteToken => address priceFeedAddress) s_quoteTokenPrice;
    mapping(address baseToken => address priceFeedAddress) private s_baseTokenPrice;
    mapping(address baseToken => address quoteToken) liquidityPools;
    // now we want to create a mapping of liquidity pools
    mapping(address tokenAAddress => mapping(address tokenBAddress => Pool pool)) liquidityPoolInfo;

    uint256 constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 constant PRECISION = 1e18;

    DEXToken private immutable i_dexToken;
    address[] s_tokenAddresses;

    event LiquidityAdded(address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB);

    modifier moreThanZero(uint256 amountA, uint256 amountB) {
        if (amountA == 0 || amountB == 0) {
            revert DEXEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier poolExists(address baseToken) {
        bool exists = false;
        for (uint256 i = 0; i < s_baseTokens.length; i++) {
            if (s_baseTokens[i] == baseToken) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            revert DEXEngine__PoolDoesNotExists(); // Revert if the pool doesn't exist
        }
        _;
    }

    modifier moreThanZeroLpTokens(address baseToken) {
        Pool storage pool = liquidityPoolInfo[baseToken][s_quoteToken];
        if(pool.tokenBalanceOfLp[msg.sender] <= 0) revert DEXEngine__NeedsMoreThanZeroLpTokens();
        _;
    }

    constructor( 
        address[] memory baseTokens,
        address[] memory baseTokenPriceFeedAddresses,
        address quoteToken,
        address quoteTokenPriceFeedAddress,
        address dexTokenAddress
    ) {
        if (baseTokens.length != baseTokenPriceFeedAddresses.length) {
            revert DEXEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        s_quoteToken = quoteToken;
        s_quoteTokenPrice[s_quoteToken] = quoteTokenPriceFeedAddress; // map the quoteToken to its price feed

        for (uint256 i = 0; i < baseTokens.length; i++) {
            s_baseTokens.push(baseTokens[i]); //list of baseTokens addresses
            liquidityPools[baseTokens[i]] = s_quoteToken; //create a pool by mapping them to the quoteToken
            s_baseTokenPrice[baseTokens[i]] = baseTokenPriceFeedAddresses[i]; //
        }

        i_dexToken = DEXToken(dexTokenAddress);
    }

    /**
     *
     * @param baseToken address of the base token
     * @param baseTokenAmount amount to deposit in the first token
     * @param quoteTokenAmount amount to deposit to the second token
     * @notice this function will deposit users collateral and mint LP tokens for the user
     */
    function depositLiquidity(address baseToken, uint256 baseTokenAmount, uint256 quoteTokenAmount)
        public
        moreThanZero(baseTokenAmount, quoteTokenAmount)
        poolExists(baseToken)
        nonReentrant
    {
        uint256 valueA = getUsdValueOfBaseTokenDonated(baseToken, baseTokenAmount);
        uint256 valueB = getUsdValueOfQuoteTokenDonated(quoteTokenAmount);

        if (valueA <= valueB * 99 / 100 || valueA >= valueB * 101 / 100) revert DEXEngine__ToleranceLevelBreached();

        Pool storage pool = liquidityPoolInfo[baseToken][s_quoteToken];
        pool.baseTokenReserve += baseTokenAmount;
        pool.quoteTokenReserve += quoteTokenAmount;
        (,,uint256 poolBalance) = getPoolValuesInUsd(baseToken);
        uint256 amountOfTokensDepositedByLpInUsd = valueA + valueB;
        pool.totalSupplyOfLpTokens = i_dexToken.totalSupply(); // this will be in wei, right?

        if (pool.totalSupplyOfLpTokens == 0) {
            // mint dextoken for user and update the state
            _mintDEXToken(amountOfTokensDepositedByLpInUsd);
            pool.tokenBalanceOfLp[msg.sender] += amountOfTokensDepositedByLpInUsd;
        } else {
            uint256 lpToken = (amountOfTokensDepositedByLpInUsd * pool.totalSupplyOfLpTokens) / poolBalance;
            _mintDEXToken(lpToken);
            pool.tokenBalanceOfLp[msg.sender] += lpToken;
        }

        ERC20 erc20baseToken = ERC20(baseToken);
        ERC20 erc20quoteToken = ERC20(s_quoteToken);

        erc20baseToken.safeTransferFrom(msg.sender, address(this), baseTokenAmount);
        erc20quoteToken.safeTransferFrom(msg.sender, address(this), quoteTokenAmount);

        emit LiquidityAdded(baseToken, s_quoteToken, baseTokenAmount, quoteTokenAmount);
    }

    function _mintDEXToken(uint256 amountDscToMint) private nonReentrant {
        bool minted = i_dexToken.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DEXEngine__MintFailed();
        }
    }
    /**
     * @param baseToken it's already in usd value
     * @param amount amount of lpTokens to burn 
     * @notice we want a situation where we want to check if the user has lp tokens
     * the user also gets an allocation proportional to his lp token
     * burns the user's lp token
     *
     */

    function withdrawLiquidity(address baseToken, uint256 amount) public moreThanZeroLpTokens(baseToken) nonReentrant {
         Pool storage pool = liquidityPoolInfo[baseToken][s_quoteToken];
        // convert the reserve tokens to dollar
        (uint256 baseTokenReserveInUsd, uint256 quoteTokenReserveInUsd, uint256 totalPoolBalance) = getPoolValuesInUsd(baseToken);
        pool.totalSupplyOfLpTokens = i_dexToken.totalSupply();
        //  get the fraction of the users lptoken to the total
        uint256 userLpTokensProportion = amount/ pool.totalSupplyOfLpTokens;
        // send proportion of each token to the user and burn 
        // update the lptoken of the user in the pool struct 
        // after calculating the token amount in dollar to return to the lp, convert the amount back to how many token it is, dyg?
    }

    // this will return in e18
    function getUsdValueOfBaseTokenDonated(address baseToken, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_baseTokenPrice[baseToken]); // get the priceFeed of the token via chainlink
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    // this will return in e18
    function getUsdValueOfQuoteTokenDonated(uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_quoteTokenPrice[s_quoteToken]); // get the priceFeed of the token via chainlink
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getPoolValuesInUsd(address baseToken) public returns (uint256, uint256, uint256) {
        Pool storage pool = liquidityPoolInfo[baseToken][s_quoteToken];
        pool.totalSupplyOfLpTokens = i_dexToken.totalSupply();
        // Convert each reserve to USD using Chainlink price feeds
        uint256 baseTokenReserveInUsd =
            getUsdValueOfBaseTokenDonated(baseToken, pool.baseTokenReserve);
        uint256 quoteTokenReserveInUsd =
            getUsdValueOfQuoteTokenDonated(pool.quoteTokenReserve);

        // Sum the USD values to get the total pool value
        uint256 totalPoolValueInUsd = baseTokenReserveInUsd + quoteTokenReserveInUsd;
        return (baseTokenReserveInUsd, quoteTokenReserveInUsd, totalPoolValueInUsd);
    }
    
    function getPoolInfo(address baseToken) internal view {
        Pool storage pool = liquidityPoolInfo[baseToken][s_quoteToken];
    } 

    function getTotalSupplyOfLpTokensInAPool() public view returns (uint256) {}
}
