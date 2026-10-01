// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PvPadHook} from "../hooks/PvPadHook.sol";
import {PvPadConstants} from "../libraries/PvPadConstants.sol";

/// @notice Minimal CREATE2 salt miner for Uniswap v4 hook permission bits.
/// @dev Local derivation helper. Deployment services must mine against their actual CREATE2
/// deployer, creation bytecode and PoolManager constructor argument.
library HookMiner {
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK;
    uint256 constant MAX_LOOP = 200_000;

    /// @notice Flags PvPadHook requires: 0x08cc (beforeAddLiquidity + swap path + swap return deltas).
    uint160 internal constant PVPAD_HOOK_FLAGS = PvPadConstants.HOOK_FLAGS;

    /// @notice Mines a salt for PvPadHook with its required flags and the given PoolManager argument.
    function findPvPadHook(address deployer, address poolManager)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        return find(deployer, PVPAD_HOOK_FLAGS, type(PvPadHook).creationCode, abi.encode(poolManager));
    }

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        flags = flags & FLAG_MASK;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        for (uint256 i; i < MAX_LOOP; i++) {
            hookAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(i));
            }
        }
        revert("HookMiner: no salt");
    }

    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }
}
