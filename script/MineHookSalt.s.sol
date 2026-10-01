// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PvPadHook} from "../src/hooks/PvPadHook.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @notice Offline evidence generator for the PvPadHook CREATE2 salt. It reads no environment
/// variables, holds no keys and broadcasts nothing; it only derives, for the deployer that will
/// actually run CREATE2 and the target chain's PoolManager, the salt whose predicted address
/// carries the 0x08cc permission bits the hook constructor enforces.
///
///   forge script script/MineHookSalt.s.sol --sig "mine(address,address)" <deployer> <poolManager>
///
/// The init-code hash printed here must match the attested creation bytes plus the ABI-encoded
/// PoolManager argument; a different compiler setting, source revision or PoolManager invalidates
/// the salt. Any salt yielding different address flags reverts `HookAddressNotValid`.
contract MineHookSalt is Script {
    struct Evidence {
        address deployer;
        address poolManager;
        bytes32 initCodeHash;
        bytes32 salt;
        address hook;
        uint160 flags;
    }

    function mine(address deployer, address poolManager) public view returns (Evidence memory evidence) {
        bytes memory initCode = abi.encodePacked(type(PvPadHook).creationCode, abi.encode(poolManager));
        (address predicted, bytes32 salt) = HookMiner.findPvPadHook(deployer, poolManager);
        evidence = Evidence({
            deployer: deployer,
            poolManager: poolManager,
            initCodeHash: keccak256(initCode),
            salt: salt,
            hook: predicted,
            flags: uint160(predicted) & Hooks.ALL_HOOK_MASK
        });
        console2.log("PvPadHook CREATE2 evidence");
        console2.log("  deployer       ", deployer);
        console2.log("  poolManager    ", poolManager);
        console2.log("  initCodeHash   ", vm.toString(evidence.initCodeHash));
        console2.log("  salt           ", vm.toString(salt));
        console2.log("  predicted hook ", predicted);
        console2.log("  address flags  ", evidence.flags);
    }
}
