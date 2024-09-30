// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
//the ERC20Burnable contract is an ERC20 which is why we can import ERC20 from it as well
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
* @title DEXToken
* @author Olasunkanmi Balogun
* Minting: Algorithmic
* Relative Stability: Pegged to collateral provided to the pool
*
* This is the contract meant to be governed by DEXEngine. This contract is just the ERC20 implementation of our token.
*/
contract DEXToken is ERC20Burnable, Ownable {
    //ERC20Burnable has a burn function that will help us maintain the peg price when we burn tokens
    error DEXToken__MustBeMoreThanZero();
    error DEXToken__BurnAmountExceedsBalance();
    error DEXToken__NotZeroAddress();

    constructor() ERC20("DEXToken", "DEXT") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DEXToken__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DEXToken__BurnAmountExceedsBalance();
        }
        super.burn(_amount); //the super keyword says it should utilize the original burn function
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DEXToken__NotZeroAddress(); // do not send to the zeroeth address
        }
        if (_amount <= 0) {
            revert DEXToken__MustBeMoreThanZero();
        }
        _mint(_to, _amount); // we can call this directly, because we didnt initially override the _mint function (ok, but why didnt we override this function)
        return true;
    }
}
