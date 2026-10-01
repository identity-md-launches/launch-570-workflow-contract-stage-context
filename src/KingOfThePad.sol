// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WorkerSubsidy} from "./WorkerSubsidy.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";

/// @notice Each crown directs future platform fees; all bids fund the workers without refunds.
contract KingOfThePad is ReentrancyGuard {
    error BidTooLow();
    error InvalidAddress();

    event KingClaimed(address indexed king, address indexed beneficiary, uint256 paid, uint256 newClaimPrice);

    WorkerSubsidy public immutable workerSubsidy;
    address public king;
    address public beneficiary;
    /// @notice Permanent recipient of platform fees captured before any king existed.
    address public firstBeneficiary;
    uint256 public claimPrice;
    uint256 public claimCount;

    constructor(WorkerSubsidy _workerSubsidy) {
        if (address(_workerSubsidy).code.length == 0) revert InvalidAddress();
        workerSubsidy = _workerSubsidy;
        claimPrice = PvPadConstants.INITIAL_CLAIM_PRICE;
    }

    function claimKing(address _beneficiary) external payable nonReentrant {
        if (_beneficiary == address(0)) revert InvalidAddress();
        if (msg.value <= claimPrice) revert BidTooLow();
        king = msg.sender;
        beneficiary = _beneficiary;
        if (claimCount == 0) firstBeneficiary = _beneficiary;
        claimCount++;
        claimPrice = (claimPrice * (PvPadConstants.BPS_DENOMINATOR + PvPadConstants.KING_BUMP_BPS))
            / PvPadConstants.BPS_DENOMINATOR;
        workerSubsidy.fundWorkers{value: msg.value}();
        emit KingClaimed(msg.sender, _beneficiary, msg.value, claimPrice);
    }
}
