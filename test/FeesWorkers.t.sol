// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";

contract FeeRecipient {
    FeeEscrow public immutable escrow;
    bool public reject;
    bool public reenter;
    bool public reentered;
    uint256 public received;

    constructor(FeeEscrow escrow_) {
        escrow = escrow_;
    }

    function configure(bool reject_, bool reenter_) external {
        reject = reject_;
        reenter = reenter_;
    }

    function withdraw(address to) external returns (uint256) {
        return escrow.withdraw(address(0), to);
    }

    receive() external payable {
        require(!reject, "reject ETH");
        received += msg.value;
        if (reenter) {
            (reentered,) = address(escrow).call(abi.encodeCall(escrow.withdraw, (address(0), address(this))));
        }
    }
}

contract WorkerRecipient {
    WorkerSubsidy public immutable workers;
    bool public reject;
    bool public reenter;
    bool public reentered;
    uint256 public received;
    uint256 public epochId;
    uint256 public claimAmount;

    constructor(WorkerSubsidy workers_) {
        workers = workers_;
    }

    function configure(bool reject_, bool reenter_, uint256 epochId_, uint256 amount_) external {
        reject = reject_;
        reenter = reenter_;
        epochId = epochId_;
        claimAmount = amount_;
    }

    receive() external payable {
        require(!reject, "reject ETH");
        received += msg.value;
        if (reenter) {
            bytes32[] memory proof = new bytes32[](0);
            (reentered,) = address(workers)
                .call(abi.encodeCall(workers.claimWorker, (epochId, address(this), claimAmount, proof)));
        }
    }
}

