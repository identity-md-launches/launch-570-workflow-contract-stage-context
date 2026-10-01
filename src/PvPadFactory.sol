// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PvPadToken} from "./PvPadToken.sol";
import {BondingCurve, IPvPadFactoryCurve} from "./BondingCurve.sol";
import {FeeEscrow} from "./FeeEscrow.sol";
import {KingOfThePad} from "./KingOfThePad.sol";
import {WorkerSubsidy} from "./WorkerSubsidy.sol";
import {PvPadHook} from "./hooks/PvPadHook.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";

/// @notice Permissionless pad: creates curves and permanently holds their graduated liquidity positions.
/// @dev The factory owns v4 positions. There is no call path that decreases liquidity or collects it.
contract PvPadFactory is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    error LaunchFeeRequired();
    error UnknownLaunch();
    error NotReady();
    error AlreadyGraduated();
    error ZeroAddress();
    error InvalidConfiguration();
    error InvalidMetadata();
    error UnexpectedPoolPrice();
    error InvalidCallback();
    error ZeroLiquidity();
    error LiquidityRangeUnavailable();
    error NotBondingCurve();

    event LaunchCreated(
        uint256 indexed launchId, address indexed creator, address token, address curve, string name, string symbol
    );
    event Graduated(uint256 indexed launchId, PoolId poolId, uint160 sqrtPriceX96);
    event LaunchMetadata(uint256 indexed launchId, string metadataURI);
    event LiquidityLocked(uint256 indexed launchId, uint128 liquidity, uint256 ethDust, uint256 tokenDust);
    event LiquidityRangeLocked(uint256 indexed launchId, int24 tickLower, int24 tickUpper);
    /// @notice Emitted when a predicted pool was preinitialized at a foreign price and a later salt was used.
    event LaunchSaltRetried(uint256 indexed launchId, uint256 attempt, address token);
    /// @notice Emitted when every bounded candidate was poisoned and the empty pool was moved back to
    /// the canonical price through the hook instead.
    event LaunchPoolRealigned(uint256 indexed launchId, uint160 foreignSqrtPriceX96);

    /// @notice Bound on automatic salt retries when predicted pools are poisoned at a foreign price.
    uint256 public constant MAX_SALT_ATTEMPTS = 16;

    struct Launch {
        address creator;
        address token;
        address curve;
        bool graduated;
        PoolId poolId;
    }

    IPoolManager public immutable poolManager;
    WorkerSubsidy public immutable workerSubsidy;
    KingOfThePad public immutable kingOfThePad;
    FeeEscrow public immutable feeEscrow;
    PvPadHook public immutable hook;
    uint160 public immutable canonicalSqrtPriceX96;
    uint256 public constant launchFee = PvPadConstants.DEFAULT_LAUNCH_FEE;
    uint256 public constant graduationThreshold = PvPadConstants.GRADUATION_THRESHOLD;
    uint256 public launchCount;

    mapping(uint256 => Launch) public launches;
    mapping(uint256 => string) public launchMetadataURI;
    mapping(PoolId => bool) public registeredPool;
    mapping(PoolId => address) public poolCreator;
    mapping(address => bool) public isBondingCurve;
    mapping(uint256 => uint128) public lockedLiquidity;
    mapping(uint256 => int24) public lockedTickLower;
    mapping(uint256 => int24) public lockedTickUpper;
    bytes32 private expectedCallback;

    constructor(
        IPoolManager _poolManager,
        WorkerSubsidy _workerSubsidy,
        KingOfThePad _king,
        PvPadHook _hook,
        address genesisCreator
    ) {
        if (
            address(_poolManager) == address(0) || address(_workerSubsidy) == address(0) || address(_king) == address(0)
                || address(_hook) == address(0) || genesisCreator == address(0)
        ) revert ZeroAddress();
        if (
            address(_hook.poolManager()) != address(_poolManager)
                || address(_king.workerSubsidy()) != address(_workerSubsidy)
        ) revert InvalidConfiguration();
        poolManager = _poolManager;
        workerSubsidy = _workerSubsidy;
        kingOfThePad = _king;
        hook = _hook;
        feeEscrow = new FeeEscrow(_king, address(this));
        feeEscrow.authorizeRecorder(address(_hook), true);
        // FullMath avoids truncating amount1 << 192 before division.
        canonicalSqrtPriceX96 = uint160(
            Math.sqrt(FullMath.mulDiv(PvPadConstants.TOKEN_SUPPLY / 4, uint256(1) << 192, graduationThreshold))
        );
        _createLaunch(genesisCreator, "Pepe Values Pepe", "PVP", bytes32(0));
        emit LaunchMetadata(0, "");
    }

    /// @notice True only once this factory has funded and locked the pool.
    function isRegisteredPool(PoolId poolId) external view returns (bool) {
        return registeredPool[poolId];
    }

    function launchCreator(PoolId poolId) external view returns (address) {
        return poolCreator[poolId];
    }

    function createLaunch(string calldata name, string calldata symbol)
        external
        payable
        nonReentrant
        returns (uint256 launchId)
    {
        return _paidLaunch(name, symbol, bytes32(0), "");
    }

    /// @notice Salt permits choosing a fresh token/pool address if someone preinitialized a predicted address.
    function createLaunch(string calldata name, string calldata symbol, bytes32 salt)
        external
        payable
        nonReentrant
        returns (uint256 launchId)
    {
        return _paidLaunch(name, symbol, salt, "");
    }

    /// @notice Optional immutable URI for an off-chain image, description and social links document.
    function createLaunch(string calldata name, string calldata symbol, bytes32 salt, string calldata metadataURI)
        external
        payable
        nonReentrant
        returns (uint256 launchId)
    {
        return _paidLaunch(name, symbol, salt, metadataURI);
    }

    function _paidLaunch(string memory name, string memory symbol, bytes32 salt, string memory metadataURI)
        private
        returns (uint256 launchId)
    {
        if (msg.value != launchFee) revert LaunchFeeRequired();
        if (bytes(metadataURI).length > 2048) revert InvalidMetadata();
        launchId = _createLaunch(msg.sender, name, symbol, salt);
        launchMetadataURI[launchId] = metadataURI;
        emit LaunchMetadata(launchId, metadataURI);
        workerSubsidy.fundWorkers{value: msg.value}();
    }

    function _createLaunch(address creator, string memory name, string memory symbol, bytes32 userSalt)
        internal
        returns (uint256 launchId)
    {
        if (
            bytes(name).length == 0 || bytes(name).length > 64 || bytes(symbol).length == 0 || bytes(symbol).length > 16
        ) {
            revert InvalidMetadata();
        }
        launchId = launchCount++;
        address token = _deployToken(launchId, creator, name, symbol, userSalt);
        address curve = address(
            new BondingCurve(
                IERC20(token), IPvPadFactoryCurve(address(this)), launchId, creator, feeEscrow, kingOfThePad
            )
        );
        PoolKey memory key = _poolKey(token);
        PoolId poolId = key.toId();
        launches[launchId] = Launch(creator, token, curve, false, poolId);
        isBondingCurve[curve] = true;
        poolCreator[poolId] = creator;
        feeEscrow.authorizeRecorder(curve, true);
        hook.bindPool(key, creator, feeEscrow);
        _initializeCanonicalPool(key, poolId, launchId);
        IERC20(token).safeTransfer(curve, PvPadConstants.TOKEN_SUPPLY);
        emit LaunchCreated(launchId, creator, token, curve, name, symbol);
    }

    function _deployToken(uint256 launchId, address creator, string memory name, string memory symbol, bytes32 userSalt)
        private
        returns (address token)
    {
        (bytes32 salt, address predicted, uint256 attempt) = _selectSalt(launchId, creator, name, symbol, userSalt);
        token = address(new PvPadToken{salt: salt}(name, symbol));
        if (token != predicted) revert InvalidConfiguration();
        if (attempt != 0) emit LaunchSaltRetried(launchId, attempt, token);
    }

    /// @dev Never seed at a foreign price. The salt scan prefers an unpoisoned candidate; when every
    /// candidate is poisoned the pool (bound to this factory, empty by the hook's liquidity gate) is
    /// moved back to the canonical price through the hook. The re-read is the hard stop.
    function _initializeCanonicalPool(PoolKey memory key, PoolId poolId, uint256 launchId) private {
        (uint160 existingPrice,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (existingPrice == 0) {
            poolManager.initialize(key, canonicalSqrtPriceX96);
            return;
        }
        if (existingPrice == canonicalSqrtPriceX96) return;
        hook.realignPool(key, canonicalSqrtPriceX96);
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (price != canonicalSqrtPriceX96) revert UnexpectedPoolPrice();
        emit LaunchPoolRealigned(launchId, existingPrice);
    }

    /// @notice Token address and salt attempt the next `createLaunch` with these inputs would use.
    /// @dev When every bounded candidate pool is poisoned at a foreign price the first candidate is
    /// returned and the create realigns its pool instead of reverting.
    function predictLaunchToken(address creator, string calldata name, string calldata symbol, bytes32 userSalt)
        external
        view
        returns (address token, uint256 attempt)
    {
        (, token, attempt) = _selectSalt(launchCount, creator, name, symbol, userSalt);
    }

    /// @dev Attempt 0 keeps the original salt derivation. Someone who predicts a token address can
    /// preinitialize its pool (the shared hook has no beforeInitialize) at a foreign price; rather than
    /// failing the whole create, skip to the next salt. A canonical-price preinitialization is accepted.
    /// When all candidates are poisoned, the first one is used and `_initializeCanonicalPool` realigns
    /// it; the genesis candidates are a pure function of the factory address, so this path must never
    /// revert inside the constructor.
    function _selectSalt(uint256 launchId, address creator, string memory name, string memory symbol, bytes32 userSalt)
        private
        view
        returns (bytes32 salt, address token, uint256 attempt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(PvPadToken).creationCode, abi.encode(name, symbol)));
        bytes32 fallbackSalt;
        address fallbackToken;
        uint256 fallbackAttempt;
        for (attempt = 0; attempt < MAX_SALT_ATTEMPTS; ++attempt) {
            salt = attempt == 0
                ? keccak256(abi.encode(launchId, creator, name, symbol, userSalt))
                : keccak256(abi.encode(launchId, creator, name, symbol, userSalt, attempt));
            token =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
            if (token.code.length != 0) continue;
            (uint160 existingPrice,,,) = StateLibrary.getSlot0(poolManager, _poolKey(token).toId());
            if (existingPrice == 0 || existingPrice == canonicalSqrtPriceX96) return (salt, token, attempt);
            if (fallbackToken == address(0)) (fallbackSalt, fallbackToken, fallbackAttempt) = (salt, token, attempt);
        }
        if (fallbackToken == address(0)) revert InvalidConfiguration();
        return (fallbackSalt, fallbackToken, fallbackAttempt);
    }

    function getPoolKey(uint256 launchId) external view returns (PoolKey memory) {
        if (launches[launchId].token == address(0)) revert UnknownLaunch();
        return _poolKey(launches[launchId].token);
    }

    function _poolKey(address token) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: PvPadConstants.POOL_FEE,
            tickSpacing: PvPadConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function graduate(uint256 launchId) external nonReentrant returns (PoolId poolId) {
        Launch storage launch = launches[launchId];
        if (launch.curve == address(0)) revert UnknownLaunch();
        if (launch.graduated) revert AlreadyGraduated();
        BondingCurve curve = BondingCurve(payable(launch.curve));
        if (!curve.readyToGraduate()) revert NotReady();
        poolId = launch.poolId;
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (price != canonicalSqrtPriceX96) revert UnexpectedPoolPrice();
        (uint256 ethAmount, uint256 tokenAmount) = curve.sweepForGraduation();
        launch.graduated = true;
        bytes memory data = abi.encode(_poolKey(launch.token), ethAmount, tokenAmount, launchId);
        expectedCallback = keccak256(data);
        poolManager.unlock(data);
        if (expectedCallback != bytes32(0)) revert InvalidCallback();
        registeredPool[poolId] = true;
        emit Graduated(launchId, poolId, price);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (
            msg.sender != address(poolManager) || expectedCallback == bytes32(0)
                || keccak256(rawData) != expectedCallback
        ) revert InvalidCallback();
        expectedCallback = bytes32(0);
        (PoolKey memory key, uint256 ethAmount, uint256 tokenAmount, uint256 launchId) =
            abi.decode(rawData, (PoolKey, uint256, uint256, uint256));
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _availableRange(key.toId(), ethAmount, tokenAmount);
        if (liquidity == 0) revert ZeroLiquidity();
        lockedLiquidity[launchId] = liquidity;
        lockedTickLower[launchId] = tickLower;
        lockedTickUpper[launchId] = tickUpper;
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(launchId)
        });
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        uint256 usedEth = uint256(uint128(-delta.amount0()));
        uint256 usedToken = uint256(uint128(-delta.amount1()));
        key.currency0.settle(poolManager, address(this), usedEth, false);
        key.currency1.settle(poolManager, address(this), usedToken, false);
        // Integer rounding dust remains locked at this contract, with no recovery or withdrawal path.
        emit LiquidityRangeLocked(launchId, tickLower, tickUpper);
        emit LiquidityLocked(launchId, liquidity, ethAmount - usedEth, tokenAmount - usedToken);
        return "";
    }

    /// @dev Permissionless v4 deposits can exhaust either extreme tick's liquidity cap for dust.
    /// Move only occupied boundaries inward, retaining the canonical price inside the range.
    /// Recompute liquidity after each move: a narrower range can require more tick capacity.
    function _availableRange(PoolId poolId, uint256 ethAmount, uint256 tokenAmount)
        private
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        int24 spacing = PvPadConstants.POOL_TICK_SPACING;
        tickLower = TickMath.minUsableTick(spacing);
        tickUpper = TickMath.maxUsableTick(spacing);
        uint128 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(spacing);
        while (true) {
            uint160 lowerPrice = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 upperPrice = TickMath.getSqrtPriceAtTick(tickUpper);
            if (lowerPrice >= canonicalSqrtPriceX96 || upperPrice <= canonicalSqrtPriceX96) {
                revert LiquidityRangeUnavailable();
            }
            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                canonicalSqrtPriceX96, lowerPrice, upperPrice, ethAmount, tokenAmount
            );
            if (liquidity > maxPerTick) revert LiquidityRangeUnavailable();
            (uint128 lowerGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, tickLower);
            (uint128 upperGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, tickUpper);
            bool lowerFull = lowerGross > maxPerTick - liquidity;
            bool upperFull = upperGross > maxPerTick - liquidity;
            if (!lowerFull && !upperFull) return (tickLower, tickUpper, liquidity);
            if (lowerFull) tickLower += spacing;
            if (upperFull) tickUpper -= spacing;
        }
    }

    /// @dev Plain ETH arrives only from a registered curve's graduation sweep; anything else would be
    /// locked here forever, so it is refused.
    receive() external payable {
        if (!isBondingCurve[msg.sender]) revert NotBondingCurve();
    }
}
