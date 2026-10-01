// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";
import {FeeEscrow} from "./FeeEscrow.sol";
import {KingOfThePad} from "./KingOfThePad.sol";

interface IPvPadFactoryCurve {
    function feeEscrow() external view returns (FeeEscrow);
    function graduationThreshold() external view returns (uint256);
}

/// @notice Constant-product curve, with explicit reserves that exclude donations and deferred fees.
/// @dev x = VIRTUAL_TOKEN + tokenReserve, y = VIRTUAL_ETH + ethReserve. Rounding favors reserves.
contract BondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Graduated();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientOutput();
    error InsufficientLiquidity();
    error NotFactory();
    error NotReady();
    error DeadlineExpired();
    error NativeTransferFailed();

    event Bought(address indexed buyer, uint256 ethIn, uint256 fee, uint256 tokensOut);
    event Sold(address indexed seller, uint256 tokensIn, uint256 fee, uint256 ethOut);
    event FeeDeferred(address indexed beneficiary, uint256 amount);
    event DeferredFeeFlushed(address indexed beneficiary, uint256 amount);

    IERC20 public immutable token;
    IPvPadFactoryCurve public immutable factory;
    FeeEscrow public immutable feeEscrow;
    KingOfThePad public immutable kingOfThePad;
    uint256 public immutable launchId;
    address public immutable creator;
    bool public graduated;
    uint256 public ethReserve;
    uint256 public tokenReserve;
    mapping(address => uint256) public deferredFees;
    mapping(address => uint256) public deferredKingShares;
    uint256 public totalDeferredFees;

    constructor(
        IERC20 _token,
        IPvPadFactoryCurve _factory,
        uint256 _launchId,
        address _creator,
        FeeEscrow _escrow,
        KingOfThePad _king
    ) {
        if (
            address(_token) == address(0) || address(_factory) == address(0) || _creator == address(0)
                || address(_escrow) == address(0) || address(_king) == address(0)
        ) revert ZeroAddress();
        token = _token;
        factory = _factory;
        feeEscrow = _escrow;
        kingOfThePad = _king;
        launchId = _launchId;
        creator = _creator;
        tokenReserve = PvPadConstants.TOKEN_SUPPLY;
    }

    function readyToGraduate() public view returns (bool) {
        return !graduated && ethReserve == PvPadConstants.GRADUATION_THRESHOLD;
    }

    function getReserves() external view returns (uint256 ethR, uint256 tokenR) {
        return (ethReserve, tokenReserve);
    }

    /// @notice Smallest gross input that fills the remaining curve, accounting for the rounded 1% fee.
    function maxBuyInput() public view returns (uint256) {
        if (graduated || ethReserve == PvPadConstants.GRADUATION_THRESHOLD) return 0;
        uint256 remaining = PvPadConstants.GRADUATION_THRESHOLD - ethReserve;
        return remaining + (remaining - 1) / 99;
    }

    /// @notice Quotes the executable part of ethIn; excess is refunded to the buyer.
    function quoteBuy(uint256 ethIn) public view returns (uint256 tokensOut, uint256 fee) {
        uint256 cap = maxBuyInput();
        if (ethIn > cap) ethIn = cap;
        if (ethIn == 0) return (0, 0);
        fee = _fee(ethIn);
        tokensOut = _tokensOutForEth(ethIn - fee);
    }

    function quoteSell(uint256 tokensIn) public view returns (uint256 ethOut, uint256 fee) {
        if (graduated || readyToGraduate() || tokensIn == 0) return (0, 0);
        uint256 grossEth = _ethOutForTokens(tokensIn);
        if (grossEth > ethReserve || tokensIn > PvPadConstants.TOKEN_SUPPLY - tokenReserve) return (0, 0);
        fee = _fee(grossEth);
        ethOut = grossEth - fee;
    }

    /// @dev Convenience overload with no price or expiry protection. UIs should use the protected overload.
    function buy(address recipient) external payable nonReentrant returns (uint256) {
        return _buy(recipient, 0, type(uint256).max);
    }

    function buy(address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256)
    {
        return _buy(recipient, minTokensOut, deadline);
    }

    function _buy(address recipient, uint256 minTokensOut, uint256 deadline) internal returns (uint256 tokensOut) {
        _checkTrade(recipient, deadline);
        if (msg.value == 0) revert ZeroAmount();
        uint256 grossInput = maxBuyInput();
        if (grossInput == 0) revert NotReady();
        if (grossInput > msg.value) grossInput = msg.value;
        uint256 fee = _fee(grossInput);
        uint256 netInput = grossInput - fee;
        tokensOut = _tokensOutForEth(netInput);
        if (tokensOut == 0 || tokensOut < minTokensOut) revert InsufficientOutput();
        if (tokensOut > tokenReserve) revert InsufficientLiquidity();
        ethReserve += netInput;
        tokenReserve -= tokensOut;
        _deliverFee(fee);
        token.safeTransfer(recipient, tokensOut);
        if (msg.value > grossInput) _sendNative(msg.sender, msg.value - grossInput);
        emit Bought(recipient, grossInput, fee, tokensOut);
    }

    /// @dev Convenience overload with no price or expiry protection. UIs should use the protected overload.
    function sell(uint256 amount, address recipient) external nonReentrant returns (uint256) {
        return _sell(amount, recipient, 0, type(uint256).max);
    }

    function sell(uint256 amount, address recipient, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256)
    {
        return _sell(amount, recipient, minEthOut, deadline);
    }

    function _sell(uint256 amount, address recipient, uint256 minEthOut, uint256 deadline)
        internal
        returns (uint256 ethOut)
    {
        _checkTrade(recipient, deadline);
        if (readyToGraduate()) revert NotReady();
        if (amount == 0) revert ZeroAmount();
        if (amount > PvPadConstants.TOKEN_SUPPLY - tokenReserve) revert InsufficientLiquidity();
        uint256 grossEth = _ethOutForTokens(amount);
        if (grossEth > ethReserve) revert InsufficientLiquidity();
        uint256 fee = _fee(grossEth);
        ethOut = grossEth - fee;
        if (ethOut == 0 || ethOut < minEthOut) revert InsufficientOutput();
        ethReserve -= grossEth;
        tokenReserve += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        _deliverFee(fee);
        _sendNative(recipient, ethOut);
        emit Sold(msg.sender, amount, fee, ethOut);
    }

    /// @notice Permissionless retry; keeps the beneficiary captured when the trade occurred.
    function flushDeferredFees(address beneficiary) external nonReentrant returns (bool success) {
        uint256 amount = deferredFees[beneficiary];
        if (amount == 0) return true;
        uint256 kingShare = deferredKingShares[beneficiary];
        deferredFees[beneficiary] = 0;
        deferredKingShares[beneficiary] = 0;
        totalDeferredFees -= amount;
        try feeEscrow.recordTradeFeeNativeShares{value: amount, gas: 150_000}(creator, beneficiary, kingShare) {
            emit DeferredFeeFlushed(beneficiary, amount);
            return true;
        } catch {
            deferredFees[beneficiary] = amount;
            deferredKingShares[beneficiary] = kingShare;
            totalDeferredFees += amount;
            return false;
        }
    }

    function sweepForGraduation() external nonReentrant returns (uint256 ethAmount, uint256 tokenAmount) {
        if (msg.sender != address(factory)) revert NotFactory();
        if (graduated) revert Graduated();
        if (!readyToGraduate()) revert NotReady();
        graduated = true;
        ethAmount = ethReserve;
        tokenAmount = tokenReserve;
        ethReserve = 0;
        tokenReserve = 0;
        token.safeTransfer(address(factory), tokenAmount);
        _sendNative(address(factory), ethAmount);
    }

    function _checkTrade(address recipient, uint256 deadline) private view {
        if (graduated) revert Graduated();
        if (recipient == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _deliverFee(uint256 fee) private {
        if (fee == 0) return;
        address beneficiary = kingOfThePad.beneficiary();
        try feeEscrow.recordTradeFeeNativeFor{value: fee, gas: 150_000}(creator, beneficiary, fee) {}
        catch {
            deferredFees[beneficiary] += fee;
            deferredKingShares[beneficiary] += fee / 2;
            totalDeferredFees += fee;
            emit FeeDeferred(beneficiary, fee);
        }
    }

    function _fee(uint256 amount) private pure returns (uint256) {
        return amount / 100;
    }

    function _tokensOutForEth(uint256 ethIn) private view returns (uint256) {
        uint256 x = PvPadConstants.VIRTUAL_TOKEN + tokenReserve;
        uint256 y = PvPadConstants.VIRTUAL_ETH + ethReserve;
        return FullMath.mulDiv(x, ethIn, y + ethIn);
    }

    function _ethOutForTokens(uint256 tokensIn) private view returns (uint256) {
        uint256 x = PvPadConstants.VIRTUAL_TOKEN + tokenReserve;
        uint256 y = PvPadConstants.VIRTUAL_ETH + ethReserve;
        return FullMath.mulDiv(y, tokensIn, x + tokensIn);
    }

    function _sendNative(address recipient, uint256 amount) private {
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    // No receive(): ETH enters only through buy(). A plain transfer would be locked here forever.
}