contract FeesWorkersTest is Test {
    WorkerSubsidy internal workers;
    KingOfThePad internal king;
    FeeEscrow internal escrow;
    address internal constant UPDATER = address(0xA11CE);
    address internal constant FIRST = address(0xF1);
    address internal constant SECOND = address(0xF2);
    address internal constant CREATOR = address(0xC1);
    address internal constant WORKER = address(0xB0B);

    function setUp() public {
        vm.warp(100 days);
        vm.deal(address(this), 100 ether);
        workers = new WorkerSubsidy(UPDATER);
        king = new KingOfThePad(workers);
        escrow = new FeeEscrow(king, address(this));
        escrow.authorizeRecorder(address(this), true);
    }

    function testKingStrictBidAndFullWorkerFunding() public {
        assertEq(king.claimPrice(), 0.01 ether);
        vm.expectRevert(KingOfThePad.BidTooLow.selector);
        king.claimKing{value: 0.01 ether}(FIRST);
        vm.expectRevert(KingOfThePad.InvalidAddress.selector);
        king.claimKing{value: 0.011 ether}(address(0));
        king.claimKing{value: 0.01 ether + 1}(FIRST);
        assertEq(king.king(), address(this));
        assertEq(king.beneficiary(), FIRST);
        assertEq(king.firstBeneficiary(), FIRST);
        assertEq(king.claimCount(), 1);
        assertEq(king.claimPrice(), 0.011 ether);
        uint256 secondBid = king.claimPrice() + 1;
        king.claimKing{value: secondBid}(SECOND);
        assertEq(king.beneficiary(), SECOND);
        assertEq(king.firstBeneficiary(), FIRST);
        assertEq(king.claimPrice(), 0.0121 ether);
        assertEq(workers.workerPot(), 0.01 ether + 1 + secondBid);
        assertEq(address(king).balance, 0);
        assertEq(FIRST.balance, 0, "previous king receives no bid refund");
    }

    function testFeeRecorderAccessAndDepositValidation() public {
        vm.prank(CREATOR);
        vm.expectRevert(FeeEscrow.NotAuthorized.selector);
        escrow.authorizeRecorder(CREATOR, true);
        vm.prank(CREATOR);
        vm.expectRevert(FeeEscrow.NotAuthorized.selector);
        escrow.recordTradeFeeNative(CREATOR, 0);
        vm.prank(CREATOR);
        vm.expectRevert(FeeEscrow.NotAuthorized.selector);
        escrow.recordTradeFeeNativeFor(CREATOR, FIRST, 0);
        vm.expectRevert(FeeEscrow.InvalidAddress.selector);
        escrow.authorizeRecorder(address(0), true);
        vm.expectRevert(FeeEscrow.FeeMismatch.selector);
        escrow.recordTradeFeeNative{value: 1}(CREATOR, 2);
        vm.expectRevert(FeeEscrow.FeeMismatch.selector);
        escrow.recordTradeFeeNative{value: 1}(CREATOR, 0);
        vm.expectRevert(FeeEscrow.InvalidAddress.selector);
        escrow.recordTradeFeeNative{value: 2}(address(0), 2);
        vm.expectRevert(FeeEscrow.UnsupportedCurrency.selector);
        escrow.recordTradeFee{value: 2}(CREATOR, CREATOR, 2);
        assertEq(address(escrow).balance, 0);
        escrow.authorizeRecorder(address(this), false);
        vm.expectRevert(FeeEscrow.NotAuthorized.selector);
        escrow.recordTradeFeeNative(CREATOR, 0);
    }

    function testAggregatedDeferredSharesPreserveEveryOddWei() public {
        king.claimKing{value: 0.011 ether}(FIRST);
        // Two independently captured fees of 101 wei: each king share is 50 wei.
        escrow.recordTradeFeeNativeShares{value: 202}(CREATOR, FIRST, 100);
        assertEq(escrow.pending(address(0), FIRST), 100);
        assertEq(escrow.pending(address(0), CREATOR), 102);
        vm.expectRevert(FeeEscrow.FeeMismatch.selector);
        escrow.recordTradeFeeNativeShares{value: 2}(CREATOR, FIRST, 2);
        vm.prank(CREATOR);
        vm.expectRevert(FeeEscrow.NotAuthorized.selector);
        escrow.recordTradeFeeNativeShares(CREATOR, FIRST, 0);
    }

    function testPreKingFeesAndDelayedDeliveryAlwaysBelongToFirstKing() public {
        escrow.recordTradeFeeNative{value: 101}(CREATOR, 101);
        assertEq(escrow.unassignedEth(), 50);
        assertEq(escrow.pending(address(0), CREATOR), 51);
        vm.expectRevert(FeeEscrow.NoBeneficiary.selector);
        escrow.assignUnassigned();
        king.claimKing{value: 0.011 ether}(FIRST);
        escrow.recordTradeFeeNative{value: 100}(CREATOR, 100);
        king.claimKing{value: 0.012 ether}(SECOND);
        escrow.assignUnassigned();
        escrow.assignUnassigned();
        assertEq(escrow.unassignedEth(), 0);
        assertEq(escrow.pending(address(0), FIRST), 100);
        assertEq(escrow.pending(address(0), SECOND), 0);
        // A deferred trade captured before the first crown retains its original entitlement.
        escrow.recordTradeFeeNativeFor{value: 100}(CREATOR, address(0), 100);
        // A trade captured during the first crown, delivered after the second crown, also does.
        escrow.recordTradeFeeNativeFor{value: 100}(CREATOR, FIRST, 100);
        escrow.recordTradeFeeNative{value: 100}(CREATOR, 100);
        assertEq(escrow.pending(address(0), FIRST), 200);
        assertEq(escrow.pending(address(0), SECOND), 50);
        assertEq(escrow.pending(address(0), CREATOR), 251);
        assertEq(escrow.totalPendingEth(), 501);
        assertEq(escrow.totalSkimmedEth(), 501);
        assertEq(address(escrow).balance, 501);
    }

    function testEscrowRejectingRecipientDoesNotLoseCredits() public {
        FeeRecipient receiver = new FeeRecipient(escrow);
        receiver.configure(true, false);
        king.claimKing{value: 0.011 ether}(address(receiver));
        escrow.recordTradeFeeNative{value: 2 ether}(address(receiver), 2 ether);
        assertEq(receiver.withdraw(address(receiver)), 0);
        assertEq(escrow.pending(address(0), address(receiver)), 2 ether);
        assertEq(escrow.totalPendingEth(), 2 ether);
        assertEq(escrow.totalWithdrawnEth(), 0);
        assertEq(receiver.withdraw(WORKER), 2 ether);
        assertEq(WORKER.balance, 2 ether);
        assertEq(escrow.pending(address(0), address(receiver)), 0);
        assertEq(escrow.totalPendingEth(), 0);
        assertEq(escrow.totalWithdrawnEth(), 2 ether);
        assertEq(address(escrow).balance, 0);
        assertEq(receiver.withdraw(WORKER), 0);
    }

    function testEscrowWithdrawalCannotReenterOrStealAnotherCredit() public {
        FeeRecipient receiver = new FeeRecipient(escrow);
        receiver.configure(false, true);
        king.claimKing{value: 0.011 ether}(FIRST);
        escrow.recordTradeFeeNative{value: 2 ether}(address(receiver), 2 ether);
        assertEq(receiver.withdraw(address(receiver)), 1 ether);
        assertFalse(receiver.reentered());
        assertEq(receiver.received(), 1 ether);
        assertEq(escrow.pending(address(0), FIRST), 1 ether);
        assertEq(address(escrow).balance, 1 ether);
        assertEq(escrow.totalPendingEth() + escrow.totalWithdrawnEth(), escrow.totalSkimmedEth());
    }

    function testWithdrawRejectsInvalidRecipientAndCurrency() public {
        escrow.recordTradeFeeNative{value: 100}(address(this), 100);
        vm.expectRevert(FeeEscrow.InvalidAddress.selector);
        escrow.withdraw(address(0), address(0));
        vm.expectRevert(FeeEscrow.UnsupportedCurrency.selector);
        escrow.withdraw(CREATOR, WORKER);
        vm.prank(SECOND);
        assertEq(escrow.withdraw(address(0), SECOND), 0);
        assertEq(escrow.pending(address(0), address(this)), 50);
    }

    function testWorkerUpdaterRotationIsExplicitTwoStep() public {
        assertEq(workers.updater(), UPDATER);
        vm.expectRevert(WorkerSubsidy.NotUpdater.selector);
        workers.proposeUpdater(SECOND);
        vm.prank(UPDATER);
        vm.expectRevert(WorkerSubsidy.InvalidAddress.selector);
        workers.proposeUpdater(address(0));
        vm.prank(UPDATER);
        workers.proposeUpdater(SECOND);
        assertEq(workers.updater(), UPDATER);
        assertEq(workers.pendingUpdater(), SECOND);
        vm.expectRevert(WorkerSubsidy.NoPendingUpdater.selector);
        workers.acceptUpdater();
        vm.prank(SECOND);
        workers.acceptUpdater();
        assertEq(workers.updater(), SECOND);
        assertEq(workers.pendingUpdater(), address(0));
        vm.prank(UPDATER);
        vm.expectRevert(WorkerSubsidy.NotUpdater.selector);
        workers.setEpoch(bytes32(uint256(1)), block.timestamp, block.timestamp + 1 days);
        vm.prank(SECOND);
        vm.expectRevert(WorkerSubsidy.NoPendingUpdater.selector);
        workers.acceptUpdater();
    }

    function testWorkerEpochValidationDoesNotConsumePot() public {
        workers.fundWorkers{value: 1 ether}();
        vm.expectRevert(WorkerSubsidy.NotUpdater.selector);
        workers.setEpoch(bytes32(uint256(1)), block.timestamp, block.timestamp + 1 days);
        vm.startPrank(UPDATER);
        vm.expectRevert(WorkerSubsidy.InvalidRoot.selector);
        workers.setEpoch(bytes32(0), block.timestamp, block.timestamp + 1 days);
        vm.expectRevert(WorkerSubsidy.InvalidWindow.selector);
        workers.setEpoch(bytes32(uint256(1)), block.timestamp - 1, block.timestamp + 1 days);
        vm.expectRevert(WorkerSubsidy.InvalidWindow.selector);
        workers.setEpoch(bytes32(uint256(1)), block.timestamp, block.timestamp);
        vm.expectRevert(WorkerSubsidy.InvalidWindow.selector);
        workers.setEpoch(bytes32(uint256(1)), block.timestamp, block.timestamp + 90 days + 1);
        // The start may not be more than one maximum window ahead either, so the pot cannot be parked.
        vm.expectRevert(WorkerSubsidy.InvalidWindow.selector);
        workers.setEpoch(bytes32(uint256(1)), block.timestamp + 90 days + 1, block.timestamp + 90 days + 2);
        vm.expectRevert(WorkerSubsidy.InvalidWindow.selector);
        workers.setEpoch(bytes32(uint256(1)), block.timestamp + 36500 days, block.timestamp + 36500 days + 1);
        vm.stopPrank();
        assertEq(workers.workerPot(), 1 ether);
        assertEq(workers.reservedForEpochs(), 0);
        assertEq(workers.currentEpoch(), 0);
        vm.expectRevert(WorkerSubsidy.NothingToFund.selector);
        workers.fundWorkers();
        _setEpoch(workers.leaf(1, WORKER, 1 ether), block.timestamp, block.timestamp + 1 days);
        vm.prank(UPDATER);
        vm.expectRevert(WorkerSubsidy.NothingToFund.selector);
        workers.setEpoch(bytes32(uint256(1)), block.timestamp, block.timestamp + 1 days);
    }

    /// @dev A far-future start can delay the reserved pot by at most two maximum windows before claims
    /// open and then recycling becomes possible; the updater cannot lock it indefinitely.
    function testWorkerEpochStartBoundedByMaxWindowKeepsPotRecoverable() public {
        workers.fundWorkers{value: 10 ether}();
        uint256 start = block.timestamp + 90 days;
        _setEpoch(workers.leaf(1, WORKER, 10 ether), start, start + 90 days);
        assertEq(workers.workerPot(), 0);
        assertEq(workers.reservedForEpochs(), 10 ether);
        vm.expectRevert(WorkerSubsidy.EpochNotOpen.selector);
        workers.claimWorker(1, WORKER, 10 ether, new bytes32[](0));
        vm.expectRevert(WorkerSubsidy.EpochNotExpired.selector);
        workers.recycleExpiredEpoch(1);
        vm.warp(start);
        workers.claimWorker(1, WORKER, 10 ether, new bytes32[](0)); // single-leaf tree: root == leaf
        assertEq(WORKER.balance, 10 ether);
        assertEq(workers.reservedForEpochs(), 0);
    }

    function testWorkerProofsRelayedClaimsDuplicatesAndBudgetIsolation() public {
        workers.fundWorkers{value: 1 ether}();
        bytes32 a = workers.leaf(1, WORKER, 0.6 ether);
        bytes32 b = workers.leaf(1, CREATOR, 0.4 ether);
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        _setEpoch(root, block.timestamp, block.timestamp + 1 days);
        assertEq(workers.workerPot(), 0);
        assertEq(workers.reservedForEpochs(), 1 ether);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        vm.expectRevert(WorkerSubsidy.InvalidProof.selector);
        workers.claimWorker(1, WORKER, 0.5 ether, proof);
        vm.expectRevert(WorkerSubsidy.InvalidProof.selector);
        workers.claimWorker(1, SECOND, 0.6 ether, proof);
        vm.prank(SECOND);
        workers.claimWorker(1, WORKER, 0.6 ether, proof);
        assertEq(WORKER.balance, 0.6 ether);
        assertEq(SECOND.balance, 0);
        assertEq(workers.reservedForEpochs(), 0.4 ether);
        vm.expectRevert(WorkerSubsidy.AlreadyClaimed.selector);
        workers.claimWorker(1, WORKER, 0.6 ether, proof);
        workers.fundWorkers{value: 2 ether}();
        // Even a valid root cannot spend more than its own epoch's reserved budget.
        _setEpoch(workers.leaf(2, SECOND, 3 ether), block.timestamp, block.timestamp + 1 days);
        vm.expectRevert(WorkerSubsidy.InvalidProof.selector);
        workers.claimWorker(2, SECOND, 3 ether, new bytes32[](0));
        proof[0] = a;
        workers.claimWorker(1, CREATOR, 0.4 ether, proof);
        assertEq(CREATOR.balance, 0.4 ether);
        assertEq(workers.reservedForEpochs(), 2 ether);
        assertEq(address(workers).balance, workers.workerPot() + workers.reservedForEpochs());
    }

    function testWorkerClaimWindowBoundariesAndExpiryRecycling() public {
        workers.fundWorkers{value: 1 ether}();
        uint256 start = block.timestamp + 100;
        uint256 end = start + 100;
        _setEpoch(workers.leaf(1, WORKER, 0.4 ether), start, end);
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(WorkerSubsidy.EpochNotOpen.selector);
        workers.claimWorker(1, WORKER, 0.4 ether, proof);
        vm.expectRevert(WorkerSubsidy.EpochNotExpired.selector);
        workers.recycleExpiredEpoch(1);
        vm.warp(end);
        workers.claimWorker(1, WORKER, 0.4 ether, proof);
        vm.expectRevert(WorkerSubsidy.EpochNotExpired.selector);
        workers.recycleExpiredEpoch(1);
        vm.warp(end + 1);
        vm.expectRevert(WorkerSubsidy.EpochNotOpen.selector);
        workers.claimWorker(1, WORKER, 0.4 ether, proof);
        vm.prank(SECOND);
        assertEq(workers.recycleExpiredEpoch(1), 0.6 ether);
        assertTrue(workers.recycled(1));
        assertEq(workers.workerPot(), 0.6 ether);
        assertEq(workers.reservedForEpochs(), 0);
        assertEq(SECOND.balance, 0);
        vm.expectRevert(WorkerSubsidy.EpochNotExpired.selector);
        workers.recycleExpiredEpoch(1);
        vm.expectRevert(WorkerSubsidy.EpochNotExpired.selector);
        workers.recycleExpiredEpoch(99);
        _setEpoch(workers.leaf(2, SECOND, 0.6 ether), block.timestamp, block.timestamp + 100);
        workers.claimWorker(2, SECOND, 0.6 ether, proof);
        assertEq(address(workers).balance, 0);
        assertEq(workers.reservedForEpochs(), 0);
    }

    function testWorkerFailedPaymentRestoresClaimAndReserve() public {
        WorkerRecipient receiver = new WorkerRecipient(workers);
        receiver.configure(true, false, 1, 1 ether);
        workers.fundWorkers{value: 1 ether}();
        _setEpoch(workers.leaf(1, address(receiver), 1 ether), block.timestamp, block.timestamp + 1 days);
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(WorkerSubsidy.TransferFailed.selector);
        workers.claimWorker(1, address(receiver), 1 ether, proof);
        assertFalse(workers.claimed(1, address(receiver)));
        (,, uint256 paid,,) = workers.epochs(1);
        assertEq(paid, 0);
        assertEq(workers.reservedForEpochs(), 1 ether);
        receiver.configure(false, false, 1, 1 ether);
        workers.claimWorker(1, address(receiver), 1 ether, proof);
        assertEq(receiver.received(), 1 ether);
        assertEq(workers.reservedForEpochs(), 0);
    }

    function testWorkerCannotReenterClaim() public {
        WorkerRecipient receiver = new WorkerRecipient(workers);
        receiver.configure(false, true, 1, 1 ether);
        workers.fundWorkers{value: 2 ether}();
        _setEpoch(workers.leaf(1, address(receiver), 1 ether), block.timestamp, block.timestamp + 1 days);
        workers.claimWorker(1, address(receiver), 1 ether, new bytes32[](0));
        assertFalse(receiver.reentered());
        assertTrue(workers.claimed(1, address(receiver)));
        assertEq(receiver.received(), 1 ether);
        assertEq(workers.reservedForEpochs(), 1 ether);
        assertEq(address(workers).balance, 1 ether);
    }

    function testWorkerRejectsUnknownEpochZeroPayeeAndZeroAmount() public {
        workers.fundWorkers{value: 1 ether}();
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(WorkerSubsidy.EpochNotOpen.selector);
        workers.claimWorker(0, WORKER, 1 ether, proof);
        _setEpoch(workers.leaf(1, address(0), 1 ether), block.timestamp, block.timestamp + 1 days);
        vm.expectRevert(WorkerSubsidy.InvalidAddress.selector);
        workers.claimWorker(1, address(0), 1 ether, proof);
        vm.expectRevert(WorkerSubsidy.InvalidProof.selector);
        workers.claimWorker(1, WORKER, 0, proof);
    }

    function testConstructorsRejectMissingDependencies() public {
        vm.expectRevert(WorkerSubsidy.InvalidAddress.selector);
        new WorkerSubsidy(address(0));
        vm.expectRevert(KingOfThePad.InvalidAddress.selector);
        new KingOfThePad(WorkerSubsidy(payable(address(0))));
        vm.expectRevert(FeeEscrow.InvalidAddress.selector);
        new FeeEscrow(KingOfThePad(address(0)), address(this));
        vm.expectRevert(FeeEscrow.InvalidAddress.selector);
        new FeeEscrow(king, address(0));
    }

    function testFuzzFeeConservationAcrossCrowns(uint96 firstFees, uint96 secondFees, uint96 thirdFees) public {
        uint256 total = uint256(firstFees) + uint256(secondFees) + uint256(thirdFees);
        vm.deal(address(this), total + 1 ether);
        escrow.recordTradeFeeNative{value: firstFees}(CREATOR, firstFees);
        king.claimKing{value: 0.011 ether}(FIRST);
        escrow.recordTradeFeeNative{value: secondFees}(CREATOR, secondFees);
        king.claimKing{value: 0.012 ether}(SECOND);
        escrow.recordTradeFeeNative{value: thirdFees}(CREATOR, thirdFees);
        escrow.assignUnassigned();
        assertEq(escrow.pending(address(0), FIRST), uint256(firstFees) / 2 + uint256(secondFees) / 2);
        assertEq(escrow.pending(address(0), SECOND), uint256(thirdFees) / 2);
        assertEq(escrow.totalPendingEth(), total);
        vm.prank(CREATOR);
        escrow.withdraw(address(0), CREATOR);
        vm.prank(FIRST);
        escrow.withdraw(address(0), FIRST);
        vm.prank(SECOND);
        escrow.withdraw(address(0), SECOND);
        assertEq(escrow.totalWithdrawnEth(), total);
        assertEq(escrow.totalPendingEth(), 0);
        assertEq(address(escrow).balance, 0);
    }

    function _setEpoch(bytes32 root, uint256 start, uint256 end) internal {
        vm.prank(UPDATER);
        workers.setEpoch(root, start, end);
    }
}
