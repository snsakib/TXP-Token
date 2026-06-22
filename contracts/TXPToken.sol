// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TXPToken is ERC20, ERC20Burnable, Ownable {
    constructor(address initialOwner)
        ERC20("Triple X POS Token", "TXP")
        Ownable(initialOwner)
    {
        _mint(initialOwner, 1000000000 * 10 ** decimals());
    }
}
