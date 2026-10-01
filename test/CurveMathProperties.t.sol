// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PvPadFactory} from "src/PvPadFactory.sol";
import {PvPadHook} from "src/hooks/PvPadHook.sol";
import {WorkerSubsidy} from "src/WorkerSubsidy.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {FeeEscrow} from "src/FeeEscrow.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {HookMiner} from "src/utils/HookMiner.sol";
import {PvPadConstants} from "src/libraries/PvPadConstants.sol";

/// @dev Stateless properties of the curve arithmetic on the real genesis launch, each from a random
/// prior fill: quotes equal execution, the cap is the smallest filling input, partial buys never reach
/// the threshold, fee-free dust cannot be round-tripped at a profit, later buyers never get a better
/// price, a holder can always exit the whole circulating supply, and graduation seeds the pool at the
/// curve's terminal price with wei-level dust. Known edges (zero, one wei, 99 wei, the exact cap, the
/// cap minus one) are pinned as plain unit tests beside the fuzzed ones.
/// forge-config: default.fuzz.runs = 512
contract CurveMathPropertiesTest is Test {
    uint256 internal constant THRESHOLD = PvPadConstants.GRADUATION_THRESHOLD;
    uint256 internal constant SUPPLY = PvPadConstants.TOKEN_SUPPLY;

    PvPadFactory factory;
    PoolManager manager;
    BondingCurve curve;
    IERC20 token;
    FeeEscrow escrow;
    address creator = address(0xC0FFEE);
    address trader = address(0xBEEF);
    address other = address(0xD00D);

    function setUp() public {
        manager = new PoolManager(address(this));
        WorkerSubsidy workers = new WorkerSubsidy(address(0xDEAD1));
        KingOfThePad king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        PvPadHook hook = new PvPadHook{salt: salt}(manager);
        factory = new PvPadFactory(manager, workers, king, hook, creator);
        escrow = factory.feeEscrow();
        (, address tokenAddress, address curveAddress,,) = factory.launches(0);
        curve = BondingCurve(payable(curveAddress));
        token = IERC20(tokenAddress);
        vm.deal(trader, 1_000 ether);
        vm.deal(other, 1_000 ether);
        vm.prank(trader);
        token.approve(address(curve), type(uint256).max);
        vm.prank(other);
        token.approve(address(curve), type(uint256).max);
    }

    /// @dev A prior gross input up to the threshold itself nets strictly less than the threshold, so
    /// the curve is never full after it.
    function _priorFill(uint256 seed) internal returns (uint256 prior) {
        prior = bound(seed, 0, THRESHOLD);
        if (prior == 0) return 0;
        vm.prank(other);
        curve.buy{value: prior}(other);
        assertFalse(curve.readyToGraduate(), "prior fill never completes the curve");
    }

    // ------------------------------------------------------------------ quotes equal execution

    function testFuzz_quoteBuyEqualsExecutionFromAnyPriorState(uint256 priorSeed, uint256 valueSeed) public {
        _priorFill(priorSeed);
        uint256 value = bound(valueSeed, 1, 10 ether);
        uint256 cap = curve.maxBuyInput();
        (uint256 quotedOut, uint256 quotedFee) = curve.quoteBuy(value);
        uint256 reserve = curve.ethReserve();
        uint256 before = trader.balance;
        vm.prank(trader);
        uint256 out = curve.buy{value: value}(trader, quotedOut, block.timestamp);
        uint256 paid = before - trader.balance;
        assertEq(out, quotedOut, "buy output equals the quote");
        assertEq(paid, value < cap ? value : cap, "gross input is the value or the cap");
        assertEq(paid / 100, quotedFee, "fee is one percent of the gross input");
        assertEq(curve.ethReserve() - reserve, paid - quotedFee, "net input enters the reserve");
        assertEq(token.balanceOf(trader), out);
    }

    function testFuzz_quoteSellEqualsExecutionFromAnyPriorState(uint256 priorSeed, uint256 amountSeed) public {
        uint256 prior = _priorFill(bound(priorSeed, 1, THRESHOLD));
        assertGt(prior, 0);
        uint256 held = token.balanceOf(other);
        uint256 amount = bound(amountSeed, 1, held);
        (uint256 quotedEth, uint256 quotedFee) = curve.quoteSell(amount);
        uint256 reserve = curve.ethReserve();
        if (quotedEth == 0) {
            vm.prank(other);
            vm.expectRevert(BondingCurve.InsufficientOutput.selector);
            curve.sell(amount, other);
            assertEq(curve.ethReserve(), reserve);
            assertEq(token.balanceOf(other), held);
            return;
        }
        uint256 before = other.balance;
        vm.prank(other);
        uint256 ethOut = curve.sell(amount, other, quotedEth, block.timestamp);
        assertEq(ethOut, quotedEth, "sell output equals the quote");
        assertEq(other.balance - before, ethOut);
        uint256 gross = reserve - curve.ethReserve();
        assertEq(gross / 100, quotedFee, "fee is one percent of the gross output");
        assertEq(gross - quotedFee, ethOut);
        assertEq(token.balanceOf(other), held - amount);
    }

    // ------------------------------------------------------------------ the cap

    function testFuzz_maxBuyInputIsTheSmallestGrossInputThatFillsTheCurve(uint256 priorSeed) public {
        _priorFill(priorSeed);
        uint256 cap = curve.maxBuyInput();
        uint256 remaining = THRESHOLD - curve.ethReserve();
        assertEq(cap - cap / 100, remaining, "the cap nets exactly the remaining distance");
        if (cap > 1) {
            uint256 before = trader.balance;
            vm.prank(trader);
            curve.buy{value: cap - 1}(trader);
            assertEq(before - trader.balance, cap - 1, "one wei under the cap is not refunded");
            assertEq(curve.ethReserve(), THRESHOLD - 1, "one wei under the cap lands one wei short");
            assertFalse(curve.readyToGraduate());
            assertEq(curve.maxBuyInput(), 1, "a single fee-free wei remains");
        }
        uint256 lastInput = curve.maxBuyInput();
        vm.prank(trader);
        curve.buy{value: lastInput}(trader);
        assertTrue(curve.readyToGraduate(), "the cap fills the curve exactly");
        assertEq(curve.ethReserve(), THRESHOLD);
        assertEq(curve.maxBuyInput(), 0);
        (uint256 quotedOut, uint256 quotedFee) = curve.quoteBuy(1 ether);
        assertEq(quotedOut + quotedFee, 0, "a full curve quotes nothing");
        (uint256 quotedEth,) = curve.quoteSell(1e18);
        assertEq(quotedEth, 0, "a full curve quotes no sale");
    }

    function testFuzz_everyInputBelowTheCapStaysStrictlyBelowTheThreshold(uint256 priorSeed, uint256 valueSeed) public {
        _priorFill(priorSeed);
        uint256 cap = curve.maxBuyInput();
        if (cap == 1) return; // nothing lies strictly between zero and the cap
        uint256 value = bound(valueSeed, 1, cap - 1);
        uint256 before = trader.balance;
        vm.prank(trader);
        curve.buy{value: value}(trader);
        assertEq(before - trader.balance, value, "no refund below the cap");
        assertLt(curve.ethReserve(), THRESHOLD);
        assertFalse(curve.readyToGraduate());
        assertGt(curve.maxBuyInput(), 0);
    }

    function testFuzz_excessOverTheCapIsRefundedToTheSenderNotTheRecipient(uint256 priorSeed, uint256 excessSeed)
        public
    {
        _priorFill(priorSeed);
        uint256 cap = curve.maxBuyInput();
        uint256 excess = bound(excessSeed, 1, 100 ether);
        address recipient = address(0x5EC1);
        uint256 before = trader.balance;
        vm.prank(trader);
        uint256 out = curve.buy{value: cap + excess}(recipient);
        assertEq(before - trader.balance, cap, "the sender pays only the cap");
        assertEq(recipient.balance, 0, "the recipient receives tokens, never ETH");
        assertEq(token.balanceOf(recipient), out);
        assertTrue(curve.readyToGraduate());
    }

    // ------------------------------------------------------------------ profit and price

    function testFuzz_feeFreeDustRoundTripNeverProfits(uint256 priorSeed, uint256 dustSeed) public {
        _priorFill(priorSeed);
        uint256 dust = bound(dustSeed, 1, 99);
        uint256 escrowBefore = address(escrow).balance;
        uint256 before = trader.balance;
        (, uint256 quotedFee) = curve.quoteBuy(dust);
        assertEq(quotedFee, 0, "below one hundred wei the fee rounds to zero");
        vm.prank(trader);
        uint256 out = curve.buy{value: dust}(trader);
        assertGt(out, 0);
        (uint256 quotedEth,) = curve.quoteSell(out);
        vm.prank(trader);
        if (quotedEth == 0) {
            vm.expectRevert(BondingCurve.InsufficientOutput.selector);
            curve.sell(out, trader);
        } else {
            curve.sell(out, trader);
        }
        assertLe(trader.balance, before, "a fee-free round trip never profits");
        assertLe(before - trader.balance, dust, "the trader cannot lose more than the dust");
        assertEq(address(escrow).balance, escrowBefore, "no fee was charged");
        assertEq(address(curve).balance, curve.ethReserve(), "no ETH is left outside the reserve");
    }

    function testFuzz_roundTripOfAnySizeNeverProfits(uint256 priorSeed, uint256 valueSeed) public {
        _priorFill(priorSeed);
        uint256 value = bound(valueSeed, 1, 5 ether);
        uint256 before = trader.balance;
        vm.prank(trader);
        uint256 out = curve.buy{value: value}(trader);
        if (curve.readyToGraduate()) {
            vm.prank(trader);
            vm.expectRevert(BondingCurve.NotReady.selector);
            curve.sell(out, trader);
            return;
        }
        (uint256 quotedEth,) = curve.quoteSell(out);
        vm.prank(trader);
        if (quotedEth == 0) vm.expectRevert(BondingCurve.InsufficientOutput.selector);
        curve.sell(out, trader);
        assertLe(trader.balance, before, "buying and selling back never profits");
    }

    function testFuzz_laterBuyersNeverGetABetterPrice(uint256 priorSeed, uint256 valueSeed) public {
        _priorFill(priorSeed);
        // At least 0.042 ETH of cap remains after any prior fill, so half of it is a valid range.
        uint256 value = bound(valueSeed, 1, curve.maxBuyInput() / 2);
        (uint256 first,) = curve.quoteBuy(value);
        vm.prank(trader);
        assertEq(curve.buy{value: value}(trader), first);
        (uint256 second,) = curve.quoteBuy(value);
        assertLe(second, first, "the same input buys no more after the price moved");
        if (value + 1 <= curve.maxBuyInput()) {
            (uint256 larger,) = curve.quoteBuy(value + 1);
            assertGe(larger, second, "quotes are monotone in the input");
        }
    }

    function testFuzz_marginalPriceNeverFallsBelowTheOpeningPrice(uint256 priorSeed) public {
        _priorFill(priorSeed);
        // Tokens per wei at the opening: x0 / y0 with virtual reserves only.
        uint256 openingTokensPerEth =
            FullMath.mulDiv(SUPPLY + PvPadConstants.VIRTUAL_TOKEN, 1 ether, PvPadConstants.VIRTUAL_ETH);
        (uint256 tokensForOneEth,) = curve.quoteBuy(1 ether);
        assertGt(tokensForOneEth, 0);
        assertLe(tokensForOneEth, openingTokensPerEth, "no state prices tokens cheaper than the opening");
    }

    // ------------------------------------------------------------------ exits and bounds

    function testFuzz_aHolderCanAlwaysExitTheWholeCirculatingSupply(uint256 priorSeed) public {
        uint256 prior = _priorFill(bound(priorSeed, 100, THRESHOLD));
        assertGt(prior, 0);
        uint256 circulating = SUPPLY - curve.tokenReserve();
        assertEq(token.balanceOf(other), circulating);
        uint256 reserve = curve.ethReserve();
        (uint256 quotedEth,) = curve.quoteSell(circulating);
        assertGt(quotedEth, 0);
        vm.prank(other);
        uint256 ethOut = curve.sell(circulating, other);
        assertEq(ethOut, quotedEth);
        assertLe(ethOut, reserve, "the exit never exceeds the reserve");
        assertEq(curve.tokenReserve(), SUPPLY, "every token is back on the curve");
        assertLe(curve.ethReserve(), 1, "at most one wei of rounding remains after a full exit");
        assertEq(address(curve).balance, curve.ethReserve());
    }

    function testFuzz_sellingMoreThanWasEverBoughtIsRejectedEvenWithTheBalance(uint256 priorSeed) public {
        _priorFill(bound(priorSeed, 1, THRESHOLD));
        uint256 circulating = SUPPLY - curve.tokenReserve();
        // Synthetic state: a balance larger than the circulating supply cannot arise through the curve.
        deal(address(token), other, circulating + 1);
        (uint256 quotedEth, uint256 quotedFee) = curve.quoteSell(circulating + 1);
        assertEq(quotedEth + quotedFee, 0, "an impossible sale quotes nothing");
        vm.prank(other);
        vm.expectRevert(BondingCurve.InsufficientLiquidity.selector);
        curve.sell(circulating + 1, other);
    }

    function testFuzz_slippageAndDeadlineGuardsRejectWithoutStateChange(uint256 priorSeed, uint256 valueSeed) public {
        _priorFill(priorSeed);
        uint256 value = bound(valueSeed, 1, 5 ether);
        (uint256 quotedOut,) = curve.quoteBuy(value);
        uint256 reserve = curve.ethReserve();
        uint256 tokenReserve = curve.tokenReserve();
        vm.startPrank(trader);
        vm.expectRevert(BondingCurve.InsufficientOutput.selector);
        curve.buy{value: value}(trader, quotedOut + 1, block.timestamp);
        vm.expectRevert(BondingCurve.DeadlineExpired.selector);
        curve.buy{value: value}(trader, quotedOut, block.timestamp - 1);
        vm.expectRevert(BondingCurve.ZeroAddress.selector);
        curve.buy{value: value}(address(0), quotedOut, block.timestamp);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.buy(trader, 0, block.timestamp);
        assertEq(curve.ethReserve(), reserve);
        assertEq(curve.tokenReserve(), tokenReserve);
        assertEq(token.balanceOf(trader), 0);
        uint256 out = curve.buy{value: value}(trader, quotedOut, block.timestamp);
        if (curve.readyToGraduate()) {
            vm.stopPrank();
            return;
        }
        (uint256 quotedEth,) = curve.quoteSell(out);
        if (quotedEth > 0) {
            vm.expectRevert(BondingCurve.InsufficientOutput.selector);
            curve.sell(out, trader, quotedEth + 1, block.timestamp);
        }
        vm.expectRevert(BondingCurve.DeadlineExpired.selector);
        curve.sell(out, trader, 0, block.timestamp - 1);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.sell(0, trader);
        vm.expectRevert(BondingCurve.ZeroAddress.selector);
        curve.sell(out, address(0));
        assertEq(token.balanceOf(trader), out, "rejected sells leave the tokens untouched");
        vm.stopPrank();
    }

    function testFuzz_sellWithoutApprovalOrBalanceRollsBackReserves(uint256 priorSeed, uint256 amountSeed) public {
        _priorFill(bound(priorSeed, 1, THRESHOLD));
        uint256 circulating = SUPPLY - curve.tokenReserve();
        uint256 amount = bound(amountSeed, 1, circulating);
        (uint256 quotedEth,) = curve.quoteSell(amount);
        if (quotedEth == 0) return;
        uint256 reserve = curve.ethReserve();
        uint256 tokenReserve = curve.tokenReserve();
        // The trader holds nothing: the token transfer fails after the reserves were updated in memory
        // of the call, and the whole trade must roll back.
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, trader, 0, amount));
        curve.sell(amount, trader);
        assertEq(curve.ethReserve(), reserve);
        assertEq(curve.tokenReserve(), tokenReserve);
        assertEq(address(curve).balance, reserve);
    }

    // ------------------------------------------------------------------ graduation seeding

    function testFuzz_graduationSeedsThePoolAtTheCurvePriceWithWeiLevelDust(uint256 a, uint256 b, uint256 c) public {
        uint256[3] memory parts = [bound(a, 1, 2 ether), bound(b, 1, 2 ether), bound(c, 1, 2 ether)];
        vm.startPrank(trader);
        for (uint256 i; i < 3 && !curve.readyToGraduate(); ++i) {
            curve.buy{value: parts[i]}(trader);
        }
        if (!curve.readyToGraduate()) curve.buy{value: 10 ether}(trader);
        vm.stopPrank();
        uint256 terminalTokens = curve.tokenReserve();
        assertGe(terminalTokens, SUPPLY / 4, "rounding leaves the pool share on the curve");
        assertLe(terminalTokens - SUPPLY / 4, 100, "the terminal reserve is the pool share up to rounding");
        // Terminal marginal price (ETH per token) equals the canonical pool price.
        uint256 canonicalPrice = uint256(factory.canonicalSqrtPriceX96());
        uint256 curveSqrtPrice = Math_sqrt(FullMath.mulDiv(terminalTokens, 1 << 192, THRESHOLD));
        assertApproxEqRel(curveSqrtPrice, canonicalPrice, 1e9, "pool opens at the curve's terminal price");
        PoolId poolId = factory.graduate(0);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(uint256(price), canonicalPrice);
        assertLe(address(factory).balance, 1e6, "ETH dust is at most a million wei");
        assertLe(token.balanceOf(address(factory)), 1e9, "token dust is at most a billion units");
        assertEq(
            address(manager).balance + address(factory).balance, THRESHOLD, "all swept ETH is pooled or locked dust"
        );
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(address(factory)), terminalTokens);
    }

    // ------------------------------------------------------------------ pinned edges

    function test_openingEdgesOneWeiAndNinetyNineWei() public {
        (uint256 oneOut, uint256 oneFee) = curve.quoteBuy(1);
        assertEq(oneFee, 0);
        assertGt(oneOut, 0, "one wei buys something at the opening");
        vm.prank(trader);
        assertEq(curve.buy{value: 1}(trader), oneOut);
        assertEq(curve.ethReserve(), 1);
        (uint256 ninetyNineOut, uint256 ninetyNineFee) = curve.quoteBuy(99);
        assertEq(ninetyNineFee, 0);
        (uint256 hundredOut, uint256 hundredFee) = curve.quoteBuy(100);
        assertEq(hundredFee, 1, "one hundred wei pays the first wei of fee");
        assertEq(hundredOut, ninetyNineOut, "the hundredth wei is the fee and buys nothing extra");
        (uint256 sellQuote,) = curve.quoteSell(1);
        assertEq(sellQuote, 0, "one token unit is worth no ETH");
        vm.prank(trader);
        vm.expectRevert(BondingCurve.InsufficientOutput.selector);
        curve.sell(1, trader);
    }

    function test_openingCapIsFourPointTwoFourEtherAndFillsExactly() public {
        uint256 cap = curve.maxBuyInput();
        assertEq(cap, THRESHOLD + (THRESHOLD - 1) / 99);
        vm.prank(trader);
        uint256 out = curve.buy{value: cap}(trader);
        assertEq(curve.ethReserve(), THRESHOLD);
        assertEq(curve.tokenReserve(), SUPPLY - out);
        assertApproxEqAbs(curve.tokenReserve(), SUPPLY / 4, 2, "the pool share stays on the curve");
        assertEq(address(escrow).balance, cap / 100, "the full fee reached the escrow");
        assertEq(address(curve).balance, THRESHOLD, "the curve holds exactly the threshold");
    }

    function Math_sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 y = x;
        z = (y + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
