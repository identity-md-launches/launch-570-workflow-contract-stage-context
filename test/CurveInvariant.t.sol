// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BondingCurve, IPvPadFactoryCurve} from "src/BondingCurve.sol";
import {PvPadToken} from "src/PvPadToken.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {WorkerSubsidy} from "src/WorkerSubsidy.sol";

/// @dev Uses the real fee contracts. Revoking the recorder simulates delivery failure without
/// replacing escrow code or changing balances. The fixture models only the factory's curve duties.
contract CurveInvariantFactory is IPvPadFactoryCurve {
    FeeEscrow public immutable feeEscrow;
    WorkerSubsidy public immutable workers;
    KingOfThePad public immutable king;
    BondingCurve public immutable curve;
    PvPadToken public immutable token;
    uint256 public constant graduationThreshold = 4.2 ether;

    constructor(address creator) {
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        feeEscrow = new FeeEscrow(king, address(this));
        token = new PvPadToken("Invariant curve", "ICV");
        curve = new BondingCurve(IERC20(address(token)), this, 0, creator, feeEscrow, king);
        token.transfer(address(curve), 1e27);
        setDelivery(true);
    }

    function setDelivery(bool enabled) public {
        feeEscrow.authorizeRecorder(address(curve), enabled);
    }

    function sweep() external returns (uint256, uint256) {
        return curve.sweepForGraduation();
    }

    receive() external payable {}
}

contract CurveRefundRejector {
    function buy(BondingCurve curve, address recipient, uint256 amount) external returns (uint256) {
        return curve.buy{value: amount}(recipient);
    }

    receive() external payable {
        revert("refund rejected");
    }
}

