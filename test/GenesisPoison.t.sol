// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadToken} from "../src/PvPadToken.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {PvPadHook, IPvPadLaunchRegistry} from "../src/hooks/PvPadHook.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @dev Service-style CREATE2 deployer: the factory address is public before the deploy transaction,
/// exactly the situation the genesis-poison finding exploits.
contract GenesisCreate2Deployer {
    error DeploymentFailed();

    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed();
    }
}

/// @dev Attacker probe that talks to the PoolManager directly, so a candidate pool whose token does not
/// exist yet (routers would fail on its balance reads) still reaches the hook's gates.
contract GenesisPoisonProbe {
    IPoolManager internal immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params) external {
        manager.unlock(abi.encode(true, key, params, IPoolManager.ModifyLiquidityParams(0, 0, 0, 0)));
    }

    function addLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params) external {
        manager.unlock(abi.encode(false, key, IPoolManager.SwapParams(false, 0, 0), params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (
            bool isSwap,
            PoolKey memory key,
            IPoolManager.SwapParams memory swapParams,
            IPoolManager.ModifyLiquidityParams memory liquidityParams
        ) = abi.decode(data, (bool, PoolKey, IPoolManager.SwapParams, IPoolManager.ModifyLiquidityParams));
        if (isSwap) manager.swap(key, swapParams, "");
        else manager.modifyLiquidity(key, liquidityParams, "");
        return "";
    }
}

/// @notice Proof for the judge's MEDIUM: all 16 predictable genesis candidate pools (ETH / token_n, fee 0,
/// spacing 60, shared PvPadHook) are initialized at a foreign price before the factory's CREATE2 exists.
/// The factory must still deploy at the predicted address with genesis at the canonical price, the
/// constructor signature and manifest schema unchanged, and no foreign price ever accepted.
contract GenesisPoisonTest is Test {
    using PoolIdLibrary for PoolKey;

    GenesisCreate2Deployer internal service;
    PoolManager internal manager;
    WorkerSubsidy internal workers;
    KingOfThePad internal king;
    PvPadHook internal hook;
    PoolSwapTest internal swapRouter;
    GenesisPoisonProbe internal probe;

    address internal constant UPDATER = address(0xA11CE);
    address internal constant GENESIS_CREATOR = address(0xC0FFEE);
    address internal attacker = address(0xBAD);
    bytes32 internal constant FACTORY_SALT = bytes32(uint256(4));
    uint160 internal constant POISON = uint160(1) << 96;
    uint256 internal constant CANDIDATES = 16;
    string internal constant NAME = "Pepe Values Pepe";
    string internal constant SYMBOL = "PVP";

    event LaunchSaltRetried(uint256 indexed launchId, uint256 attempt, address token);
    event LaunchPoolRealigned(uint256 indexed launchId, uint160 foreignSqrtPriceX96);
    event PoolRealigned(PoolId indexed poolId, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96);

    function setUp() public {
        service = new GenesisCreate2Deployer();
        manager = new PoolManager(address(this));
        workers = new WorkerSubsidy(UPDATER);
        king = new KingOfThePad(workers);
        (address predictedHook, bytes32 hookSalt) = HookMiner.findPvPadHook(address(service), address(manager));
        hook = PvPadHook(
            payable(service.deploy(abi.encodePacked(type(PvPadHook).creationCode, abi.encode(manager)), hookSalt))
        );
        assertEq(address(hook), predictedHook);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x08cc);
        swapRouter = new PoolSwapTest(manager);
        probe = new GenesisPoisonProbe(manager);
        vm.deal(attacker, 100 ether);
        vm.deal(GENESIS_CREATOR, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    /// @dev The finding's exact scenario. Before the fix the constructor reverted `UnexpectedPoolPrice`
    /// and every retry at the same CREATE2 address failed the same way.
    function test_allSixteenGenesisCandidatesPoisonedBeforeCreate2StillDeploysAtPredictedAddress() public {
        address predicted = _predictedFactory();
        assertEq(predicted.code.length, 0);
        _poisonAll(predicted, POISON);
        address first = _candidate(predicted, 0);

        // While the factory does not exist the poisoned pools are inert: no swap, no liquidity.
        _assertPoolIsInert(_key(first));
        uint256 managerBefore = address(manager).balance;
        uint256 attackerBefore = attacker.balance;

        vm.expectEmit(true, true, true, true, address(hook));
        emit PoolRealigned(_key(first).toId(), POISON, _canonical());
        vm.expectEmit(true, true, true, true, predicted);
        emit LaunchPoolRealigned(0, POISON);
        PvPadFactory factory = _deployFactory();

        assertEq(address(factory), predicted, "deployed at the pre-announced CREATE2 address");
        assertEq(address(manager).balance, managerBefore, "realignment moves no ETH");
        assertEq(attacker.balance, attackerBefore, "the attacker gains nothing");
        _assertRealignedGenesis(factory, first);
        _assertSiblingsUntouched(predicted, 1, POISON);
        _assertGenesisGraduatesAndChargesFees(factory, first);
    }

    function _assertRealignedGenesis(PvPadFactory factory, address first) private view {
        assertEq(factory.canonicalSqrtPriceX96(), _canonical());
        assertEq(factory.MAX_SALT_ATTEMPTS(), CANDIDATES);
        assertEq(factory.launchCount(), 1);
        (address creator, address token, address curve, bool graduated, PoolId poolId) = factory.launches(0);
        assertEq(creator, GENESIS_CREATOR);
        assertEq(token, first, "genesis lands on the first candidate, not a re-salt");
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(_key(first).toId()));
        assertFalse(graduated);
        assertEq(PvPadToken(token).factory(), address(factory));
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        assertEq(PvPadToken(token).balanceOf(address(manager)), 0, "realignment moves no tokens");
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, _canonical(), "genesis pool is at the canonical price when the constructor returns");
        assertEq(StateLibrary.getLiquidity(manager, poolId), 0);
        assertFalse(factory.registeredPool(poolId));
        (IPvPadLaunchRegistry registry,, address payee) = hook.bindings(poolId);
        assertEq(address(registry), address(factory));
        assertEq(payee, GENESIS_CREATOR);
        assertEq(address(hook).balance, 0);
        assertEq(workers.workerPot(), 0, "genesis pays no launch fee");
    }

    /// @dev Genesis still behaves like any launch: closed until graduation, then locked full range, 1% fee.
    function _assertGenesisGraduatesAndChargesFees(PvPadFactory factory, address token) private {
        _assertPoolIsInert(_key(token));
        (,, address curve,, PoolId poolId) = factory.launches(0);
        vm.prank(GENESIS_CREATOR);
        BondingCurve(payable(curve)).buy{value: 5 ether}(GENESIS_CREATOR, 1, block.timestamp);
        factory.graduate(0);
        assertTrue(factory.registeredPool(poolId));
        assertEq(factory.lockedTickLower(0), -887220);
        assertEq(factory.lockedTickUpper(0), 887220);
        assertGt(factory.lockedLiquidity(0), 0);
        uint256 escrowBefore = address(factory.feeEscrow()).balance;
        swapRouter.swap{value: 1 ether}(
            _key(token),
            IPoolManager.SwapParams(true, -1 ether, _canonical() / 2),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(address(factory.feeEscrow()).balance - escrowBefore, 0.01 ether);
        assertGt(PvPadToken(token).balanceOf(address(this)), 0);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_genesisPoisonedAtAnyForeignPricesDeploysAtCanonicalPrice(uint160 seed, bool firstBelow) public {
        uint160 canonical = _canonical();
        uint160 low = uint160(bound(seed, TickMath.MIN_SQRT_PRICE, canonical - 1));
        uint160 high = uint160(bound(seed, canonical + 1, TickMath.MAX_SQRT_PRICE - 1));
        address predicted = _predictedFactory();
        vm.startPrank(attacker);
        for (uint256 i; i < CANDIDATES; ++i) {
            manager.initialize(_key(_candidate(predicted, i)), (i % 2 == 0) == firstBelow ? low : high);
        }
        vm.stopPrank();
        uint256 managerBefore = address(manager).balance;

        PvPadFactory factory = _deployFactory();
        assertEq(address(factory), predicted);
        (, address token,,, PoolId poolId) = factory.launches(0);
        assertEq(token, _candidate(predicted, 0));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, canonical);
        assertEq(StateLibrary.getLiquidity(manager, poolId), 0);
        assertEq(address(manager).balance, managerBefore);
        assertEq(PvPadToken(token).balanceOf(address(manager)), 0);
        for (uint256 i = 1; i < CANDIDATES; ++i) {
            address sibling = _candidate(predicted, i);
            (uint160 untouched,,,) = StateLibrary.getSlot0(manager, _key(sibling).toId());
            assertEq(untouched, (i % 2 == 0) == firstBelow ? low : high);
            assertEq(sibling.code.length, 0);
        }
    }

    /// @dev A canonical-price preinitialization is not poison: attempt 0 is used and nothing is realigned.
    function test_genesisCandidatePreinitializedAtCanonicalPriceIsAcceptedWithoutRealignment() public {
        address predicted = _predictedFactory();
        address first = _candidate(predicted, 0);
        vm.prank(attacker);
        manager.initialize(_key(first), _canonical());

        vm.recordLogs();
        PvPadFactory factory = _deployFactory();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != PoolRealigned.selector, "no hook realignment");
            assertTrue(logs[i].topics[0] != LaunchPoolRealigned.selector, "no factory realignment");
            assertTrue(logs[i].topics[0] != LaunchSaltRetried.selector, "no re-salt");
        }
        (, address token,,, PoolId poolId) = factory.launches(0);
        assertEq(token, first);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, _canonical());
    }

    /// @dev Fewer than 16 poisoned candidates keep the bounded re-salt: the first clean candidate wins.
    function test_partialGenesisPoisonResaltsInsideTheConstructorAtThePredictedAddress() public {
        address predicted = _predictedFactory();
        vm.startPrank(attacker);
        for (uint256 i; i < 5; ++i) {
            manager.initialize(_key(_candidate(predicted, i)), POISON);
        }
        vm.stopPrank();
        address clean = _candidate(predicted, 5);

        vm.expectEmit(true, true, true, true, predicted);
        emit LaunchSaltRetried(0, 5, clean);
        PvPadFactory factory = _deployFactory();
        assertEq(address(factory), predicted);
        (, address token,,, PoolId poolId) = factory.launches(0);
        assertEq(token, clean);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, _canonical());
        for (uint256 i; i < 5; ++i) {
            address skipped = _candidate(predicted, i);
            assertEq(skipped.code.length, 0);
            (uint160 poisoned,,,) = StateLibrary.getSlot0(manager, _key(skipped).toId());
            assertEq(poisoned, POISON, "skipped candidates are left alone");
            (IPvPadLaunchRegistry registry,,) = hook.bindings(_key(skipped).toId());
            assertEq(address(registry), address(0));
        }
    }

    /// @dev Failure paths after a realigned deploy: nobody but the bound factory can move the genesis
    /// price, nobody can re-initialize it, and the realigned pool stays closed until graduation. The
    /// poisoned siblings are never bound, so not even the factory can touch them.
    function test_realignedGenesisCannotBeMovedReinitializedOrOpenedByAnyone() public {
        address predicted = _predictedFactory();
        _poisonAll(predicted, POISON);
        PvPadFactory factory = _deployFactory();
        PoolKey memory key = factory.getPoolKey(0);

        address[3] memory strangers = [attacker, GENESIS_CREATOR, address(service)];
        for (uint256 i; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(PvPadHook.NotLaunchFactory.selector);
            hook.realignPool(key, POISON);
        }
        vm.prank(attacker);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, POISON);
        _assertPoolIsInert(key);

        PoolKey memory sibling = _key(_candidate(predicted, 1));
        vm.prank(address(factory));
        vm.expectRevert(PvPadHook.NotLaunchFactory.selector);
        hook.realignPool(sibling, _canonical());
        _assertPoolIsInert(sibling);

        (uint160 price,,,) = StateLibrary.getSlot0(manager, key.toId());
        assertEq(price, _canonical());
        (uint160 siblingPrice,,,) = StateLibrary.getSlot0(manager, sibling.toId());
        assertEq(siblingPrice, POISON);
    }

    /// @dev The hard stop: if realignment does not land on the canonical price the constructor reverts,
    /// the CREATE2 address stays free (nothing partially deployed) and the same salt deploys once the
    /// hook behaves. Genesis is never accepted at a foreign price.
    function test_realignmentThatLeavesAForeignPriceAbortsTheDeployAndTheSameSaltRetries() public {
        address predicted = _predictedFactory();
        _poisonAll(predicted, POISON);
        PoolId genesisId = _key(_candidate(predicted, 0)).toId();

        vm.mockCall(address(hook), abi.encodeWithSelector(PvPadHook.realignPool.selector), bytes(""));
        vm.expectRevert(GenesisCreate2Deployer.DeploymentFailed.selector);
        _deployFactory();
        assertEq(predicted.code.length, 0);
        assertEq(_candidate(predicted, 0).code.length, 0);
        (IPvPadLaunchRegistry registry,,) = hook.bindings(genesisId);
        assertEq(address(registry), address(0), "a failed deploy leaves no binding behind");
        (uint160 price,,,) = StateLibrary.getSlot0(manager, genesisId);
        assertEq(price, POISON, "a failed deploy leaves the attacker's price, never a half-realigned one");

        vm.clearMockedCalls();
        PvPadFactory factory = _deployFactory();
        assertEq(address(factory), predicted);
        (,,,, PoolId poolId) = factory.launches(0);
        (uint160 recovered,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(recovered, _canonical());
    }

    /// @dev Later launches keep the bounded re-salt and the realignment fallback after a poisoned genesis.
    function test_laterLaunchesKeepBoundedResaltAfterPoisonedGenesis() public {
        address predicted = _predictedFactory();
        _poisonAll(predicted, POISON);
        PvPadFactory factory = _deployFactory();

        address first = _launchCandidate(address(factory), 1, attacker, "Later", "LTR", 0);
        address second = _launchCandidate(address(factory), 1, attacker, "Later", "LTR", 1);
        vm.startPrank(attacker);
        manager.initialize(_key(first), POISON);
        (address token, uint256 attempt) = factory.predictLaunchToken(attacker, "Later", "LTR", 0);
        assertEq(token, second);
        assertEq(attempt, 1);
        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchSaltRetried(1, 1, second);
        uint256 id = factory.createLaunch{value: 0.0005 ether}("Later", "LTR");
        vm.stopPrank();
        assertEq(id, 1);
        (, address launched,,, PoolId poolId) = factory.launches(id);
        assertEq(launched, second);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, _canonical());
        assertEq(workers.workerPot(), 0.0005 ether);
    }

    /// @dev The hook's gates, not a router's bookkeeping, are what refuse the attacker: no swap before
    /// graduation (`PoolNotGraduated`) and no liquidity from anyone but the bound factory (`LiquidityClosed`).
    function _assertPoolIsInert(PoolKey memory key) private {
        vm.prank(attacker);
        vm.expectRevert(_wrapped(IHooks.beforeSwap.selector, PvPadHook.PoolNotGraduated.selector));
        probe.swap(key, IPoolManager.SwapParams(true, -0.01 ether, TickMath.MIN_SQRT_PRICE + 1));
        vm.prank(attacker);
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, PvPadHook.LiquidityClosed.selector));
        probe.addLiquidity(key, IPoolManager.ModifyLiquidityParams(-887220, 887220, 1e18, bytes32(0)));
        assertEq(StateLibrary.getLiquidity(manager, key.toId()), 0);
    }

    function _assertSiblingsUntouched(address factoryAddress, uint256 from, uint160 expected) private view {
        for (uint256 i = from; i < CANDIDATES; ++i) {
            address sibling = _candidate(factoryAddress, i);
            PoolId siblingId = _key(sibling).toId();
            (uint160 untouched,,,) = StateLibrary.getSlot0(manager, siblingId);
            assertEq(untouched, expected, "untouched candidates keep the attacker's price");
            assertEq(sibling.code.length, 0);
            assertEq(StateLibrary.getLiquidity(manager, siblingId), 0);
            (IPvPadLaunchRegistry registry,,) = hook.bindings(siblingId);
            assertEq(address(registry), address(0));
        }
    }

    function _wrapped(bytes4 callback, bytes4 reason) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _poisonAll(address factoryAddress, uint160 price) private {
        vm.startPrank(attacker);
        for (uint256 i; i < CANDIDATES; ++i) {
            manager.initialize(_key(_candidate(factoryAddress, i)), price);
        }
        vm.stopPrank();
    }

    function _deployFactory() private returns (PvPadFactory) {
        return PvPadFactory(payable(service.deploy(_factoryInitCode(), FACTORY_SALT)));
    }

    function _factoryInitCode() private view returns (bytes memory) {
        return
            abi.encodePacked(type(PvPadFactory).creationCode, abi.encode(manager, workers, king, hook, GENESIS_CREATOR));
    }

    function _predictedFactory() private view returns (address) {
        return HookMiner.computeAddress(address(service), uint256(FACTORY_SALT), _factoryInitCode());
    }

    /// @dev Same formula as the factory constructor: sqrt((S/4) * 2^192 / 4.2 ETH).
    function _canonical() private pure returns (uint160) {
        return uint160(Math.sqrt(FullMath.mulDiv(1e27 / 4, uint256(1) << 192, 4.2 ether)));
    }

    function _candidate(address factoryAddress, uint256 attempt) private pure returns (address) {
        return _launchCandidate(factoryAddress, 0, GENESIS_CREATOR, NAME, SYMBOL, attempt);
    }

    function _launchCandidate(
        address factoryAddress,
        uint256 launchId,
        address creator,
        string memory name,
        string memory symbol,
        uint256 attempt
    ) private pure returns (address) {
        bytes32 salt = attempt == 0
            ? keccak256(abi.encode(launchId, creator, name, symbol, bytes32(0)))
            : keccak256(abi.encode(launchId, creator, name, symbol, bytes32(0), attempt));
        bytes32 initHash = keccak256(abi.encodePacked(type(PvPadToken).creationCode, abi.encode(name, symbol)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factoryAddress, salt, initHash)))));
    }

    function _key(address token) private view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 60, IHooks(address(hook)));
    }

    receive() external payable {}
}
