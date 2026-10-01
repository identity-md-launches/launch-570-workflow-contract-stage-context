// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadHook} from "../src/hooks/PvPadHook.sol";
import {PvPadIntegrationTest} from "./PvPadIntegration.t.sol";

/// @dev Proofs for the pre-graduation liquidity gate (HIGH) and the threshold sell gate (LOW).
/// Against the previous hook (0x00cc, no beforeAddLiquidity) the first group fails: the deposit is
/// accepted and the locked range shifts inward (887100 instead of 887220).
contract GraduationLiquidityTest is PvPadIntegrationTest {
    using PoolIdLibrary for PoolKey;

    int24 internal constant LOWER = -887220;
    int24 internal constant UPPER = 887220;

    function test_tickOverflowGriefOnUpperBoundaryIsRejectedBeforeGraduation() public {
        PoolModifyLiquidityTest attackerRouter = new PoolModifyLiquidityTest(manager);
        uint256 balanceBefore = trader.balance;
        _attemptPosition(attackerRouter, UPPER - 60, UPPER, Pool.tickSpacingToMaxLiquidityPerTick(60), true);
        assertEq(trader.balance, balanceBefore, "rejected deposit costs nothing");
        (uint128 gross,) = StateLibrary.getTickLiquidity(manager, _key(0).toId(), UPPER);
        assertEq(gross, 0);

        _graduateAndCheckPosition(LOWER, UPPER);
        (BalanceDelta delta, uint256 fee) = _swap(true, -int256(0.1 ether));
        assertGt(delta.amount1(), 0);
        assertEq(fee, 0.001 ether);
        _assertPositionCannotBeRemoved(attackerRouter, LOWER, UPPER);
    }

    function test_tickOverflowGriefOnLowerBoundaryIsRejectedBeforeGraduation() public {
        PoolModifyLiquidityTest attackerRouter = new PoolModifyLiquidityTest(manager);
        IERC20 token = _fundTokenPosition(attackerRouter);
        uint256 balanceBefore = token.balanceOf(trader);
        _attemptPosition(attackerRouter, LOWER, LOWER + 60, Pool.tickSpacingToMaxLiquidityPerTick(60), true);
        assertEq(token.balanceOf(trader), balanceBefore);

        _graduateAndCheckPosition(LOWER, UPPER);
        _assertPositionCannotBeRemoved(attackerRouter, LOWER, UPPER);
    }

    function test_repeatedGriefAttemptsAcrossManyTicksStillLeaveFullRange() public {
        PoolModifyLiquidityTest attackerRouter = new PoolModifyLiquidityTest(manager);
        _fundTokenPosition(attackerRouter);
        uint128 maximum = Pool.tickSpacingToMaxLiquidityPerTick(60);
        for (int24 i; i < 4; ++i) {
            _attemptPosition(attackerRouter, LOWER + i * 120, LOWER + i * 120 + 60, maximum, true);
            _attemptPosition(attackerRouter, UPPER - i * 120 - 60, UPPER - i * 120, maximum, true);
        }
        _attemptPosition(attackerRouter, -60, 60, 1, true); // even one unit around the price
        _attemptPosition(attackerRouter, LOWER, UPPER, 1, true);
        assertEq(StateLibrary.getLiquidity(manager, _key(0).toId()), 0);

        _graduateAndCheckPosition(LOWER, UPPER);
    }

    function test_griefRejectedEvenWhenCurveIsAlreadyFullButNotYetGraduated() public {
        (BondingCurve curve,) = _curve(0);
        vm.prank(trader);
        curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        assertTrue(curve.readyToGraduate());
        PoolModifyLiquidityTest attackerRouter = new PoolModifyLiquidityTest(manager);
        _attemptPosition(attackerRouter, UPPER - 60, UPPER, Pool.tickSpacingToMaxLiquidityPerTick(60), true);
        vm.prank(address(0x1234));
        factory.graduate(0);
        assertEq(factory.lockedTickLower(0), LOWER);
        assertEq(factory.lockedTickUpper(0), UPPER);
    }

    function test_liquidityOpensAfterGraduationAndOwnPositionsStayRemovable() public {
        _graduateAndCheckPosition(LOWER, UPPER);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        (, IERC20 token) = _curve(0);
        vm.prank(trader);
        token.approve(address(lpRouter), type(uint256).max);
        uint128 locked = factory.lockedLiquidity(0);
        PoolId id = _key(0).toId();

        _attemptPosition(lpRouter, LOWER, UPPER, 1_000_000, false);
        assertEq(StateLibrary.getLiquidity(manager, id), locked + 1_000_000);
        _attemptPosition(lpRouter, UPPER - 60, UPPER, Pool.tickSpacingToMaxLiquidityPerTick(60) / 2, false);
        (uint128 lpLiquidity,,) = StateLibrary.getPositionInfo(manager, id, address(lpRouter), LOWER, UPPER, 0);
        assertEq(lpLiquidity, 1_000_000);

        (BalanceDelta delta, uint256 fee) = _swap(true, -int256(0.1 ether));
        assertGt(delta.amount1(), 0);
        assertEq(fee, 0.001 ether);

        vm.prank(trader);
        lpRouter.modifyLiquidity(_key(0), IPoolManager.ModifyLiquidityParams(LOWER, UPPER, -1_000_000, 0), "");
        assertEq(StateLibrary.getLiquidity(manager, id), locked);
        (uint128 stillLocked,,) = StateLibrary.getPositionInfo(manager, id, address(factory), LOWER, UPPER, 0);
        assertEq(stillLocked, locked);
        _assertPositionCannotBeRemoved(lpRouter, LOWER, UPPER);
    }

    function test_unboundPoolNamingThisHookNeverOpensLiquidity() public {
        PoolKey memory foreign = _key(0);
        foreign.fee = 500;
        manager.initialize(foreign, factory.canonicalSqrtPriceX96());
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        vm.prank(trader);
        vm.expectRevert(_liquidityClosed());
        lpRouter.modifyLiquidity{value: 0.001 ether}(
            foreign, IPoolManager.ModifyLiquidityParams(LOWER, UPPER, 1_000_000, 0), ""
        );
        _graduateAndCheckPosition(LOWER, UPPER);
        vm.prank(trader);
        vm.expectRevert(_liquidityClosed());
        lpRouter.modifyLiquidity{value: 0.001 ether}(
            foreign, IPoolManager.ModifyLiquidityParams(LOWER, UPPER, 1_000_000, 0), ""
        );
    }

    /// @dev The inward-moving range scan stays as defense in depth. Modelled via storage reads only.
    function test_defenseInDepthScanStillMovesSaturatedBoundaryInward() public {
        (BondingCurve curve,) = _curve(0);
        vm.prank(trader);
        curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        PoolId poolId = _key(0).toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), StateLibrary.POOLS_SLOT));
        bytes32 tickSlot =
            keccak256(abi.encodePacked(int256(UPPER), bytes32(uint256(stateSlot) + StateLibrary.TICKS_OFFSET)));
        bytes4 selector = bytes4(keccak256("extsload(bytes32)"));
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(selector, tickSlot),
            abi.encode(uint256(Pool.tickSpacingToMaxLiquidityPerTick(60)))
        );
        vm.prank(address(0x1234));
        factory.graduate(0);
        vm.clearMockedCalls();
        assertEq(factory.lockedTickLower(0), LOWER);
        assertEq(factory.lockedTickUpper(0), UPPER - 60);
        (uint128 locked,,) = StateLibrary.getPositionInfo(manager, poolId, address(factory), LOWER, UPPER - 60, 0);
        assertEq(locked, factory.lockedLiquidity(0));
        assertGt(locked, 0);
    }

    function test_unavailableRangeRollsBackAndCanBeRetried() public {
        (BondingCurve curve, IERC20 token) = _curve(0);
        vm.prank(trader);
        curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        uint256 tokenReserve = curve.tokenReserve();
        PoolId poolId = _key(0).toId();
        bytes32 slot0 = keccak256(abi.encode(poolId, StateLibrary.POOLS_SLOT));
        bytes32 originalSlot0 = manager.extsload(slot0);
        // Model every boundary being full while preserving the actual canonical pool price.
        bytes4 selector = bytes4(keccak256("extsload(bytes32)"));
        vm.mockCall(
            address(manager), abi.encodeWithSelector(selector), abi.encode(Pool.tickSpacingToMaxLiquidityPerTick(60))
        );
        vm.mockCall(address(manager), abi.encodeWithSelector(selector, slot0), abi.encode(originalSlot0));
        vm.expectRevert(PvPadFactory.LiquidityRangeUnavailable.selector);
        factory.graduate(0);
        vm.clearMockedCalls();

        assertFalse(curve.graduated());
        assertFalse(factory.isRegisteredPool(poolId));
        assertEq(curve.ethReserve(), 4.2 ether);
        assertEq(address(curve).balance, 4.2 ether);
        assertEq(curve.tokenReserve(), tokenReserve);
        assertEq(token.balanceOf(address(curve)), tokenReserve);
        assertEq(factory.lockedLiquidity(0), 0);
        vm.prank(address(0x1234));
        factory.graduate(0);
        assertTrue(curve.graduated());
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_thresholdSellsOfAnySizeRevertAndGraduationProceeds(uint256 amountSeed, bool protectedOverload)
        public
    {
        (BondingCurve curve, IERC20 token) = _curve(0);
        address holder = address(0xBAD);
        vm.deal(holder, 1 ether);
        vm.prank(holder);
        curve.buy{value: 0.02 ether}(holder);
        vm.prank(trader);
        curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        assertTrue(curve.readyToGraduate());
        uint256 balance = token.balanceOf(holder);
        uint256 amount = bound(amountSeed, 1, balance);
        uint256 tokenReserve = curve.tokenReserve();
        (uint256 quote, uint256 fee) = curve.quoteSell(amount);
        assertEq(quote + fee, 0);
        vm.startPrank(holder);
        token.approve(address(curve), amount);
        vm.expectRevert(BondingCurve.NotReady.selector);
        if (protectedOverload) curve.sell(amount, holder, 0, block.timestamp);
        else curve.sell(amount, holder);
        vm.expectRevert(BondingCurve.NotReady.selector);
        curve.buy{value: 1}(holder);
        vm.stopPrank();
        assertEq(curve.ethReserve(), 4.2 ether);
        assertEq(curve.tokenReserve(), tokenReserve);
        assertEq(token.balanceOf(holder), balance);
        assertTrue(curve.readyToGraduate());
        vm.prank(address(0x1234));
        factory.graduate(0);
        assertTrue(curve.graduated());
        assertTrue(factory.isRegisteredPool(_key(0).toId()));
    }

    function _liquidityClosed() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(PvPadHook.LiquidityClosed.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _fundTokenPosition(PoolModifyLiquidityTest attackerRouter) private returns (IERC20 token) {
        BondingCurve curve;
        (curve, token) = _curve(0);
        vm.startPrank(trader);
        curve.buy{value: 0.01 ether}(trader, 1, block.timestamp);
        token.approve(address(attackerRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _attemptPosition(
        PoolModifyLiquidityTest lpRouter,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        bool expectClosed
    ) private {
        PoolKey memory key = _key(0);
        vm.prank(trader);
        if (expectClosed) vm.expectRevert(_liquidityClosed());
        lpRouter.modifyLiquidity{value: 0.001 ether}(
            key, IPoolManager.ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0)), ""
        );
    }

    function _graduateAndCheckPosition(int24 lower, int24 upper) private {
        (BondingCurve curve, IERC20 token) = _curve(0);
        if (!curve.readyToGraduate()) {
            vm.prank(trader);
            curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        }
        assertTrue(curve.readyToGraduate());
        vm.prank(address(0x1234));
        factory.graduate(0);

        PoolKey memory key = _key(0);
        assertTrue(curve.graduated());
        assertTrue(factory.isRegisteredPool(key.toId()));
        assertEq(curve.ethReserve(), 0);
        assertEq(curve.tokenReserve(), 0);
        assertEq(factory.lockedTickLower(0), lower);
        assertEq(factory.lockedTickUpper(0), upper);
        (uint128 locked,,) =
            StateLibrary.getPositionInfo(manager, key.toId(), address(factory), lower, upper, bytes32(0));
        assertGt(locked, 0);
        assertEq(locked, factory.lockedLiquidity(0));
        assertEq(locked, StateLibrary.getLiquidity(manager, key.toId()));
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function _assertPositionCannotBeRemoved(PoolModifyLiquidityTest lpRouter, int24 lower, int24 upper) private {
        PoolKey memory key = _key(0);
        uint128 locked = factory.lockedLiquidity(0);
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(lower, upper, -int256(uint256(locked)), bytes32(0)), ""
        );
        (uint128 afterAttempt,,) =
            StateLibrary.getPositionInfo(manager, key.toId(), address(factory), lower, upper, bytes32(0));
        assertEq(afterAttempt, locked);
    }
}
