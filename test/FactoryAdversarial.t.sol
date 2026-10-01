// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PvPadFactory} from "src/PvPadFactory.sol";
import {PvPadToken} from "src/PvPadToken.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {PvPadHook, IPvPadLaunchRegistry} from "src/hooks/PvPadHook.sol";
import {WorkerSubsidy} from "src/WorkerSubsidy.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";
import {HookMiner} from "src/utils/HookMiner.sol";

contract FactoryAdversarialTest is Test {
    using PoolIdLibrary for PoolKey;
    PoolManager internal manager;
    WorkerSubsidy internal workers;
    KingOfThePad internal king;
    PvPadHook internal hook;
    PvPadFactory internal factory;
    address internal creator = address(0xC0FFEE);
    uint256 internal constant FEE = 0.0005 ether;

    function setUp() public {
        manager = new PoolManager(address(this));
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        hook = new PvPadHook{salt: salt}(manager);
        factory = new PvPadFactory(manager, workers, king, hook, creator);
        vm.deal(creator, 100 ether);
    }

    function test_failedWorkerFundingRollsBackEntireLaunchAndSameSaltCanRetry() public {
        string memory name = "Atomic";
        string memory symbol = "ATM";
        bytes32 userSalt = keccak256("retry identical inputs");
        address predicted;
        {
            bytes32 salt = keccak256(abi.encode(uint256(1), creator, name, symbol, userSalt));
            bytes32 initHash = keccak256(abi.encodePacked(type(PvPadToken).creationCode, abi.encode(name, symbol)));
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash)))));
        }
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(predicted), 0, 60, IHooks(address(hook)));
        PoolId id = key.toId();
        uint256 balanceBefore = creator.balance;

        vm.mockCallRevert(address(workers), abi.encodeCall(WorkerSubsidy.fundWorkers, ()), hex"deadbeef");
        vm.expectRevert(bytes4(0xdeadbeef));
        vm.prank(creator);
        factory.createLaunch{value: FEE}(name, symbol, userSalt, "ipfs://atomic");

        assertEq(factory.launchCount(), 1);
        assertEq(factory.launchMetadataURI(1), "");
        assertEq(factory.poolCreator(id), address(0));
        assertFalse(factory.registeredPool(id));
        assertEq(predicted.code.length, 0);
        assertEq(creator.balance, balanceBefore);
        assertEq(address(factory).balance, 0);
        assertEq(address(workers).balance, 0);
        assertEq(workers.workerPot(), 0);
        {
            (IPvPadLaunchRegistry registry, FeeEscrow boundEscrow, address boundCreator) = hook.bindings(id);
            assertEq(address(registry), address(0));
            assertEq(address(boundEscrow), address(0));
            assertEq(boundCreator, address(0));
            (uint160 price,,,) = StateLibrary.getSlot0(manager, id);
            assertEq(price, 0);
        }

        vm.clearMockedCalls();
        vm.prank(creator);
        uint256 launchId = factory.createLaunch{value: FEE}(name, symbol, userSalt, "ipfs://atomic");
        assertEq(launchId, 1);
        (address owner, address token, address curve, bool graduated, PoolId actualId) = factory.launches(1);
        assertEq(owner, creator);
        assertEq(token, predicted);
        assertEq(PoolId.unwrap(actualId), PoolId.unwrap(id));
        assertFalse(graduated);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        assertTrue(factory.feeEscrow().authorizedRecorders(curve));
        assertEq(workers.workerPot(), FEE);
        assertEq(address(workers).balance, FEE);
        assertEq(creator.balance, balanceBefore - FEE);
    }

    function test_maximumMetadataLengthsAndRepeatedSaltCreateIndependentLaunches() public {
        string memory name = new string(64);
        string memory symbol = new string(16);
        string memory metadata = new string(2048);
        vm.startPrank(creator);
        uint256 first = factory.createLaunch{value: FEE}(name, symbol, bytes32(0), metadata);
        uint256 second = factory.createLaunch{value: FEE}(name, symbol, bytes32(0), metadata);
        vm.stopPrank();
        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(factory.launchCount(), 3);
        (, address token1, address curve1,, PoolId pool1) = factory.launches(first);
        (, address token2, address curve2,, PoolId pool2) = factory.launches(second);
        assertTrue(token1 != token2);
        assertTrue(curve1 != curve2);
        assertTrue(PoolId.unwrap(pool1) != PoolId.unwrap(pool2));
        assertEq(PvPadToken(token1).name(), name);
        assertEq(PvPadToken(token2).symbol(), symbol);
        assertEq(factory.launchMetadataURI(first), metadata);
        assertEq(factory.launchMetadataURI(second), metadata);
        assertEq(PvPadToken(token1).balanceOf(curve1), 1e27);
        assertEq(PvPadToken(token2).balanceOf(curve2), 1e27);
        assertEq(PvPadToken(token1).balanceOf(creator), 0);
        assertEq(PvPadToken(token2).balanceOf(creator), 0);
        assertEq(workers.workerPot(), 2 * FEE);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_inexactLaunchFeeNeverChangesState(uint256 paymentSeed, bool overpay) public {
        uint256 payment = overpay ? bound(paymentSeed, FEE + 1, 1 ether) : bound(paymentSeed, 0, FEE - 1);
        uint256 beforeBalance = creator.balance;
        vm.expectRevert(PvPadFactory.LaunchFeeRequired.selector);
        vm.prank(creator);
        factory.createLaunch{value: payment}("Fee", "FEE");
        assertEq(factory.launchCount(), 1);
        assertEq(workers.workerPot(), 0);
        assertEq(address(workers).balance, 0);
        assertEq(creator.balance, beforeBalance);
    }

    function test_emptySymbolAndOverlongNameFailWithoutCharging() public {
        vm.startPrank(creator);
        vm.expectRevert(PvPadFactory.InvalidMetadata.selector);
        factory.createLaunch{value: FEE}("Name", "");
        vm.expectRevert(PvPadFactory.InvalidMetadata.selector);
        factory.createLaunch{value: FEE}(new string(65), "OK");
        vm.stopPrank();
        assertEq(factory.launchCount(), 1);
        assertEq(workers.workerPot(), 0);
        assertEq(creator.balance, 100 ether);
    }

    function test_unknownAndUnfundedLaunchCannotGraduate() public {
        vm.expectRevert(PvPadFactory.UnknownLaunch.selector);
        factory.graduate(type(uint256).max);
        vm.expectRevert(PvPadFactory.UnknownLaunch.selector);
        factory.getPoolKey(1);
        vm.expectRevert(PvPadFactory.NotReady.selector);
        factory.graduate(0);
        (, address token, address curve, bool graduated, PoolId id) = factory.launches(0);
        assertFalse(graduated);
        assertFalse(BondingCurve(payable(curve)).graduated());
        assertFalse(factory.registeredPool(id));
        assertEq(factory.lockedLiquidity(0), 0);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
    }

    /// @dev Neither the factory nor a curve accepts plain ETH from anyone else; only the registered
    /// curve's graduation sweep may push ETH into the factory, and nothing can ever be locked by mistake.
    function test_strayEthToFactoryOrCurveIsRejectedWhileGraduationSweepStillWorks() public {
        (,, address curve,,) = factory.launches(0);
        address stranger = address(0x5712A9);
        vm.deal(stranger, 3 ether);
        vm.startPrank(stranger);
        (bool ok,) = address(factory).call{value: 1 ether}("");
        assertFalse(ok, "factory refuses stray ETH");
        (ok,) = curve.call{value: 1 ether}("");
        assertFalse(ok, "curve refuses stray ETH");
        (ok,) = curve.call{value: 0}("");
        assertFalse(ok, "curve has no fallback either");
        vm.stopPrank();
        assertEq(stranger.balance, 3 ether);
        assertEq(address(factory).balance, 0);
        assertEq(curve.balance, 0);
        vm.prank(stranger);
        vm.expectRevert(PvPadFactory.NotBondingCurve.selector);
        payable(address(factory)).transfer(1 ether);

        vm.prank(creator);
        BondingCurve(payable(curve)).buy{value: 5 ether}(creator, 1, block.timestamp);
        assertEq(curve.balance, 4.2 ether);
        factory.graduate(0);
        assertEq(curve.balance, 0, "sweep delivered the reserves to the factory");
        assertGt(factory.lockedLiquidity(0), 0);
    }

    function test_constructorRejectsMismatchedManagerAndWorkerPot() public {
        PoolManager otherManager = new PoolManager(address(this));
        vm.expectRevert(PvPadFactory.InvalidConfiguration.selector);
        new PvPadFactory(otherManager, workers, king, hook, creator);
        WorkerSubsidy otherWorkers = new WorkerSubsidy(creator);
        vm.expectRevert(PvPadFactory.InvalidConfiguration.selector);
        new PvPadFactory(manager, otherWorkers, king, hook, creator);
        vm.expectRevert(PvPadFactory.ZeroAddress.selector);
        new PvPadFactory(manager, workers, king, hook, address(0));
        vm.expectRevert(PvPadFactory.ZeroAddress.selector);
        new PvPadFactory(IPoolManager(address(0)), workers, king, hook, creator);
    }
}
