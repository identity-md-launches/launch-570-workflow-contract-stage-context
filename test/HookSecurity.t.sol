// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PvPadHook} from "../src/hooks/PvPadHook.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @dev Fault injection only. The integration suite separately exercises the real v4 PoolManager.
contract FeeHookManager {
    function take(Currency currency, address to, uint256 amount) external {
        require(Currency.unwrap(currency) == address(0));
        (bool ok,) = to.call{value: amount}("");
        require(ok);
    }

    function before(PvPadHook hook, PoolKey memory key, IPoolManager.SwapParams memory params)
        external
        returns (BeforeSwapDelta delta)
    {
        (, delta,) = hook.beforeSwap(msg.sender, key, params, "");
    }

    function afterFee(PvPadHook hook, PoolKey memory key, IPoolManager.SwapParams memory params, int128 ethDelta)
        external
        returns (int128 fee)
    {
        (, fee) = hook.afterSwap(msg.sender, key, params, toBalanceDelta(ethDelta, 0), "");
    }

    function addLiquidity(PvPadHook hook, address sender, PoolKey memory key) external view returns (bytes4) {
        return hook.beforeAddLiquidity(sender, key, IPoolManager.ModifyLiquidityParams(-60, 60, 1, bytes32(0)), "");
    }

    receive() external payable {}
}

contract FeeHookKing {
    address public beneficiary = address(0xBEEF);

    function setBeneficiary(address value) external {
        beneficiary = value;
    }
}

contract FaultInjectingEscrow {
    address public immutable factory;
    FeeHookKing public immutable kingOfThePad;
    bool public fail;
    address public recorder;
    mapping(address => uint256) public credits;

    constructor(address factory_, FeeHookKing king_) {
        factory = factory_;
        kingOfThePad = king_;
    }

    function setRecorder(address recorder_) external {
        recorder = recorder_;
    }

    function setFail(bool value) external {
        fail = value;
    }

    function recordTradeFeeNativeShares(address creator, address beneficiary, uint256 kingShare) external payable {
        require(msg.sender == recorder && !fail && kingShare <= msg.value);
        credits[beneficiary] += kingShare;
        credits[creator] += msg.value - kingShare;
    }

    function recordTradeFeeNativeFor(address creator, address beneficiary, uint256 amount) external payable {
        require(msg.sender == recorder && !fail && msg.value == amount);
        credits[beneficiary] += amount / 2;
        credits[creator] += amount - amount / 2;
    }
}

contract HookTokenProvenance {
    address public immutable factory = msg.sender;
}

