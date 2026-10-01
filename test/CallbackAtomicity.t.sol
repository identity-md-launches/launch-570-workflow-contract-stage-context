// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {WorkerSubsidy} from "src/WorkerSubsidy.sol";
import {PvPadToken} from "src/PvPadToken.sol";
import {CurveFixture} from "./CurveFactory.t.sol";

contract RefundCallbackBuyer {
    BondingCurve private immutable curve;
    bool public rejectRefund = true;
    bytes4 public buyFailure;
    bytes4 public sellFailure;

    constructor(BondingCurve curve_) {
        curve = curve_;
    }

    function acceptRefund() external {
        rejectRefund = false;
    }

    function buy(address recipient) external payable returns (uint256) {
        return curve.buy{value: msg.value}(recipient);
    }

    receive() external payable {
        require(!rejectRefund, "refund rejected");
        try curve.buy{value: 1}(address(this)) {}
        catch (bytes memory reason) {
            buyFailure = bytes4(reason);
        }
        try curve.sell(1, address(this)) {}
        catch (bytes memory reason) {
            sellFailure = bytes4(reason);
        }
    }
}

contract DonatingWorkerPayee {
    WorkerSubsidy private workers;
    bytes32 private nextRoot;
    bytes4 public epochFailure;

    function configure(WorkerSubsidy workers_, bytes32 nextRoot_) external {
        workers = workers_;
        nextRoot = nextRoot_;
    }

    receive() external payable {
        workers.fundWorkers{value: 3}();
        try workers.setEpoch(nextRoot, block.timestamp, block.timestamp + 1 days) {}
        catch (bytes memory reason) {
            epochFailure = bytes4(reason);
        }
    }
}

