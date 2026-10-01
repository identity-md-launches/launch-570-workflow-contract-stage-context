// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title PvPadConstants
/// @notice Frozen economic and curve defaults (see SPEC.md).
library PvPadConstants {
    uint256 internal constant FEE_BPS = 100; // 1%
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant KING_CREATOR_SPLIT_BPS = 5_000; // 50% each

    uint256 internal constant DEFAULT_LAUNCH_FEE = 0.0005 ether;
    uint256 internal constant GRADUATION_THRESHOLD = 4.2 ether;

    uint256 internal constant INITIAL_CLAIM_PRICE = 0.01 ether;
    uint256 internal constant KING_BUMP_BPS = 1_000; // +10%

    uint256 internal constant TOKEN_SUPPLY = 1_000_000_000 * 1e18; // 1e27

    /// @dev Virtual reserves (constant-product x*y=k). See README curve section.
    uint256 internal constant VIRTUAL_ETH = 2.1 ether;
    uint256 internal constant VIRTUAL_TOKEN = TOKEN_SUPPLY / 8;

    uint24 internal constant POOL_FEE = 0; // pad fee via hook only
    int24 internal constant POOL_TICK_SPACING = 60;

    /// @dev Shared hook address flags, 0x08cc: beforeAddLiquidity (pre-graduation liquidity gate),
    /// beforeSwap, afterSwap and both swap return deltas. beforeInitialize is deliberately absent.
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint256 internal constant MAX_EPOCH_WINDOW = 90 days;
}
