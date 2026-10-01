// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KingOfThePad} from "./KingOfThePad.sol";

/// @notice Native ETH fee credits for registered launch creators and king beneficiaries.
/// @dev Only the immutable factory can authorize its curves and the shared hook. Recording never
/// calls a payee; failed withdrawals leave the caller's credit available for a different recipient.
contract FeeEscrow is ReentrancyGuard {
    error NotAuthorized();
    error InvalidAddress();
    error UnsupportedCurrency();
    error FeeMismatch();
    error NoBeneficiary();

    KingOfThePad public immutable kingOfThePad;
    address public immutable factory;

    /// @dev Currency is address(0) for the native-ETH-only v1 launchpad.
    mapping(address currency => mapping(address account => uint256 amount)) public pending;
    mapping(address recorder => bool allowed) public authorizedRecorders;
    uint256 public unassignedEth;
    uint256 public totalSkimmedEth;
    uint256 public totalPendingEth;
    uint256 public totalWithdrawnEth;

    event RecorderAuthorized(address indexed recorder, bool allowed);
    event FeeCredited(address indexed account, address indexed currency, uint256 amount, bool isKingShare);
    event FeeWithdrawn(address indexed account, address indexed currency, uint256 amount);

    constructor(KingOfThePad _king, address _factory) {
        if (address(_king).code.length == 0 || _factory == address(0)) revert InvalidAddress();
        kingOfThePad = _king;
        factory = _factory;
    }

    modifier onlyRecorder() {
        if (!authorizedRecorders[msg.sender]) revert NotAuthorized();
        _;
    }

    function authorizeRecorder(address recorder, bool allowed) external {
        if (msg.sender != factory) revert NotAuthorized();
        if (recorder == address(0)) revert InvalidAddress();
        authorizedRecorders[recorder] = allowed;
        emit RecorderAuthorized(recorder, allowed);
    }

    function recordTradeFee(address creator, address currency, uint256 feeAmount) external payable onlyRecorder {
        if (currency != address(0)) revert UnsupportedCurrency();
        if (msg.value != feeAmount) revert FeeMismatch();
        _record(creator, kingOfThePad.beneficiary(), feeAmount / 2);
    }

    function recordTradeFeeNative(address creator, uint256 feeAmount) external payable onlyRecorder {
        if (msg.value != feeAmount) revert FeeMismatch();
        _record(creator, kingOfThePad.beneficiary(), feeAmount / 2);
    }

    /// @notice Deliver a captured fee, retaining the king who owned its share at trade time.
    /// @dev Trusted recorders snapshot the beneficiary before capture, including on a deferred
    /// delivery retry. A zero snapshot means the fee predates the first king claim.
    function recordTradeFeeNativeFor(address creator, address kingBeneficiary, uint256 feeAmount)
        external
        payable
        onlyRecorder
    {
        if (msg.value != feeAmount) revert FeeMismatch();
        _record(creator, kingBeneficiary, feeAmount / 2);
    }

    /// @notice Deliver aggregated deferred fees without rounding their shares a second time.
    /// @dev Authorized recorders sum each captured trade's fee / 2 for kingShare. Its maximum
    /// is half the total; the creator retains every individual trade's odd wei.
    function recordTradeFeeNativeShares(address creator, address kingBeneficiary, uint256 kingShare)
        external
        payable
        onlyRecorder
    {
        if (kingShare > msg.value / 2) revert FeeMismatch();
        _record(creator, kingBeneficiary, kingShare);
    }

    function _record(address creator, address kingBeneficiary, uint256 kingShare) private {
        if (creator == address(0)) revert InvalidAddress();
        uint256 feeAmount = msg.value;
        if (feeAmount == 0) return;
        totalSkimmedEth += feeAmount;
        if (kingBeneficiary == address(0)) kingBeneficiary = kingOfThePad.firstBeneficiary();
        if (kingBeneficiary == address(0)) {
            unassignedEth += kingShare;
        } else {
            _credit(kingBeneficiary, kingShare, true);
        }
        _credit(creator, feeAmount - kingShare, false);
    }

    function withdraw(address currency, address to) external nonReentrant returns (uint256 amount) {
        if (currency != address(0)) revert UnsupportedCurrency();
        if (to == address(0)) revert InvalidAddress();
        amount = pending[currency][msg.sender];
        if (amount == 0) return 0;
        pending[currency][msg.sender] = 0;
        totalPendingEth -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) {
            // A recorder may credit this account during the callback; preserve that new credit too.
            pending[currency][msg.sender] += amount;
            totalPendingEth += amount;
            return 0;
        }
        totalWithdrawnEth += amount;
        emit FeeWithdrawn(msg.sender, currency, amount);
    }

    /// @notice Assign all fees captured before the first crown to that first beneficiary forever.
    function assignUnassigned() external {
        address first = kingOfThePad.firstBeneficiary();
        if (first == address(0)) revert NoBeneficiary();
        uint256 amount = unassignedEth;
        unassignedEth = 0;
        _credit(first, amount, true);
    }

    function _credit(address account, uint256 amount, bool isKingShare) private {
        if (amount == 0) return;
        pending[address(0)][account] += amount;
        totalPendingEth += amount;
        emit FeeCredited(account, address(0), amount, isKingShare);
    }
}
