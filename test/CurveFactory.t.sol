// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadHook} from "../src/hooks/PvPadHook.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BondingCurve, IPvPadFactoryCurve} from "../src/BondingCurve.sol";
import {PvPadToken} from "../src/PvPadToken.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {PvPadConstants} from "../src/libraries/PvPadConstants.sol";

contract CurveFixture is IPvPadFactoryCurve {
    FeeEscrow public immutable feeEscrow;
    KingOfThePad public immutable king;
    BondingCurve public immutable curve;
    PvPadToken public immutable token;
    uint256 public constant graduationThreshold = 4.2 ether;

    constructor(address creator) {
        WorkerSubsidy subsidy = new WorkerSubsidy(address(this));
        king = new KingOfThePad(subsidy);
        feeEscrow = new FeeEscrow(king, address(this));
        token = new PvPadToken("Curve test", "CVT");
        curve = new BondingCurve(IERC20(address(token)), this, 0, creator, feeEscrow, king);
        feeEscrow.authorizeRecorder(address(curve), true);
        token.transfer(address(curve), PvPadConstants.TOKEN_SUPPLY);
    }

    function sweep() external returns (uint256, uint256) {
        return curve.sweepForGraduation();
    }

    receive() external payable {}
}

contract RejectEth {
    receive() external payable {
        revert("reject");
    }
}

contract ReenterCurve {
    BondingCurve public immutable curve;
    bool public blocked;

    constructor(BondingCurve _curve) {
        curve = _curve;
    }

    receive() external payable {
        try curve.buy{value: 1}(address(this)) {
            blocked = false;
        } catch (bytes memory reason) {
            blocked = bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        }
    }
}

