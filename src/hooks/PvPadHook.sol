// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PvPadConstants} from "../libraries/PvPadConstants.sol";
import {FeeEscrow} from "../FeeEscrow.sol";

interface IPvPadLaunchRegistry {
    /// @notice True only after the canonical launch pool has graduated.
    function isRegisteredPool(PoolId poolId) external view returns (bool);
}

interface IPvPadTokenFactory {
    function factory() external view returns (address);
}

/// @notice Shared native-ETH fee hook. Each token's deploying factory binds its canonical pool.
/// @dev Deployment must use a CREATE2 salt yielding the permission bits in REQUIRED_FLAGS (0x08cc):
/// beforeAddLiquidity, beforeSwap, afterSwap and both swap return-delta flags. No beforeInitialize.
/// Before graduation only the bound factory may add liquidity, so nobody can saturate a tick's
/// liquidity cap or otherwise shape the pool ahead of the locked graduation deposit.
contract PvPadHook is IHooks, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    error NotPoolManager();
    error ZeroAddress();
    error InvalidPool();
    error NotLaunchFactory();
    error PoolAlreadyBound();
    error PoolNotGraduated();
    error LiquidityClosed();
    error PartialFill();
    error AmountTooLarge();
    error UnsupportedCallback();
    error NothingToRealign();
    error PoolHasLiquidity();
    error InvalidCallback();
    error RealignFailed();

    /// @notice Address bits (masked by Hooks.ALL_HOOK_MASK) a deployed instance must carry.
    uint160 public constant REQUIRED_FLAGS = PvPadConstants.HOOK_FLAGS;

    struct PoolBinding {
        IPvPadLaunchRegistry registry;
        FeeEscrow escrow;
        address creator;
    }

    IPoolManager public immutable poolManager;
    mapping(PoolId => PoolBinding) public bindings;

    /// @dev A failed delivery keeps its original beneficiary, even if the king changes before retry.
    mapping(address escrow => mapping(address creator => mapping(address beneficiary => uint256 amount))) public
        deferredFees;
    mapping(address escrow => mapping(address creator => mapping(address beneficiary => uint256 amount))) public
        deferredKingShares;
    uint256 public totalDeferred;
    /// @dev Hash of the realignment in flight; nonzero only between `unlock` and its callback.
    bytes32 private pendingRealign;

    event PoolBound(PoolId indexed poolId, address indexed factory, address creator, address escrow);
    event PoolRealigned(PoolId indexed poolId, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96);
    event FeeDeferred(address indexed escrow, address indexed creator, address indexed beneficiary, uint256 amount);
    event DeferredDelivered(
        address indexed escrow, address indexed creator, address indexed beneficiary, uint256 amount
    );

    constructor(IPoolManager _poolManager) {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != REQUIRED_FLAGS) {
            revert Hooks.HookAddressNotValid(address(this));
        }
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Called atomically during launch creation, before the factory initializes the pool.
    /// @dev Token provenance prevents a foreign registry from capturing an existing launch's fees.
    /// No callback into the factory is needed, so this also works for constructor-created genesis.
    function bindPool(PoolKey calldata key, address creator, FeeEscrow escrow) external {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) == address(0)
                || address(key.hooks) != address(this) || key.fee != PvPadConstants.POOL_FEE
                || key.tickSpacing != PvPadConstants.POOL_TICK_SPACING
        ) revert InvalidPool();
        if (creator == address(0) || address(escrow) == address(0)) revert ZeroAddress();
        if (
            IPvPadTokenFactory(Currency.unwrap(key.currency1)).factory() != msg.sender || escrow.factory() != msg.sender
        ) revert NotLaunchFactory();
        PoolId id = key.toId();
        if (address(bindings[id].registry) != address(0)) revert PoolAlreadyBound();
        bindings[id] = PoolBinding(IPvPadLaunchRegistry(msg.sender), escrow, creator);
        emit PoolBound(id, msg.sender, creator, address(escrow));
    }

    /// @notice Moves a bound pool that someone preinitialized at a foreign price back to `targetSqrtPriceX96`.
    /// @dev Only the bound factory may call it, and only with zero active liquidity. For canonical
    /// launches, the factory calls this only during creation, when the `beforeAddLiquidity` gate
    /// guarantees no positions exist. The factory has no post-graduation realignment path; active
    /// liquidity alone cannot rule out positions outside the current price. With no positions a swap moves the price to
    /// its limit without transferring value; the callback verifies the delta is exactly zero. Nothing
    /// here calls back into the factory, so constructor-created genesis can use it. The PoolManager
    /// skips this hook's own callbacks because the hook is the swapping caller.
    function realignPool(PoolKey calldata key, uint160 targetSqrtPriceX96) external nonReentrant {
        PoolId id = key.toId();
        if (address(bindings[id].registry) != msg.sender) revert NotLaunchFactory();
        (uint160 current,,,) = StateLibrary.getSlot0(poolManager, id);
        if (current == 0 || current == targetSqrtPriceX96) revert NothingToRealign();
        if (StateLibrary.getLiquidity(poolManager, id) != 0) revert PoolHasLiquidity();
        bytes memory data = abi.encode(key, current > targetSqrtPriceX96, targetSqrtPriceX96);
        pendingRealign = keccak256(data);
        poolManager.unlock(data);
        if (pendingRealign != bytes32(0)) revert InvalidCallback();
        (uint160 realigned,,,) = StateLibrary.getSlot0(poolManager, id);
        if (realigned != targetSqrtPriceX96) revert RealignFailed();
        emit PoolRealigned(id, current, targetSqrtPriceX96);
    }

    /// @dev Only the realignment swap. A one-wei exact input against zero liquidity consumes nothing
    /// and leaves the price exactly at the limit.
    function unlockCallback(bytes calldata rawData) external onlyPoolManager returns (bytes memory) {
        if (pendingRealign == bytes32(0) || keccak256(rawData) != pendingRealign) revert InvalidCallback();
        pendingRealign = bytes32(0);
        (PoolKey memory key, bool zeroForOne, uint160 target) = abi.decode(rawData, (PoolKey, bool, uint160));
        BalanceDelta delta = poolManager.swap(
            key, IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1, sqrtPriceLimitX96: target}), ""
        );
        if (BalanceDelta.unwrap(delta) != 0) revert RealignFailed();
        return "";
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Liquidity is closed until graduation: only the bound factory deposits (its locked
    /// graduation position), then anyone may add. Unbound pools that name this hook stay closed.
    /// @dev `sender` is the PoolManager's caller. The factory registers the pool only after its
    /// deposit settles, so the factory check is what admits the graduation deposit itself.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        PoolBinding storage binding = bindings[id];
        if (address(binding.registry) == address(0)) revert LiquidityClosed();
        if (sender != address(binding.registry) && !binding.registry.isRegisteredPool(id)) revert LiquidityClosed();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolBinding storage binding = _activeBinding(key);
        if (!_ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = _specifiedFee(params.amountSpecified);
        if (fee != 0) _collect(binding, fee);
        // Positive specified delta retains part of an exact input, or grosses up an exact output.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_asInt128(fee), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        PoolBinding storage binding = _activeBinding(key);
        if (_ethIsSpecified(params)) {
            // v4 afterSwap can only return an unspecified delta. A partial specified fill would
            // overcharge the precomputed fee, so atomically reject it, including the fee delivery.
            uint256 specifiedFee = _specifiedFee(params.amountSpecified);
            if (int256(delta.amount0()) != params.amountSpecified + int256(specifiedFee)) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 magnitude = _magnitude(int256(delta.amount0()));
        // Exact token output buys specify a net ETH payment to the pool. Gross it up so the
        // fee is also 1% of the trader's total ETH input, matching exact ETH input buys.
        uint256 fee = delta.amount0() < 0 && magnitude != 0 ? (magnitude - 1) / 99 : _fee(magnitude);
        if (fee != 0) _collect(binding, fee);
        return (IHooks.afterSwap.selector, _asInt128(fee));
    }

    /// @notice Anyone can retry escrow delivery; neither amount nor destination can be redirected.
    function retryDeferred(FeeEscrow escrow, address creator, address beneficiary)
        external
        nonReentrant
        returns (uint256 amount)
    {
        amount = deferredFees[address(escrow)][creator][beneficiary];
        if (amount == 0) return 0;
        uint256 kingShare = deferredKingShares[address(escrow)][creator][beneficiary];
        deferredFees[address(escrow)][creator][beneficiary] = 0;
        deferredKingShares[address(escrow)][creator][beneficiary] = 0;
        totalDeferred -= amount;
        try escrow.recordTradeFeeNativeShares{value: amount, gas: 200_000}(creator, beneficiary, kingShare) {
            emit DeferredDelivered(address(escrow), creator, beneficiary, amount);
        } catch {
            deferredFees[address(escrow)][creator][beneficiary] = amount;
            deferredKingShares[address(escrow)][creator][beneficiary] = kingShare;
            totalDeferred += amount;
            return 0;
        }
    }

    function _activeBinding(PoolKey calldata key) private view returns (PoolBinding storage binding) {
        PoolId id = key.toId();
        binding = bindings[id];
        if (address(binding.registry) == address(0) || !binding.registry.isRegisteredPool(id)) {
            revert PoolNotGraduated();
        }
    }

    function _collect(PoolBinding storage binding, uint256 amount) private {
        // Native ETH is always currency0 in the canonical key.
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
        address beneficiary = binding.escrow.kingOfThePad().beneficiary();
        try binding.escrow.recordTradeFeeNativeFor{value: amount, gas: 200_000}(binding.creator, beneficiary, amount) {}
        catch {
            deferredFees[address(binding.escrow)][binding.creator][beneficiary] += amount;
            deferredKingShares[address(binding.escrow)][binding.creator][beneficiary] += amount / 2;
            totalDeferred += amount;
            emit FeeDeferred(address(binding.escrow), binding.creator, beneficiary, amount);
        }
    }

    function _ethIsSpecified(IPoolManager.SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _magnitude(int256 amount) private pure returns (uint256) {
        // Reject quantities v4 cannot express as BalanceDelta; also avoids negating int256.min.
        if (amount < -int256(type(int128).max) || amount > int256(type(int128).max)) revert AmountTooLarge();
        return uint256(amount < 0 ? -amount : amount);
    }

    function _specifiedFee(int256 specified) private pure returns (uint256 fee) {
        uint256 magnitude = _magnitude(specified);
        if (specified <= 0) return _fee(magnitude);
        // Exact ETH output specifies the user's net receipt. Choose the smallest gross output
        // satisfying gross - floor(gross / 100) == net; charge 1% of that gross ETH leg.
        fee = (magnitude - 1) / 99;
        if (magnitude + fee > uint256(uint128(type(int128).max))) revert AmountTooLarge();
    }

    function _fee(uint256 magnitude) private pure returns (uint256) {
        return magnitude / (PvPadConstants.BPS_DENOMINATOR / PvPadConstants.FEE_BPS);
    }

    function _asInt128(uint256 value) private pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(uint128(value));
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert UnsupportedCallback();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert UnsupportedCallback();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert UnsupportedCallback();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert UnsupportedCallback();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert UnsupportedCallback();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert UnsupportedCallback();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert UnsupportedCallback();
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }
}
