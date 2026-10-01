// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PvPadFactory} from "src/PvPadFactory.sol";
import {PvPadHook} from "src/hooks/PvPadHook.sol";
import {WorkerSubsidy} from "src/WorkerSubsidy.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {HookMiner} from "src/utils/HookMiner.sol";

/// @dev Test-only router: both swaps run before settlement in one real PoolManager unlock.
/// The ETH bridge stays in flash accounting. Fee observations measure actual manager ETH
/// transfers during each swap, independently of hook/escrow counters and fee formulas.
contract BatchSwapRouter {
    using CurrencySettler for Currency;

    error NotManager();
    error MinimumOutput();

    struct Result {
        uint256 bridgeEth;
        uint256 tokensOut;
        uint256 sellFee;
        uint256 buyFee;
    }

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function route(PoolKey memory first, PoolKey memory second, uint256 tokensIn, uint256 minOut, uint160 buyLimit)
        external
        returns (Result memory)
    {
        return abi.decode(manager.unlock(abi.encode(msg.sender, first, second, tokensIn, minOut, buyLimit)), (Result));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (address payer, PoolKey memory first, PoolKey memory second, uint256 amount, uint256 minOut, uint160 limit) =
            abi.decode(data, (address, PoolKey, PoolKey, uint256, uint256, uint160));
        Result memory result;
        uint256 beforeEth = address(manager).balance;
        BalanceDelta sold =
            manager.swap(first, IPoolManager.SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1), "");
        require(sold.amount0() > 0 && int256(sold.amount1()) == -int256(amount), "sell must fill");
        result.bridgeEth = uint256(uint128(sold.amount0()));
        result.sellFee = beforeEth - address(manager).balance;
        beforeEth = address(manager).balance;
        BalanceDelta bought = manager.swap(
            second,
            IPoolManager.SwapParams(true, -int256(result.bridgeEth), limit == 0 ? TickMath.MIN_SQRT_PRICE + 1 : limit),
            ""
        );
        require(int256(bought.amount0()) == -int256(result.bridgeEth) && bought.amount1() > 0, "buy must fill");
        result.tokensOut = uint256(uint128(bought.amount1()));
        result.buyFee = beforeEth - address(manager).balance;
        if (result.tokensOut < minOut) revert MinimumOutput();
        require(
            TransientStateLibrary.currencyDelta(manager, address(this), Currency.wrap(address(0))) == 0,
            "ETH bridge must net to zero"
        );
        _settle(first.currency1, payer);
        if (Currency.unwrap(first.currency1) != Currency.unwrap(second.currency1)) _settle(second.currency1, payer);
        return abi.encode(result);
    }

    function _settle(Currency currency, address payer) private {
        int256 delta = TransientStateLibrary.currencyDelta(manager, address(this), currency);
        if (delta < 0) currency.settle(manager, payer, uint256(-delta), false);
        if (delta > 0) currency.take(manager, payer, uint256(delta), false);
    }
}

abstract contract BatchSwapFixture is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager internal manager;
    BatchSwapRouter internal router;
    PvPadFactory internal factory;
    PvPadHook internal hook;
    WorkerSubsidy internal workers;
    KingOfThePad internal king;
    FeeEscrow internal escrow;
    IERC20[2] internal tokens;
    PoolKey[2] internal keys;
    address[3] internal actors = [address(0xBA710), address(0xBA711), address(0xBA712)];
    address[2] internal creators = [address(0xBC710), address(0xBC711)];

    function setUp() public virtual {
        vm.deal(address(this), 100 ether);
        manager = new PoolManager(address(this));
        router = new BatchSwapRouter(manager);
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        hook = new PvPadHook{salt: salt}(manager);
        factory = new PvPadFactory(manager, workers, king, hook, creators[0]);
        escrow = factory.feeEscrow();
        king.claimKing{value: 0.02 ether}(actors[0]);
        vm.deal(creators[1], 1 ether);
        vm.prank(creators[1]);
        factory.createLaunch{value: 0.0005 ether}("Batch Second", "BTWO");
        for (uint256 i; i < 2; ++i) {
            (, address token, address curve,,) = factory.launches(i);
            tokens[i] = IERC20(token);
            keys[i] = factory.getPoolKey(i);
            uint256 cap = BondingCurve(curve).maxBuyInput();
            BondingCurve(curve).buy{value: cap}(address(this));
            factory.graduate(i);
            uint256 share = tokens[i].balanceOf(address(this)) / actors.length;
            for (uint256 j; j < actors.length; ++j) {
                tokens[i].transfer(actors[j], j == actors.length - 1 ? tokens[i].balanceOf(address(this)) : share);
                vm.prank(actors[j]);
                tokens[i].approve(address(router), type(uint256).max);
            }
        }
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 10_000 ether);
        }
    }

    function _outage(bool fail) internal {
        if (!fail) {
            vm.clearMockedCalls();
            return;
        }
        vm.mockCallRevert(address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeFor.selector), "outage");
        vm.mockCallRevert(
            address(escrow), abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeShares.selector), "outage"
        );
    }

    function _assertSettled() internal view {
        assertFalse(TransientStateLibrary.isUnlocked(manager));
        assertEq(TransientStateLibrary.getNonzeroDeltaCount(manager), 0);
        assertEq(address(router).balance, 0);
        for (uint256 i; i < 2; ++i) {
            assertEq(tokens[i].balanceOf(address(router)), 0);
            assertEq(TransientStateLibrary.currencyDelta(manager, address(router), keys[i].currency1), 0);
        }
        assertEq(TransientStateLibrary.currencyDelta(manager, address(router), Currency.wrap(address(0))), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(hook), Currency.wrap(address(0))), 0);
    }

    /// @dev Capture both pools, every known holder, fees and transient state for atomicity checks.
    function _state() internal view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                address(manager).balance,
                address(hook).balance,
                address(escrow).balance,
                hook.totalDeferred(),
                escrow.totalSkimmedEth(),
                escrow.totalPendingEth(),
                escrow.totalWithdrawnEth()
            )
        );
        for (uint256 i; i < 2; ++i) {
            (uint160 price, int24 tick,,) = StateLibrary.getSlot0(manager, keys[i].toId());
            digest = keccak256(
                abi.encode(
                    digest,
                    price,
                    tick,
                    tokens[i].balanceOf(address(manager)),
                    tokens[i].balanceOf(address(router)),
                    escrow.pending(address(0), creators[i])
                )
            );
            for (uint256 j; j < actors.length; ++j) {
                digest = keccak256(
                    abi.encode(
                        digest,
                        actors[j].balance,
                        tokens[i].balanceOf(actors[j]),
                        tokens[i].allowance(actors[j], address(router)),
                        escrow.pending(address(0), actors[j]),
                        hook.deferredFees(address(escrow), creators[i], actors[j]),
                        hook.deferredKingShares(address(escrow), creators[i], actors[j])
                    )
                );
            }
        }
    }
}
