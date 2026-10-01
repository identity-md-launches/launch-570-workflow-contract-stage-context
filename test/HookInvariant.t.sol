// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PvPadFactory} from "src/PvPadFactory.sol";
import {PvPadHook} from "src/hooks/PvPadHook.sol";
import {WorkerSubsidy} from "src/WorkerSubsidy.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {HookMiner} from "src/utils/HookMiner.sol";

contract HookInvariantRejectEther {
    receive() external payable {
        revert("receiver unavailable");
    }
}

/// @dev Real v4 execution and settlement; only the escrow's two delivery entry points are
/// fault-injected. Ghost fees come from actual ETH paid/received and pool balance movement,
/// never from the hook's fee counters or the escrow's credits.
contract HookInvariantHandler is Test {
    using PoolIdLibrary for PoolKey;

    PvPadFactory public immutable factory;
    PvPadHook public immutable hook;
    FeeEscrow public immutable escrow;
    KingOfThePad public immutable king;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    PoolModifyLiquidityTest public immutable liquidityRouter;
    HookInvariantRejectEther public immutable rejector;
    address[3] public actors;
    address[2] public creators;
    uint128[2] public initialLiquidity;
    int24[2] public initialTickLower;
    int24[2] public initialTickUpper;
    mapping(address => uint256) public expectedPending;
    mapping(uint256 => mapping(address => uint256)) public expectedDeferred;
    mapping(uint256 => mapping(address => uint256)) public expectedDeferredKing;
    uint256 public captured;
    uint256 public withdrawn;
    uint256 public expectedWorkerPot;
    uint256 public swaps;
    bool public deliveryFails;

    constructor(PvPadFactory factory_, PoolSwapTest router_, address[3] memory actors_, address[2] memory creators_) {
        factory = factory_;
        hook = factory_.hook();
        escrow = factory_.feeEscrow();
        king = factory_.kingOfThePad();
        manager = factory_.poolManager();
        router = router_;
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        rejector = new HookInvariantRejectEther();
        actors = actors_;
        creators = creators_;
        // Each seeded curve receives exactly 4.2 ETH net from a capped buy.
        uint256 seedFee = (uint256(4.2 ether) - 1) / 99;
        captured = 2 * seedFee;
        expectedPending[actors_[0]] = 2 * (seedFee / 2);
        expectedWorkerPot = 0.02 ether + 0.0005 ether;
        for (uint256 i; i < 2; ++i) {
            expectedPending[creators_[i]] = seedFee - seedFee / 2;
            initialLiquidity[i] = factory_.lockedLiquidity(i);
            initialTickLower[i] = factory_.lockedTickLower(i);
            initialTickUpper[i] = factory_.lockedTickUpper(i);
            require(initialLiquidity[i] != 0, "fixture needs locked pools");
        }
        require(escrow.totalSkimmedEth() == captured, "incorrect seed fee");
    }

    function setDeliveryFailure(bool fail) public {
        deliveryFails = fail;
        if (fail) {
            vm.mockCallRevert(
                address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeFor.selector), "delivery failed"
            );
            vm.mockCallRevert(
                address(escrow),
                abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeShares.selector),
                "delivery failed"
            );
        } else {
            vm.clearMockedCalls();
        }
    }

    function swap(uint8 launchSeed, uint8 actorSeed, uint8 modeSeed, uint128 amountSeed) public {
        uint256 launch = launchSeed % 2;
        address actor = actors[actorSeed % 3];
        uint256 mode = modeSeed % 4;
        bool buy = mode < 2;
        // Modes: exact ETH input, exact token output, exact token input, exact ETH output.
        uint256 amount = mode == 0
            ? bound(amountSeed, 1, 0.1 ether)
            : mode == 3 ? bound(amountSeed, 1, 0.001 ether) : bound(amountSeed, 1e10, 10_000 ether);
        int256 specified = mode == 0 || mode == 2 ? -int256(amount) : int256(amount);
        PoolKey memory key = factory.getPoolKey(launch);
        uint256 traderBefore = actor.balance;
        uint256 managerBefore = address(manager).balance;
        address beneficiary = king.beneficiary();
        vm.prank(actor);
        BalanceDelta delta = router.swap{value: buy ? 1 ether : 0}(
            key,
            IPoolManager.SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 gross;
        uint256 fee;
        if (buy) {
            gross = traderBefore - actor.balance;
            fee = gross / 100;
            assertEq(address(manager).balance - managerBefore, gross - fee, "pool keeps only net buy ETH");
            assertEq(int256(delta.amount0()), -int256(gross));
            assertGt(delta.amount1(), 0);
        } else {
            gross = managerBefore - address(manager).balance;
            fee = gross / 100;
            assertEq(actor.balance - traderBefore, gross - fee, "seller receives gross output less fee");
            assertEq(uint256(uint128(delta.amount0())), gross - fee);
            assertLt(delta.amount1(), 0);
        }
        if (mode == 0) assertEq(gross, amount);
        if (mode == 1) assertEq(uint256(uint128(delta.amount1())), amount);
        if (mode == 2) assertEq(uint256(uint128(-delta.amount1())), amount);
        if (mode == 3) assertEq(actor.balance - traderBefore, amount);
        _capture(launch, beneficiary, fee);
        ++swaps;
    }

    function _capture(uint256 launch, address beneficiary, uint256 fee) private {
        captured += fee;
        if (deliveryFails) {
            expectedDeferred[launch][beneficiary] += fee;
            expectedDeferredKing[launch][beneficiary] += fee / 2;
        } else {
            expectedPending[beneficiary] += fee / 2;
            expectedPending[creators[launch]] += fee - fee / 2;
        }
    }

    function claimKing(uint8 actorSeed, uint8 beneficiarySeed) public {
        address actor = actors[actorSeed % 3];
        uint256 bid = king.claimPrice() + 1;
        vm.prank(actor);
        king.claimKing{value: bid}(actors[beneficiarySeed % 3]);
        expectedWorkerPot += bid;
    }

    function retry(uint8 launchSeed, uint8 beneficiarySeed) public {
        uint256 launch = launchSeed % 2;
        address beneficiary = actors[beneficiarySeed % 3];
        uint256 amount = expectedDeferred[launch][beneficiary];
        uint256 kingShare = expectedDeferredKing[launch][beneficiary];
        uint256 delivered = hook.retryDeferred(escrow, creators[launch], beneficiary);
        if (deliveryFails) {
            assertEq(delivered, 0, "failed delivery must keep original liability");
        } else {
            assertEq(delivered, amount, "retry delivers exactly the captured bucket");
            expectedDeferred[launch][beneficiary] = 0;
            expectedDeferredKing[launch][beneficiary] = 0;
            expectedPending[beneficiary] += kingShare;
            expectedPending[creators[launch]] += amount - kingShare;
        }
    }

    function withdraw(uint8 payeeSeed, uint8 recipientSeed, bool reject) public {
        address payee = _payee(payeeSeed % 5);
        address recipient = reject ? address(rejector) : actors[recipientSeed % 3];
        uint256 beforeBalance = recipient.balance;
        vm.prank(payee);
        uint256 paid = escrow.withdraw(address(0), recipient);
        if (reject) {
            assertEq(paid, 0);
            assertEq(escrow.pending(address(0), payee), expectedPending[payee]);
        } else {
            assertEq(paid, expectedPending[payee]);
            assertEq(recipient.balance - beforeBalance, paid);
            expectedPending[payee] = 0;
            withdrawn += paid;
        }
    }

    function attackLockedPosition(uint8 launchSeed, uint8 actorSeed) public {
        uint256 launch = launchSeed % 2;
        PoolKey memory key = factory.getPoolKey(launch);
        vm.prank(actors[actorSeed % 3]);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        liquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                initialTickLower[launch],
                initialTickUpper[launch],
                -int256(uint256(initialLiquidity[launch])),
                bytes32(launch)
            ),
            ""
        );
        vm.expectRevert(PvPadFactory.InvalidCallback.selector);
        factory.unlockCallback(abi.encode(key, uint256(0), uint256(0), launch));
        vm.expectRevert(PvPadFactory.AlreadyGraduated.selector);
        factory.graduate(launch);
        (,, address curve,,) = factory.launches(launch);
        vm.expectRevert(BondingCurve.Graduated.selector);
        BondingCurve(payable(curve)).sell(1, actors[0]);
    }

    function assertFeeConservation() public view {
        uint256 pending;
        uint256 deferred;
        for (uint256 i; i < 5; ++i) {
            address payee = _payee(i);
            assertEq(escrow.pending(address(0), payee), expectedPending[payee], "wrong payee allocation");
            pending += expectedPending[payee];
        }
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 3; ++j) {
                address beneficiary = actors[j];
                uint256 amount = expectedDeferred[i][beneficiary];
                assertEq(hook.deferredFees(address(escrow), creators[i], beneficiary), amount);
                assertEq(
                    hook.deferredKingShares(address(escrow), creators[i], beneficiary),
                    expectedDeferredKing[i][beneficiary]
                );
                deferred += amount;
            }
        }
        assertEq(hook.totalDeferred(), deferred);
        assertEq(address(hook).balance, deferred, "every deferred wei remains in hook custody");
        assertEq(address(escrow).balance, pending, "escrow assets equal outstanding credits");
        assertEq(escrow.totalPendingEth(), pending);
        assertEq(escrow.totalWithdrawnEth(), withdrawn);
        assertEq(escrow.totalSkimmedEth() + deferred, captured);
        assertEq(pending + deferred + withdrawn, captured, "all captured fees accounted for exactly once");
        assertEq(escrow.unassignedEth(), 0);
    }

    function assertLockedLiquidityAndSupply() public view {
        for (uint256 i; i < 2; ++i) {
            (, address tokenAddress, address curveAddress, bool graduated, PoolId id) = factory.launches(i);
            IERC20 token = IERC20(tokenAddress);
            BondingCurve curve = BondingCurve(payable(curveAddress));
            assertTrue(graduated && curve.graduated() && factory.isRegisteredPool(id));
            assertEq(curve.ethReserve(), 0);
            assertEq(curve.tokenReserve(), 0);
            assertEq(address(curve).balance, 0);
            (uint128 liquidity,,) = StateLibrary.getPositionInfo(
                manager, id, address(factory), initialTickLower[i], initialTickUpper[i], bytes32(i)
            );
            assertEq(liquidity, initialLiquidity[i], "graduation position cannot be withdrawn");
            assertEq(factory.lockedLiquidity(i), liquidity);
            assertEq(factory.lockedTickLower(i), initialTickLower[i]);
            assertEq(factory.lockedTickUpper(i), initialTickUpper[i]);
            assertEq(StateLibrary.getLiquidity(manager, id), liquidity);
            uint256 accounted =
                token.balanceOf(address(manager)) + token.balanceOf(address(factory)) + token.balanceOf(curveAddress);
            for (uint256 j; j < 3; ++j) {
                accounted += token.balanceOf(actors[j]);
            }
            assertEq(accounted, 1e27, "all launch tokens stay with traders or locked reserve custody");
            assertEq(token.totalSupply(), 1e27);
        }
        assertEq(address(router).balance, 0, "router refunds all unused ETH");
        assertEq(factory.workerSubsidy().workerPot(), expectedWorkerPot);
        assertEq(address(factory.workerSubsidy()).balance, expectedWorkerPot);
    }

    function _payee(uint256 index) private view returns (address) {
        return index < 3 ? actors[index] : creators[index - 3];
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract HookInvariantTest is Test {
    HookInvariantHandler public handler;

    function setUp() public {
        address[3] memory actors = [address(0xA100), address(0xA101), address(0xA102)];
        address[2] memory creators = [address(0xC100), address(0xC101)];
        PoolManager manager = new PoolManager(address(this));
        PoolSwapTest router = new PoolSwapTest(manager);
        WorkerSubsidy workers = new WorkerSubsidy(address(this));
        KingOfThePad king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        PvPadHook hook = new PvPadHook{salt: salt}(manager);
        PvPadFactory factory = new PvPadFactory(manager, workers, king, hook, creators[0]);
        vm.deal(address(this), 100 ether);
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1_000_000 ether);
        }
        king.claimKing{value: 0.02 ether}(actors[0]);
        vm.deal(creators[1], 0.0005 ether);
        vm.prank(creators[1]);
        factory.createLaunch{value: 0.0005 ether}("Second invariant launch", "SECOND");
        for (uint256 i; i < 2; ++i) {
            _seedPool(factory, router, actors, i);
        }
        handler = new HookInvariantHandler(factory, router, actors, creators);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.claimKing.selector;
        selectors[2] = handler.setDeliveryFailure.selector;
        selectors[3] = handler.retry.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.attackLockedPosition.selector;
        selectors[6] = handler.swap.selector; // Give real swaps twice the weight of each auxiliary action.
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function _seedPool(PvPadFactory factory, PoolSwapTest router, address[3] memory actors, uint256 launch) private {
        (, address tokenAddress, address curveAddress,,) = factory.launches(launch);
        IERC20 token = IERC20(tokenAddress);
        vm.prank(actors[0]);
        BondingCurve(payable(curveAddress)).buy{value: 5 ether}(actors[0], 1, block.timestamp);
        // Launch 1 faces boundary-saturation attempts before graduation (the hook rejects them) and a
        // real foreign position afterwards (liquidity opens once graduated).
        if (launch == 1) _attemptBoundarySaturation(factory, actors[0], token, launch, true);
        factory.graduate(launch);
        assertEq(factory.lockedTickLower(launch), TickMath.minUsableTick(60));
        assertEq(factory.lockedTickUpper(launch), TickMath.maxUsableTick(60));
        if (launch == 1) _attemptBoundarySaturation(factory, actors[0], token, launch, false);
        uint256 share = token.balanceOf(actors[0]) / 3;
        for (uint256 j = 1; j < 3; ++j) {
            vm.prank(actors[0]);
            token.transfer(actors[j], share);
        }
        for (uint256 j; j < 3; ++j) {
            vm.prank(actors[j]);
            token.approve(address(router), type(uint256).max);
        }
    }

    function _attemptBoundarySaturation(
        PvPadFactory factory,
        address actor,
        IERC20 token,
        uint256 launch,
        bool expectClosed
    ) private {
        PoolModifyLiquidityTest attacker = new PoolModifyLiquidityTest(factory.poolManager());
        PoolKey memory key = factory.getPoolKey(launch);
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        // Pre-graduation attempts use the full per-tick cap (the grief); the post-graduation foreign
        // position leaves room for the factory's full-range liquidity already sharing the boundary.
        int256 maximum = int256(uint256(Pool.tickSpacingToMaxLiquidityPerTick(60)));
        if (!expectClosed) maximum /= 2;
        bytes memory closed = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(factory.hook()),
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(PvPadHook.LiquidityClosed.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.startPrank(actor);
        token.approve(address(attacker), type(uint256).max);
        if (expectClosed) vm.expectRevert(closed);
        attacker.modifyLiquidity{value: 0.001 ether}(
            key, IPoolManager.ModifyLiquidityParams(lower, lower + 60, maximum, bytes32(0)), ""
        );
        if (expectClosed) vm.expectRevert(closed);
        attacker.modifyLiquidity{value: 0.001 ether}(
            key, IPoolManager.ModifyLiquidityParams(upper - 60, upper, maximum, bytes32(0)), ""
        );
        vm.stopPrank();
    }

    function invariant_realPoolFeeCustodyAndBeneficiaryAccounting() public view {
        handler.assertFeeConservation();
    }

    function invariant_graduationRemainsFinalAndPositionsRemainLocked() public view {
        handler.assertLockedLiquidityAndSupply();
    }

    function test_realPoolDeferredOddWeiKeepCreatorAndOriginalKingAcrossRetries() public {
        handler.setDeliveryFailure(true);
        handler.swap(0, 0, 0, 100);
        handler.swap(0, 1, 0, 100);
        assertEq(handler.hook().totalDeferred(), 2);
        handler.claimKing(1, 1);
        handler.retry(0, 0);
        handler.assertFeeConservation();
        handler.setDeliveryFailure(false);
        handler.retry(0, 0);
        handler.retry(0, 0);
        handler.withdraw(3, 0, true);
        handler.withdraw(3, 2, false);
        handler.assertFeeConservation();
        handler.assertLockedLiquidityAndSupply();
    }

    function test_allFourModesPreserveAccountingWhenFeeDeliveryFails() public {
        handler.setDeliveryFailure(true);
        for (uint8 i; i < 4; ++i) {
            handler.swap(i % 2, i % 3, i, i % 3 == 0 ? uint128(0.001 ether) : uint128(1_000 ether));
        }
        assertEq(handler.swaps(), 4);
        assertGt(handler.hook().totalDeferred(), 0);
        handler.claimKing(2, 2);
        handler.assertFeeConservation();
        handler.setDeliveryFailure(false);
        handler.retry(0, 0);
        handler.retry(1, 0);
        handler.assertFeeConservation();
        handler.attackLockedPosition(0, 0);
        handler.attackLockedPosition(1, 1);
        handler.assertLockedLiquidityAndSupply();
    }

    function test_fullRangeGraduationWithForeignPositionsRemainsLockedAcrossAllSwapModes() public {
        assertEq(handler.initialTickLower(1), TickMath.minUsableTick(60));
        assertEq(handler.initialTickUpper(1), TickMath.maxUsableTick(60));
        PoolId id = handler.factory().getPoolKey(1).toId();
        (uint128 foreignGross,) = StateLibrary.getTickLiquidity(handler.manager(), id, TickMath.maxUsableTick(60));
        assertEq(foreignGross, Pool.tickSpacingToMaxLiquidityPerTick(60) / 2 + handler.initialLiquidity(1));
        for (uint8 mode; mode < 4; ++mode) {
            handler.swap(1, mode % 3, mode, mode == 0 || mode == 3 ? uint128(0.001 ether) : uint128(1_000 ether));
            handler.attackLockedPosition(1, mode % 3);
            handler.assertFeeConservation();
            handler.assertLockedLiquidityAndSupply();
        }
        assertEq(handler.swaps(), 4);
    }
}
