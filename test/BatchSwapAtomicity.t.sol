// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PvPadHook} from "src/hooks/PvPadHook.sol";
import {BatchSwapFixture, BatchSwapRouter} from "./helpers/BatchSwapFixture.sol";

/// forge-config: default.fuzz.runs = 512
contract BatchSwapAtomicityTest is BatchSwapFixture {
    using PoolIdLibrary for PoolKey;

    struct BeforeRoute {
        uint256 ethBalance;
        uint256 managerEth;
        uint256 input;
        uint256 output;
        uint256 skimmed;
        uint256 kingCredit;
        uint256 inputCreatorCredit;
        uint256 outputCreatorCredit;
    }

    function testFuzz_twoLegRouteSettlesWithoutNativePayment(uint256 amountSeed, bool reverse, bool outage) public {
        uint256 first = reverse ? 1 : 0;
        uint256 second = 1 - first;
        uint256 amount = bound(amountSeed, 1e10, 1_000_000 ether);
        _outage(outage);
        address actor = actors[1];
        BeforeRoute memory beforeRoute = _beforeRoute(actor, first, second);
        vm.prank(actor);
        BatchSwapRouter.Result memory result = router.route(keys[first], keys[second], amount, 1, 0);
        assertEq(actor.balance, beforeRoute.ethBalance, "the ETH leg is internal to the manager");
        assertEq(beforeRoute.input - tokens[first].balanceOf(actor), amount);
        assertEq(tokens[second].balanceOf(actor) - beforeRoute.output, result.tokensOut);
        assertEq(result.sellFee, (result.bridgeEth + result.sellFee) / 100);
        assertEq(result.buyFee, result.bridgeEth / 100);
        assertEq(beforeRoute.managerEth - address(manager).balance, result.sellFee + result.buyFee);
        if (outage) {
            assertEq(escrow.totalSkimmedEth(), beforeRoute.skimmed);
            assertEq(hook.deferredFees(address(escrow), creators[first], actors[0]), result.sellFee);
            assertEq(hook.deferredFees(address(escrow), creators[second], actors[0]), result.buyFee);
            assertEq(address(hook).balance, result.sellFee + result.buyFee);
            _outage(false);
            assertEq(hook.retryDeferred(escrow, creators[first], actors[0]), result.sellFee);
            assertEq(hook.retryDeferred(escrow, creators[second], actors[0]), result.buyFee);
        }
        assertEq(escrow.totalSkimmedEth() - beforeRoute.skimmed, result.sellFee + result.buyFee);
        assertEq(escrow.pending(address(0), actors[0]) - beforeRoute.kingCredit, result.sellFee / 2 + result.buyFee / 2);
        assertEq(
            escrow.pending(address(0), creators[first]) - beforeRoute.inputCreatorCredit,
            result.sellFee - result.sellFee / 2
        );
        assertEq(
            escrow.pending(address(0), creators[second]) - beforeRoute.outputCreatorCredit,
            result.buyFee - result.buyFee / 2
        );
        _assertSettled();
    }

    function _beforeRoute(address actor, uint256 first, uint256 second) private view returns (BeforeRoute memory b) {
        b.ethBalance = actor.balance;
        b.managerEth = address(manager).balance;
        b.input = tokens[first].balanceOf(actor);
        b.output = tokens[second].balanceOf(actor);
        b.skimmed = escrow.totalSkimmedEth();
        b.kingCredit = escrow.pending(address(0), actors[0]);
        b.inputCreatorCredit = escrow.pending(address(0), creators[first]);
        b.outputCreatorCredit = escrow.pending(address(0), creators[second]);
    }

    function test_secondLegPartialFillRollsBackBothDeliveredFeesAndPoolPrices() public {
        _partialFillRollback(false);
    }

    function test_secondLegPartialFillRollsBackBothDeferredFeesAndPoolPrices() public {
        _partialFillRollback(true);
    }

    function _partialFillRollback(bool outage) private {
        _outage(outage);
        bytes32 beforeState = _state();
        (uint160 price,,,) = StateLibrary.getSlot0(manager, keys[1].toId());
        vm.expectRevert(_hookError(IHooks.afterSwap.selector, PvPadHook.PartialFill.selector));
        vm.prank(actors[1]);
        router.route(keys[0], keys[1], 10_000 ether, 1, price - 1);
        assertEq(_state(), beforeState, "both legs must roll back");
        _assertSettled();
        vm.prank(actors[1]);
        BatchSwapRouter.Result memory result = router.route(keys[0], keys[1], 10_000 ether, 1, 0);
        assertGt(result.tokensOut, 0, "the next unlock must remain usable");
        _assertSettled();
    }

    function test_ungraduatedSecondLegCannotKeepFirstLegFees() public {
        factory.createLaunch{value: 0.0005 ether}("Still on curve", "CURVE");
        PoolKey memory closed = factory.getPoolKey(2);
        bytes32 beforeState = _state();
        vm.expectRevert(_hookError(IHooks.beforeSwap.selector, PvPadHook.PoolNotGraduated.selector));
        vm.prank(actors[1]);
        router.route(keys[0], closed, 10_000 ether, 1, 0);
        assertEq(_state(), beforeState);
        _assertSettled();
    }

    function testFuzz_slippageFailureAfterBothSwapsIsAtomic(uint256 amountSeed, bool outage) public {
        uint256 amount = bound(amountSeed, 1e10, 1_000_000 ether);
        _outage(outage);
        bytes32 beforeState = _state();
        vm.expectRevert(BatchSwapRouter.MinimumOutput.selector);
        vm.prank(actors[1]);
        router.route(keys[0], keys[1], amount, type(uint256).max, 0);
        assertEq(_state(), beforeState);
        _assertSettled();
    }

    function testFuzz_insufficientFinalSettlementAllowanceRollsBackBothSwaps(
        uint256 amountSeed,
        uint256 allowanceSeed,
        bool outage
    ) public {
        uint256 amount = bound(amountSeed, 1e10, 1_000_000 ether);
        uint256 allowance = bound(allowanceSeed, 0, amount - 1);
        vm.prank(actors[1]);
        tokens[0].approve(address(router), allowance);
        _outage(outage);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), allowance, amount)
        );
        vm.prank(actors[1]);
        router.route(keys[0], keys[1], amount, 1, 0);
        assertEq(_state(), beforeState);
        _assertSettled();
        vm.prank(actors[1]);
        tokens[0].approve(address(router), amount);
        vm.prank(actors[1]);
        BatchSwapRouter.Result memory result = router.route(keys[0], keys[1], amount, 1, 0);
        assertGt(result.tokensOut, 0);
        assertEq(tokens[0].allowance(actors[1], address(router)), 0);
        _assertSettled();
    }

    function testFuzz_samePoolRoundTripCannotCreateTokens(uint256 amountSeed, bool outage) public {
        uint256 amount = bound(amountSeed, 1e10, 1_000_000 ether);
        _outage(outage);
        uint256 beforeTokens = tokens[0].balanceOf(actors[1]);
        uint256 beforeEth = actors[1].balance;
        uint256 beforeManager = address(manager).balance;
        vm.prank(actors[1]);
        BatchSwapRouter.Result memory result = router.route(keys[0], keys[0], amount, 1, 0);
        assertLe(result.tokensOut, amount, "selling and rebuying must never profit");
        assertEq(tokens[0].balanceOf(actors[1]), beforeTokens - amount + result.tokensOut);
        assertEq(actors[1].balance, beforeEth);
        assertEq(beforeManager - address(manager).balance, result.sellFee + result.buyFee);
        _assertSettled();
    }

    function test_samePoolOddWeiFeesKeepTheirPerLegRoundingWhenRetried() public {
        uint256 creatorBefore = escrow.pending(address(0), creators[0]);
        uint256 kingBefore = escrow.pending(address(0), actors[0]);
        _outage(true);
        vm.prank(actors[1]);
        BatchSwapRouter.Result memory result = router.route(keys[0], keys[0], 1e10, 1, 0);
        assertEq(result.sellFee, 1);
        assertEq(result.buyFee, 1);
        assertEq(hook.deferredFees(address(escrow), creators[0], actors[0]), 2);
        assertEq(hook.deferredKingShares(address(escrow), creators[0], actors[0]), 0);
        _outage(false);
        assertEq(hook.retryDeferred(escrow, creators[0], actors[0]), 2);
        assertEq(escrow.pending(address(0), creators[0]), creatorBefore + 2);
        assertEq(escrow.pending(address(0), actors[0]), kingBefore);
        assertEq(hook.totalDeferred(), 0);
        _assertSettled();
    }

    function _hookError(bytes4 callback, bytes4 reason) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