contract HookSecurityTest is Test {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    FeeHookManager private manager;
    FeeHookKing private king;
    FaultInjectingEscrow private escrow;
    PvPadHook private hook;
    PoolKey private key;
    bool private graduated;
    address private constant CREATOR = address(0xC0FFEE);

    function setUp() public {
        manager = new FeeHookManager();
        king = new FeeHookKing();
        escrow = new FaultInjectingEscrow(address(this), king);
        (address predicted, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        hook = new PvPadHook{salt: salt}(IPoolManager(address(manager)));
        assertEq(address(hook), predicted);
        escrow.setRecorder(address(hook));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(new HookTokenProvenance())), 0, 60, hook);
        hook.bindPool(key, CREATOR, FeeEscrow(payable(address(escrow))));
        graduated = true;
        vm.deal(address(manager), 100 ether);
    }

    function isRegisteredPool(PoolId id) external view returns (bool) {
        return graduated && PoolId.unwrap(id) == PoolId.unwrap(key.toId());
    }

    function test_hookUsesSwapAndAddLiquidityFlagsAndNoInitializationCallback() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x08cc);
        assertEq(hook.REQUIRED_FLAGS(), 0x08cc);
        assertEq(HookMiner.PVPAD_HOOK_FLAGS, 0x08cc);
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertTrue(p.beforeAddLiquidity);
        assertFalse(p.beforeInitialize || p.afterInitialize || p.afterAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        vm.expectRevert(PvPadHook.UnsupportedCallback.selector);
        hook.beforeInitialize(address(this), key, 1 << 96);
        vm.expectRevert(PvPadHook.UnsupportedCallback.selector);
        hook.beforeRemoveLiquidity(address(this), key, IPoolManager.ModifyLiquidityParams(-60, 60, -1, 0), "");
    }

    function test_constructorRejectsWrongPermissionAddress() public {
        bytes memory code = abi.encodePacked(type(PvPadHook).creationCode, abi.encode(IPoolManager(address(manager))));
        uint256 salt;
        while (uint160(HookMiner.computeAddress(address(this), salt, code)) & Hooks.ALL_HOOK_MASK == 0x08cc) salt++;
        vm.expectRevert();
        new PvPadHook{salt: bytes32(salt)}(IPoolManager(address(manager)));
    }

    function test_legacySwapOnlyFlagAddressIsRejected() public {
        // The previous 0x00cc layout (no beforeAddLiquidity) can no longer host this hook.
        (address legacy, bytes32 salt) = HookMiner.find(
            address(this), 0x00cc, type(PvPadHook).creationCode, abi.encode(IPoolManager(address(manager)))
        );
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, legacy));
        new PvPadHook{salt: salt}(IPoolManager(address(manager)));
    }

    function test_beforeAddLiquidityAdmitsOnlyBoundFactoryUntilGraduation() public {
        graduated = false;
        vm.expectRevert(PvPadHook.LiquidityClosed.selector);
        manager.addLiquidity(hook, address(0xBAD), key);
        vm.expectRevert(PvPadHook.LiquidityClosed.selector);
        manager.addLiquidity(hook, address(manager), key);
        // The bound factory (this test contract bound the pool) deposits its graduation position.
        assertEq(manager.addLiquidity(hook, address(this), key), IHooks.beforeAddLiquidity.selector);
        graduated = true;
        assertEq(manager.addLiquidity(hook, address(0xBAD), key), IHooks.beforeAddLiquidity.selector);
        assertEq(manager.addLiquidity(hook, address(this), key), IHooks.beforeAddLiquidity.selector);
    }

    function test_beforeAddLiquidityRejectsUnboundPoolsAndDirectCalls() public {
        PoolKey memory unbound = key;
        unbound.fee = 500;
        vm.expectRevert(PvPadHook.LiquidityClosed.selector);
        manager.addLiquidity(hook, address(this), unbound);
        unbound = key;
        unbound.currency1 = Currency.wrap(address(new HookTokenProvenance()));
        vm.expectRevert(PvPadHook.LiquidityClosed.selector);
        manager.addLiquidity(hook, address(this), unbound);
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, IPoolManager.ModifyLiquidityParams(-60, 60, 1, 0), "");
    }

    function test_foreignRegistryCannotCaptureTokenPool() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(PvPadHook.NotLaunchFactory.selector);
        hook.bindPool(key, address(0xBAD), FeeEscrow(payable(address(escrow))));
    }

    function test_poolCannotBeRebound() public {
        vm.expectRevert(PvPadHook.PoolAlreadyBound.selector);
        hook.bindPool(key, address(0xBAD), FeeEscrow(payable(address(escrow))));
    }

    function test_foreignEscrowRejected() public {
        FaultInjectingEscrow foreign = new FaultInjectingEscrow(address(0xBAD), king);
        vm.expectRevert(PvPadHook.NotLaunchFactory.selector);
        hook.bindPool(key, CREATOR, FeeEscrow(payable(address(foreign))));
    }

    function test_onlyCanonicalPoolCanBind() public {
        PoolKey memory badKey = key;
        badKey.fee = 3000;
        vm.expectRevert(PvPadHook.InvalidPool.selector);
        hook.bindPool(badKey, CREATOR, FeeEscrow(payable(address(escrow))));
    }

    function test_callbacksRequirePoolManager() public {
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, _params(-1 ether), "");
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, _params(-1 ether), toBalanceDelta(-1 ether, 0), "");
    }

    function test_preGraduationSwapRejected() public {
        graduated = false;
        vm.expectRevert(PvPadHook.PoolNotGraduated.selector);
        manager.before(hook, key, _params(-1 ether));
    }

    function test_feeDeliveryFailurePreservesFeeAndOriginalKing() public {
        escrow.setFail(true);
        BeforeSwapDelta delta = manager.before(hook, key, _params(-1 ether));
        assertEq(delta.getSpecifiedDelta(), 0.01 ether);
        assertEq(hook.totalDeferred(), 0.01 ether);
        assertEq(address(hook).balance, 0.01 ether);
        assertEq(hook.deferredFees(address(escrow), CREATOR, address(0xBEEF)), 0.01 ether);
        king.setBeneficiary(address(0xCAFE));
        escrow.setFail(false);
        uint256 delivered = hook.retryDeferred(FeeEscrow(payable(address(escrow))), CREATOR, address(0xBEEF));
        assertEq(delivered, 0.01 ether);
        assertEq(escrow.credits(address(0xBEEF)), 0.005 ether);
        assertEq(escrow.credits(address(0xCAFE)), 0);
        assertEq(escrow.credits(CREATOR), 0.005 ether);
        assertEq(hook.totalDeferred(), 0);
        assertEq(address(hook).balance, 0);
        assertEq(hook.retryDeferred(FeeEscrow(payable(address(escrow))), CREATOR, address(0xBEEF)), 0);
    }

    function test_deferredAggregationPreservesPerTradeRounding() public {
        escrow.setFail(true);
        manager.before(hook, key, _params(-100));
        manager.before(hook, key, _params(-100));
        assertEq(hook.totalDeferred(), 2);
        assertEq(hook.deferredKingShares(address(escrow), CREATOR, address(0xBEEF)), 0);
        escrow.setFail(false);
        hook.retryDeferred(FeeEscrow(payable(address(escrow))), CREATOR, address(0xBEEF));
        assertEq(escrow.credits(CREATOR), 2);
        assertEq(escrow.credits(address(0xBEEF)), 0);
        assertEq(address(escrow).balance, 2);
    }

    function test_retryFailureKeepsDeferredCredit() public {
        escrow.setFail(true);
        manager.before(hook, key, _params(-1 ether));
        assertEq(hook.retryDeferred(FeeEscrow(payable(address(escrow))), CREATOR, address(0xBEEF)), 0);
        assertEq(hook.totalDeferred(), 0.01 ether);
        assertEq(hook.deferredFees(address(escrow), CREATOR, address(0xBEEF)), 0.01 ether);
        assertEq(address(hook).balance, 0.01 ether);
    }

    function test_dustDoesNotCreateDeferredCredits() public {
        escrow.setFail(true);
        BeforeSwapDelta delta = manager.before(hook, key, _params(-99));
        assertEq(delta.getSpecifiedDelta(), 0);
        assertEq(hook.totalDeferred(), 0);
    }

    function test_extremeSpecifiedAmountRejectedCleanly() public {
        vm.expectRevert(PvPadHook.AmountTooLarge.selector);
        manager.before(hook, key, _params(type(int256).min));
    }

    function test_afterSwapRejectsPartialSpecifiedFill() public {
        vm.expectRevert(PvPadHook.PartialFill.selector);
        manager.afterFee(hook, key, _params(-1 ether), -0.5 ether);
    }

    function testFuzz_exactTokenOutputFeeIsOnePercentOfGrossEthInput(uint128 coreInput) public {
        coreInput = uint128(bound(coreInput, 1, 10 ether));
        IPoolManager.SwapParams memory params = _params(1 ether);
        int128 fee = manager.afterFee(hook, key, params, -int128(coreInput));
        assertEq(uint128(fee), (uint256(coreInput) + uint128(fee)) / 100);
        assertEq(escrow.credits(CREATOR) + escrow.credits(address(0xBEEF)), uint128(fee));
    }

    function testFuzz_exactEthOutputFeeIsOnePercentOfGrossEthOutput(uint128 netOutput) public {
        netOutput = uint128(bound(netOutput, 1, 10 ether));
        IPoolManager.SwapParams memory params = _params(int256(uint256(netOutput)));
        params.zeroForOne = false;
        BeforeSwapDelta delta = manager.before(hook, key, params);
        uint256 fee = uint128(delta.getSpecifiedDelta());
        assertEq(fee, (uint256(netOutput) + fee) / 100);
        assertEq(escrow.credits(CREATOR) + escrow.credits(address(0xBEEF)), fee);
    }

    function testFuzz_feeConservationOnSpecifiedInput(uint128 amount) public {
        amount = uint128(bound(amount, 1, 10 ether));
        uint256 fee = uint256(amount) / 100;
        BeforeSwapDelta delta = manager.before(hook, key, _params(-int256(uint256(amount))));
        assertEq(uint128(delta.getSpecifiedDelta()), fee);
        assertEq(escrow.credits(CREATOR) + escrow.credits(address(0xBEEF)), fee);
        assertEq(address(escrow).balance, fee);
        assertEq(address(manager).balance, 100 ether - fee);
        assertEq(hook.totalDeferred(), 0);
    }

    function _params(int256 amount) private pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({zeroForOne: true, amountSpecified: amount, sqrtPriceLimitX96: 1});
    }
}
