// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadToken} from "../src/PvPadToken.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {PvPadHook, IPvPadLaunchRegistry} from "../src/hooks/PvPadHook.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

contract FactoryDeployer {
    function deploy(PoolManager manager, WorkerSubsidy workers, KingOfThePad king, PvPadHook hook, address creator)
        external
        returns (PvPadFactory)
    {
        return new PvPadFactory(manager, workers, king, hook, creator);
    }
}

/// @dev Proofs for bounded salt retry when a predicted pool is preinitialized at a foreign price (LOW).
contract LaunchResaltTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager internal manager;
    WorkerSubsidy internal workers;
    KingOfThePad internal king;
    PvPadHook internal hook;
    PvPadFactory internal factory;
    address internal creator = address(0xC0FFEE);
    uint256 internal constant FEE = 0.0005 ether;
    uint160 internal constant POISON = uint160(1) << 96;

    event LaunchSaltRetried(uint256 indexed launchId, uint256 attempt, address token);
    event LaunchPoolRealigned(uint256 indexed launchId, uint160 foreignSqrtPriceX96);
    event PoolRealigned(PoolId indexed poolId, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96);

    function setUp() public {
        manager = new PoolManager(address(this));
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        hook = new PvPadHook{salt: salt}(manager);
        factory = new PvPadFactory(manager, workers, king, hook, creator);
        vm.deal(creator, 100 ether);
    }

    function test_poisonedPredictedPoolSkipsToNextSaltAndNeverSeedsForeignPrice() public {
        address first = _token(address(factory), 1, creator, "Poisoned", "PSN", 0, 0);
        address second = _token(address(factory), 1, creator, "Poisoned", "PSN", 0, 1);
        manager.initialize(_key(first), POISON);
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Poisoned", "PSN", 0);
        assertEq(predicted, second);
        assertEq(attempt, 1);

        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchSaltRetried(1, 1, second);
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Poisoned", "PSN");
        assertEq(id, 1);
        (, address token, address curve,, PoolId poolId) = factory.launches(id);
        assertEq(token, second);
        assertEq(first.code.length, 0);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(_key(second).toId()));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
        assertEq(workers.workerPot(), FEE);

        // The poisoned pool is untouched: still at the attacker's price, unbound, unfunded.
        (uint160 poisonedPrice,,,) = StateLibrary.getSlot0(manager, _key(first).toId());
        assertEq(poisonedPrice, POISON);
        assertEq(StateLibrary.getLiquidity(manager, _key(first).toId()), 0);
        (IPvPadLaunchRegistry registry,,) = hook.bindings(_key(first).toId());
        assertEq(address(registry), address(0));
        assertFalse(factory.registeredPool(_key(first).toId()));
    }

    function test_canonicalPreinitializationKeepsAttemptZero() public {
        address first = _token(address(factory), 1, creator, "Canonical", "CAN", 0, 0);
        manager.initialize(_key(first), factory.canonicalSqrtPriceX96());
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Canonical", "CAN", 0);
        assertEq(predicted, first);
        assertEq(attempt, 0);
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Canonical", "CAN");
        (, address token,,,) = factory.launches(id);
        assertEq(token, first);
    }

    function test_repeatedFrontRunningConsumesSuccessiveAttempts() public {
        for (uint256 i; i < 3; ++i) {
            manager.initialize(_key(_token(address(factory), 1, creator, "Chase", "CHS", 0, i)), POISON);
        }
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Chase", "CHS", 0);
        assertEq(attempt, 3);
        assertEq(predicted, _token(address(factory), 1, creator, "Chase", "CHS", 0, 3));
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Chase", "CHS");
        (, address token,,,) = factory.launches(id);
        assertEq(token, predicted);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_poisonDepthWithinBoundSelectsFirstCleanSalt(uint8 depthSeed, bytes32 userSalt) public {
        uint256 depth = bound(depthSeed, 0, factory.MAX_SALT_ATTEMPTS() - 1);
        for (uint256 i; i < depth; ++i) {
            manager.initialize(_key(_token(address(factory), 1, creator, "Fuzz", "FZ", userSalt, i)), POISON);
        }
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Fuzz", "FZ", userSalt);
        assertEq(attempt, depth);
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Fuzz", "FZ", userSalt);
        (, address token,,, PoolId poolId) = factory.launches(id);
        assertEq(token, predicted);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
    }

    /// @dev Every bounded candidate poisoned: the create no longer fails closed. The first candidate is
    /// used and its empty, now-bound pool is moved back to the canonical price through the hook.
    function test_everyBoundedSaltPoisonedRealignsFirstCandidateAndNeverSeedsForeignPrice() public {
        uint256 attempts = factory.MAX_SALT_ATTEMPTS();
        for (uint256 i; i < attempts; ++i) {
            manager.initialize(_key(_token(address(factory), 1, creator, "Brick", "BRK", 0, i)), POISON);
        }
        address first = _token(address(factory), 1, creator, "Brick", "BRK", 0, 0);
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Brick", "BRK", 0);
        assertEq(predicted, first);
        assertEq(attempt, 0);
        uint256 managerBalance = address(manager).balance;

        vm.expectEmit(true, true, true, true, address(hook));
        emit PoolRealigned(_key(first).toId(), POISON, factory.canonicalSqrtPriceX96());
        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchPoolRealigned(1, POISON);
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Brick", "BRK");
        assertEq(id, 1);
        (, address token, address curve,, PoolId poolId) = factory.launches(id);
        assertEq(token, first);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
        assertEq(StateLibrary.getLiquidity(manager, poolId), 0);
        assertEq(address(manager).balance, managerBalance, "realignment moves no ETH");
        assertEq(PvPadToken(token).balanceOf(address(manager)), 0, "realignment moves no tokens");
        assertEq(workers.workerPot(), FEE);
        for (uint256 i = 1; i < attempts; ++i) {
            (uint160 poisoned,,,) =
                StateLibrary.getSlot0(manager, _key(_token(address(factory), 1, creator, "Brick", "BRK", 0, i)).toId());
            assertEq(poisoned, POISON, "untouched candidates keep the attacker's price");
        }

        // The realigned launch graduates and trades like any other.
        vm.prank(creator);
        BondingCurve(payable(curve)).buy{value: 5 ether}(creator, 1, block.timestamp);
        factory.graduate(id);
        assertEq(factory.lockedTickLower(id), -887220);
        assertEq(factory.lockedTickUpper(id), 887220);
        assertGt(factory.lockedLiquidity(id), 0);
    }

    /// @dev Reproduces the reviewer's genesis proof: all 16 genesis candidates of the future factory
    /// address are poisoned, yet the constructor succeeds with genesis at the canonical price.
    function test_everyGenesisCandidatePoisonedStillConstructsAtCanonicalPrice() public {
        FactoryDeployer deployer = new FactoryDeployer();
        address futureFactory = vm.computeCreateAddress(address(deployer), 1);
        for (uint256 i; i < 16; ++i) {
            manager.initialize(_key(_token(futureFactory, 0, creator, "Pepe Values Pepe", "PVP", 0, i)), POISON);
        }
        address first = _token(futureFactory, 0, creator, "Pepe Values Pepe", "PVP", 0, 0);
        vm.expectEmit(true, true, true, true, futureFactory);
        emit LaunchPoolRealigned(0, POISON);
        PvPadFactory realigned = deployer.deploy(manager, workers, king, hook, creator);
        assertEq(address(realigned), futureFactory);
        assertEq(realigned.launchCount(), 1);
        (, address token, address curve,, PoolId poolId) = realigned.launches(0);
        assertEq(token, first);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, realigned.canonicalSqrtPriceX96());
    }

    /// @dev Realignment works from either side of the canonical price, including the most extreme
    /// prices v4 accepts, and still moves no value because the gated pool holds no liquidity.
    function test_realignmentFromExtremeForeignPricesInBothDirections() public {
        uint256 attempts = factory.MAX_SALT_ATTEMPTS();
        for (uint256 i; i < attempts; ++i) {
            manager.initialize(
                _key(_token(address(factory), 1, creator, "Low", "LOW", 0, i)), TickMath.MIN_SQRT_PRICE + 1
            );
            manager.initialize(
                _key(_token(address(factory), 2, creator, "High", "HIGH", 0, i)), TickMath.MAX_SQRT_PRICE - 1
            );
        }
        uint256 managerBalance = address(manager).balance;
        vm.startPrank(creator);
        uint256 low = factory.createLaunch{value: FEE}("Low", "LOW");
        uint256 high = factory.createLaunch{value: FEE}("High", "HIGH");
        vm.stopPrank();
        (,,,, PoolId lowId) = factory.launches(low);
        (,,,, PoolId highId) = factory.launches(high);
        (uint160 lowPrice,,,) = StateLibrary.getSlot0(manager, lowId);
        (uint160 highPrice,,,) = StateLibrary.getSlot0(manager, highId);
        assertEq(lowPrice, factory.canonicalSqrtPriceX96());
        assertEq(highPrice, factory.canonicalSqrtPriceX96());
        assertEq(address(manager).balance, managerBalance);
    }

    function test_freshUserSaltStillEscapesPoisonedDerivations() public {
        uint256 attempts = factory.MAX_SALT_ATTEMPTS();
        for (uint256 i; i < attempts; ++i) {
            manager.initialize(_key(_token(address(factory), 1, creator, "Brick", "BRK", 0, i)), POISON);
        }
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Brick", "BRK", bytes32(uint256(1)));
        assertEq(id, 1);
        (, address token,,, PoolId poolId) = factory.launches(id);
        assertEq(token, _token(address(factory), 1, creator, "Brick", "BRK", bytes32(uint256(1)), 0));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
    }

    function test_poisonedGenesisPoolResaltsInsideConstructor() public {
        // A fresh deployer contract has nonce 1, so its first CREATE address is exactly predictable.
        FactoryDeployer deployer = new FactoryDeployer();
        address futureFactory = vm.computeCreateAddress(address(deployer), 1);
        address first = _token(futureFactory, 0, creator, "Pepe Values Pepe", "PVP", 0, 0);
        address second = _token(futureFactory, 0, creator, "Pepe Values Pepe", "PVP", 0, 1);
        manager.initialize(_key(first), POISON);
        vm.expectEmit(true, true, true, true, futureFactory);
        emit LaunchSaltRetried(0, 1, second);
        PvPadFactory resalted = deployer.deploy(manager, workers, king, hook, creator);
        assertEq(address(resalted), futureFactory);
        (, address token, address curve,, PoolId poolId) = resalted.launches(0);
        assertEq(token, second);
        assertEq(first.code.length, 0);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, resalted.canonicalSqrtPriceX96());
        (uint160 poisonedPrice,,,) = StateLibrary.getSlot0(manager, _key(first).toId());
        assertEq(poisonedPrice, POISON);
    }

    function test_predictionMatchesUnpoisonedCreateAndAdvancesWithLaunchCount() public {
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Plain", "PLN", 0);
        assertEq(attempt, 0);
        assertEq(predicted, _token(address(factory), 1, creator, "Plain", "PLN", 0, 0));
        vm.prank(creator);
        factory.createLaunch{value: FEE}("Plain", "PLN");
        (, address token,,,) = factory.launches(1);
        assertEq(token, predicted);
        (address next,) = factory.predictLaunchToken(creator, "Plain", "PLN", 0);
        assertTrue(next != predicted);
        assertEq(next, _token(address(factory), 2, creator, "Plain", "PLN", 0, 0));
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_allCandidatesPoisonedAtMixedPricesRecoversWithoutMovingValue(
        uint160 priceSeed,
        bytes32 userSalt,
        bool firstBelowCanonical
    ) public {
        uint160 canonical = factory.canonicalSqrtPriceX96();
        uint160 low = uint160(bound(priceSeed, TickMath.MIN_SQRT_PRICE, canonical - 1));
        uint160 high = uint160(bound(priceSeed, canonical + 1, TickMath.MAX_SQRT_PRICE - 1));
        _poisonMixedCandidates(userSalt, low, high, firstBelowCanonical);
        {
            (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Mixed", "MIX", userSalt);
            assertEq(predicted, _token(address(factory), 1, creator, "Mixed", "MIX", userSalt, 0));
            assertEq(attempt, 0);
        }
        _assertMixedRecovery(userSalt);
        _assertMixedCandidatesUntouched(userSalt, low, high, firstBelowCanonical);
    }

    function _poisonMixedCandidates(bytes32 userSalt, uint160 low, uint160 high, bool firstBelowCanonical) private {
        for (uint256 i; i < factory.MAX_SALT_ATTEMPTS(); ++i) {
            uint160 poison = (i % 2 == 0) == firstBelowCanonical ? low : high;
            manager.initialize(_key(_token(address(factory), 1, creator, "Mixed", "MIX", userSalt, i)), poison);
        }
    }

    function _assertMixedRecovery(bytes32 userSalt) private {
        uint256 balanceBefore = creator.balance;
        uint256 managerBefore = address(manager).balance;
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Mixed", "MIX", userSalt);
        (, address token, address curve,, PoolId poolId) = factory.launches(id);
        assertEq(id, 1);
        assertEq(token, _token(address(factory), 1, creator, "Mixed", "MIX", userSalt, 0));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
        assertEq(StateLibrary.getLiquidity(manager, poolId), 0);
        assertEq(PvPadToken(token).totalSupply(), 1e27);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        assertEq(PvPadToken(token).balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, managerBefore);
        assertEq(creator.balance, balanceBefore - FEE);
        assertEq(workers.workerPot(), FEE);
        assertEq(address(workers).balance, FEE);
        assertEq(address(factory).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(factory.feeEscrow()).balance, 0);
    }

    function _assertMixedCandidatesUntouched(bytes32 userSalt, uint160 low, uint160 high, bool firstBelowCanonical)
        private
        view
    {
        for (uint256 i = 1; i < factory.MAX_SALT_ATTEMPTS(); ++i) {
            address sibling = _token(address(factory), 1, creator, "Mixed", "MIX", userSalt, i);
            PoolId siblingId = _key(sibling).toId();
            (uint160 untouched,,,) = StateLibrary.getSlot0(manager, siblingId);
            assertEq(untouched, (i % 2 == 0) == firstBelowCanonical ? low : high);
            assertEq(sibling.code.length, 0);
            assertEq(StateLibrary.getLiquidity(manager, siblingId), 0);
            (IPvPadLaunchRegistry registry,,) = hook.bindings(siblingId);
            assertEq(address(registry), address(0));
        }
    }

    function test_missingRealignmentCallbackRollsBackLaunchAndCanRetry() public {
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), abi.encode(bytes("")));
        _assertRecoveryFailureAndRetry(PvPadHook.InvalidCallback.selector);
    }

    function test_nonzeroRealignmentDeltaRollsBackLaunchAndCanRetry() public {
        // Inject an impossible result from the trusted manager to exercise the hook's hard stop.
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(int256(1)));
        _assertRecoveryFailureAndRetry(PvPadHook.RealignFailed.selector);
    }

    function test_zeroDeltaWithoutPriceMovementRollsBackLaunchAndCanRetry() public {
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(int256(0)));
        _assertRecoveryFailureAndRetry(PvPadHook.RealignFailed.selector);
    }

    function test_factoryRejectsRecoveryThatDidNotRestoreCanonicalPriceAndCanRetry() public {
        vm.mockCall(address(hook), abi.encodeWithSelector(PvPadHook.realignPool.selector), bytes(""));
        _assertRecoveryFailureAndRetry(PvPadFactory.UnexpectedPoolPrice.selector);
    }

    function test_workerFailureAfterRealignmentRestoresPoisonedPriceAndCanRetry() public {
        vm.mockCallRevert(address(workers), abi.encodeCall(WorkerSubsidy.fundWorkers, ()), hex"deadbeef");
        _assertRecoveryFailureAndRetry(bytes4(0xdeadbeef));
    }

    function _assertRecoveryFailureAndRetry(bytes4 expectedError) private {
        uint256 attempts = factory.MAX_SALT_ATTEMPTS();
        for (uint256 i; i < attempts; ++i) {
            manager.initialize(_key(_token(address(factory), 1, creator, "Retry", "RTY", 0, i)), POISON);
        }
        address first = _token(address(factory), 1, creator, "Retry", "RTY", 0, 0);
        // CREATE2 for the token also advances the factory nonce before the curve's CREATE.
        address expectedCurve = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)) + 1);
        uint256 creatorBefore = creator.balance;
        uint256 managerBefore = address(manager).balance;
        vm.prank(creator);
        vm.expectRevert(expectedError);
        factory.createLaunch{value: FEE}("Retry", "RTY", bytes32(0), "ipfs://retry");

        assertEq(factory.launchCount(), 1);
        assertEq(factory.launchMetadataURI(1), "");
        (, address rolledBackToken, address rolledBackCurve,,) = factory.launches(1);
        assertEq(rolledBackToken, address(0));
        assertEq(rolledBackCurve, address(0));
        assertEq(expectedCurve.code.length, 0);
        assertFalse(factory.isBondingCurve(expectedCurve));
        assertFalse(factory.feeEscrow().authorizedRecorders(expectedCurve));
        assertEq(creator.balance, creatorBefore);
        assertEq(address(manager).balance, managerBefore);
        assertEq(address(factory).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(workers.workerPot(), 0);
        assertEq(address(workers).balance, 0);
        for (uint256 i; i < attempts; ++i) {
            address candidate = _token(address(factory), 1, creator, "Retry", "RTY", 0, i);
            PoolId poolId = _key(candidate).toId();
            assertEq(candidate.code.length, 0);
            (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
            assertEq(price, POISON, "a reverted recovery restores every original pool price");
            assertEq(StateLibrary.getLiquidity(manager, poolId), 0);
            assertEq(factory.poolCreator(poolId), address(0));
            assertFalse(factory.registeredPool(poolId));
            (IPvPadLaunchRegistry registry, FeeEscrow escrow, address payee) = hook.bindings(poolId);
            assertEq(address(registry), address(0));
            assertEq(address(escrow), address(0));
            assertEq(payee, address(0));
        }

        vm.clearMockedCalls();
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Retry", "RTY", bytes32(0), "ipfs://retry");
        (, address token, address curve,, PoolId actualPool) = factory.launches(id);
        assertEq(id, 1);
        assertEq(token, first);
        assertEq(curve, expectedCurve);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        assertTrue(factory.isBondingCurve(curve));
        assertTrue(factory.feeEscrow().authorizedRecorders(curve));
        assertEq(factory.launchMetadataURI(id), "ipfs://retry");
        (uint160 recovered,,,) = StateLibrary.getSlot0(manager, actualPool);
        assertEq(recovered, factory.canonicalSqrtPriceX96());
        assertEq(creator.balance, creatorBefore - FEE);
        assertEq(workers.workerPot(), FEE);
        assertEq(address(workers).balance, FEE);
        // No stale callback authorization survives either the failed or successful realignment.
        bytes memory callback = abi.encode(_key(first), true, factory.canonicalSqrtPriceX96());
        vm.prank(address(manager));
        vm.expectRevert(PvPadHook.InvalidCallback.selector);
        hook.unlockCallback(callback);
    }

    function _token(
        address deployer,
        uint256 launchId,
        address launchCreator,
        string memory name,
        string memory symbol,
        bytes32 userSalt,
        uint256 attempt
    ) internal pure returns (address) {
        bytes32 salt = attempt == 0
            ? keccak256(abi.encode(launchId, launchCreator, name, symbol, userSalt))
            : keccak256(abi.encode(launchId, launchCreator, name, symbol, userSalt, attempt));
        bytes32 initHash = keccak256(abi.encodePacked(type(PvPadToken).creationCode, abi.encode(name, symbol)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
    }

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 60, IHooks(address(hook)));
    }
}