contract CurveFactoryTest is Test {
    CurveFixture fixture;
    BondingCurve curve;
    PvPadToken token;
    FeeEscrow escrow;
    KingOfThePad king;
    address creator = address(0xC0FFEE);
    address trader = address(0xBEEF);
    address beneficiary = address(0xCAFE);

    function setUp() public {
        fixture = new CurveFixture(creator);
        curve = fixture.curve();
        token = fixture.token();
        escrow = fixture.feeEscrow();
        king = fixture.king();
        vm.deal(trader, 100 ether);
        vm.deal(beneficiary, 1 ether);
        vm.prank(beneficiary);
        king.claimKing{value: 0.02 ether}(beneficiary);
    }

    function testFuzz_roundTripConservesAssetsAndChargesBothFees(uint256 gross) public {
        gross = bound(gross, 10_000, 4 ether);
        uint256 initialInvariant =
            (PvPadConstants.TOKEN_SUPPLY + PvPadConstants.VIRTUAL_TOKEN) * PvPadConstants.VIRTUAL_ETH;
        uint256 startBalance = trader.balance;
        vm.startPrank(trader);
        uint256 out = curve.buy{value: gross}(trader, 1, block.timestamp);
        token.approve(address(curve), out);
        (uint256 quoted, uint256 sellFee) = curve.quoteSell(out);
        uint256 proceeds = curve.sell(out, trader, quoted, block.timestamp);
        vm.stopPrank();
        assertEq(proceeds, quoted);
        assertEq(token.balanceOf(trader), 0);
        assertEq(curve.tokenReserve(), PvPadConstants.TOKEN_SUPPLY);
        assertEq(address(curve).balance, curve.ethReserve());
        uint256 allFees = gross / 100 + sellFee;
        assertEq(address(escrow).balance, allFees);
        assertEq(startBalance - trader.balance, curve.ethReserve() + allFees);
        assertGe(
            (curve.tokenReserve() + PvPadConstants.VIRTUAL_TOKEN) * (curve.ethReserve() + PvPadConstants.VIRTUAL_ETH),
            initialInvariant
        );
        assertEq(escrow.pending(address(0), beneficiary), (gross / 100) / 2 + sellFee / 2);
        assertEq(escrow.pending(address(0), creator), allFees - escrow.pending(address(0), beneficiary));
    }

    function testFuzz_capRefundsExcessAndEndsAtGraduationPrice(uint256 first) public {
        first = bound(first, 1, 4 ether);
        vm.prank(trader);
        curve.buy{value: first}(trader);
        uint256 cap = curve.maxBuyInput();
        uint256 before = trader.balance;
        (uint256 expected,) = curve.quoteBuy(10 ether);
        vm.prank(trader);
        uint256 bought = curve.buy{value: 10 ether}(trader, expected, block.timestamp);
        assertEq(bought, expected);
        assertEq(before - trader.balance, cap);
        assertTrue(curve.readyToGraduate());
        assertEq(curve.ethReserve(), 4.2 ether);
        assertApproxEqAbs(curve.tokenReserve(), PvPadConstants.TOKEN_SUPPLY / 4, 2);
        assertEq(curve.maxBuyInput(), 0);
        vm.prank(trader);
        vm.expectRevert(BondingCurve.NotReady.selector);
        curve.buy{value: 1}(trader);
    }

    function test_slippageDeadlineAndZeroRecipientRevertWithoutStateChange() public {
        (uint256 quote,) = curve.quoteBuy(1 ether);
        vm.startPrank(trader);
        vm.expectRevert(BondingCurve.InsufficientOutput.selector);
        curve.buy{value: 1 ether}(trader, quote + 1, block.timestamp);
        vm.expectRevert(BondingCurve.DeadlineExpired.selector);
        curve.buy{value: 1 ether}(trader, 0, block.timestamp - 1);
        vm.expectRevert(BondingCurve.ZeroAddress.selector);
        curve.buy{value: 1 ether}(address(0));
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.buy(trader);
        assertEq(curve.ethReserve(), 0);
        uint256 out = curve.buy{value: 1 ether}(trader);
        token.approve(address(curve), out);
        (uint256 ethQuote,) = curve.quoteSell(out);
        vm.expectRevert(BondingCurve.InsufficientOutput.selector);
        curve.sell(out, trader, ethQuote + 1, block.timestamp);
        vm.stopPrank();
    }

    function test_failedRecipientRollsBackSaleAndReentrantRecipientCannotTrade() public {
        vm.startPrank(trader);
        uint256 out = curve.buy{value: 1 ether}(trader);
        token.approve(address(curve), out);
        uint256 reserve = curve.ethReserve();
        RejectEth rejected = new RejectEth();
        vm.expectRevert(BondingCurve.NativeTransferFailed.selector);
        curve.sell(out, address(rejected));
        assertEq(token.balanceOf(trader), out);
        assertEq(curve.ethReserve(), reserve);
        ReenterCurve reenter = new ReenterCurve(curve);
        curve.sell(out, address(reenter));
        assertTrue(reenter.blocked());
        vm.stopPrank();
    }

    function test_graduationAuthorizationAndDonationsExcluded() public {
        vm.expectRevert(BondingCurve.NotFactory.selector);
        curve.sweepForGraduation();
        vm.expectRevert(BondingCurve.NotReady.selector);
        fixture.sweep();
        vm.prank(trader);
        uint256 bought = curve.buy{value: 10 ether}(trader);
        vm.prank(trader);
        token.transfer(address(curve), bought / 10);
        vm.deal(address(curve), address(curve).balance + 1 ether);
        uint256 trackedTokens = curve.tokenReserve();
        (uint256 ethSwept, uint256 tokenSwept) = fixture.sweep();
        assertEq(ethSwept, 4.2 ether);
        assertEq(tokenSwept, trackedTokens);
        assertEq(address(curve).balance, 1 ether);
        assertEq(token.balanceOf(address(curve)), bought / 10);
        assertTrue(curve.graduated());
        vm.expectRevert(BondingCurve.Graduated.selector);
        fixture.sweep();
        vm.startPrank(trader);
        vm.expectRevert(BondingCurve.Graduated.selector);
        curve.buy{value: 1}(trader);
        vm.expectRevert(BondingCurve.Graduated.selector);
        curve.sell(1, trader);
        vm.stopPrank();
    }

    function test_failedFeeDeliveryPreservesOriginalKingAndPerTradeRounding() public {
        vm.mockCallRevert(address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeFor.selector), "fail");
        vm.startPrank(trader);
        curve.buy{value: 300}(trader);
        curve.buy{value: 300}(trader);
        vm.stopPrank();
        assertEq(curve.totalDeferredFees(), 6);
        assertEq(curve.deferredKingShares(beneficiary), 2);
        assertEq(address(curve).balance, curve.ethReserve() + 6);
        address nextKing = address(0x1234);
        vm.deal(nextKing, 1 ether);
        vm.prank(nextKing);
        king.claimKing{value: 0.03 ether}(nextKing);
        vm.clearMockedCalls();
        assertTrue(curve.flushDeferredFees(beneficiary));
        assertEq(curve.totalDeferredFees(), 0);
        assertEq(escrow.pending(address(0), beneficiary), 2);
        assertEq(escrow.pending(address(0), nextKing), 0);
        assertEq(escrow.pending(address(0), creator), 4);
        assertTrue(curve.flushDeferredFees(beneficiary));
        assertEq(escrow.pending(address(0), beneficiary), 2);
    }

    function test_failedRetryRetainsFeeAndGraduationCannotSweepIt() public {
        vm.mockCallRevert(address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeFor.selector), "fail");
        vm.prank(trader);
        curve.buy{value: 10 ether}(trader);
        uint256 deferred = curve.totalDeferredFees();
        vm.mockCallRevert(
            address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeShares.selector), "fail"
        );
        assertFalse(curve.flushDeferredFees(beneficiary));
        assertEq(curve.totalDeferredFees(), deferred);
        fixture.sweep();
        assertEq(address(curve).balance, deferred);
        vm.clearMockedCalls();
        assertTrue(curve.flushDeferredFees(beneficiary));
        assertEq(address(curve).balance, 0);
    }
}

