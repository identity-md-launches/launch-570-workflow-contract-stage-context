// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {WorkerSubsidy} from "src/WorkerSubsidy.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";

/// @dev A trusted recorder can deliver new fees while it receives an older withdrawal.
contract CallbackFeeRecorder {
    FeeEscrow internal immutable escrow;
    address internal immutable kingBeneficiary;
    uint256 public newFee;
    bool public rejectPayment;
    bool public reentrySucceeded;

    constructor(FeeEscrow escrow_, address kingBeneficiary_) {
        escrow = escrow_;
        kingBeneficiary = kingBeneficiary_;
    }

    function configure(uint256 fee, bool reject) external {
        newFee = fee;
        rejectPayment = reject;
    }

    function withdraw(address recipient) external returns (uint256) {
        return escrow.withdraw(address(0), recipient);
    }

    receive() external payable {
        (reentrySucceeded,) = address(escrow).call(abi.encodeCall(escrow.withdraw, (address(0), address(this))));
        escrow.recordTradeFeeNativeFor{value: newFee}(address(this), kingBeneficiary, newFee);
        require(!rejectPayment, "reject after callback");
    }
}

/// forge-config: default.fuzz.runs = 512
contract WorkerAdversarialTest is Test {
    WorkerSubsidy internal workers;
    KingOfThePad internal king;
    FeeEscrow internal escrow;
    address internal constant PAYEE = address(0xAAA1);
    address internal constant SECOND = address(0xAAA2);
    address internal constant RELAYER = address(0xAAA3);

    function setUp() public {
        vm.warp(100 days);
        vm.deal(address(this), type(uint128).max);
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        escrow = new FeeEscrow(king, address(this));
        escrow.authorizeRecorder(address(this), true);
    }

    function testFuzzProofCannotBeReplayedIntoAnotherFundedEpoch(uint96 amountSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, type(uint96).max);
        bytes32 leaf = _leaf(1, PAYEE, amount);
        workers.fundWorkers{value: amount}();
        workers.setEpoch(leaf, block.timestamp, block.timestamp + 1 days);
        workers.fundWorkers{value: amount}();
        // Even re-publishing exactly the first root cannot make its leaf spend epoch two.
        workers.setEpoch(leaf, block.timestamp, block.timestamp + 1 days);
        vm.prank(RELAYER);
        workers.claimWorker(1, PAYEE, amount, new bytes32[](0));
        vm.expectRevert(WorkerSubsidy.InvalidProof.selector);
        workers.claimWorker(2, PAYEE, amount, new bytes32[](0));
        assertEq(PAYEE.balance, amount);
        assertEq(RELAYER.balance, 0);
        assertFalse(workers.claimed(2, PAYEE));
        assertEq(workers.reservedForEpochs(), amount);
        assertEq(address(workers).balance, amount);
    }

    function testMaxWindowStartAndEndAreInclusiveAndFullEpochRecyclesZero() public {
        workers.fundWorkers{value: 2}();
        bytes32 a = _leaf(1, PAYEE, 1);
        bytes32 b = _leaf(1, SECOND, 1);
        uint256 start = block.timestamp + 1;
        uint256 end = start + 90 days;
        workers.setEpoch(_pair(a, b), start, end);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        vm.warp(start);
        workers.claimWorker(1, PAYEE, 1, proof);
        proof[0] = a;
        vm.warp(end);
        workers.claimWorker(1, SECOND, 1, proof);
        assertEq(workers.reservedForEpochs(), 0);
        vm.expectRevert(WorkerSubsidy.EpochNotExpired.selector);
        workers.recycleExpiredEpoch(1);
        vm.warp(end + 1);
        assertEq(workers.recycleExpiredEpoch(1), 0);
        assertTrue(workers.recycled(1));
        assertEq(workers.workerPot(), 0);
        vm.expectRevert(WorkerSubsidy.EpochNotOpen.selector);
        workers.claimWorker(1, SECOND, 1, proof);
    }

    function testSupersededUpdaterCannotAcceptOrPublish() public {
        workers.fundWorkers{value: 1}();
        workers.proposeUpdater(PAYEE);
        workers.proposeUpdater(SECOND);
        vm.prank(PAYEE);
        vm.expectRevert(WorkerSubsidy.NoPendingUpdater.selector);
        workers.acceptUpdater();
        vm.prank(PAYEE);
        vm.expectRevert(WorkerSubsidy.NotUpdater.selector);
        workers.setEpoch(_leaf(1, PAYEE, 1), block.timestamp, block.timestamp + 1);
        assertEq(workers.updater(), address(this));
        assertEq(workers.pendingUpdater(), SECOND);
        vm.prank(SECOND);
        workers.acceptUpdater();
        vm.expectRevert(WorkerSubsidy.NotUpdater.selector);
        workers.proposeUpdater(PAYEE);
        assertEq(workers.workerPot(), 1);
        assertEq(workers.currentEpoch(), 0);
    }

    function testFuzzEpochBudgetRemainsIsolatedWhenRootOverallocates(uint96 firstSeed, uint96 laterSeed) public {
        uint256 first = bound(uint256(firstSeed), 2, type(uint96).max);
        uint256 later = bound(uint256(laterSeed), 1, type(uint96).max);
        bytes32 a = _leaf(1, PAYEE, first);
        bytes32 b = _leaf(1, SECOND, 1);
        workers.fundWorkers{value: first}();
        workers.setEpoch(_pair(a, b), block.timestamp, block.timestamp + 1 days);
        workers.fundWorkers{value: later}();
        workers.setEpoch(_leaf(2, SECOND, later), block.timestamp, block.timestamp + 1 days);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        workers.claimWorker(1, PAYEE, first, proof);
        proof[0] = a;
        vm.expectRevert(WorkerSubsidy.InvalidProof.selector);
        workers.claimWorker(1, SECOND, 1, proof);
        assertFalse(workers.claimed(1, SECOND));
        assertEq(workers.reservedForEpochs(), later);
        workers.claimWorker(2, SECOND, later, new bytes32[](0));
        assertEq(PAYEE.balance, first);
        assertEq(SECOND.balance, later);
        assertEq(address(workers).balance, 0);
    }

    function testOneWeiReceiveDonationAndZeroReceiveRollback() public {
        (bool ok,) = address(workers).call{value: 1}("");
        assertTrue(ok);
        assertEq(workers.workerPot(), 1);
        (ok,) = address(workers).call("");
        assertFalse(ok);
        assertEq(workers.workerPot(), 1);
        assertEq(address(workers).balance, 1);
    }

    function testFuzzKingOverbidDoesNotSetNextPriceOrRefundPreviousKing(uint96 overbidSeed) public {
        uint256 overbid = bound(uint256(overbidSeed), 0.01 ether + 1, type(uint96).max);
        vm.deal(PAYEE, overbid);
        vm.prank(PAYEE);
        king.claimKing{value: overbid}(PAYEE);
        assertEq(king.claimPrice(), 0.011 ether);
        king.claimKing{value: 0.011 ether + 1}(SECOND);
        assertEq(king.claimPrice(), 0.0121 ether);
        assertEq(king.firstBeneficiary(), PAYEE);
        assertEq(king.beneficiary(), SECOND);
        assertEq(PAYEE.balance, 0);
        assertEq(workers.workerPot(), overbid + 0.011 ether + 1);
        assertEq(address(king).balance, 0);
    }

    function testWithdrawalKeepsNewCreditRecordedDuringCallback() public {
        CallbackFeeRecorder receiver = new CallbackFeeRecorder(escrow, PAYEE);
        escrow.authorizeRecorder(address(receiver), true);
        receiver.configure(3, false);
        escrow.recordTradeFeeNativeFor{value: 20}(address(receiver), PAYEE, 20);
        assertEq(receiver.withdraw(address(receiver)), 10);
        assertFalse(receiver.reentrySucceeded());
        assertEq(address(receiver).balance, 7);
        assertEq(escrow.pending(address(0), address(receiver)), 2);
        assertEq(escrow.pending(address(0), PAYEE), 11);
        assertEq(escrow.totalPendingEth(), 13);
        assertEq(escrow.totalSkimmedEth(), 23);
        assertEq(escrow.totalWithdrawnEth(), 10);
        assertEq(address(escrow).balance, 13);
        assertEq(receiver.withdraw(SECOND), 2);
        assertEq(SECOND.balance, 2);
    }

    function testRejectingCallbackRollsBackNewCreditsAndPreservesOldWithdrawal() public {
        CallbackFeeRecorder receiver = new CallbackFeeRecorder(escrow, PAYEE);
        escrow.authorizeRecorder(address(receiver), true);
        receiver.configure(3, true);
        escrow.recordTradeFeeNativeFor{value: 20}(address(receiver), PAYEE, 20);
        assertEq(receiver.withdraw(address(receiver)), 0);
        assertEq(escrow.pending(address(0), address(receiver)), 10);
        assertEq(escrow.pending(address(0), PAYEE), 10);
        assertEq(escrow.totalPendingEth(), 20);
        assertEq(escrow.totalSkimmedEth(), 20);
        assertEq(escrow.totalWithdrawnEth(), 0);
        assertEq(address(escrow).balance, 20);
        assertEq(address(receiver).balance, 0);
        assertEq(receiver.withdraw(SECOND), 10);
        assertEq(SECOND.balance, 10);
    }

    function testFuzzAggregatedFeesMatchIndividualOddRounding(uint96 firstFee, uint96 secondFee) public {
        uint256 total = uint256(firstFee) + secondFee;
        uint256 expectedKing = uint256(firstFee) / 2 + uint256(secondFee) / 2;
        escrow.recordTradeFeeNativeShares{value: total}(SECOND, PAYEE, expectedKing);
        assertEq(escrow.pending(address(0), PAYEE), expectedKing);
        assertEq(escrow.pending(address(0), SECOND), total - expectedKing);
        assertEq(escrow.totalPendingEth(), total);
        vm.prank(PAYEE);
        assertEq(escrow.withdraw(address(0), PAYEE), expectedKing);
        vm.prank(SECOND);
        assertEq(escrow.withdraw(address(0), SECOND), total - expectedKing);
        assertEq(PAYEE.balance + SECOND.balance, total);
        assertEq(address(escrow).balance, 0);
    }

    function testCoincidentCreatorAndKingReceivesFullOddFeeOnce() public {
        escrow.recordTradeFeeNativeFor{value: 101}(PAYEE, PAYEE, 101);
        assertEq(escrow.pending(address(0), PAYEE), 101);
        vm.prank(PAYEE);
        assertEq(escrow.withdraw(address(0), SECOND), 101);
        vm.prank(PAYEE);
        assertEq(escrow.withdraw(address(0), SECOND), 0);
        assertEq(SECOND.balance, 101);
        assertEq(escrow.totalWithdrawnEth(), 101);
        assertEq(address(escrow).balance, 0);
    }

    function testFuzzInvalidExplicitSnapshotFeePreservesState(uint96 valueSeed) public {
        uint256 value = valueSeed;
        vm.expectRevert(FeeEscrow.FeeMismatch.selector);
        escrow.recordTradeFeeNativeFor{value: value}(PAYEE, SECOND, value + 1);
        vm.expectRevert(FeeEscrow.FeeMismatch.selector);
        escrow.recordTradeFeeNativeShares{value: value}(PAYEE, SECOND, value / 2 + 1);
        assertEq(escrow.totalPendingEth(), 0);
        assertEq(escrow.totalSkimmedEth(), 0);
        assertEq(escrow.unassignedEth(), 0);
        assertEq(address(escrow).balance, 0);
    }

    function _leaf(uint256 epoch, address payee, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(abi.encode(epoch, payee, amount))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
