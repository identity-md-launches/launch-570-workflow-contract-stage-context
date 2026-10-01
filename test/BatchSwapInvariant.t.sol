// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PvPadFactory} from "src/PvPadFactory.sol";
import {PvPadHook} from "src/hooks/PvPadHook.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {BatchSwapFixture, BatchSwapRouter} from "./helpers/BatchSwapFixture.sol";

/// @dev Independent payee ledger: amounts come from actual per-leg ETH transfers in
/// the router; destinations come from the actors selected by this handler. Never
/// initialize entitlements from the escrow or update ghosts from its fee counters.
contract BatchSwapHandler is Test {
    using PoolIdLibrary for PoolKey;

    struct BeforeRoute {
        uint256 input;
        uint256 output;
        uint256 actorEth;
        uint256 managerEth;
    }

    PvPadFactory public immutable factory;
    IPoolManager public immutable manager;
    BatchSwapRouter public immutable router;
    PvPadHook public immutable hook;
    FeeEscrow public immutable escrow;
    KingOfThePad public immutable king;
    address[3] public actors;
    address[2] public creators;
    uint128[2] public initialLiquidity;
    uint256 public immutable initialManagerEth;
    uint256 public routeFees;
    uint256 public withdrawn;
    uint256 public routes;
    uint256 public crowns;
    uint256 public expectedPot = 0.0205 ether;
    uint256 public expectedPrice = 0.011 ether;
    uint256 public beneficiaryIndex;
    bool public outage;
    mapping(address => uint256) public expectedPending;
    mapping(uint256 => mapping(uint256 => uint256)) public deferred;
    mapping(uint256 => mapping(uint256 => uint256)) public deferredKing;
    uint256 private constant SEED_FEE = (uint256(4.2 ether) - 1) / 99;

    constructor(
        PvPadFactory factory_,
        BatchSwapRouter router_,
        address[3] memory actors_,
        address[2] memory creators_
    ) {
        factory = factory_;
        manager = factory_.poolManager();
        router = router_;
        hook = factory_.hook();
        escrow = factory_.feeEscrow();
        king = factory_.kingOfThePad();
        actors = actors_;
        creators = creators_;
        initialManagerEth = address(manager).balance;
        expectedPending[actors[0]] = 2 * (SEED_FEE / 2);
        for (uint256 i; i < 2; ++i) {
            expectedPending[creators[i]] = SEED_FEE - SEED_FEE / 2;
            initialLiquidity[i] = factory_.lockedLiquidity(i);
            require(initialLiquidity[i] > 0, "pools must be graduated");
        }
    }

    function route(uint8 actorSeed, bool reverse, bool samePool, uint256 amountSeed) public {
        uint256 first = reverse ? 1 : 0;
        uint256 second = samePool ? first : 1 - first;
        address actor = actors[actorSeed % actors.length];
        _route(actor, first, second, bound(amountSeed, 1e10, 100_000 ether));
    }

    function _route(address actor, uint256 first, uint256 second, uint256 amount) private {
        PoolKey memory firstKey = factory.getPoolKey(first);
        PoolKey memory secondKey = factory.getPoolKey(second);
        IERC20 input = IERC20(Currency.unwrap(firstKey.currency1));
        IERC20 output = IERC20(Currency.unwrap(secondKey.currency1));
        BeforeRoute memory b =
            BeforeRoute(input.balanceOf(actor), output.balanceOf(actor), actor.balance, address(manager).balance);
        vm.prank(actor);
        BatchSwapRouter.Result memory result = router.route(firstKey, secondKey, amount, 1, 0);
        assertEq(result.sellFee, (result.bridgeEth + result.sellFee) / 100, "sell fee is 1% of gross ETH");
        assertEq(result.buyFee, result.bridgeEth / 100, "buy fee is 1% of gross ETH");
        assertEq(actor.balance, b.actorEth, "no external ETH bridge payment");
        assertEq(b.managerEth - address(manager).balance, result.sellFee + result.buyFee);
        if (first == second) {
            assertLe(result.tokensOut, amount, "same-pool round trip cannot profit");
            assertEq(input.balanceOf(actor), b.input - amount + result.tokensOut);
        } else {
            assertEq(input.balanceOf(actor), b.input - amount);
            assertEq(output.balanceOf(actor), b.output + result.tokensOut);
        }
        _capture(first, result.sellFee);
        _capture(second, result.buyFee);
        ++routes;
    }

    function setOutage(bool fail) public {
        outage = fail;
        if (!fail) {
            vm.clearMockedCalls();
            return;
        }
        vm.mockCallRevert(address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeFor.selector), "outage");
        vm.mockCallRevert(
            address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeShares.selector), "outage"
        );
    }

    function crown(uint8 actorSeed, uint8 beneficiarySeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 bid = expectedPrice + 1;
        beneficiaryIndex = beneficiarySeed % actors.length;
        vm.prank(actor);
        king.claimKing{value: bid}(actors[beneficiaryIndex]);
        expectedPot += bid;
        expectedPrice = expectedPrice * 11 / 10;
        ++crowns;
    }

    function retry(uint8 launchSeed, uint8 beneficiarySeed, uint8 callerSeed) public {
        uint256 launch = launchSeed % 2;
        uint256 beneficiary = beneficiarySeed % actors.length;
        uint256 amount = deferred[launch][beneficiary];
        uint256 kingShare = deferredKing[launch][beneficiary];
        vm.prank(actors[callerSeed % actors.length]);
        uint256 delivered = hook.retryDeferred(escrow, creators[launch], actors[beneficiary]);
        assertEq(delivered, outage ? 0 : amount);
        if (!outage) {
            expectedPending[creators[launch]] += amount - kingShare;
            expectedPending[actors[beneficiary]] += kingShare;
            deferred[launch][beneficiary] = 0;
            deferredKing[launch][beneficiary] = 0;
        }
    }

    function withdraw(uint8 payeeSeed) public {
        uint256 index = payeeSeed % 5;
        address payee = index < 3 ? actors[index] : creators[index - 3];
        uint256 amount = expectedPending[payee];
        uint256 balanceBefore = payee.balance;
        vm.prank(payee);
        assertEq(escrow.withdraw(address(0), payee), amount);
        assertEq(payee.balance - balanceBefore, amount);
        expectedPending[payee] = 0;
        withdrawn += amount;
    }

    function rejectRoute(uint8 actorSeed, bool reverse) public {
        uint256 first = reverse ? 1 : 0;
        PoolKey memory firstKey = factory.getPoolKey(first);
        PoolKey memory secondKey = factory.getPoolKey(1 - first);
        (uint160 firstPrice,,,) = StateLibrary.getSlot0(manager, firstKey.toId());
        (uint160 secondPrice,,,) = StateLibrary.getSlot0(manager, secondKey.toId());
        vm.expectRevert(BatchSwapRouter.MinimumOutput.selector);
        vm.prank(actors[actorSeed % actors.length]);
        router.route(firstKey, secondKey, 100 ether, type(uint256).max, 0);
        (uint160 firstAfter,,,) = StateLibrary.getSlot0(manager, firstKey.toId());
        (uint160 secondAfter,,,) = StateLibrary.getSlot0(manager, secondKey.toId());
        assertEq(firstAfter, firstPrice);
        assertEq(secondAfter, secondPrice);
        // No ghost changes: the next invariant also verifies fee and custody rollback.
    }

    function _capture(uint256 launch, uint256 fee) private {
        routeFees += fee;
        if (outage) {
            deferred[launch][beneficiaryIndex] += fee;
            deferredKing[launch][beneficiaryIndex] += fee / 2;
        } else {
            expectedPending[creators[launch]] += fee - fee / 2;
            expectedPending[actors[beneficiaryIndex]] += fee / 2;
        }
    }

    function checkFeeLedger() public view {
        uint256 pendingSum;
        uint256 deferredSum;
        for (uint256 i; i < 5; ++i) {
            address payee = i < 3 ? actors[i] : creators[i - 3];
            assertEq(escrow.pending(address(0), payee), expectedPending[payee]);
            pendingSum += expectedPending[payee];
        }
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(hook.deferredFees(address(escrow), creators[i], actors[j]), deferred[i][j]);
                assertEq(hook.deferredKingShares(address(escrow), creators[i], actors[j]), deferredKing[i][j]);
                deferredSum += deferred[i][j];
            }
        }
        assertEq(2 * SEED_FEE + routeFees, pendingSum + deferredSum + withdrawn);
        assertEq(escrow.totalSkimmedEth(), 2 * SEED_FEE + routeFees - deferredSum);
        assertEq(escrow.totalPendingEth(), pendingSum);
        assertEq(escrow.totalWithdrawnEth(), withdrawn);
        assertEq(escrow.unassignedEth(), 0);
        assertEq(address(escrow).balance, pendingSum);
        assertEq(hook.totalDeferred(), deferredSum);
        assertEq(address(hook).balance, deferredSum);
        assertEq(address(manager).balance + routeFees, initialManagerEth);
        assertEq(factory.workerSubsidy().workerPot(), expectedPot);
        assertEq(address(factory.workerSubsidy()).balance, expectedPot);
        assertEq(king.claimPrice(), expectedPrice);
        assertEq(king.claimCount(), 1 + crowns);
        assertEq(king.beneficiary(), actors[beneficiaryIndex]);
        assertEq(king.firstBeneficiary(), actors[0]);
    }

    function checkCustodyAndLocks() public view {
        assertFalse(TransientStateLibrary.isUnlocked(manager));
        assertEq(TransientStateLibrary.getNonzeroDeltaCount(manager), 0);
        assertEq(address(router).balance, 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(router), Currency.wrap(address(0))), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(hook), Currency.wrap(address(0))), 0);
        for (uint256 i; i < 2; ++i) {
            PoolKey memory key = factory.getPoolKey(i);
            IERC20 token = IERC20(Currency.unwrap(key.currency1));
            uint256 held = token.balanceOf(address(manager)) + token.balanceOf(address(factory));
            for (uint256 j; j < actors.length; ++j) {
                held += token.balanceOf(actors[j]);
            }
            assertEq(token.totalSupply(), 1e27);
            assertEq(held, 1e27);
            assertEq(token.balanceOf(address(router)), 0);
            assertEq(TransientStateLibrary.currencyDelta(manager, address(router), key.currency1), 0);
            (uint128 locked,,) =
                StateLibrary.getPositionInfo(manager, key.toId(), address(factory), -887220, 887220, bytes32(i));
            assertEq(locked, initialLiquidity[i]);
            assertEq(StateLibrary.getLiquidity(manager, key.toId()), initialLiquidity[i]);
            assertTrue(factory.isRegisteredPool(key.toId()));
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BatchSwapInvariantTest is BatchSwapFixture {
    BatchSwapHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new BatchSwapHandler(factory, router, actors, creators);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.route.selector;
        selectors[1] = handler.setOutage.selector;
        selectors[2] = handler.crown.selector;
        selectors[3] = handler.retry.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.rejectRoute.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_eachLegKeepsItsCreatorAndCapturedKingEntitlement() public view {
        handler.checkFeeLedger();
    }

    function invariant_batchSettlementConservesSupplyAndLockedLiquidity() public view {
        handler.checkCustodyAndLocks();
    }

    function test_sequenceDefersBothLegsRotatesKingAndRetriesEachOriginalBucket() public {
        handler.setOutage(true);
        handler.route(1, false, false, 10_000 ether);
        handler.checkFeeLedger();
        handler.crown(2, 2);
        handler.route(2, true, false, 20_000 ether);
        handler.route(0, false, true, 30_000 ether);
        handler.retry(0, 0, 1); // Failed delivery preserves the old king's bucket.
        handler.rejectRoute(0, false);
        handler.checkFeeLedger();
        handler.setOutage(false);
        for (uint8 i; i < 2; ++i) {
            for (uint8 j; j < 3; ++j) {
                handler.retry(i, j, 1);
            }
        }
        for (uint8 i; i < 5; ++i) {
            handler.withdraw(i);
        }
        handler.route(1, true, true, 1e10);
        handler.checkFeeLedger();
        handler.checkCustodyAndLocks();
        assertEq(handler.routes(), 4);
        assertEq(hook.totalDeferred(), 0);
        assertGt(handler.withdrawn(), 0);
    }
}
