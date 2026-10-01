// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {WorkerSubsidy} from "src/WorkerSubsidy.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";

/// @dev The ledger records inputs and successful payments, never copies contract accounting.
contract WorkerAccountingHandler is Test {
    struct Allocation {
        uint256 budget;
        uint256 amount;
        uint256 start;
        uint256 end;
        uint256 paid;
        uint8 claimedMask;
        bool recycled;
    }

    WorkerSubsidy public immutable workers;
    address[4] public payees;
    mapping(uint256 => Allocation) public allocations;
    mapping(address => uint256) public paidTo;
    uint256 public deposited;
    uint256 public paidOut;
    uint256 public pot;
    uint256 public epochCount;
    address public expectedUpdater;
    address public expectedPending;

    constructor() {
        workers = new WorkerSubsidy(address(this));
        expectedUpdater = address(this);
        for (uint256 i; i < 4; i++) {
            payees[i] = address(uint160(0xAA00 + i));
        }
        vm.deal(address(this), 1e36);
        donate(16 ether);
        openEpoch(0, 7 days);
    }

    function donate(uint256 amount) public {
        amount = bound(amount, 1, 20 ether);
        workers.fundWorkers{value: amount}();
        deposited += amount;
        pot += amount;
    }

    function openEpoch(uint256 delay, uint256 length) public {
        if (pot < 4) donate(4);
        uint256 id = epochCount + 1;
        uint256 start = block.timestamp + bound(delay, 0, 2 days);
        uint256 end = start + bound(length, 1, 90 days);
        uint256 amount = pot / 4;
        bytes32 root = _root(id, amount);
        vm.prank(expectedUpdater);
        workers.setEpoch(root, start, end);
        allocations[id] = Allocation(pot, amount, start, end, 0, 0, false);
        pot = 0;
        epochCount = id;
    }

    function claim(uint256 epochSeed, uint256 actorSeed, uint256 relayerSeed) external {
        uint256 id = bound(epochSeed, 1, epochCount);
        uint256 actor = actorSeed % 4;
        Allocation storage a = allocations[id];
        bytes32[] memory proof = _proof(id, a.amount, actor);
        bytes4 expectedError;
        if (a.recycled || block.timestamp < a.start || block.timestamp > a.end) {
            expectedError = WorkerSubsidy.EpochNotOpen.selector;
        } else if ((a.claimedMask & uint8(1 << actor)) != 0) {
            expectedError = WorkerSubsidy.AlreadyClaimed.selector;
        }
        if (expectedError != bytes4(0)) vm.expectRevert(expectedError);
        vm.prank(address(uint160(0xBB00 + relayerSeed % 4)));
        workers.claimWorker(id, payees[actor], a.amount, proof);
        if (expectedError == bytes4(0)) {
            a.claimedMask |= uint8(1 << actor);
            a.paid += a.amount;
            paidOut += a.amount;
            paidTo[payees[actor]] += a.amount;
        }
    }

    function invalidClaim(uint256 epochSeed, uint256 actorSeed) external {
        uint256 id = bound(epochSeed, 1, epochCount);
        uint256 actor = actorSeed % 4;
        Allocation storage a = allocations[id];
        bytes4 expectedError = WorkerSubsidy.InvalidProof.selector;
        if (a.recycled || block.timestamp < a.start || block.timestamp > a.end) {
            expectedError = WorkerSubsidy.EpochNotOpen.selector;
        } else if ((a.claimedMask & uint8(1 << actor)) != 0) {
            expectedError = WorkerSubsidy.AlreadyClaimed.selector;
        }
        vm.expectRevert(expectedError);
        workers.claimWorker(id, payees[actor], a.amount + 1, _proof(id, a.amount, actor));
    }

    function recycle(uint256 epochSeed, uint256 actorSeed) external {
        uint256 id = bound(epochSeed, 1, epochCount);
        Allocation storage a = allocations[id];
        bool expired = !a.recycled && block.timestamp > a.end;
        if (!expired) vm.expectRevert(WorkerSubsidy.EpochNotExpired.selector);
        vm.prank(payees[actorSeed % 4]);
        uint256 returned = workers.recycleExpiredEpoch(id);
        if (expired) {
            assertEq(returned, a.budget - a.paid);
            a.recycled = true;
            pot += a.budget - a.paid;
        }
    }

    function advanceTime(uint256 delta) external {
        vm.warp(block.timestamp + bound(delta, 1, 45 days));
    }

    function proposeUpdater(uint256 actorSeed) external {
        address next = address(uint160(0xCC00 + actorSeed % 4));
        vm.prank(expectedUpdater);
        workers.proposeUpdater(next);
        expectedPending = next;
    }

    function acceptUpdater(uint256 actorSeed) external {
        address caller = address(uint160(0xCC00 + actorSeed % 4));
        if (caller != expectedPending) vm.expectRevert(WorkerSubsidy.NoPendingUpdater.selector);
        vm.prank(caller);
        workers.acceptUpdater();
        if (caller == expectedPending) {
            expectedUpdater = caller;
            expectedPending = address(0);
        }
    }

    function assertAccounting() external view {
        uint256 reserved;
        for (uint256 id = 1; id <= epochCount; id++) {
            Allocation memory a = allocations[id];
            (bytes32 root, uint256 budget, uint256 paid, uint256 start, uint256 end) = workers.epochs(id);
            assertEq(root, _root(id, a.amount));
            assertEq(budget, a.budget);
            assertEq(paid, a.paid);
            assertEq(start, a.start);
            assertEq(end, a.end);
            assertEq(workers.recycled(id), a.recycled);
            if (!a.recycled) reserved += a.budget - a.paid;
            for (uint256 i; i < 4; i++) {
                assertEq(workers.claimed(id, payees[i]), (a.claimedMask & uint8(1 << i)) != 0);
            }
        }
        assertEq(workers.currentEpoch(), epochCount);
        assertEq(workers.workerPot(), pot);
        assertEq(workers.reservedForEpochs(), reserved);
        assertEq(address(workers).balance, deposited - paidOut);
        assertEq(pot + reserved + paidOut, deposited);
        assertEq(workers.updater(), expectedUpdater);
        assertEq(workers.pendingUpdater(), expectedPending);
        for (uint256 i; i < 4; i++) {
            assertEq(payees[i].balance, paidTo[payees[i]]);
        }
    }

    function _leaf(uint256 id, uint256 actor, uint256 amount) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(abi.encode(id, payees[actor], amount))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _root(uint256 id, uint256 amount) internal view returns (bytes32) {
        return
            _pair(_pair(_leaf(id, 0, amount), _leaf(id, 1, amount)), _pair(_leaf(id, 2, amount), _leaf(id, 3, amount)));
    }

    function _proof(uint256 id, uint256 amount, uint256 actor) internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        proof[0] = _leaf(id, actor ^ 1, amount);
        uint256 other = actor < 2 ? 2 : 0;
        proof[1] = _pair(_leaf(id, other, amount), _leaf(id, other + 1, amount));
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract WorkerAccountingInvariantTest is StdInvariant, Test {
    WorkerAccountingHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        handler = new WorkerAccountingHandler();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.openEpoch.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.invalidClaim.selector;
        selectors[4] = handler.recycle.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.proposeUpdater.selector;
        selectors[7] = handler.acceptUpdater.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_workerFundsAndEveryEpochMatchIndependentLedger() public view {
        handler.assertAccounting();
    }

    function testHandlerExercisesClaimsOverlappingEpochsAndRecycledFunds() public {
        handler.claim(1, 0, 3);
        handler.donate(8 ether);
        handler.openEpoch(0, 3 days);
        handler.claim(2, 1, 0);
        handler.assertAccounting();
        assertEq(handler.paidOut(), 6 ether);
        assertEq(handler.workers().reservedForEpochs(), 18 ether);
        handler.advanceTime(8 days);
        handler.recycle(1, 2);
        handler.recycle(2, 3);
        handler.assertAccounting();
        assertEq(handler.pot(), 18 ether);
        handler.openEpoch(0, 1 days);
        for (uint256 i; i < 4; i++) {
            handler.claim(3, i, 3 - i);
        }
        handler.assertAccounting();
        assertEq(handler.paidOut(), 24 ether);
        assertEq(address(handler.workers()).balance, 0);
    }
}

contract AccountingRejector {
    receive() external payable {
        revert("reject payment");
    }
}

contract FeeKingAccountingHandler is Test {
    WorkerSubsidy public immutable workers;
    KingOfThePad public immutable king;
    FeeEscrow public immutable escrow;
    AccountingRejector public immutable rejector;
    address[4] public actors;
    uint256[4] public credit;
    uint256[4] public received;
    uint256 public feeDeposits;
    uint256 public withdrawals;
    uint256 public unassigned;
    uint256 public bids;
    uint256 public crowns;
    uint256 public expectedPrice = 0.01 ether;
    uint256 public firstIndex = 4;
    uint256 public currentIndex = 4;
    address public expectedKing;
    bool public recorderAllowed = true;

    constructor() {
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        escrow = new FeeEscrow(king, address(this));
        rejector = new AccountingRejector();
        escrow.authorizeRecorder(address(this), true);
        for (uint256 i; i < 4; i++) {
            actors[i] = address(uint160(0xDD00 + i));
        }
        vm.deal(address(this), 1e36);
        recordFee(0, 0, 101, 0);
    }

    function claimKing(uint256 actorSeed, uint256 beneficiarySeed, uint256 excess) public {
        uint256 beneficiary = beneficiarySeed % 4;
        address bidder = address(uint160(0xEE00 + actorSeed % 4));
        uint256 bid = expectedPrice + bound(excess, 1, 20 ether);
        vm.deal(bidder, bid);
        vm.prank(bidder);
        king.claimKing{value: bid}(actors[beneficiary]);
        bids += bid;
        if (crowns == 0) firstIndex = beneficiary;
        crowns++;
        currentIndex = beneficiary;
        expectedKing = bidder;
        expectedPrice += expectedPrice / 10;
    }

    function invalidKingBid(uint256 amountSeed, uint256 actorSeed) external {
        uint256 amount = bound(amountSeed, 0, expectedPrice);
        vm.expectRevert(KingOfThePad.BidTooLow.selector);
        king.claimKing{value: amount}(actors[actorSeed % 4]);
    }

    /// @dev Modes cover live beneficiary, captured beneficiary, pre-crown and aggregate delivery.
    function recordFee(uint256 creatorSeed, uint256 snapshotSeed, uint256 amount, uint256 modeSeed) public {
        uint256 creator = creatorSeed % 4;
        uint256 mode = modeSeed % 4;
        uint256 recipient = mode == 0 ? currentIndex : snapshotSeed % 5;
        amount = bound(amount, 0, 20 ether);
        uint256 kingShare = mode == 3 ? (amount / 5) * 2 : amount / 2;
        address captured = recipient == 4 ? address(0) : actors[recipient];
        if (!recorderAllowed) vm.expectRevert(FeeEscrow.NotAuthorized.selector);
        if (mode == 0) {
            escrow.recordTradeFeeNative{value: amount}(actors[creator], amount);
        } else if (mode == 1) {
            escrow.recordTradeFeeNativeFor{value: amount}(actors[creator], captured, amount);
        } else if (mode == 2) {
            recipient = currentIndex;
            escrow.recordTradeFee{value: amount}(actors[creator], address(0), amount);
        } else {
            escrow.recordTradeFeeNativeShares{value: amount}(actors[creator], captured, kingShare);
        }
        if (!recorderAllowed) return;
        feeDeposits += amount;
        credit[creator] += amount - kingShare;
        if (recipient == 4) recipient = firstIndex;
        if (recipient == 4) unassigned += kingShare;
        else credit[recipient] += kingShare;
    }

    function assignUnassigned(uint256 callerSeed) external {
        if (firstIndex == 4) vm.expectRevert(FeeEscrow.NoBeneficiary.selector);
        vm.prank(actors[callerSeed % 4]);
        escrow.assignUnassigned();
        if (firstIndex != 4) {
            credit[firstIndex] += unassigned;
            unassigned = 0;
        }
    }

    function withdraw(uint256 ownerSeed, uint256 recipientSeed, bool rejects) external {
        uint256 owner = ownerSeed % 4;
        uint256 recipient = recipientSeed % 4;
        vm.prank(actors[owner]);
        uint256 paid = escrow.withdraw(address(0), rejects ? address(rejector) : actors[recipient]);
        assertEq(paid, rejects ? 0 : credit[owner]);
        if (!rejects) {
            received[recipient] += credit[owner];
            withdrawals += credit[owner];
            credit[owner] = 0;
        }
    }

    function toggleRecorder() external {
        recorderAllowed = !recorderAllowed;
        escrow.authorizeRecorder(address(this), recorderAllowed);
    }

    function unauthorizedRecord(uint256 actorSeed, uint256 amount) external {
        address caller = address(uint160(0xFF00 + actorSeed % 4));
        amount = bound(amount, 0, 20 ether);
        vm.deal(caller, amount);
        vm.expectRevert(FeeEscrow.NotAuthorized.selector);
        vm.prank(caller);
        escrow.recordTradeFeeNative{value: amount}(actors[actorSeed % 4], amount);
    }

    function assertAccounting() external view {
        uint256 totalCredit;
        for (uint256 i; i < 4; i++) {
            totalCredit += credit[i];
            assertEq(escrow.pending(address(0), actors[i]), credit[i]);
            assertEq(actors[i].balance, received[i]);
        }
        assertEq(escrow.totalPendingEth(), totalCredit);
        assertEq(escrow.totalSkimmedEth(), feeDeposits);
        assertEq(escrow.totalWithdrawnEth(), withdrawals);
        assertEq(escrow.unassignedEth(), unassigned);
        assertEq(totalCredit + unassigned + withdrawals, feeDeposits);
        assertEq(address(escrow).balance, feeDeposits - withdrawals);
        assertEq(escrow.authorizedRecorders(address(this)), recorderAllowed);
        assertEq(king.claimCount(), crowns);
        assertEq(king.claimPrice(), expectedPrice);
        assertEq(king.king(), expectedKing);
        assertEq(king.beneficiary(), currentIndex == 4 ? address(0) : actors[currentIndex]);
        assertEq(king.firstBeneficiary(), firstIndex == 4 ? address(0) : actors[firstIndex]);
        assertEq(address(king).balance, 0);
        assertEq(address(workers).balance, bids);
        assertEq(workers.workerPot(), bids);
        assertEq(address(rejector).balance, 0);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract FeeKingAccountingInvariantTest is StdInvariant, Test {
    FeeKingAccountingHandler internal handler;

    function setUp() public {
        handler = new FeeKingAccountingHandler();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.claimKing.selector;
        selectors[1] = handler.invalidKingBid.selector;
        selectors[2] = handler.recordFee.selector;
        selectors[3] = handler.assignUnassigned.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.toggleRecorder.selector;
        selectors[6] = handler.unauthorizedRecord.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_feeEntitlementsAndKingBidsMatchIndependentLedger() public view {
        handler.assertAccounting();
    }

    function testHandlerExercisesPreCrownAndCapturedCreditsAcrossCrowns() public {
        handler.claimKing(0, 1, 1);
        handler.assignUnassigned(3);
        handler.recordFee(0, 1, 101, 1);
        handler.claimKing(2, 2, 1);
        handler.recordFee(0, 4, 100, 1);
        handler.assertAccounting();
        assertEq(handler.credit(1), 150);
        assertEq(handler.credit(2), 0);
        handler.withdraw(1, 3, true);
        handler.assertAccounting();
        assertEq(handler.credit(1), 150);
        handler.withdraw(1, 3, false);
        handler.withdraw(0, 2, false);
        handler.assertAccounting();
        assertEq(handler.withdrawals(), 302);
        assertEq(address(handler.escrow()).balance, 0);
    }
}
