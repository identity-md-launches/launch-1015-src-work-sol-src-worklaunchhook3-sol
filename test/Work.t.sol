// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Work} from "../src/Work.sol";

contract WorkTest is Test {
    Work internal work;

    function setUp() public {
        work = new Work();
    }

    function testMetadataAndEntireFixedSupplyToDeployer() public view {
        assertEq(work.name(), "Work");
        assertEq(work.symbol(), "WORK");
        assertEq(work.decimals(), 18);
        assertEq(work.totalSupply(), 1_000_000_000 ether);
        assertEq(work.balanceOf(address(this)), work.totalSupply());
    }

    function testFuzzTransferPreservesSupply(uint256 amount) public {
        amount = bound(amount, 0, work.totalSupply());
        address recipient = makeAddr("recipient");
        assertTrue(work.transfer(recipient, amount));
        assertEq(work.balanceOf(recipient), amount);
        assertEq(work.balanceOf(address(this)) + work.balanceOf(recipient), work.totalSupply());
        assertEq(work.totalSupply(), 1_000_000_000 ether);
    }

    function testAllowanceAndTransferFrom() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        work.approve(spender, 10 ether);
        vm.prank(spender);
        assertTrue(work.transferFrom(address(this), recipient, 3 ether));
        assertEq(work.allowance(address(this), spender), 7 ether);
        assertEq(work.balanceOf(recipient), 3 ether);
    }

    function testInsufficientBalanceAndAllowanceRevert() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        work.transfer(address(this), 1);
        vm.prank(stranger);
        vm.expectRevert();
        work.transferFrom(address(this), stranger, 1);
        assertEq(work.balanceOf(address(this)), work.totalSupply());
    }

    function testNoMintOwnerPauseOrUpgradeEntrypoints() public {
        (bool minted,) = address(work).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        (bool owned,) = address(work).call(abi.encodeWithSignature("owner()"));
        (bool paused,) = address(work).call(abi.encodeWithSignature("pause()"));
        (bool upgraded,) = address(work).call(abi.encodeWithSignature("upgradeTo(address)", address(this)));
        assertFalse(minted || owned || paused || upgraded);
        assertEq(work.totalSupply(), 1_000_000_000 ether);
    }
}
