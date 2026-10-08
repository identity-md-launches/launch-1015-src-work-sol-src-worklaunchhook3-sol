// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Work} from "../src/Work.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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

    /// forge-config: default.fuzz.runs = 1000
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

    function testZeroOneAndFullSupplyTransfersAndSelfTransfers() public {
        address recipient = makeAddr("recipient");
        uint256 supply = work.totalSupply();
        work.transfer(recipient, 0);
        assertEq(work.balanceOf(recipient), 0);
        work.transfer(address(this), supply);
        assertEq(work.balanceOf(address(this)), supply);
        work.transfer(recipient, 1);
        assertEq(work.balanceOf(recipient), 1);
        work.transfer(recipient, supply - 1);
        assertEq(work.balanceOf(address(this)), 0);
        assertEq(work.balanceOf(recipient), supply);
        vm.prank(recipient);
        work.transfer(address(this), supply);
        assertEq(work.balanceOf(address(this)), supply);
        assertEq(work.totalSupply(), supply);
    }

    function testZeroRecipientAndSpenderRevertWithoutBurningSupply() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        work.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        work.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        work.approve(address(0), 1);
        assertEq(work.balanceOf(address(this)), 1_000_000_000 ether);
        assertEq(work.balanceOf(address(0)), 0);
        assertEq(work.totalSupply(), 1_000_000_000 ether);
    }

    function testUnlimitedApprovalOverwriteAndRevocation() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        work.approve(spender, type(uint256).max);
        vm.prank(spender);
        work.transferFrom(address(this), recipient, 1 ether);
        assertEq(work.allowance(address(this), spender), type(uint256).max);
        work.approve(spender, 3);
        vm.prank(spender);
        work.transferFrom(address(this), recipient, 3);
        assertEq(work.allowance(address(this), spender), 0);
        work.approve(spender, type(uint256).max);
        work.approve(spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        work.transferFrom(address(this), recipient, 1);
        assertEq(work.balanceOf(recipient), 1 ether + 3);
    }

    function testRevertingTransferFromRollsBackAllowanceSpending() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        uint256 tooMuch = work.totalSupply() + 1;
        work.approve(spender, tooMuch);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), work.totalSupply(), tooMuch
            )
        );
        vm.prank(spender);
        work.transferFrom(address(this), recipient, tooMuch);
        assertEq(work.allowance(address(this), spender), tooMuch);
        assertEq(work.balanceOf(recipient), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        work.transferFrom(address(this), address(0), 1);
        assertEq(work.allowance(address(this), spender), tooMuch);
        assertEq(work.balanceOf(address(this)), work.totalSupply());
    }

    function testMaximumTransferAndAbsentBurnCannotAlterFixedSupply() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), work.totalSupply(), type(uint256).max
            )
        );
        work.transfer(makeAddr("recipient"), type(uint256).max);
        (bool burned,) = address(work).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(burned);
        assertEq(work.totalSupply(), 1_000_000_000 ether);
        assertEq(work.balanceOf(address(this)), work.totalSupply());
    }
}
