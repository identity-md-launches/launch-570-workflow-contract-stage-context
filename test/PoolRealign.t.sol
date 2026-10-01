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
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadToken} from "../src/PvPadToken.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {PvPadHook} from "../src/hooks/PvPadHook.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @notice Security properties of `PvPadHook.realignPool`, the registry-only price reset for a bound,
/// empty pool that someone preinitialized at a foreign price. Uses the real vendored PoolManager.
contract PoolRealignTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager internal manager;
    WorkerSubsidy internal workers;
    KingOfThePad internal king;
    PvPadHook internal hook;
    PvPadFactory internal factory;
    PoolSwapTest internal router;
    address internal creator = address(0xC0FFEE);
    uint160 internal constant POISON = uint160(1) << 96;

    function setUp() public {
        manager = new PoolManager(address(this));
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        hook = new PvPadHook{salt: salt}(manager);
        factory = new PvPadFactory(manager, workers, king, hook, creator);
        router = new PoolSwapTest(manager);
        vm.deal(creator, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function test_onlyTheBoundFactoryCanRealignAndOnlyAnEmptyMispricedPool() public {
        PoolKey memory key = factory.getPoolKey(0);
        uint160 canonical = factory.canonicalSqrtPriceX96();

        // Strangers, the creator and the test deployer are not the bound registry.
        vm.expectRevert(PvPadHook.NotLaunchFactory.selector);
        hook.realignPool(key, POISON);
        vm.prank(creator);
        vm.expectRevert(PvPadHook.NotLaunchFactory.selector);
        hook.realignPool(key, POISON);

        // An unbound pool that merely names the hook has no registry at all.
        PvPadToken foreign = new PvPadToken("Foreign", "FRN");
        PoolKey memory unbound =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(foreign)), 0, 60, IHooks(address(hook)));
        manager.initialize(unbound, POISON);
        vm.prank(address(factory));
        vm.expectRevert(PvPadHook.NotLaunchFactory.selector);
        hook.realignPool(unbound, canonical);

        // The registry itself cannot move a pool that is already at the requested price.
        vm.prank(address(factory));
        vm.expectRevert(PvPadHook.NothingToRealign.selector);
        hook.realignPool(key, canonical);

        // An uninitialized pool is never bound (the factory binds and initializes atomically), so the
        // registry check rejects it before any price logic runs.
        PvPadToken other = new PvPadToken("Other", "OTH");
        PoolKey memory uninitialized =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(other)), 0, 60, IHooks(address(hook)));
        vm.prank(address(factory));
        vm.expectRevert(PvPadHook.NotLaunchFactory.selector);
        hook.realignPool(uninitialized, canonical);

        // After graduation the pool holds the permanent position, so even the registry is refused.
        (,, address curve,,) = factory.launches(0);
        vm.prank(creator);
        BondingCurve(payable(curve)).buy{value: 5 ether}(creator, 1, block.timestamp);
        factory.graduate(0);
        assertGt(StateLibrary.getLiquidity(manager, key.toId()), 0);
        vm.prank(address(factory));
        vm.expectRevert(PvPadHook.PoolHasLiquidity.selector);
        hook.realignPool(key, POISON);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, key.toId());
        assertEq(price, canonical, "a live pool's price cannot be touched");
    }

    function test_unlockCallbackAcceptsOnlyThePoolManagerDuringARealignment() public {
        PoolKey memory key = factory.getPoolKey(0);
        bytes memory data = abi.encode(key, true, uint160(1) << 95);
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.unlockCallback(data);
        vm.prank(address(manager));
        vm.expectRevert(PvPadHook.InvalidCallback.selector);
        hook.unlockCallback(data);
        // A stranger unlocking the PoolManager has its own callback invoked, never the hook's.
        vm.expectRevert();
        manager.unlock(data);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, key.toId());
        assertEq(price, factory.canonicalSqrtPriceX96());
    }

    function test_realignedPoolGraduatesAndTradesWithFeesLikeAnyOther() public {
        // Poison every candidate so the create has to realign its first candidate.
        string memory name = "Realigned";
        string memory symbol = "RLG";
        for (uint256 i; i < factory.MAX_SALT_ATTEMPTS(); ++i) {
            manager.initialize(_key(_token(1, name, symbol, i)), POISON);
        }
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: 0.0005 ether}(name, symbol);
        (, address token, address curve,, PoolId poolId) = factory.launches(id);
        assertEq(token, _token(1, name, symbol, 0));
        (uint160 price, int24 tick,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
        assertEq(StateLibrary.getLiquidity(manager, poolId), 0);

        // Nobody can swap or add liquidity on the realigned pool before graduation.
        PoolKey memory key = factory.getPoolKey(id);
        vm.expectRevert();
        router.swap{value: 0.1 ether}(
            key, IPoolManager.SwapParams(true, -0.1 ether, price - 1), PoolSwapTest.TestSettings(false, false), ""
        );

        vm.prank(creator);
        BondingCurve(payable(curve)).buy{value: 5 ether}(creator, 1, block.timestamp);
        factory.graduate(id);
        assertEq(factory.lockedTickLower(id), -887220);
        assertEq(factory.lockedTickUpper(id), 887220);
        (, int24 tickAfter,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(tickAfter, tick, "graduation deposits at the realigned price");

        // A real buy through the graduated pool pays the 1% ETH fee into the escrow.
        uint256 escrowBefore = address(factory.feeEscrow()).balance;
        router.swap{value: 1 ether}(
            key, IPoolManager.SwapParams(true, -1 ether, price / 2), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(address(factory.feeEscrow()).balance - escrowBefore, 0.01 ether);
        assertGt(PvPadToken(token).balanceOf(address(this)), 0);
    }

    function _token(uint256 launchId, string memory name, string memory symbol, uint256 attempt)
        internal
        view
        returns (address)
    {
        bytes32 salt = attempt == 0
            ? keccak256(abi.encode(launchId, creator, name, symbol, bytes32(0)))
            : keccak256(abi.encode(launchId, creator, name, symbol, bytes32(0), attempt));
        bytes32 initHash = keccak256(abi.encodePacked(type(PvPadToken).creationCode, abi.encode(name, symbol)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash)))));
    }

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 60, IHooks(address(hook)));
    }

    receive() external payable {}
}
