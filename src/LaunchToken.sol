// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Protocol launch artifact; distinct from the pad's curve-funded genesis token.
contract LaunchToken is ERC20 {
    constructor() ERC20("Pepe Values Pepe", "PVP") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
