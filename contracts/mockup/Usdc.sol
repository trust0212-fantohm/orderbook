// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.18;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USDC is ERC20 {
    constructor() ERC20("USDC Token", "USDC") {}

    function mint(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
