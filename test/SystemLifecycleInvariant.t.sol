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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PvPadFactory} from "src/PvPadFactory.sol";
import {PvPadHook} from "src/hooks/PvPadHook.sol";
import {WorkerSubsidy} from "src/WorkerSubsidy.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {HookMiner} from "src/utils/HookMiner.sol";
import {PvPadConstants} from "src/libraries/PvPadConstants.sol";

/// @dev Drives the whole deployment (real factory, real PoolManager, shared hook, escrow, king, worker
/// pot) through random lifecycle sequences: launches are created on the fly, curves are traded, filled
/// and graduated, graduated pools are swapped in all four modes, the crown changes hands, fee delivery
/// is fault-injected and retried, and value is pushed into the contracts outside the accounted paths.
/// Ghost figures are measured from actual ETH and token movement, never read back from the counters
/// they are checked against. Expected failures assert their exact revert; any other revert fails the
/// campaign.
contract SystemLifecycleHandler is Test {
    using PoolIdLibrary for PoolKey;

    uint256 public constant MAX_LAUNCHES = 4;
    uint256 internal constant THRESHOLD = PvPadConstants.GRADUATION_THRESHOLD;
    uint256 internal constant SUPPLY = PvPadConstants.TOKEN_SUPPLY;
    uint256 internal constant LAUNCH_FEE = PvPadConstants.DEFAULT_LAUNCH_FEE;

    PvPadFactory public immutable factory;
    PvPadHook public immutable hook;
    FeeEscrow public immutable escrow;
    KingOfThePad public immutable king;
    WorkerSubsidy public immutable workers;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    address[3] public actors;
    address[2] public creators;

    // Independent ledger.
    mapping(uint256 => address) public creatorOf;
    mapping(uint256 => bool) public ghostGraduated;
    mapping(uint256 => uint128) public lockedLiquidityAt;
    mapping(uint256 => uint256) public ghostTokenDonated;
    mapping(uint256 => mapping(address => uint256)) public ghostCurveDeferred;
    mapping(uint256 => mapping(address => uint256)) public ghostCurveDeferredKing;
    mapping(address => mapping(address => uint256)) public ghostHookDeferred;
    mapping(address => mapping(address => uint256)) public ghostHookDeferredKing;
    mapping(address => uint256) public ghostCredit;
    mapping(address => uint256) public ghostWithdrawn;
    uint256 public ghostFees;
    uint256 public ghostUnassigned;
    uint256 public ghostWorkerPot;
    uint256 public ghostClaimPrice = PvPadConstants.INITIAL_CLAIM_PRICE;
    uint256 public ghostClaims;
    address public ghostFirstBeneficiary;
    uint256 public ghostManagerEth;
    uint256 public ghostFactoryDust;
    bool public outage;

    // Coverage counters for the deterministic drive.
    uint256 public curveBuys;
    uint256 public curveSells;
    uint256 public graduations;
    uint256 public poolSwaps;
    uint256 public deferrals;
    uint256 public deliveries;
    uint256 public realignedLaunches;
    uint256 public resaltedLaunches;

    constructor(PvPadFactory factory_, PoolSwapTest router_, address[3] memory actors_, address[2] memory creators_) {
        factory = factory_;
        hook = factory_.hook();
        escrow = factory_.feeEscrow();
        king = factory_.kingOfThePad();
        workers = factory_.workerSubsidy();
        manager = factory_.poolManager();
        router = router_;
        actors = actors_;
        creators = creators_;
        require(factory_.launchCount() == 1, "fixture must hold only genesis");
        creatorOf[0] = creators_[0];
        _approveAll(0);
    }

    // ------------------------------------------------------------------ launches

    function createLaunch(uint8 creatorSeed) public {
        uint256 id = factory.launchCount();
        if (id >= MAX_LAUNCHES) return;
        address creator = creators[creatorSeed % 2];
        string memory name = string.concat("System launch ", vm.toString(id));
        uint256 potBefore = workers.workerPot();
        vm.prank(creator);
        uint256 got = factory.createLaunch{value: LAUNCH_FEE}(name, "SYS");
        assertEq(got, id, "launch ids are sequential");
        assertEq(factory.launchCount(), id + 1);
        (address launchCreator, address tokenAddress, address curveAddress, bool graduated, PoolId poolId) =
            factory.launches(id);
        assertEq(launchCreator, creator);
        assertFalse(graduated);
        assertTrue(factory.isBondingCurve(curveAddress));
        assertEq(factory.poolCreator(poolId), creator);
        assertEq(IERC20(tokenAddress).balanceOf(curveAddress), SUPPLY, "whole supply sits on the curve");
        assertEq(BondingCurve(payable(curveAddress)).tokenReserve(), SUPPLY);
        assertEq(workers.workerPot() - potBefore, LAUNCH_FEE, "launch fee funds the workers in full");
        creatorOf[id] = creator;
        ghostWorkerPot += LAUNCH_FEE;
        _approveAll(id);
    }

    struct RecoveryBalances {
        uint256 managerEth;
        uint256 hookEth;
        uint256 escrowEth;
        uint256 creatorEth;
    }

    /// @dev Exercise both recovery paths while other launches may already hold reserves, locked LP
    /// or deferred fees. The existing ledgers must still balance after every later action.
    function poisonAndCreateLaunch(uint8 creatorSeed, uint8 depthSeed, uint160 priceSeed, bool exhaust) public {
        uint256 id = factory.launchCount();
        if (id >= MAX_LAUNCHES) return;
        address creator = creators[creatorSeed % 2];
        uint160 poison;
        address[] memory candidates;
        address predicted;
        {
            string memory name = string.concat("System launch ", vm.toString(id));
            uint256 attempts = factory.MAX_SALT_ATTEMPTS();
            uint256 depth = exhaust ? attempts : bound(depthSeed, 1, attempts - 1);
            uint160 canonical = factory.canonicalSqrtPriceX96();
            poison = depthSeed % 2 == 0
                ? uint160(bound(priceSeed, TickMath.MIN_SQRT_PRICE, canonical - 1))
                : uint160(bound(priceSeed, canonical + 1, TickMath.MAX_SQRT_PRICE - 1));
            candidates = new address[](depth);
            for (uint256 i; i < depth; ++i) {
                (address candidate, uint256 attempt) = factory.predictLaunchToken(creator, name, "SYS", bytes32(0));
                assertEq(attempt, i, "prediction advances past each poisoned candidate");
                candidates[i] = candidate;
                PoolKey memory key =
                    PoolKey(Currency.wrap(address(0)), Currency.wrap(candidate), 0, 60, IHooks(address(hook)));
                manager.initialize(key, poison);
            }
            uint256 selectedAttempt;
            (predicted, selectedAttempt) = factory.predictLaunchToken(creator, name, "SYS", bytes32(0));
            assertEq(selectedAttempt, exhaust ? 0 : depth);
        }
        RecoveryBalances memory before =
            RecoveryBalances(address(manager).balance, address(hook).balance, address(escrow).balance, creator.balance);
        createLaunch(creatorSeed);
        (, address token,,, PoolId poolId) = factory.launches(id);
        assertEq(token, predicted);
        if (exhaust) {
            assertEq(token, candidates[0]);
            ++realignedLaunches;
        } else {
            ++resaltedLaunches;
        }
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96(), "recovery never admits a foreign opening price");
        assertEq(address(manager).balance, before.managerEth, "recovery cannot spend another pool's ETH");
        assertEq(address(hook).balance, before.hookEth, "recovery cannot spend deferred fees");
        assertEq(address(escrow).balance, before.escrowEth);
        assertEq(creator.balance, before.creatorEth - LAUNCH_FEE);
        for (uint256 i = exhaust ? 1 : 0; i < candidates.length; ++i) {
            PoolKey memory key =
                PoolKey(Currency.wrap(address(0)), Currency.wrap(candidates[i]), 0, 60, IHooks(address(hook)));
            (uint160 untouched,,,) = StateLibrary.getSlot0(manager, key.toId());
            assertEq(untouched, poison);
            assertEq(candidates[i].code.length, 0);
        }
    }

    /// @dev Every privileged or malformed entry point an outsider could try, asserted to fail closed.
    function probeRejections(uint8 launchSeed, uint8 actorSeed) public {
        address actor = actors[actorSeed % 3];
        uint256 count = factory.launchCount();
        uint256 id = launchSeed % count;
        (,, address curveAddress,,) = factory.launches(id);
        BondingCurve curve = BondingCurve(payable(curveAddress));
        PoolKey memory key = factory.getPoolKey(id);
        vm.startPrank(actor);
        vm.expectRevert(PvPadFactory.LaunchFeeRequired.selector);
        factory.createLaunch{value: LAUNCH_FEE - 1}("Underpaid", "UP");
        vm.expectRevert(PvPadFactory.LaunchFeeRequired.selector);
        factory.createLaunch{value: LAUNCH_FEE + 1}("Overpaid", "OP");
        vm.expectRevert(PvPadFactory.InvalidMetadata.selector);
        factory.createLaunch{value: LAUNCH_FEE}("", "EMPTY");
        vm.expectRevert(PvPadFactory.UnknownLaunch.selector);
        factory.graduate(count);
        vm.expectRevert(PvPadFactory.UnknownLaunch.selector);
        factory.getPoolKey(count);
        vm.expectRevert(PvPadFactory.InvalidCallback.selector);
        factory.unlockCallback(abi.encode(key, uint256(0), uint256(0), id));
        vm.expectRevert(BondingCurve.NotFactory.selector);
        curve.sweepForGraduation();
        vm.expectRevert(FeeEscrow.NotAuthorized.selector);
        escrow.authorizeRecorder(actor, true);
        // recordTradeFeeNative is never fault-injected, so the authorization check is what answers.
        vm.expectRevert(FeeEscrow.NotAuthorized.selector);
        escrow.recordTradeFeeNative{value: 1}(actor, 1);
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(actor, key, IPoolManager.ModifyLiquidityParams(-60, 60, 1, bytes32(0)), "");
        vm.expectRevert(PvPadHook.NotLaunchFactory.selector);
        hook.realignPool(key, uint160(1) << 96);
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(key, true, uint160(1) << 95));
        vm.expectRevert(WorkerSubsidy.NotUpdater.selector);
        workers.setEpoch(bytes32(uint256(1)), block.timestamp, block.timestamp + 1 days);
        uint256 price = king.claimPrice();
        vm.expectRevert(KingOfThePad.BidTooLow.selector);
        king.claimKing{value: price}(actor);
        vm.expectRevert(KingOfThePad.InvalidAddress.selector);
        king.claimKing{value: price + 1}(address(0));
        vm.stopPrank();
        vm.prank(address(factory));
        vm.expectRevert(PvPadHook.PoolAlreadyBound.selector);
        hook.bindPool(key, actor, escrow);
        assertEq(factory.launchCount(), count, "rejected calls change nothing");
    }

    // ------------------------------------------------------------------ curve trading

    function buy(uint8 launchSeed, uint8 actorSeed, uint256 valueSeed, bool protectedOverload) public {
        uint256 id = launchSeed % factory.launchCount();
        address actor = actors[actorSeed % 3];
        (, address tokenAddress, address curveAddress,,) = factory.launches(id);
        BondingCurve curve = BondingCurve(payable(curveAddress));
        IERC20 token = IERC20(tokenAddress);
        uint256 value = bound(valueSeed, 1, 5 ether);
        if (ghostGraduated[id]) {
            vm.prank(actor);
            vm.expectRevert(BondingCurve.Graduated.selector);
            curve.buy{value: value}(actor);
            return;
        }
        if (curve.readyToGraduate()) {
            vm.prank(actor);
            vm.expectRevert(BondingCurve.NotReady.selector);
            curve.buy{value: value}(actor);
            return;
        }
        TradeSnapshot memory snap = _snapshot(curve, token, actor);
        (snap.quoted, snap.quotedFee) = curve.quoteBuy(value);
        assertGt(snap.quoted, 0, "a funded curve always quotes output");
        vm.prank(actor);
        uint256 out = protectedOverload
            ? curve.buy{value: value}(actor, snap.quoted, block.timestamp)
            : curve.buy{value: value}(actor);
        assertEq(out, snap.quoted, "execution matches the quote");
        uint256 paid = snap.actorEth - actor.balance;
        assertLe(paid, value);
        uint256 netIn = curve.ethReserve() - snap.ethReserve;
        uint256 fee = paid - netIn;
        assertEq(fee, snap.quotedFee);
        assertEq(fee, paid / 100, "fee is exactly one percent of the gross input");
        assertEq(snap.tokenReserve - curve.tokenReserve(), out);
        assertEq(token.balanceOf(actor) - snap.actorTokens, out);
        assertLe(curve.ethReserve(), THRESHOLD, "reserves never exceed the threshold");
        if (paid < value) assertEq(curve.ethReserve(), THRESHOLD, "a refund only happens at the cap");
        // Delivered fees leave the curve; deferred fees stay in its custody.
        uint256 retained = address(curve).balance - snap.curveEth - netIn;
        assertTrue(retained == 0 || retained == fee, "fee is either delivered or fully retained");
        _recordCurveFee(id, snap.beneficiary, fee, retained == fee && fee != 0);
        ++curveBuys;
    }

    struct TradeSnapshot {
        uint256 ethReserve;
        uint256 tokenReserve;
        uint256 actorEth;
        uint256 actorTokens;
        uint256 curveEth;
        address beneficiary;
        uint256 quoted;
        uint256 quotedFee;
    }

    function _snapshot(BondingCurve curve, IERC20 token, address actor)
        private
        view
        returns (TradeSnapshot memory snap)
    {
        snap.ethReserve = curve.ethReserve();
        snap.tokenReserve = curve.tokenReserve();
        snap.actorEth = actor.balance;
        snap.actorTokens = token.balanceOf(actor);
        snap.curveEth = address(curve).balance;
        snap.beneficiary = king.beneficiary();
    }

    function sell(uint8 launchSeed, uint8 actorSeed, uint256 amountSeed, bool protectedOverload) public {
        uint256 id = launchSeed % factory.launchCount();
        address actor = actors[actorSeed % 3];
        (, address tokenAddress, address curveAddress,,) = factory.launches(id);
        BondingCurve curve = BondingCurve(payable(curveAddress));
        IERC20 token = IERC20(tokenAddress);
        uint256 held = token.balanceOf(actor);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        if (ghostGraduated[id]) {
            vm.prank(actor);
            vm.expectRevert(BondingCurve.Graduated.selector);
            curve.sell(amount, actor);
            return;
        }
        if (curve.readyToGraduate()) {
            vm.prank(actor);
            vm.expectRevert(BondingCurve.NotReady.selector);
            curve.sell(amount, actor);
            return;
        }
        TradeSnapshot memory snap = _snapshot(curve, token, actor);
        (snap.quoted, snap.quotedFee) = curve.quoteSell(amount);
        if (snap.quoted == 0) {
            vm.prank(actor);
            vm.expectRevert(BondingCurve.InsufficientOutput.selector);
            curve.sell(amount, actor);
            return;
        }
        vm.prank(actor);
        uint256 ethOut =
            protectedOverload ? curve.sell(amount, actor, snap.quoted, block.timestamp) : curve.sell(amount, actor);
        assertEq(ethOut, snap.quoted, "execution matches the quote");
        assertEq(actor.balance - snap.actorEth, ethOut);
        assertEq(token.balanceOf(actor), snap.actorTokens - amount);
        uint256 grossEth = snap.ethReserve - curve.ethReserve();
        uint256 fee = grossEth - ethOut;
        assertEq(fee, snap.quotedFee);
        assertEq(fee, grossEth / 100, "fee is exactly one percent of the gross output");
        assertEq(curve.tokenReserve() - snap.tokenReserve, amount);
        uint256 retained = snap.curveEth - address(curve).balance;
        assertTrue(retained == grossEth || retained == ethOut, "fee is either delivered or fully retained");
        _recordCurveFee(id, snap.beneficiary, fee, retained == ethOut && fee != 0);
        ++curveSells;
    }

    function donateEthToCurve(uint8 launchSeed, uint8 actorSeed, uint256 amountSeed) public {
        uint256 id = launchSeed % factory.launchCount();
        address actor = actors[actorSeed % 3];
        (,, address curveAddress,,) = factory.launches(id);
        BondingCurve curve = BondingCurve(payable(curveAddress));
        uint256 amount = bound(amountSeed, 1, 1 ether);
        uint256 reserve = curve.ethReserve();
        uint256 cap = curve.maxBuyInput();
        uint256 actorBefore = actor.balance;
        uint256 curveBefore = curveAddress.balance;
        vm.prank(actor);
        (bool ok,) = curveAddress.call{value: amount}("");
        assertFalse(ok, "plain ETH transfers are refused");
        assertEq(actor.balance, actorBefore, "rejected ETH stays with the sender");
        assertEq(curveAddress.balance, curveBefore);
        assertEq(curve.ethReserve(), reserve, "rejected donations never enter the reserves");
        assertEq(curve.maxBuyInput(), cap, "rejected donations never move the curve");
    }

    function donateTokensToCurve(uint8 launchSeed, uint8 actorSeed, uint256 amountSeed) public {
        uint256 id = launchSeed % factory.launchCount();
        address actor = actors[actorSeed % 3];
        (, address tokenAddress, address curveAddress,,) = factory.launches(id);
        uint256 held = IERC20(tokenAddress).balanceOf(actor);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        uint256 reserve = BondingCurve(payable(curveAddress)).tokenReserve();
        vm.prank(actor);
        IERC20(tokenAddress).transfer(curveAddress, amount);
        assertEq(BondingCurve(payable(curveAddress)).tokenReserve(), reserve, "donated tokens are not reserves");
        ghostTokenDonated[id] += amount;
    }

    // ------------------------------------------------------------------ graduation

    function graduate(uint8 launchSeed, uint8 actorSeed) public {
        uint256 id = launchSeed % factory.launchCount();
        address actor = actors[actorSeed % 3];
        (, address tokenAddress, address curveAddress,, PoolId poolId) = factory.launches(id);
        BondingCurve curve = BondingCurve(payable(curveAddress));
        IERC20 token = IERC20(tokenAddress);
        if (ghostGraduated[id]) {
            vm.prank(actor);
            vm.expectRevert(PvPadFactory.AlreadyGraduated.selector);
            factory.graduate(id);
            return;
        }
        if (!curve.readyToGraduate()) {
            vm.prank(actor);
            vm.expectRevert(PvPadFactory.NotReady.selector);
            factory.graduate(id);
            return;
        }
        GraduationSnapshot memory snap;
        snap.managerEth = address(manager).balance;
        snap.factoryEth = address(factory).balance;
        snap.managerTokens = token.balanceOf(address(manager));
        snap.factoryTokens = token.balanceOf(address(factory));
        snap.sweptTokens = curve.tokenReserve();
        snap.curveEth = address(curve).balance;
        vm.prank(actor);
        PoolId returned = factory.graduate(id);
        assertEq(PoolId.unwrap(returned), PoolId.unwrap(poolId));
        _verifyGraduation(id, poolId, curve, token, snap);
    }

    struct GraduationSnapshot {
        uint256 managerEth;
        uint256 factoryEth;
        uint256 managerTokens;
        uint256 factoryTokens;
        uint256 sweptTokens;
        uint256 curveEth;
    }

    function _verifyGraduation(
        uint256 id,
        PoolId poolId,
        BondingCurve curve,
        IERC20 token,
        GraduationSnapshot memory snap
    ) private {
        (,,, bool graduated,) = factory.launches(id);
        assertTrue(graduated && curve.graduated() && factory.isRegisteredPool(poolId));
        assertEq(curve.ethReserve(), 0);
        assertEq(curve.tokenReserve(), 0);
        assertEq(snap.curveEth - address(curve).balance, THRESHOLD, "exactly the threshold leaves the curve");
        uint256 managerGain = address(manager).balance - snap.managerEth;
        uint256 factoryGain = address(factory).balance - snap.factoryEth;
        assertEq(managerGain + factoryGain, THRESHOLD, "swept ETH is either pooled or locked as dust");
        assertEq(
            token.balanceOf(address(manager)) - snap.managerTokens + token.balanceOf(address(factory))
                - snap.factoryTokens,
            snap.sweptTokens,
            "swept tokens are either pooled or locked as dust"
        );
        assertEq(factory.lockedTickLower(id), TickMath.minUsableTick(60), "full range lower");
        assertEq(factory.lockedTickUpper(id), TickMath.maxUsableTick(60), "full range upper");
        uint128 locked = factory.lockedLiquidity(id);
        assertGt(locked, 0);
        assertEq(_lockedPosition(id, poolId), locked, "factory owns the locked position");
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96(), "pool opens at the canonical price");
        ghostGraduated[id] = true;
        lockedLiquidityAt[id] = locked;
        ghostManagerEth += managerGain;
        ghostFactoryDust += factoryGain;
        ++graduations;
    }

    function _lockedPosition(uint256 id, PoolId poolId) private view returns (uint128 position) {
        (position,,) = StateLibrary.getPositionInfo(
            manager, poolId, address(factory), factory.lockedTickLower(id), factory.lockedTickUpper(id), bytes32(id)
        );
    }

    // ------------------------------------------------------------------ pool trading

    function swap(uint8 launchSeed, uint8 actorSeed, uint8 modeSeed, uint128 amountSeed) public {
        uint256 id = launchSeed % factory.launchCount();
        address actor = actors[actorSeed % 3];
        (, address tokenAddress,,,) = factory.launches(id);
        IERC20 token = IERC20(tokenAddress);
        PoolKey memory key = factory.getPoolKey(id);
        if (!ghostGraduated[id]) {
            bytes memory closed = abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(PvPadHook.PoolNotGraduated.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            );
            vm.prank(actor);
            vm.expectRevert(closed);
            router.swap{value: 0.01 ether}(
                key,
                IPoolManager.SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            return;
        }
        SwapSnapshot memory snap;
        snap.actor = actor;
        snap.token = token;
        snap.mode = modeSeed % 4;
        snap.held = token.balanceOf(actor);
        if (snap.mode == 2 && snap.held == 0) snap.mode = 0;
        if (snap.mode == 3 && snap.held < 1e25) snap.mode = 1;
        // Modes: exact ETH input, exact token output, exact token input, exact ETH output.
        snap.amount = snap.mode == 0
            ? bound(amountSeed, 1, 0.05 ether)
            : snap.mode == 1
                ? bound(amountSeed, 1e9, 1e23)
                : snap.mode == 2 ? bound(amountSeed, 1, snap.held) : bound(amountSeed, 1, 0.001 ether);
        snap.isBuy = snap.mode < 2;
        snap.actorEth = actor.balance;
        snap.managerEth = address(manager).balance;
        snap.managerTokens = token.balanceOf(address(manager));
        snap.custody = address(hook).balance + address(escrow).balance;
        snap.hookEth = address(hook).balance;
        snap.beneficiary = king.beneficiary();
        snap.delta = _executeSwap(key, snap);
        _verifySwap(id, snap);
    }

    struct SwapSnapshot {
        address actor;
        IERC20 token;
        uint256 mode;
        uint256 held;
        uint256 amount;
        bool isBuy;
        uint256 actorEth;
        uint256 managerEth;
        uint256 managerTokens;
        uint256 custody;
        uint256 hookEth;
        address beneficiary;
        BalanceDelta delta;
    }

    function _executeSwap(PoolKey memory key, SwapSnapshot memory snap) private returns (BalanceDelta) {
        int256 specified = snap.mode == 0 || snap.mode == 2 ? -int256(snap.amount) : int256(snap.amount);
        vm.prank(snap.actor);
        return router.swap{value: snap.isBuy ? 1 ether : 0}(
            key,
            IPoolManager.SwapParams(
                snap.isBuy, specified, snap.isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _verifySwap(uint256 id, SwapSnapshot memory snap) private {
        uint256 gross;
        uint256 fee;
        uint256 tokensMoved;
        if (snap.isBuy) {
            gross = snap.actorEth - snap.actor.balance;
            fee = gross / 100;
            tokensMoved = uint256(uint128(snap.delta.amount1()));
            assertEq(address(manager).balance - snap.managerEth, gross - fee, "pool keeps the net buy input");
            assertEq(int256(snap.delta.amount0()), -int256(gross));
            assertEq(snap.token.balanceOf(snap.actor) - snap.held, tokensMoved);
            assertEq(snap.managerTokens - snap.token.balanceOf(address(manager)), tokensMoved);
            ghostManagerEth += gross - fee;
        } else {
            gross = snap.managerEth - address(manager).balance;
            fee = gross / 100;
            tokensMoved = uint256(uint128(-snap.delta.amount1()));
            assertEq(snap.actor.balance - snap.actorEth, gross - fee, "seller receives the gross output less fee");
            assertEq(uint256(uint128(snap.delta.amount0())), gross - fee);
            assertEq(snap.held - snap.token.balanceOf(snap.actor), tokensMoved);
            ghostManagerEth -= gross;
        }
        if (snap.mode == 0) assertEq(gross, snap.amount);
        if (snap.mode == 1 || snap.mode == 2) assertEq(tokensMoved, snap.amount);
        if (snap.mode == 3) assertEq(snap.actor.balance - snap.actorEth, snap.amount);
        assertEq(
            address(hook).balance + address(escrow).balance - snap.custody, fee, "fee ETH is in hook or escrow custody"
        );
        bool deferred = address(hook).balance - snap.hookEth == fee && fee != 0;
        _recordHookFee(creatorOf[id], snap.beneficiary, fee, deferred);
        ++poolSwaps;
    }

    // ------------------------------------------------------------------ fee delivery

    function setOutage(bool fail) public {
        outage = fail;
        if (fail) {
            vm.mockCallRevert(
                address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeFor.selector), "escrow down"
            );
            vm.mockCallRevert(
                address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeShares.selector), "escrow down"
            );
        } else {
            vm.clearMockedCalls();
        }
    }

    function flushCurve(uint8 launchSeed, uint8 beneficiarySeed) public {
        uint256 id = launchSeed % factory.launchCount();
        address beneficiary = _beneficiaryKey(beneficiarySeed);
        (,, address curveAddress,,) = factory.launches(id);
        BondingCurve curve = BondingCurve(payable(curveAddress));
        uint256 amount = ghostCurveDeferred[id][beneficiary];
        uint256 kingShare = ghostCurveDeferredKing[id][beneficiary];
        assertEq(curve.deferredFees(beneficiary), amount);
        assertEq(curve.deferredKingShares(beneficiary), kingShare);
        uint256 curveEth = address(curve).balance;
        bool success = curve.flushDeferredFees(beneficiary);
        if (amount == 0) {
            assertTrue(success, "nothing to flush reports success");
            return;
        }
        if (outage) {
            assertFalse(success);
            assertEq(curve.deferredFees(beneficiary), amount, "failed retry keeps the liability");
            assertEq(address(curve).balance, curveEth);
            return;
        }
        assertTrue(success);
        assertEq(curveEth - address(curve).balance, amount, "flush moves exactly the deferred amount");
        assertEq(curve.deferredFees(beneficiary), 0);
        ghostCurveDeferred[id][beneficiary] = 0;
        ghostCurveDeferredKing[id][beneficiary] = 0;
        _settleFee(creatorOf[id], beneficiary, amount, kingShare);
    }

    function retryHook(uint8 creatorSeed, uint8 beneficiarySeed) public {
        address creator = creators[creatorSeed % 2];
        address beneficiary = _beneficiaryKey(beneficiarySeed);
        uint256 amount = ghostHookDeferred[creator][beneficiary];
        uint256 kingShare = ghostHookDeferredKing[creator][beneficiary];
        assertEq(hook.deferredFees(address(escrow), creator, beneficiary), amount);
        assertEq(hook.deferredKingShares(address(escrow), creator, beneficiary), kingShare);
        uint256 hookEth = address(hook).balance;
        uint256 delivered = hook.retryDeferred(escrow, creator, beneficiary);
        if (amount == 0 || outage) {
            assertEq(delivered, 0);
            assertEq(
                hook.deferredFees(address(escrow), creator, beneficiary), amount, "failed retry keeps the liability"
            );
            assertEq(address(hook).balance, hookEth);
            return;
        }
        assertEq(delivered, amount, "retry delivers exactly the deferred bucket");
        assertEq(hookEth - address(hook).balance, amount);
        ghostHookDeferred[creator][beneficiary] = 0;
        ghostHookDeferredKing[creator][beneficiary] = 0;
        _settleFee(creator, beneficiary, amount, kingShare);
    }

    function withdraw(uint8 payeeSeed, uint8 recipientSeed) public {
        address payee = _payee(payeeSeed % 5);
        address recipient = actors[recipientSeed % 3];
        uint256 expected = escrow.pending(address(0), payee);
        uint256 recipientEth = recipient.balance;
        vm.prank(payee);
        uint256 paid = escrow.withdraw(address(0), recipient);
        assertEq(paid, expected);
        assertEq(escrow.pending(address(0), payee), 0);
        if (recipient != payee) assertEq(recipient.balance - recipientEth, paid);
        ghostWithdrawn[payee] += paid;
    }

    function assignUnassigned(uint8 actorSeed) public {
        address actor = actors[actorSeed % 3];
        address first = king.firstBeneficiary();
        if (first == address(0)) {
            vm.prank(actor);
            vm.expectRevert(FeeEscrow.NoBeneficiary.selector);
            escrow.assignUnassigned();
            return;
        }
        uint256 pendingBefore = escrow.pending(address(0), first);
        vm.prank(actor);
        escrow.assignUnassigned();
        assertEq(escrow.unassignedEth(), 0);
        assertEq(
            escrow.pending(address(0), first) - pendingBefore, ghostUnassigned, "pre-crown fees go to the first king"
        );
        ghostCredit[first] += ghostUnassigned;
        ghostUnassigned = 0;
    }

    // ------------------------------------------------------------------ crown and workers

    function claimKing(uint8 actorSeed, uint8 beneficiarySeed, uint256 overbidSeed) public {
        address actor = actors[actorSeed % 3];
        address beneficiary = actors[beneficiarySeed % 3];
        uint256 bid = king.claimPrice() + 1 + bound(overbidSeed, 0, 0.01 ether);
        uint256 potBefore = workers.workerPot();
        address previousKing = king.king();
        uint256 previousKingEth = previousKing.balance;
        vm.prank(actor);
        king.claimKing{value: bid}(beneficiary);
        assertEq(king.king(), actor);
        assertEq(king.beneficiary(), beneficiary);
        assertEq(workers.workerPot() - potBefore, bid, "the whole bid funds the workers");
        if (previousKing != address(0) && previousKing != actor) {
            assertEq(previousKing.balance, previousKingEth, "no refund to the previous king");
        }
        if (ghostFirstBeneficiary == address(0)) ghostFirstBeneficiary = beneficiary;
        ghostWorkerPot += bid;
        ++ghostClaims;
        ghostClaimPrice = ghostClaimPrice * 11_000 / 10_000;
    }

    function fundWorkers(uint8 actorSeed, uint256 amountSeed, bool viaReceive) public {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 0, 1 ether);
        if (amount == 0) {
            vm.prank(actor);
            vm.expectRevert(WorkerSubsidy.NothingToFund.selector);
            workers.fundWorkers();
            return;
        }
        vm.prank(actor);
        if (viaReceive) {
            (bool ok,) = address(workers).call{value: amount}("");
            assertTrue(ok);
        } else {
            workers.fundWorkers{value: amount}();
        }
        ghostWorkerPot += amount;
    }

    // ------------------------------------------------------------------ invariant checks

    function checkTokenSupplyAccounting() public view {
        uint256 count = factory.launchCount();
        for (uint256 i; i < count; ++i) {
            (, address tokenAddress, address curveAddress,,) = factory.launches(i);
            IERC20 token = IERC20(tokenAddress);
            uint256 accounted = token.balanceOf(curveAddress) + token.balanceOf(address(factory))
                + token.balanceOf(address(manager)) + token.balanceOf(address(hook)) + token.balanceOf(address(router));
            for (uint256 j; j < 3; ++j) {
                accounted += token.balanceOf(actors[j]);
            }
            for (uint256 j; j < 2; ++j) {
                accounted += token.balanceOf(creators[j]);
            }
            assertEq(token.totalSupply(), SUPPLY, "fixed supply");
            assertEq(accounted, SUPPLY, "every launch token is held by a known party");
            assertEq(token.balanceOf(address(hook)), 0, "the hook never holds launch tokens");
        }
    }

    function checkCurveCustody() public view {
        uint256 count = factory.launchCount();
        uint256 k0 = (SUPPLY + PvPadConstants.VIRTUAL_TOKEN) * PvPadConstants.VIRTUAL_ETH;
        for (uint256 i; i < count; ++i) {
            (, address tokenAddress, address curveAddress, bool graduated,) = factory.launches(i);
            BondingCurve curve = BondingCurve(payable(curveAddress));
            assertEq(graduated, ghostGraduated[i], "graduation flag matches the ledger");
            assertEq(curve.graduated(), graduated);
            assertEq(
                address(curve).balance,
                curve.ethReserve() + curve.totalDeferredFees(),
                "curve ETH is reserves plus retained fees"
            );
            assertEq(
                IERC20(tokenAddress).balanceOf(curveAddress),
                curve.tokenReserve() + ghostTokenDonated[i],
                "curve tokens are reserves plus donations"
            );
            assertLe(curve.ethReserve(), THRESHOLD);
            assertEq(curve.readyToGraduate(), !graduated && curve.ethReserve() == THRESHOLD);
            if (graduated) {
                assertEq(curve.ethReserve(), 0);
                assertEq(curve.tokenReserve(), 0);
                assertEq(curve.maxBuyInput(), 0);
            } else {
                assertGe(
                    (curve.tokenReserve() + PvPadConstants.VIRTUAL_TOKEN)
                        * (curve.ethReserve() + PvPadConstants.VIRTUAL_ETH),
                    k0,
                    "rounding never favours the trader"
                );
                assertGe(curve.tokenReserve(), SUPPLY / 4, "the pool share is never sold off the curve");
            }
            uint256 deferred;
            for (uint256 j; j < 4; ++j) {
                address beneficiary = _beneficiaryKey(uint8(j));
                assertEq(curve.deferredFees(beneficiary), ghostCurveDeferred[i][beneficiary]);
                assertEq(curve.deferredKingShares(beneficiary), ghostCurveDeferredKing[i][beneficiary]);
                deferred += ghostCurveDeferred[i][beneficiary];
            }
            assertEq(curve.totalDeferredFees(), deferred, "no deferred fee outside the known beneficiaries");
        }
    }

    function checkGraduationFinalityAndPools() public view {
        uint256 count = factory.launchCount();
        for (uint256 i; i < count; ++i) {
            (address creator,, address curveAddress, bool graduated, PoolId poolId) = factory.launches(i);
            PoolKey memory key = factory.getPoolKey(i);
            assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(poolId));
            assertEq(creator, creatorOf[i]);
            assertEq(factory.poolCreator(poolId), creator);
            assertEq(factory.launchCreator(poolId), creator);
            assertTrue(factory.isBondingCurve(curveAddress));
            assertEq(factory.isRegisteredPool(poolId), graduated, "registry opens only on graduation");
            (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
            if (graduated) {
                uint128 locked = factory.lockedLiquidity(i);
                assertEq(locked, lockedLiquidityAt[i], "locked liquidity never changes");
                assertEq(_lockedPosition(i, poolId), locked, "the factory position is never withdrawn");
                assertGe(StateLibrary.getLiquidity(manager, poolId), locked, "pool liquidity covers the lock");
                assertEq(factory.lockedTickLower(i), TickMath.minUsableTick(60));
                assertEq(factory.lockedTickUpper(i), TickMath.maxUsableTick(60));
            } else {
                assertEq(factory.lockedLiquidity(i), 0);
                assertEq(StateLibrary.getLiquidity(manager, poolId), 0, "nobody can seed an ungraduated pool");
                assertEq(price, factory.canonicalSqrtPriceX96(), "an ungraduated pool stays at the canonical price");
            }
        }
        assertEq(address(manager).balance, ghostManagerEth, "pool ETH equals seeds plus net swap flow");
        assertEq(address(factory).balance, ghostFactoryDust, "factory holds only graduation dust");
        assertEq(address(router).balance, 0);
    }

    function checkFeeCustodyAndEntitlements() public view {
        uint256 count = factory.launchCount();
        uint256 curveDeferred;
        for (uint256 i; i < count; ++i) {
            (,, address curveAddress,,) = factory.launches(i);
            curveDeferred += BondingCurve(payable(curveAddress)).totalDeferredFees();
        }
        uint256 hookDeferred;
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 4; ++j) {
                address beneficiary = _beneficiaryKey(uint8(j));
                assertEq(
                    hook.deferredFees(address(escrow), creators[i], beneficiary),
                    ghostHookDeferred[creators[i]][beneficiary]
                );
                assertEq(
                    hook.deferredKingShares(address(escrow), creators[i], beneficiary),
                    ghostHookDeferredKing[creators[i]][beneficiary]
                );
                hookDeferred += ghostHookDeferred[creators[i]][beneficiary];
            }
        }
        assertEq(hook.totalDeferred(), hookDeferred, "no hook deferral outside the known keys");
        assertEq(address(hook).balance, hookDeferred, "hook holds exactly its deferred fees");
        assertEq(
            escrow.totalSkimmedEth() + curveDeferred + hookDeferred,
            ghostFees,
            "every charged wei is delivered or deferred"
        );
        assertEq(escrow.unassignedEth(), ghostUnassigned);
        assertEq(address(escrow).balance, escrow.totalPendingEth() + escrow.unassignedEth(), "escrow is fully backed");
        assertEq(
            escrow.totalSkimmedEth(),
            escrow.totalPendingEth() + escrow.totalWithdrawnEth() + escrow.unassignedEth(),
            "skimmed equals pending plus withdrawn plus unassigned"
        );
        uint256 pending;
        uint256 withdrawn;
        for (uint256 i; i < 5; ++i) {
            address payee = _payee(i);
            assertEq(
                escrow.pending(address(0), payee) + ghostWithdrawn[payee],
                ghostCredit[payee],
                "payee entitlement matches the 50/50 rule with odd wei to the creator"
            );
            pending += escrow.pending(address(0), payee);
            withdrawn += ghostWithdrawn[payee];
        }
        assertEq(pending, escrow.totalPendingEth(), "no credit leaks to an unknown account");
        assertEq(withdrawn, escrow.totalWithdrawnEth());
    }

    function checkWorkersAndCrown() public view {
        assertEq(workers.workerPot(), ghostWorkerPot, "pot equals launch fees plus bids plus donations");
        assertEq(address(workers).balance, ghostWorkerPot);
        assertEq(workers.reservedForEpochs(), 0);
        assertEq(king.claimPrice(), ghostClaimPrice, "claim price follows the ten percent bump exactly");
        assertEq(king.claimCount(), ghostClaims);
        assertEq(king.firstBeneficiary(), ghostFirstBeneficiary, "the first beneficiary is permanent");
        if (ghostClaims == 0) assertEq(king.beneficiary(), address(0));
    }

    // ------------------------------------------------------------------ internals

    function _recordCurveFee(uint256 id, address beneficiary, uint256 fee, bool deferred) private {
        ghostFees += fee;
        if (fee == 0) return;
        if (deferred) {
            assertTrue(outage, "delivery only fails during an injected outage");
            ghostCurveDeferred[id][beneficiary] += fee;
            ghostCurveDeferredKing[id][beneficiary] += fee / 2;
            ++deferrals;
        } else {
            assertFalse(outage, "an outage must defer the fee");
            _settleFee(creatorOf[id], beneficiary, fee, fee / 2);
        }
    }

    function _recordHookFee(address creator, address beneficiary, uint256 fee, bool deferred) private {
        ghostFees += fee;
        if (fee == 0) return;
        if (deferred) {
            assertTrue(outage, "delivery only fails during an injected outage");
            ghostHookDeferred[creator][beneficiary] += fee;
            ghostHookDeferredKing[creator][beneficiary] += fee / 2;
            ++deferrals;
        } else {
            assertFalse(outage, "an outage must defer the fee");
            _settleFee(creator, beneficiary, fee, fee / 2);
        }
    }

    /// @dev SPEC rule: half to the king beneficiary captured at trade time, the rest (odd wei
    /// included) to the creator. A capture from before the first crown belongs to the first king, or
    /// stays unassigned until there is one.
    function _settleFee(address creator, address beneficiary, uint256 amount, uint256 kingShare) private {
        if (beneficiary == address(0)) beneficiary = king.firstBeneficiary();
        if (beneficiary == address(0)) ghostUnassigned += kingShare;
        else ghostCredit[beneficiary] += kingShare;
        ghostCredit[creator] += amount - kingShare;
        ++deliveries;
    }

    function _approveAll(uint256 id) private {
        (, address tokenAddress, address curveAddress,,) = factory.launches(id);
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(actors[i]);
            IERC20(tokenAddress).approve(curveAddress, type(uint256).max);
            IERC20(tokenAddress).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _beneficiaryKey(uint8 seed) private view returns (address) {
        uint256 index = seed % 4;
        return index == 3 ? address(0) : actors[index];
    }

    function _payee(uint256 index) private view returns (address) {
        return index < 3 ? actors[index] : creators[index - 3];
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract SystemLifecycleInvariantTest is Test {
    SystemLifecycleHandler public handler;

    function setUp() public {
        address[3] memory actors = [address(0xA200), address(0xA201), address(0xA202)];
        address[2] memory creators = [address(0xC200), address(0xC201)];
        PoolManager manager = new PoolManager(address(this));
        PoolSwapTest router = new PoolSwapTest(manager);
        WorkerSubsidy workers = new WorkerSubsidy(address(0xDEAD1));
        KingOfThePad king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        PvPadHook hook = new PvPadHook{salt: salt}(manager);
        PvPadFactory factory = new PvPadFactory(manager, workers, king, hook, creators[0]);
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1_000_000 ether);
        }
        for (uint256 i; i < creators.length; ++i) {
            vm.deal(creators[i], 1_000 ether);
        }
        handler = new SystemLifecycleHandler(factory, router, actors, creators);
        bytes4[] memory selectors = new bytes4[](21);
        selectors[0] = handler.createLaunch.selector;
        selectors[1] = handler.buy.selector;
        selectors[2] = handler.buy.selector;
        selectors[3] = handler.buy.selector;
        selectors[4] = handler.sell.selector;
        selectors[5] = handler.sell.selector;
        selectors[6] = handler.graduate.selector;
        selectors[7] = handler.graduate.selector;
        selectors[8] = handler.swap.selector;
        selectors[9] = handler.swap.selector;
        selectors[10] = handler.claimKing.selector;
        selectors[11] = handler.setOutage.selector;
        selectors[12] = handler.flushCurve.selector;
        selectors[13] = handler.retryHook.selector;
        selectors[14] = handler.withdraw.selector;
        selectors[15] = handler.assignUnassigned.selector;
        selectors[16] = handler.donateEthToCurve.selector;
        selectors[17] = handler.donateTokensToCurve.selector;
        selectors[18] = handler.fundWorkers.selector;
        selectors[19] = handler.probeRejections.selector;
        selectors[20] = handler.poisonAndCreateLaunch.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_everyLaunchTokenIsHeldByAKnownParty() public view {
        handler.checkTokenSupplyAccounting();
    }

    function invariant_curveCustodyEqualsReservesRetainedFeesAndDonations() public view {
        handler.checkCurveCustody();
    }

    function invariant_graduationIsFinalAndPoolsMatchTheLedger() public view {
        handler.checkGraduationFinalityAndPools();
    }

    function invariant_everyFeeWeiIsDeliveredDeferredOrWithdrawnExactlyOnce() public view {
        handler.checkFeeCustodyAndEntitlements();
    }

    function invariant_workerPotAndCrownFollowTheFrozenEconomics() public view {
        handler.checkWorkersAndCrown();
    }

    function test_recoveredLaunchesPreserveLivePoolReservesAndDeferredFees() public {
        handler.claimKing(0, 0, 0);
        handler.buy(0, 0, 5 ether, true);
        handler.graduate(0, 0);
        handler.setOutage(true);
        handler.swap(0, 0, 0, uint128(0.01 ether));
        assertGt(handler.hook().totalDeferred(), 0);
        // Recover from both sides of the canonical price, then exercise the bounded re-salt path.
        handler.poisonAndCreateLaunch(1, 0, TickMath.MIN_SQRT_PRICE, true);
        handler.poisonAndCreateLaunch(0, 1, TickMath.MAX_SQRT_PRICE - 1, true);
        handler.poisonAndCreateLaunch(1, 15, uint160(1) << 96, false);
        assertEq(handler.realignedLaunches(), 2);
        assertEq(handler.resaltedLaunches(), 1);
        assertEq(handler.factory().launchCount(), 4);
        handler.buy(1, 1, 5 ether, true);
        handler.graduate(1, 1);
        handler.swap(1, 1, 0, uint128(0.02 ether));
        handler.probeRejections(1, 2);
        handler.setOutage(false);
        handler.flushCurve(1, 0);
        handler.retryHook(0, 0);
        handler.retryHook(1, 0);
        handler.withdraw(0, 0);
        handler.checkTokenSupplyAccounting();
        handler.checkCurveCustody();
        handler.checkGraduationFinalityAndPools();
        handler.checkFeeCustodyAndEntitlements();
        handler.checkWorkersAndCrown();
    }

    /// @dev A deterministic drive through every transition so none depends on random selection:
    /// pre-crown fees, a second launch, fills, graduation, all four swap modes under an escrow outage,
    /// retries, a crown change, withdrawals and the assignment of pre-crown fees.
    function test_handlerDrivesEveryLifecycleTransition() public {
        handler.buy(0, 0, 1 ether, true); // pre-crown fee: king share is unassigned
        handler.createLaunch(1);
        handler.createLaunch(0);
        assertEq(handler.factory().launchCount(), 3);
        handler.sell(0, 0, 1e24, false);
        handler.swap(1, 0, 0, 1); // ungraduated pool rejects swaps
        handler.graduate(1, 0); // not ready yet
        handler.setOutage(true);
        handler.buy(1, 1, 5 ether, false); // fills launch 1 with the fee deferred
        handler.buy(1, 1, 1, true); // curve locked at threshold
        handler.sell(1, 1, 1e20, true);
        handler.flushCurve(1, 3); // outage keeps the pre-crown liability
        handler.setOutage(false);
        handler.claimKing(2, 2, 0);
        handler.flushCurve(1, 3); // delivered to the first king
        handler.graduate(1, 2);
        handler.graduate(1, 2); // already graduated
        handler.buy(1, 0, 1 ether, true); // curve closed after graduation
        handler.setOutage(true);
        handler.swap(1, 1, 0, uint128(0.01 ether));
        handler.swap(1, 1, 1, uint128(1e21));
        handler.swap(1, 1, 2, uint128(1e22));
        handler.swap(1, 1, 3, uint128(0.0005 ether));
        assertGt(handler.hook().totalDeferred(), 0);
        handler.retryHook(1, 2); // outage keeps the hook liability
        handler.setOutage(false);
        handler.retryHook(1, 2);
        handler.swap(1, 2, 0, uint128(0.02 ether));
        handler.claimKing(0, 1, 123);
        handler.swap(1, 1, 2, uint128(1e21)); // fees from launch 1 now reach the new king
        handler.buy(2, 2, 2 ether, false); // and curve fees from launch 2 reach the same king
        handler.donateEthToCurve(2, 0, 0.5 ether);
        handler.donateTokensToCurve(2, 2, 1e18);
        handler.assignUnassigned(0);
        handler.withdraw(2, 0); // first king beneficiary
        handler.withdraw(1, 1); // second king beneficiary
        handler.withdraw(3, 2); // genesis creator
        handler.withdraw(4, 0); // second creator
        handler.fundWorkers(0, 0, false);
        handler.fundWorkers(0, 1 ether, true);
        handler.probeRejections(1, 0);
        assertEq(handler.graduations(), 1);
        assertEq(handler.poolSwaps(), 6);
        assertGt(handler.deferrals(), 0);
        assertGt(handler.deliveries(), 0);
        handler.checkTokenSupplyAccounting();
        handler.checkCurveCustody();
        handler.checkGraduationFinalityAndPools();
        handler.checkFeeCustodyAndEntitlements();
        handler.checkWorkersAndCrown();
    }

    /// @dev Fees from a curve launch and from a graduated pool land on the same crowned beneficiary.
    function test_curveAndPoolFeesReachTheSameKing() public {
        handler.claimKing(0, 0, 0);
        handler.createLaunch(1);
        handler.buy(1, 1, 5 ether, true);
        handler.graduate(1, 1);
        address beneficiary = handler.actors(0);
        uint256 before = handler.escrow().pending(address(0), beneficiary);
        handler.buy(0, 2, 1 ether, true);
        uint256 afterCurve = handler.escrow().pending(address(0), beneficiary);
        assertEq(afterCurve - before, (1 ether / 100) / 2, "curve fee half reaches the king");
        handler.swap(1, 2, 0, uint128(1 ether / 100));
        uint256 afterPool = handler.escrow().pending(address(0), beneficiary);
        assertEq(afterPool - afterCurve, (1 ether / 100 / 100) / 2, "pool fee half reaches the same king");
        handler.checkFeeCustodyAndEntitlements();
    }
}
