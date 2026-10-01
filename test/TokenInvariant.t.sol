// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {PvPadToken} from "src/PvPadToken.sol";

/// @dev A closed set of holders allows a complete balance and allowance ledger.
/// Both token implementations are driven independently by the same ERC-20 operations.
contract TokenLedgerHandler is Test {
    uint256 public constant SUPPLY = 1e27;
    IERC20[2] public tokens;
    address[4] public actors;
    uint256[4][2] public balances;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public allowances;

    constructor() {
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(0x71000 + i));
        }
        vm.startPrank(actors[0]);
        tokens[0] = IERC20(address(new LaunchToken()));
        tokens[1] = IERC20(address(new PvPadToken("Ledger token", "LED")));
        vm.stopPrank();
        balances[0][0] = SUPPLY;
        balances[1][0] = SUPPLY;
    }

    function transfer(uint256 tokenSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        uint256 t = tokenSeed % 2;
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        amount = bound(amount, 0, balances[t][from]);
        vm.prank(actors[from]);
        assertTrue(tokens[t].transfer(actors[to], amount));
        balances[t][from] -= amount;
        balances[t][to] += amount;
    }

    function approve(uint256 tokenSeed, uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited)
        external
    {
        uint256 t = tokenSeed % 2;
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        amount = unlimited ? type(uint256).max : bound(amount, 0, SUPPLY);
        vm.prank(actors[owner]);
        assertTrue(tokens[t].approve(actors[spender], amount));
        allowances[t][owner][spender] = amount;
    }

    function transferFrom(uint256 tokenSeed, uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount)
        external
    {
        uint256 t = tokenSeed % 2;
        uint256 from = fromSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 to = toSeed % 4;
        uint256 allowed = allowances[t][from][spender];
        uint256 maximum = balances[t][from] < allowed ? balances[t][from] : allowed;
        amount = bound(amount, 0, maximum);
        vm.prank(actors[spender]);
        assertTrue(tokens[t].transferFrom(actors[from], actors[to], amount));
        balances[t][from] -= amount;
        balances[t][to] += amount;
        if (allowed != type(uint256).max) allowances[t][from][spender] -= amount;
    }

    function overspend(uint256 tokenSeed, uint256 fromSeed, uint256 toSeed) external {
        uint256 t = tokenSeed % 2;
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 balance = balances[t][from];
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actors[from], balance, balance + 1)
        );
        vm.prank(actors[from]);
        tokens[t].transfer(actors[to], balance + 1);
    }

    function exceedAllowance(uint256 tokenSeed, uint256 fromSeed, uint256 spenderSeed) external {
        uint256 t = tokenSeed % 2;
        uint256 from = fromSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 allowed = allowances[t][from][spender];
        // Infinite allowances have no representable larger input. The separate transfer
        // handler still exercises their balance limit and their non-decrementing semantics.
        if (allowed == type(uint256).max) return;
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], allowed, allowed + 1
            )
        );
        vm.prank(actors[spender]);
        tokens[t].transferFrom(actors[from], actors[spender], allowed + 1);
    }

    function rejectZeroRecipient(uint256 tokenSeed, uint256 fromSeed, uint256 amount) external {
        uint256 t = tokenSeed % 2;
        uint256 from = fromSeed % 4;
        amount = bound(amount, 0, balances[t][from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(actors[from]);
        tokens[t].transfer(address(0), amount);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TokenLedgerInvariantTest is Test {
    TokenLedgerHandler internal handler;

    function setUp() public {
        handler = new TokenLedgerHandler();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.overspend.selector;
        selectors[4] = handler.exceedAllowance.selector;
        selectors[5] = handler.rejectZeroRecipient.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyAndEveryHolderMatchesLedger() public view {
        for (uint256 t; t < 2; ++t) {
            IERC20 token = handler.tokens(t);
            uint256 sum;
            for (uint256 i; i < 4; ++i) {
                uint256 balance = token.balanceOf(handler.actors(i));
                assertEq(balance, handler.balances(t, i), "holder ledger diverged");
                sum += balance;
            }
            assertEq(sum, 1e27);
            assertEq(token.totalSupply(), 1e27);
            assertEq(token.balanceOf(address(0)), 0);
            assertEq(token.balanceOf(address(handler)), 0);
        }
    }

    function invariant_allAllowancesMatchApprovalsAndSpending() public view {
        for (uint256 t; t < 2; ++t) {
            for (uint256 owner; owner < 4; ++owner) {
                for (uint256 spender; spender < 4; ++spender) {
                    assertEq(
                        handler.tokens(t).allowance(handler.actors(owner), handler.actors(spender)),
                        handler.allowances(t, owner, spender),
                        "allowance ledger diverged"
                    );
                }
            }
        }
    }
}

contract TokenBoundaryTest is Test {
    IERC20[2] internal tokens;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        tokens[0] = IERC20(address(new LaunchToken()));
        tokens[1] = IERC20(address(new PvPadToken("Boundary", "BND")));
    }

    function test_fullSupplyOneWeiAndZeroTransfersIncludingSelf() public {
        for (uint256 t; t < 2; ++t) {
            IERC20 token = tokens[t];
            assertTrue(token.transfer(alice, 1e27));
            vm.startPrank(alice);
            assertTrue(token.transfer(alice, 1e27));
            assertTrue(token.transfer(bob, 0));
            assertEq(token.balanceOf(alice), 1e27);
            assertEq(token.balanceOf(bob), 0);
            assertTrue(token.transfer(bob, 1));
            assertTrue(token.transfer(bob, 1e27 - 1));
            vm.stopPrank();
            assertEq(token.balanceOf(alice), 0);
            assertEq(token.balanceOf(bob), 1e27);
            assertEq(token.totalSupply(), 1e27);
        }
    }

    function test_maxApprovalSurvivesSpendAndCanBeRevoked() public {
        for (uint256 t; t < 2; ++t) {
            IERC20 token = tokens[t];
            token.approve(alice, type(uint256).max);
            vm.prank(alice);
            token.transferFrom(address(this), bob, 1);
            assertEq(token.allowance(address(this), alice), type(uint256).max);
            token.approve(alice, 0);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
            vm.prank(alice);
            token.transferFrom(address(this), bob, 1);
            assertEq(token.balanceOf(bob), 1);
            assertEq(token.balanceOf(address(this)), 1e27 - 1);
        }
    }

    function test_failedTransferFromRestoresFiniteAllowance() public {
        for (uint256 t; t < 2; ++t) {
            IERC20 token = tokens[t];
            token.approve(alice, type(uint256).max - 1);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 1e27, 1e27 + 1)
            );
            vm.prank(alice);
            token.transferFrom(address(this), bob, 1e27 + 1);
            assertEq(token.allowance(address(this), alice), type(uint256).max - 1);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(alice);
            token.transferFrom(address(this), address(0), 1);
            assertEq(token.allowance(address(this), alice), type(uint256).max - 1);
            assertEq(token.balanceOf(address(this)), 1e27);
            assertEq(token.balanceOf(bob), 0);
        }
    }

    function test_zeroSpenderAndMaximumTransferRejected() public {
        for (uint256 t; t < 2; ++t) {
            IERC20 token = tokens[t];
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            token.approve(address(0), 0);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, address(this), 1e27, type(uint256).max
                )
            );
            token.transfer(bob, type(uint256).max);
            assertEq(token.balanceOf(address(this)), 1e27);
            assertEq(token.balanceOf(bob), 0);
            assertEq(token.totalSupply(), 1e27);
        }
    }
}
