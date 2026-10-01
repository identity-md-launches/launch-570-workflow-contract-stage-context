// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadHook} from "../src/hooks/PvPadHook.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

contract RejectEther {
    receive() external payable {
        revert("no ETH");
    }
}

contract PvPadIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    PoolManager manager;
    PoolSwapTest router;
    WorkerSubsidy workers;
    KingOfThePad king;
    FeeEscrow escrow;
    PvPadHook hook;
    PvPadFactory factory;
    address creator = address(0xC0FFEE);
    address trader = address(0xBEEF);
    address beneficiary = address(0xCAFE);

    function setUp() public {
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        hook = new PvPadHook{salt: salt}(manager);
        factory = new PvPadFactory(manager, workers, king, hook, creator);
        escrow = factory.feeEscrow();
        vm.deal(address(this), 100 ether);
        vm.deal(trader, 100 ether);
        king.claimKing{value: 0.02 ether}(beneficiary);
    }

    function _curve(uint256 id) internal view returns (BondingCurve curve, IERC20 token) {
        (, address tokenAddress, address curveAddress,,) = factory.launches(id);
        return (BondingCurve(payable(curveAddress)), IERC20(tokenAddress));
    }

    function _key(uint256 id) internal view returns (PoolKey memory) {
        (, IERC20 token) = _curve(id);
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0, 60, IHooks(address(hook)));
    }

    function _graduate(uint256 id) internal {
        (BondingCurve curve, IERC20 token) = _curve(id);
        vm.prank(trader);
        curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        assertEq(curve.ethReserve(), 4.2 ether);
        factory.graduate(id);
        uint256 approval = token.balanceOf(trader);
        vm.prank(trader);
        token.approve(address(router), approval);
    }

    function _swap(bool zeroForOne, int256 amount) internal returns (BalanceDelta delta, uint256 fee) {
        uint256 beforeFees = escrow.totalSkimmedEth();
        PoolKey memory key = _key(0);
        vm.prank(trader);
        delta = router.swap{value: zeroForOne ? 1 ether : 0}(
            key,
            IPoolManager.SwapParams(
                zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        fee = escrow.totalSkimmedEth() - beforeFees;
    }

    function test_realPoolAllFourSwapModesChargeETHAndConserveCredits() public {
        _graduate(0);
        uint256 beforeKing = escrow.pending(address(0), beneficiary);
        uint256 beforeCreator = escrow.pending(address(0), creator);
        (BalanceDelta a, uint256 f1) = _swap(true, -int256(0.1 ether));
        assertEq(a.amount0(), -int128(0.1 ether));
        assertEq(f1, 0.001 ether);
        assertGt(a.amount1(), 0);
        (BalanceDelta b, uint256 f2) = _swap(false, -int256(1_000 ether));
        assertGt(b.amount0(), 0);
        assertEq(f2, (uint256(uint128(b.amount0())) + f2) / 100);
        (BalanceDelta c, uint256 f3) = _swap(true, int256(1_000 ether));
        assertEq(c.amount1(), int128(1_000 ether));
        assertEq(f3, uint256(uint128(-c.amount0())) / 100);
        (BalanceDelta d, uint256 f4) = _swap(false, int256(0.001 ether));
        assertEq(d.amount0(), int128(0.001 ether));
        // Exact ETH output grosses up by 1/0.99, retaining the requested net output.
        assertEq(f4, (uint256(uint128(d.amount0())) + f4) / 100);
        assertEq(escrow.pending(address(0), beneficiary) - beforeKing, f1 / 2 + f2 / 2 + f3 / 2 + f4 / 2);
        assertEq(
            escrow.pending(address(0), creator) - beforeCreator, f1 - f1 / 2 + f2 - f2 / 2 + f3 - f3 / 2 + f4 - f4 / 2
        );
        assertEq(address(escrow).balance, escrow.totalSkimmedEth());
        assertEq(address(hook).balance, 0);
    }

    function test_secondLaunchCurveAndPostGraduationFeesShareKing() public {
        vm.prank(creator);
        vm.deal(creator, 1 ether);
        assertEq(factory.createLaunch{value: 0.0005 ether}("Second", "TWO"), 1);
        assertEq(factory.launchCount(), 2);
        _graduate(0);
        _graduate(1);
        (BalanceDelta delta, uint256 firstFee) = _swap(true, -int256(0.1 ether));
        assertGt(delta.amount1(), 0);
        uint256 beforeKing = escrow.pending(address(0), beneficiary);
        PoolKey memory secondKey = _key(1);
        vm.prank(trader);
        router.swap{value: 0.1 ether}(
            secondKey,
            IPoolManager.SwapParams(true, -int256(0.1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(escrow.pending(address(0), beneficiary) - beforeKing, firstFee / 2);
        assertEq(workers.workerPot(), 0.0205 ether);
        assertEq(
            escrow.pending(address(0), creator), escrow.totalSkimmedEth() - escrow.pending(address(0), beneficiary)
        );
    }

    function test_graduationLocksFactoryPositionAndStopsCurve() public {
        _graduate(0);
        PoolKey memory key = _key(0);
        (uint128 locked,,) = StateLibrary.getPositionInfo(
            manager, key.toId(), address(factory), TickMath.minUsableTick(60), TickMath.maxUsableTick(60), bytes32(0)
        );
        assertGt(locked, 0);
        assertEq(locked, StateLibrary.getLiquidity(manager, key.toId()));
        (BondingCurve curve, IERC20 token) = _curve(0);
        assertTrue(curve.graduated());
        assertEq(curve.ethReserve(), 0);
        assertEq(curve.tokenReserve(), 0);
        assertGt(token.balanceOf(address(manager)), 0);
        vm.expectRevert();
        factory.graduate(0);
        vm.expectRevert();
        curve.buy{value: 1 ether}(trader, 1, block.timestamp);
        vm.expectRevert();
        curve.sell(1, trader, 0, block.timestamp);
        vm.expectRevert();
        factory.unlockCallback("");
        PoolModifyLiquidityTest malicious = new PoolModifyLiquidityTest(manager);
        vm.expectRevert();
        malicious.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), -int256(uint256(locked)), bytes32(0)
            ),
            ""
        );
        (uint128 stillLocked,,) = StateLibrary.getPositionInfo(
            manager, key.toId(), address(factory), TickMath.minUsableTick(60), TickMath.maxUsableTick(60), bytes32(0)
        );
        assertEq(locked, stillLocked);
    }

    function test_pregraduationAndForeignPoolSwapsRejected() public {
        PoolKey memory key = _key(0);
        vm.expectRevert();
        router.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams(true, -int256(0.1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        key.fee = 500;
        manager.initialize(key, 79228162514264337593543950336);
        vm.expectRevert();
        router.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams(true, -int256(0.1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function test_rejectingBeneficiaryDoesNotBlockCurveOrPool() public {
        RejectEther rejecting = new RejectEther();
        king.claimKing{value: 0.02 ether}(address(rejecting));
        _graduate(0);
        _swap(true, -int256(0.1 ether));
        uint256 credit = escrow.pending(address(0), address(rejecting));
        assertGt(credit, 0);
        vm.prank(address(rejecting));
        assertEq(escrow.withdraw(address(0), address(rejecting)), 0);
        assertEq(escrow.pending(address(0), address(rejecting)), credit);
        vm.prank(address(rejecting));
        assertEq(escrow.withdraw(address(0), trader), credit);
    }

    function test_partialFillETHSpecifiedRevertsWithoutLosingFunds() public {
        _graduate(0);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, _key(0).toId());
        uint256 feesBefore = escrow.totalSkimmedEth();
        uint256 balanceBefore = trader.balance;
        PoolKey memory key = _key(0);
        vm.expectRevert();
        vm.prank(trader);
        router.swap{value: 1 ether}(
            key, IPoolManager.SwapParams(true, -int256(1 ether), price - 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(trader.balance, balanceBefore);
        assertEq(escrow.totalSkimmedEth(), feesBefore);
    }

    function test_graduationFailureRollsBackReserveSweep() public {
        (BondingCurve curve, IERC20 token) = _curve(0);
        vm.prank(trader);
        curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        uint256 tokenReserve = curve.tokenReserve();
        vm.mockCallRevert(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), "manager unavailable");
        vm.expectRevert();
        factory.graduate(0);
        assertFalse(curve.graduated());
        assertEq(curve.ethReserve(), 4.2 ether);
        assertEq(curve.tokenReserve(), tokenReserve);
        assertEq(token.balanceOf(address(curve)), tokenReserve);
        assertEq(address(curve).balance, 4.2 ether);
        vm.clearMockedCalls();
        vm.prank(address(0x1234));
        factory.graduate(0);
        assertTrue(curve.graduated());
    }

    function test_thresholdDustSellCannotInvalidatePermissionlessGraduation() public {
        (BondingCurve curve, IERC20 token) = _curve(0);
        address holder = address(0xBAD);
        vm.deal(holder, 0.01 ether);
        vm.prank(holder);
        curve.buy{value: 0.01 ether}(holder);
        vm.prank(trader);
        curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        uint256 sliver = 5_892_857_143; // Before this fix, a zero-fee 99 wei sell.
        uint256 balanceBefore = token.balanceOf(holder);
        uint256 reserveBefore = curve.tokenReserve();
        uint256 feesBefore = escrow.totalSkimmedEth();
        (uint256 quote, uint256 fee) = curve.quoteSell(sliver);
        assertEq(quote, 0);
        assertEq(fee, 0);
        vm.startPrank(holder);
        token.approve(address(curve), sliver);
        vm.expectRevert(BondingCurve.NotReady.selector);
        curve.sell(sliver, holder);
        vm.expectRevert(BondingCurve.NotReady.selector);
        curve.sell(sliver, holder, 0, block.timestamp);
        vm.stopPrank();
        assertEq(curve.ethReserve(), 4.2 ether);
        assertEq(curve.tokenReserve(), reserveBefore);
        assertEq(token.balanceOf(holder), balanceBefore);
        assertEq(token.allowance(holder, address(curve)), sliver);
        assertEq(escrow.totalSkimmedEth(), feesBefore);
        assertTrue(curve.readyToGraduate());
        vm.prank(address(0x1234));
        factory.graduate(0);
        assertTrue(curve.graduated());
        assertTrue(factory.isRegisteredPool(_key(0).toId()));
    }

    function test_unspecifiedETHPartialFillChargesOnlyExecution() public {
        _graduate(0);
        PoolKey memory key = _key(0);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, key.toId());
        uint256 feesBefore = escrow.totalSkimmedEth();
        vm.prank(trader);
        BalanceDelta delta = router.swap(
            key,
            IPoolManager.SwapParams(false, -int256(1_000_000 ether), uint160(uint256(price) * 1001 / 1000)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertGt(delta.amount1(), -int128(1_000_000 ether));
        assertLt(delta.amount1(), 0);
        uint256 fee = escrow.totalSkimmedEth() - feesBefore;
        assertGt(fee, 0);
        assertEq(fee, (uint256(uint128(delta.amount0())) + fee) / 100);
    }

    function test_deploymentFloorRuntimeAndSupply() public {
        LaunchToken protocolToken = new LaunchToken();
        (BondingCurve curve, IERC20 padToken) = _curve(0);
        address[8] memory contracts = [
            address(protocolToken),
            address(workers),
            address(king),
            address(hook),
            address(factory),
            address(escrow),
            address(curve),
            address(padToken)
        ];
        for (uint256 i; i < contracts.length; i++) {
            bytes memory code = contracts[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            for (uint256 j; j < code.length; j++) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
        assertEq(protocolToken.totalSupply(), 1e27);
        assertEq(protocolToken.balanceOf(address(this)), 1e27);
        assertEq(padToken.totalSupply(), 1e27);
        assertEq(padToken.balanceOf(address(curve)), 1e27);
        assertEq(padToken.balanceOf(creator), 0);
        assertEq(workers.updater(), address(this));
        assertEq(escrow.factory(), address(factory));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x08cc);
        assertEq(hook.REQUIRED_FLAGS(), 0x08cc);
        assertFalse(hook.getHookPermissions().beforeInitialize);
        assertTrue(hook.getHookPermissions().beforeAddLiquidity);
    }

    receive() external payable {}
}
