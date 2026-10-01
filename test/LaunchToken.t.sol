// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_supplyAndExactTransfer() public {
        assertEq(token.name(), "Pepe Values Pepe");
        assertEq(token.symbol(), "PVP");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        token.transfer(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 100 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndFailureAtomicity() public {
        token.approve(alice, 20 ether);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 12 ether);
        assertEq(token.allowance(address(this), alice), 8 ether);
        assertEq(token.balanceOf(bob), 12 ether);
        vm.expectRevert();
        vm.prank(alice);
        token.transferFrom(address(this), bob, 9 ether);
        assertEq(token.balanceOf(bob), 12 ether);
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_noAdministrativeMintOrUpgradeSelectors() public {
        bytes4[5] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("initialize(address)"))
        ];
        for (uint256 i; i < selectors.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(address(this)), token.totalSupply());
    }
}