contract CurveSequenceHandler is Test {
    CurveInvariantFactory public immutable fixture;
    BondingCurve public immutable curve;
    PvPadToken public immutable token;
    FeeEscrow public immutable escrow;
    KingOfThePad public immutable king;
    address public immutable creator;
    address[4] public actors;

    uint256 public grossBuys;
    uint256 public netSells;
    uint256 public fees;
    uint256 public tokenDonations;
    uint256 public workerFunding;
    uint256 public sweptNative;
    uint256 public sweptTokens;
    uint256 public withdrawn;
    uint256 public unassigned;
    uint256 public lastProduct = (1e27 + 1e27 / 8) * 2.1 ether;
    uint256 public buys;
    uint256 public sells;
    bool public fundingComplete;
    uint256 public tokensAtCapacity;
    bool public terminal;
    mapping(address => uint256) public expectedPending;
    mapping(address => uint256) public expectedDeferred;
    mapping(address => uint256) public expectedKingShares;

    constructor(CurveInvariantFactory fixture_, address creator_) {
        fixture = fixture_;
        curve = fixture_.curve();
        token = fixture_.token();
        escrow = fixture_.feeEscrow();
        king = fixture_.king();
        creator = creator_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(0xA110 + i));
            vm.deal(actors[i], 1_000 ether);
            vm.prank(actors[i]);
            token.approve(address(curve), type(uint256).max);
        }
    }

    function buy(uint256 payerSeed, uint256 recipientSeed, uint256 valueSeed) public {
        address payer = actors[payerSeed % actors.length];
        address recipient = actors[recipientSeed % actors.length];
        if (terminal) {
            vm.prank(payer);
            vm.expectRevert(BondingCurve.Graduated.selector);
            curve.buy{value: 1}(recipient);
            return;
        }
        uint256 cap = curve.maxBuyInput();
        if (cap == 0) {
            vm.prank(payer);
            vm.expectRevert(BondingCurve.NotReady.selector);
            curve.buy{value: 1}(recipient);
            return;
        }
        // The cap must be the smallest input that fills exactly the missing net ETH.
        uint256 remaining = 4.2 ether - curve.ethReserve();
        assertEq(cap - cap / 100, remaining);
        assertLt((cap - 1) - (cap - 1) / 100, remaining);
        uint256 offered = bound(valueSeed, 1, 0.9 ether);
        uint256 accepted = offered > cap ? cap : offered;
        uint256 fee = accepted / 100;
        (uint256 quoted, uint256 quotedFee) = curve.quoteBuy(offered);
        assertEq(quotedFee, fee);
        uint256 beforeEth = payer.balance;
        uint256 beforeTokens = token.balanceOf(recipient);
        vm.prank(payer);
        uint256 received = curve.buy{value: offered}(recipient, quoted, block.timestamp);
        assertEq(received, quoted);
        assertGt(received, 0);
        assertEq(beforeEth - payer.balance, accepted, "cap must refund the payer");
        assertEq(token.balanceOf(recipient) - beforeTokens, received);
        grossBuys += accepted;
        ++buys;
        _captureFee(fee);
        // Derive the one-way funding transition from cash flows, independently of readiness.
        if (grossBuys == netSells + fees + 4.2 ether) {
            fundingComplete = true;
            tokensAtCapacity = curve.tokenReserve();
        }
        _checkProduct();
    }

    function sell(uint256 sellerSeed, uint256 recipientSeed, uint256 amountSeed) public {
        address seller = actors[sellerSeed % actors.length];
        address recipient = actors[recipientSeed % actors.length];
        if (terminal) {
            vm.prank(seller);
            vm.expectRevert(BondingCurve.Graduated.selector);
            curve.sell(1, recipient);
            return;
        }
        uint256 balance = token.balanceOf(seller);
        if (fundingComplete) {
            uint256 amount = balance == 0 ? 1 : bound(amountSeed, 1, balance);
            (uint256 quoted, uint256 quotedFee) = curve.quoteSell(amount);
            assertEq(quoted, 0);
            assertEq(quotedFee, 0);
            vm.prank(seller);
            vm.expectRevert(BondingCurve.NotReady.selector);
            curve.sell(amount, recipient);
            return;
        }
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        (uint256 quoted, uint256 quotedFee) = curve.quoteSell(amount);
        if (quoted == 0) {
            vm.prank(seller);
            vm.expectRevert(BondingCurve.InsufficientOutput.selector);
            curve.sell(amount, recipient);
            return;
        }
        uint256 beforeEth = recipient.balance;
        uint256 beforeReserve = curve.ethReserve();
        vm.prank(seller);
        uint256 received = curve.sell(amount, recipient, quoted, block.timestamp);
        uint256 gross = beforeReserve - curve.ethReserve();
        assertEq(quotedFee, gross / 100);
        assertEq(received, gross - gross / 100);
        assertEq(received, quoted);
        assertEq(recipient.balance - beforeEth, received);
        assertEq(token.balanceOf(seller), balance - amount);
        netSells += received;
        ++sells;
        _captureFee(gross / 100);
        _checkProduct();
    }

    function donate(uint256 actorSeed, uint256 ethSeed, uint256 tokenSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 ethAmount = bound(ethSeed, 0, 0.01 ether);
        uint256 tokens = bound(tokenSeed, 0, token.balanceOf(actor));
        uint256 beforeEthReserve = curve.ethReserve();
        uint256 beforeTokenReserve = curve.tokenReserve();
        uint256 beforeCurveBalance = address(curve).balance;
        uint256 beforeActorBalance = actor.balance;
        vm.startPrank(actor);
        // The curve has no receive(): a plain ETH transfer (even zero) is refused and nothing is locked.
        (bool ok,) = address(curve).call{value: ethAmount}("");
        assertFalse(ok, "plain ETH transfers to the curve are rejected");
        token.transfer(address(curve), tokens);
        vm.stopPrank();
        tokenDonations += tokens;
        assertEq(address(curve).balance, beforeCurveBalance);
        assertEq(actor.balance, beforeActorBalance);
        assertEq(curve.ethReserve(), beforeEthReserve, "donations do not buy curve capacity");
        assertEq(curve.tokenReserve(), beforeTokenReserve);
    }

    function setDelivery(bool enabled) public {
        fixture.setDelivery(enabled);
    }

    function claimCrown(uint256 payerSeed, uint256 beneficiarySeed) public {
        address payer = actors[payerSeed % actors.length];
        address beneficiary = actors[beneficiarySeed % actors.length];
        uint256 bid = king.claimPrice() + 1;
        // At depth 64 even an all-crown sequence remains within this funded actor set.
        vm.prank(payer);
        king.claimKing{value: bid}(beneficiary);
        workerFunding += bid;
        assertEq(king.beneficiary(), beneficiary);
    }

    function flush(uint256 beneficiarySeed) public {
        address beneficiary = beneficiarySeed % 5 == 4 ? address(0) : actors[beneficiarySeed % 4];
        uint256 amount = expectedDeferred[beneficiary];
        uint256 share = expectedKingShares[beneficiary];
        bool enabled = escrow.authorizedRecorders(address(curve));
        bool succeeded = curve.flushDeferredFees(beneficiary);
        assertEq(succeeded, amount == 0 || enabled);
        if (amount != 0 && enabled) {
            expectedDeferred[beneficiary] = 0;
            expectedKingShares[beneficiary] = 0;
            _credit(beneficiary, amount, share);
        }
    }

    function assignUnassigned() public {
        address first = king.firstBeneficiary();
        if (first == address(0)) {
            vm.expectRevert(FeeEscrow.NoBeneficiary.selector);
            escrow.assignUnassigned();
            return;
        }
        expectedPending[first] += unassigned;
        unassigned = 0;
        escrow.assignUnassigned();
    }

    function withdraw(uint256 accountSeed, uint256 recipientSeed) public {
        address account = accountSeed % 5 == 4 ? creator : actors[accountSeed % 4];
        address recipient = actors[recipientSeed % actors.length];
        uint256 amount = expectedPending[account];
        uint256 beforeEth = recipient.balance;
        vm.prank(account);
        assertEq(escrow.withdraw(address(0), recipient), amount);
        assertEq(recipient.balance - beforeEth, amount);
        expectedPending[account] = 0;
        withdrawn += amount;
    }

    function graduate(uint256 seed) public {
        if (terminal) {
            vm.expectRevert(BondingCurve.Graduated.selector);
            fixture.sweep();
            return;
        }
        if (!curve.readyToGraduate()) {
            if (seed % 16 > 1) {
                vm.expectRevert(BondingCurve.NotReady.selector);
                fixture.sweep();
                return;
            }
            // Occasionally complete funding so random campaigns exercise both lifecycle states.
            // Each top-up uses the same checked buy path, including the cap refund and fee model.
            while (!curve.readyToGraduate()) buy(seed, seed, 0.9 ether);
        }
        // Keep some fully funded curves unswept so subsequent calls exercise the trading lock.
        if (seed % 4 != 0) return;
        uint256 tokens = curve.tokenReserve();
        (uint256 nativeSwept, uint256 tokensSwept) = fixture.sweep();
        assertEq(nativeSwept, 4.2 ether);
        assertEq(tokensSwept, tokens);
        sweptNative = nativeSwept;
        sweptTokens = tokensSwept;
        terminal = true;
    }

    function _captureFee(uint256 fee) internal {
        fees += fee;
        address beneficiary = king.beneficiary();
        if (escrow.authorizedRecorders(address(curve))) {
            _credit(beneficiary, fee, fee / 2);
        } else {
            expectedDeferred[beneficiary] += fee;
            expectedKingShares[beneficiary] += fee / 2;
        }
    }

    function _credit(address beneficiary, uint256 fee, uint256 share) internal {
        expectedPending[creator] += fee - share;
        if (beneficiary == address(0)) beneficiary = king.firstBeneficiary();
        if (beneficiary == address(0)) unassigned += share;
        else expectedPending[beneficiary] += share;
    }

    function _checkProduct() internal {
        uint256 product = (curve.tokenReserve() + 1e27 / 8) * (curve.ethReserve() + 2.1 ether);
        assertGe(product, lastProduct, "rounding must never decrease reserve product");
        lastProduct = product;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract CurveInvariantTest is Test {
    CurveInvariantFactory fixture;
    CurveSequenceHandler handler;
    BondingCurve curve;
    PvPadToken token;
    FeeEscrow escrow;
    address constant CREATOR = address(0xC0FEE);

    function setUp() public {
        fixture = new CurveInvariantFactory(CREATOR);
        curve = fixture.curve();
        token = fixture.token();
        escrow = fixture.feeEscrow();
        handler = new CurveSequenceHandler(fixture, CREATOR);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.setDelivery.selector;
        selectors[4] = handler.claimCrown.selector;
        selectors[5] = handler.flush.selector;
        selectors[6] = handler.assignUnassigned.selector;
        selectors[7] = handler.withdraw.selector;
        selectors[8] = handler.graduate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// SPEC conservation: actual reserves exclude token donations and deferred fee liabilities; the
    /// curve's ETH balance is exactly its reserves plus deferred fees because plain transfers are refused.
    function invariant_curveReservesEqualIndependentCashFlows() public view {
        assertEq(handler.grossBuys(), handler.netSells() + handler.fees() + curve.ethReserve() + handler.sweptNative());
        assertEq(address(curve).balance, curve.ethReserve() + curve.totalDeferredFees());
        assertEq(token.balanceOf(address(curve)), curve.tokenReserve() + handler.tokenDonations());
        assertLe(curve.ethReserve(), 4.2 ether);
        assertEq(curve.readyToGraduate(), handler.fundingComplete() && !handler.terminal());
        if (handler.fundingComplete() && !handler.terminal()) {
            assertEq(curve.ethReserve(), 4.2 ether, "a funded curve cannot lose graduation readiness");
            assertEq(curve.tokenReserve(), handler.tokensAtCapacity());
            assertEq(curve.maxBuyInput(), 0);
        }
    }

    /// Every captured fee has exactly one destination, including individual odd-wei rounding.
    function invariant_everyFeeIsBackedAndBelongsToItsCapturedBeneficiary() public view {
        uint256 pending = handler.expectedPending(CREATOR);
        uint256 deferred = handler.expectedDeferred(address(0));
        assertEq(escrow.pending(address(0), CREATOR), pending);
        assertEq(curve.deferredFees(address(0)), deferred);
        assertEq(curve.deferredKingShares(address(0)), handler.expectedKingShares(address(0)));
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 owed = handler.expectedPending(actor);
            pending += owed;
            deferred += handler.expectedDeferred(actor);
            assertEq(escrow.pending(address(0), actor), owed);
            assertEq(curve.deferredFees(actor), handler.expectedDeferred(actor));
            assertEq(curve.deferredKingShares(actor), handler.expectedKingShares(actor));
        }
        assertEq(curve.totalDeferredFees(), deferred);
        assertEq(escrow.totalPendingEth(), pending);
        assertEq(escrow.unassignedEth(), handler.unassigned());
        assertEq(escrow.totalWithdrawnEth(), handler.withdrawn());
        assertEq(address(escrow).balance, pending + handler.unassigned());
        assertEq(handler.fees(), pending + handler.unassigned() + handler.withdrawn() + deferred);
        assertEq(escrow.totalSkimmedEth() + deferred, handler.fees());
    }

    /// Closed-world asset accounting detects phantom minting, missing refunds, or excess payouts.
    function invariant_supplyAndNativeAssetsAreConserved() public view {
        uint256 tokens = token.balanceOf(address(curve)) + token.balanceOf(address(fixture));
        uint256 native = address(curve).balance + address(escrow).balance + address(fixture).balance
            + address(fixture.workers()).balance;
        for (uint256 i; i < 4; ++i) {
            tokens += token.balanceOf(handler.actors(i));
            native += handler.actors(i).balance;
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(tokens, 1e27);
        assertEq(native, 4_000 ether);
        assertEq(fixture.workers().workerPot(), handler.workerFunding());
        assertEq(address(fixture.workers()).balance, handler.workerFunding());
    }

    function invariant_graduationIsTerminalAndOnlySweepsTradingReserves() public view {
        assertEq(curve.graduated(), handler.terminal());
        assertEq(address(fixture).balance, handler.sweptNative());
        assertEq(token.balanceOf(address(fixture)), handler.sweptTokens());
        if (handler.terminal()) {
            assertEq(curve.ethReserve(), 0);
            assertEq(curve.tokenReserve(), 0);
            assertEq(curve.maxBuyInput(), 0);
            (uint256 bought, uint256 buyFee) = curve.quoteBuy(type(uint256).max);
            (uint256 sold, uint256 sellFee) = curve.quoteSell(type(uint256).max);
            assertEq(bought + buyFee + sold + sellFee, 0);
        }
    }

    /// A deterministic sequence proves the handler reaches deferred, retry, and terminal states.
    function test_handlerExercisesDeferredRoundingCrownChangesAndGraduation() public {
        handler.setDelivery(false);
        handler.buy(0, 1, 300);
        handler.buy(0, 1, 300);
        handler.flush(4);
        handler.claimCrown(0, 2);
        handler.claimCrown(0, 3);
        handler.setDelivery(true);
        handler.flush(4);
        assertEq(escrow.pending(address(0), handler.actors(2)), 2);
        assertEq(escrow.pending(address(0), handler.actors(3)), 0);
        handler.sell(1, 2, type(uint256).max);
        handler.setDelivery(false);
        for (uint256 i; i < 5; ++i) {
            handler.buy(i, i, 0.9 ether);
        }
        handler.donate(1, 17, 19);
        handler.graduate(0);
        assertTrue(handler.terminal());
        handler.buy(0, 0, 1);
        handler.sell(0, 0, 1);
        handler.graduate(0);
        handler.setDelivery(true);
        handler.flush(3);
        handler.assignUnassigned();
        handler.withdraw(4, 0);
        handler.withdraw(2, 1);
        handler.withdraw(3, 2);
        assertGt(handler.buys(), 0);
        assertGt(handler.sells(), 0);
        invariant_curveReservesEqualIndependentCashFlows();
        invariant_everyFeeIsBackedAndBelongsToItsCapturedBeneficiary();
        invariant_supplyAndNativeAssetsAreConserved();
        invariant_graduationIsTerminalAndOnlySweepsTradingReserves();
    }

    function test_handlerExercisesFundedTradingLockBeforeSweep() public {
        handler.setDelivery(false);
        handler.graduate(1); // Fill the curve, deliberately defer the reserve sweep.
        assertTrue(handler.fundingComplete());
        assertFalse(handler.terminal());
        assertTrue(curve.readyToGraduate());
        assertGt(curve.totalDeferredFees(), 0);
        handler.sell(1, 2, 1);
        handler.sell(1, 2, 5_892_857_143); // Previously sufficient to remove 99 wei of reserves.
        handler.sell(1, 2, token.balanceOf(handler.actors(1)));
        handler.buy(1, 2, 1);
        handler.donate(1, 17, 19);
        handler.claimCrown(0, 2);
        handler.flush(4); // Failed delivery must preserve readiness and the fee liability.
        handler.setDelivery(true);
        handler.flush(4);
        invariant_curveReservesEqualIndependentCashFlows();
        invariant_everyFeeIsBackedAndBelongsToItsCapturedBeneficiary();
        invariant_supplyAndNativeAssetsAreConserved();
        handler.graduate(0);
        assertTrue(handler.terminal());
        invariant_curveReservesEqualIndependentCashFlows();
        invariant_everyFeeIsBackedAndBelongsToItsCapturedBeneficiary();
        invariant_supplyAndNativeAssetsAreConserved();
        invariant_graduationIsTerminalAndOnlySweepsTradingReserves();
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_fundedCurveRejectsBothSellOverloadsAtomically(uint256 amountSeed, bool protectedOverload) public {
        handler.graduate(1);
        address seller = handler.actors(1);
        address recipient = handler.actors(2);
        uint256 tokensBefore = token.balanceOf(seller);
        uint256 amount = bound(amountSeed, 1, tokensBefore);
        uint256 recipientBefore = recipient.balance;
        vm.prank(seller);
        token.approve(address(curve), amount);
        uint256 allowanceBefore = token.allowance(seller, address(curve));
        (uint256 quoted, uint256 fee) = curve.quoteSell(amount);
        assertEq(quoted, 0);
        assertEq(fee, 0);
        vm.prank(seller);
        vm.expectRevert(BondingCurve.NotReady.selector);
        if (protectedOverload) curve.sell(amount, recipient, 0, block.timestamp);
        else curve.sell(amount, recipient);
        assertEq(token.balanceOf(seller), tokensBefore);
        assertEq(token.allowance(seller, address(curve)), allowanceBefore);
        assertEq(recipient.balance, recipientBefore);
        invariant_curveReservesEqualIndependentCashFlows();
        invariant_everyFeeIsBackedAndBelongsToItsCapturedBeneficiary();
        invariant_supplyAndNativeAssetsAreConserved();
        handler.graduate(0);
        assertTrue(handler.terminal());
        invariant_graduationIsTerminalAndOnlySweepsTradingReserves();
    }

    function test_feeRoundingAtOneWeiAndHundredWeiBoundaries() public {
        handler.claimCrown(0, 1);
        handler.setDelivery(false);
        uint256[8] memory inputs = [uint256(1), 99, 100, 101, 199, 200, 299, 300];
        for (uint256 i; i < inputs.length; ++i) {
            handler.buy(0, 0, inputs[i]);
        }
        assertEq(curve.ethReserve(), 1289);
        assertEq(curve.totalDeferredFees(), 10);
        assertEq(curve.deferredKingShares(handler.actors(1)), 3);
        handler.setDelivery(true);
        handler.flush(1);
        assertEq(escrow.pending(address(0), CREATOR), 7);
        assertEq(escrow.pending(address(0), handler.actors(1)), 3);
        invariant_curveReservesEqualIndependentCashFlows();
        invariant_everyFeeIsBackedAndBelongsToItsCapturedBeneficiary();
        invariant_supplyAndNativeAssetsAreConserved();
    }

    function test_rejectedCapRefundRollsBackTokensReservesAndDeferredFees() public {
        CurveRefundRejector buyer = new CurveRefundRejector();
        vm.deal(address(buyer), 5 ether);
        handler.setDelivery(false);
        address recipient = handler.actors(0);
        vm.expectRevert(BondingCurve.NativeTransferFailed.selector);
        buyer.buy(curve, recipient, 5 ether);
        assertEq(address(buyer).balance, 5 ether);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(curve)), 1e27);
        assertEq(curve.ethReserve(), 0);
        assertEq(curve.tokenReserve(), 1e27);
        assertEq(curve.totalDeferredFees(), 0);
        assertEq(curve.deferredFees(address(0)), 0);
        assertEq(curve.deferredKingShares(address(0)), 0);
        assertEq(address(curve).balance, 0);
        assertEq(escrow.totalSkimmedEth(), 0);

        // The same buyer can fill the curve exactly because no refund is needed.
        uint256 cap = curve.maxBuyInput();
        uint256 bought = buyer.buy(curve, recipient, cap);
        assertGt(bought, 0);
        assertEq(token.balanceOf(recipient), bought);
        assertEq(address(buyer).balance, 5 ether - cap);
        assertTrue(curve.readyToGraduate());
        assertEq(curve.totalDeferredFees(), cap / 100);
        assertEq(address(curve).balance, 4.2 ether + cap / 100);
    }
}
