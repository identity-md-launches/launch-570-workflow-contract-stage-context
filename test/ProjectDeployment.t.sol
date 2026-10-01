// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {PvPadToken} from "../src/PvPadToken.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {PvPadHook} from "../src/hooks/PvPadHook.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {MineHookSalt} from "../script/MineHookSalt.s.sol";

/// @dev Local service-factory stand-in. Never broadcasts, reads keys or changes the environment.
contract LocalProjectDeployer {
    address private immutable controller = msg.sender;

    error Unauthorized();
    error DeploymentFailed();

    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        if (msg.sender != controller) revert Unauthorized();
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed();
    }
}

/// @notice Exercises constructor-only deployment through a separate CREATE2 factory, like the
/// protected floor, with a real local PoolManager and explicit roles different from the deployer.
contract ProjectDeploymentTest is Test {
    LocalProjectDeployer service;
    PoolManager manager;
    LaunchToken protocolToken;
    WorkerSubsidy workers;
    KingOfThePad king;
    PvPadHook hook;
    address constant UPDATER = address(0xA11CE);
    address constant GENESIS_CREATOR = address(0xC0FFEE);

    function setUp() public {
        service = new LocalProjectDeployer();
        manager = new PoolManager(address(this));
        protocolToken = LaunchToken(service.deploy(type(LaunchToken).creationCode, bytes32(uint256(1))));
        _assertProtocolSupply();
        workers = WorkerSubsidy(
            payable(service.deploy(
                    abi.encodePacked(type(WorkerSubsidy).creationCode, abi.encode(UPDATER)), bytes32(uint256(2))
                ))
        );
        _assertProtocolSupply();
        king = KingOfThePad(
            service.deploy(abi.encodePacked(type(KingOfThePad).creationCode, abi.encode(workers)), bytes32(uint256(3)))
        );
        _assertProtocolSupply();
        (address predicted, bytes32 salt) = HookMiner.findPvPadHook(address(service), address(manager));
        hook = PvPadHook(
            payable(service.deploy(abi.encodePacked(type(PvPadHook).creationCode, abi.encode(manager)), salt))
        );
        assertEq(address(hook), predicted);
        assertEq(uint160(address(hook)) & 0x3fff, 0x08cc);
        _assertProtocolSupply();
    }

    /// @dev The offline evidence script derives exactly the salt, init-code hash and address that the
    /// service deployer needs; an unmined salt cannot construct the hook at all.
    function test_mineHookSaltScriptMatchesTheDeployedHookAndUnminedSaltsFail() public {
        // Evidence is derived before anything is deployed from this deployer, as the service would.
        LocalProjectDeployer fresh = new LocalProjectDeployer();
        MineHookSalt.Evidence memory evidence = new MineHookSalt().mine(address(fresh), address(manager));
        bytes memory initCode = abi.encodePacked(type(PvPadHook).creationCode, abi.encode(manager));
        assertEq(evidence.initCodeHash, keccak256(initCode));
        assertEq(evidence.flags, 0x08cc);
        assertEq(HookMiner.computeAddress(address(fresh), uint256(evidence.salt), initCode), evidence.hook);
        for (uint256 salt = 1000; salt < 1008; ++salt) {
            if (salt == uint256(evidence.salt)) continue;
            vm.expectRevert(LocalProjectDeployer.DeploymentFailed.selector);
            fresh.deploy(initCode, bytes32(salt));
        }
        address deployed = fresh.deploy(initCode, evidence.salt);
        assertEq(deployed, evidence.hook);
        assertEq(address(PvPadHook(payable(deployed)).poolManager()), address(manager));
        _assertProtocolSupply();
    }

    function test_constructorOnlyCreate2DeploymentConfiguresGenesisAndSecondLaunch() public {
        bytes memory initCode = _factoryCode(workers);
        // EIP-3860 applies to the complete init code including static constructor arguments.
        assertLe(initCode.length, 49_152);
        address predicted = HookMiner.computeAddress(address(service), 4, initCode);
        PvPadFactory pad = PvPadFactory(payable(service.deploy(initCode, bytes32(uint256(4)))));
        assertEq(address(pad), predicted);
        assertEq(workers.updater(), UPDATER);
        assertEq(address(king.workerSubsidy()), address(workers));
        assertEq(pad.feeEscrow().factory(), address(pad));
        assertEq(pad.launchCount(), 1);
        assertEq(workers.workerPot(), 0, "genesis has no create fee");
        (address creator, address token, address curve, bool graduated,) = pad.launches(0);
        assertEq(creator, GENESIS_CREATOR);
        assertEq(PvPadToken(token).factory(), address(pad));
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        assertEq(PvPadToken(token).balanceOf(GENESIS_CREATOR), 0);
        assertEq(PvPadToken(token).name(), "Pepe Values Pepe");
        assertEq(PvPadToken(token).symbol(), "PVP");
        assertFalse(graduated);
        assertTrue(pad.feeEscrow().authorizedRecorders(curve));
        assertTrue(pad.feeEscrow().authorizedRecorders(address(hook)));
        _assertProtocolSupply();

        // The operational role comes from the constructor argument, never the service caller.
        vm.deal(address(this), 10 ether);
        workers.fundWorkers{value: 1 ether}();
        bytes32 root = workers.leaf(1, UPDATER, 1 ether);
        vm.prank(address(service));
        vm.expectRevert(WorkerSubsidy.NotUpdater.selector);
        workers.setEpoch(root, block.timestamp, block.timestamp + 1 days);
        vm.prank(UPDATER);
        workers.setEpoch(root, block.timestamp, block.timestamp + 1 days);

        address secondCreator = address(0xB0B);
        vm.deal(secondCreator, 1 ether);
        vm.prank(secondCreator);
        uint256 id = pad.createLaunch{value: 0.0005 ether}("Second", "TWO");
        assertEq(id, 1);
        assertEq(workers.workerPot(), 0.0005 ether);
        (address secondOwner, address secondToken, address secondCurve,,) = pad.launches(id);
        assertEq(secondOwner, secondCreator);
        assertNotEq(secondToken, token);
        assertEq(PvPadToken(secondToken).balanceOf(secondCurve), 1e27);
        BondingCurve(payable(secondCurve)).buy{value: 5 ether}(address(this), 1, block.timestamp);
        pad.graduate(id);
        assertGt(pad.lockedLiquidity(id), 0);
        assertEq(pad.lockedTickLower(id), -887220);
        assertEq(pad.lockedTickUpper(id), 887220);
        _assertProtocolSupply();
    }

    function test_miswiredConstructorFailsWithoutMovingSupplyAndSameSaltCanRetry() public {
        WorkerSubsidy otherWorkers = new WorkerSubsidy(UPDATER);
        bytes memory invalidCode = _factoryCode(otherWorkers);
        address predicted = HookMiner.computeAddress(address(service), 4, invalidCode);
        vm.expectRevert(LocalProjectDeployer.DeploymentFailed.selector);
        service.deploy(invalidCode, bytes32(uint256(4)));
        assertEq(predicted.code.length, 0);
        assertEq(workers.workerPot(), 0);
        _assertProtocolSupply();

        PvPadFactory pad = PvPadFactory(payable(service.deploy(_factoryCode(workers), bytes32(uint256(4)))));
        assertEq(pad.launchCount(), 1);
        _assertProtocolSupply();
    }

    function _factoryCode(WorkerSubsidy pot) private view returns (bytes memory) {
        return abi.encodePacked(type(PvPadFactory).creationCode, abi.encode(manager, pot, king, hook, GENESIS_CREATOR));
    }

    function _assertProtocolSupply() private view {
        assertEq(protocolToken.totalSupply(), 1e27);
        assertEq(protocolToken.decimals(), 18);
        assertEq(protocolToken.balanceOf(address(service)), 1e27);
    }

    receive() external payable {}
}