contract FactoryConstructionTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager manager;
    WorkerSubsidy workers;
    KingOfThePad king;
    PvPadHook hook;
    PvPadFactory factory;

    function setUp() public {
        manager = new PoolManager(address(this));
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        hook = new PvPadHook{salt: salt}(manager);
        factory = new PvPadFactory(manager, workers, king, hook, address(0xBEEF));
        vm.deal(address(this), 1 ether);
    }

    function test_genesisIsAlreadyConfiguredAndMetadataImmutable() public {
        assertEq(factory.launchCount(), 1);
        (address creator,,, bool graduated,) = factory.launches(0);
        assertEq(creator, address(0xBEEF));
        assertFalse(graduated);
        assertEq(factory.launchMetadataURI(0), "");
        assertEq(workers.workerPot(), 0);
        uint256 id =
            factory.createLaunch{value: 0.0005 ether}("Metadata", "META", bytes32(0), "ipfs://example/launch.json");
        assertEq(id, 1);
        assertEq(factory.launchMetadataURI(id), "ipfs://example/launch.json");
        assertEq(workers.workerPot(), 0.0005 ether);
        (bool ok,) = address(factory).call(abi.encodeWithSignature("setMetadataURI(uint256,string)", id, "changed"));
        assertFalse(ok);
    }

    function test_invalidFeesMetadataAndCallbackFailAtomically() public {
        vm.expectRevert(PvPadFactory.LaunchFeeRequired.selector);
        factory.createLaunch("Token", "TOK");
        vm.expectRevert(PvPadFactory.LaunchFeeRequired.selector);
        factory.createLaunch{value: 0.0005 ether + 1}("Token", "TOK");
        vm.expectRevert(PvPadFactory.InvalidMetadata.selector);
        factory.createLaunch{value: 0.0005 ether}("", "TOK");
        vm.expectRevert(PvPadFactory.InvalidMetadata.selector);
        factory.createLaunch{value: 0.0005 ether}("Token", new string(17));
        vm.expectRevert(PvPadFactory.InvalidMetadata.selector);
        factory.createLaunch{value: 0.0005 ether}("Token", "TOK", bytes32(0), new string(2049));
        vm.expectRevert(PvPadFactory.InvalidCallback.selector);
        factory.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(PvPadFactory.InvalidCallback.selector);
        factory.unlockCallback("");
        assertEq(factory.launchCount(), 1);
        assertEq(workers.workerPot(), 0);
    }

    function test_poisonedPredictedPoolIsSkippedAutomaticallyAndNeverSeeded() public {
        address predicted = _predictedToken("Poisoned", "PSN", bytes32(0));
        PoolKey memory key = _key(predicted);
        manager.initialize(key, uint160(1 << 96));
        uint256 id = factory.createLaunch{value: 0.0005 ether}("Poisoned", "PSN");
        assertEq(id, 1);
        (, address token,,, PoolId poolId) = factory.launches(id);
        assertTrue(token != predicted);
        assertEq(predicted.code.length, 0);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
        (uint160 poisoned,,,) = StateLibrary.getSlot0(manager, key.toId());
        assertEq(poisoned, uint160(1 << 96));
        assertEq(workers.workerPot(), 0.0005 ether);
        // An explicit user salt remains available as a manual escape hatch.
        uint256 next = factory.createLaunch{value: 0.0005 ether}("Poisoned", "PSN", bytes32(uint256(1)));
        assertEq(next, 2);
        assertEq(workers.workerPot(), 0.001 ether);
    }

    function test_preinitializedCanonicalPriceCanLaunchSafely() public {
        address predicted = _predictedToken("Canonical", "CAN", bytes32(0));
        manager.initialize(_key(predicted), factory.canonicalSqrtPriceX96());
        uint256 id = factory.createLaunch{value: 0.0005 ether}("Canonical", "CAN");
        (, address token,, bool graduated,) = factory.launches(id);
        assertEq(token, predicted);
        assertFalse(graduated);
    }

    function _predictedToken(string memory name, string memory symbol, bytes32 userSalt)
        internal
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(factory.launchCount(), address(this), name, symbol, userSalt));
        bytes32 initHash = keccak256(abi.encodePacked(type(PvPadToken).creationCode, abi.encode(name, symbol)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash)))));
    }

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 60, IHooks(address(hook)));
    }
}