/// @notice Late callback failures must revert every preceding transfer and accounting change.
contract CallbackAtomicityTest is Test {
    address private constant CREATOR = address(0xC0FFEE);
    address private constant KING = address(0xCAFE);
    address private constant RECIPIENT = address(0xBEEF);

    CurveFixture private fixture;
    BondingCurve private curve;
    PvPadToken private token;
    FeeEscrow private escrow;

    struct BeforeRefund {
        uint256 ethReserve;
        uint256 tokenReserve;
        uint256 curveBalance;
        uint256 escrowBalance;
        uint256 creatorCredit;
        uint256 kingCredit;
        uint256 skimmed;
        uint256 pending;
        uint256 deferred;
        uint256 deferredShare;
    }

    function setUp() public {
        vm.deal(address(this), 100 ether);
        fixture = new CurveFixture(CREATOR);
        curve = fixture.curve();
        token = fixture.token();
        escrow = fixture.feeEscrow();
        fixture.king().claimKing{value: 0.02 ether}(KING);
    }

    function test_rejectedRefundRollsBackTokenTransferAndDeliveredFee() public {
        _checkRejectedRefund(false);
    }

    function test_rejectedRefundRollsBackTokenTransferAndDeferredFee() public {
        _checkRejectedRefund(true);
    }

    function _checkRejectedRefund(bool deferFees) private {
        if (deferFees) {
            vm.mockCallRevert(
                address(escrow),
                abi.encodeWithSelector(FeeEscrow.recordTradeFeeNativeFor.selector),
                "escrow unavailable"
            );
        }
        // Start with existing credits/reserves so the failed trade must preserve them too.
        curve.buy{value: 300}(CREATOR);
        BeforeRefund memory before_ = BeforeRefund({
            ethReserve: curve.ethReserve(),
            tokenReserve: curve.tokenReserve(),
            curveBalance: address(curve).balance,
            escrowBalance: address(escrow).balance,
            creatorCredit: escrow.pending(address(0), CREATOR),
            kingCredit: escrow.pending(address(0), KING),
            skimmed: escrow.totalSkimmedEth(),
            pending: escrow.totalPendingEth(),
            deferred: curve.totalDeferredFees(),
            deferredShare: curve.deferredKingShares(KING)
        });
        RefundCallbackBuyer buyer = new RefundCallbackBuyer(curve);
        uint256 cap = curve.maxBuyInput();
        (uint256 expected,) = curve.quoteBuy(cap);
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert(BondingCurve.NativeTransferFailed.selector);
        buyer.buy{value: cap + 17}(RECIPIENT);
        assertEq(address(this).balance, balanceBefore);
        assertEq(address(buyer).balance, 0);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(token.balanceOf(address(curve)), before_.tokenReserve);
        assertEq(curve.ethReserve(), before_.ethReserve);
        assertEq(curve.tokenReserve(), before_.tokenReserve);
        assertEq(address(curve).balance, before_.curveBalance);
        assertEq(address(escrow).balance, before_.escrowBalance);
        assertEq(escrow.pending(address(0), CREATOR), before_.creatorCredit);
        assertEq(escrow.pending(address(0), KING), before_.kingCredit);
        assertEq(escrow.totalSkimmedEth(), before_.skimmed);
        assertEq(escrow.totalPendingEth(), before_.pending);
        assertEq(curve.totalDeferredFees(), before_.deferred);
        assertEq(curve.deferredFees(KING), before_.deferred);
        assertEq(curve.deferredKingShares(KING), before_.deferredShare);
        assertFalse(curve.readyToGraduate());

        // A contract that cannot receive ETH can still buy at the exact cap: no refund is needed.
        assertEq(buyer.buy{value: cap}(RECIPIENT), expected);
        assertEq(token.balanceOf(RECIPIENT), expected);
        assertEq(address(buyer).balance, 0);
        assertTrue(curve.readyToGraduate());
        if (deferFees) {
            vm.clearMockedCalls();
            assertTrue(curve.flushDeferredFees(KING));
        }
        assertEq(curve.totalDeferredFees(), 0);
        assertEq(address(curve).balance, curve.ethReserve());
        assertEq(escrow.totalSkimmedEth(), 3 + cap / 100);
        assertEq(escrow.pending(address(0), KING), 1 + (cap / 100) / 2);
        assertEq(escrow.totalPendingEth(), address(escrow).balance);
    }

    function test_refundCallbackCannotBuyOrSellAgain() public {
        RefundCallbackBuyer buyer = new RefundCallbackBuyer(curve);
        buyer.acceptRefund();
        uint256 cap = curve.maxBuyInput();
        (uint256 expected,) = curve.quoteBuy(cap);
        assertEq(buyer.buy{value: cap + 17}(RECIPIENT), expected);
        assertEq(buyer.buyFailure(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(buyer.sellFailure(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(buyer).balance, 17);
        assertEq(token.balanceOf(RECIPIENT), expected);
        assertEq(escrow.totalSkimmedEth(), cap / 100);
        assertEq(address(curve).balance, 4.2 ether);
    }

    function test_workerDonationDuringPayoutCannotAllocateAReentrantEpoch() public {
        DonatingWorkerPayee payee = new DonatingWorkerPayee();
        WorkerSubsidy workers = new WorkerSubsidy(address(payee));
        bytes32 thirdRoot = workers.leaf(3, RECIPIENT, 3);
        payee.configure(workers, thirdRoot);
        workers.fundWorkers{value: 10}();
        bytes32 firstRoot = workers.leaf(1, address(payee), 10);
        vm.prank(address(payee));
        workers.setEpoch(firstRoot, block.timestamp, block.timestamp + 1 days);
        workers.fundWorkers{value: 5}();
        bytes32 secondRoot = workers.leaf(2, RECIPIENT, 5);
        vm.prank(address(payee));
        workers.setEpoch(secondRoot, block.timestamp, block.timestamp + 1 days);

        workers.claimWorker(1, address(payee), 10, new bytes32[](0));
        assertEq(payee.epochFailure(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertTrue(workers.claimed(1, address(payee)));
        assertEq(workers.currentEpoch(), 2);
        assertEq(address(payee).balance, 7);
        assertEq(workers.workerPot(), 3);
        assertEq(workers.reservedForEpochs(), 5);
        assertEq(address(workers).balance, 8);

        // The donation can be allocated after the callback, without spending epoch two's reserve.
        vm.prank(address(payee));
        workers.setEpoch(thirdRoot, block.timestamp, block.timestamp + 1 days);
        assertEq(workers.workerPot(), 0);
        assertEq(workers.reservedForEpochs(), 8);
        workers.claimWorker(2, RECIPIENT, 5, new bytes32[](0));
        workers.claimWorker(3, RECIPIENT, 3, new bytes32[](0));
        assertEq(RECIPIENT.balance, 8);
        assertEq(workers.reservedForEpochs(), 0);
        assertEq(address(workers).balance, 0);
    }

    function test_failedWorkerFundingCannotReplaceTheCrownOrFirstBeneficiary() public {
        WorkerSubsidy workers = new WorkerSubsidy(address(this));
        KingOfThePad king = new KingOfThePad(workers);
        vm.mockCallRevert(address(workers), abi.encodeCall(workers.fundWorkers, ()), "worker funding failed");
        vm.expectRevert(bytes("worker funding failed"));
        king.claimKing{value: 0.02 ether}(KING);
        assertEq(king.king(), address(0));
        assertEq(king.beneficiary(), address(0));
        assertEq(king.firstBeneficiary(), address(0));
        assertEq(king.claimCount(), 0);
        assertEq(king.claimPrice(), 0.01 ether);
        assertEq(address(king).balance, 0);
        assertEq(address(workers).balance, 0);

        vm.clearMockedCalls();
        king.claimKing{value: 0.02 ether}(KING);
        vm.mockCallRevert(address(workers), abi.encodeCall(workers.fundWorkers, ()), "worker funding failed");
        vm.deal(RECIPIENT, 0.03 ether);
        vm.prank(RECIPIENT);
        vm.expectRevert(bytes("worker funding failed"));
        king.claimKing{value: 0.03 ether}(RECIPIENT);
        assertEq(king.king(), address(this));
        assertEq(king.beneficiary(), KING);
        assertEq(king.firstBeneficiary(), KING);
        assertEq(king.claimCount(), 1);
        assertEq(king.claimPrice(), 0.011 ether);
        assertEq(RECIPIENT.balance, 0.03 ether);
        assertEq(address(king).balance, 0);
        assertEq(workers.workerPot(), 0.02 ether);
        assertEq(address(workers).balance, 0.02 ether);
    }
}
