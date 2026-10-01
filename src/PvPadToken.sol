// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";

/// @notice Fixed-supply launch token. Minted to factory caller; transferred to curve at create.
contract PvPadToken is ERC20 {
    address public immutable factory;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        factory = msg.sender;
        _mint(msg.sender, PvPadConstants.TOKEN_SUPPLY);
    }
}
