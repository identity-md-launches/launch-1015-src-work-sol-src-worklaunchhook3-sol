// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WorkPoolFixture} from "./helpers/WorkPoolFixture.sol";
import {WorkLaunchHandler} from "./helpers/WorkLaunchHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract WorkLaunchInvariantTest is WorkPoolFixture {
    WorkLaunchHandler internal handler;
    address[3] internal actors;

    function setUp() public override {
        super.setUp();
        _open();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("invariant trader ", vm.toString(i)));
            work.transfer(actors[i], 10_000_000 ether);
            imd.transfer(actors[i], 10_000_000 ether);
        }
        handler = new WorkLaunchHandler(manager, work, imd, hook, router, key, actors);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.sweep.selector;
        selectors[3] = handler.sweepWhileUnlocked.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.setFee.selector;
        selectors[6] = handler.rejectFeeChange.selector;
        selectors[7] = handler.rejectReinitialization.selector;
        selectors[8] = handler.transfer.selector;
        selectors[9] = handler.approve.selector;
        selectors[10] = handler.transferFrom.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        // Seed nonzero obligations in BOTH currencies and all four swap modes.
        // The conservation property cannot pass solely because no fees accrued.
        handler.swap(0, true, true, 10 ether, false);
        handler.swap(1, true, false, 10 ether, false);
        handler.swap(2, false, true, 10 ether, false);
        handler.swap(0, false, false, 10 ether, false);
        handler.donate(1, true, 3 ether);
        handler.donate(2, false, 7 ether);
    }

    function invariantFeesAndDonationsAreConservedAndBacked() public view {
        _checkCurrency(IERC20(address(work)));
        _checkCurrency(IERC20(IMD));
        assertGt(handler.fees(address(work)), 0);
        assertGt(handler.fees(IMD), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0, "no native claims");
    }

    function _checkCurrency(IERC20 coin) internal view {
        uint256 outstanding = _claim(address(coin));
        assertEq(
            outstanding + coin.balanceOf(address(hook)) + coin.balanceOf(TREASURY),
            handler.fees(address(coin)) + handler.donations(address(coin)),
            "every fee and donation is pending or delivered exactly once"
        );
        assertGe(coin.balanceOf(address(manager)), outstanding, "claims backed by manager tokens");
        uint256 sum = coin.balanceOf(address(this)) + coin.balanceOf(address(manager)) + coin.balanceOf(address(hook))
            + coin.balanceOf(TREASURY);
        for (uint256 i; i < actors.length; ++i) {
            sum += coin.balanceOf(actors[i]);
        }
        assertEq(sum, 1_000_000_000 ether, "no tokens lost or created");
        assertEq(coin.totalSupply(), 1_000_000_000 ether);
        assertEq(coin.balanceOf(address(router)), 0);
        assertEq(coin.balanceOf(address(handler)), 0);
    }

    function invariantAdminAndLaunchStateRemainBounded() public view {
        assertEq(hook.openedAt(), OPEN_TIME, "launch cannot restart");
        assertEq(hook.standingFee(), handler.expectedStandingFee());
        assertLe(hook.standingFee(), 1000);
        assertGe(hook.feeNow(), hook.standingFee());
        assertLe(hook.feeNow(), 5000);
        if (block.timestamp >= OPEN_TIME + 900) assertEq(hook.feeNow(), hook.standingFee());
        assertEq(hook.B(), TREASURY);
        assertEq(hook.token(), address(work));
        assertEq(address(hook.poolManager()), address(manager));
    }

    function invariantWorkAllowancesFollowActorAuthorization() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(work.allowance(actors[i], actors[j]), handler.allowances(actors[i], actors[j]));
            }
        }
        assertEq(work.balanceOf(address(0)), 0);
    }

    /// @dev Liveness after every randomized sequence, including prior failed sweeps.
    function afterInvariant() public {
        handler.sweep(2, 0);
        assertEq(_claim(IMD), 0);
        assertEq(_claim(address(work)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(work.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(TREASURY), handler.fees(IMD) + handler.donations(IMD));
        assertEq(work.balanceOf(TREASURY), handler.fees(address(work)) + handler.donations(address(work)));
    }

    function testHandlerSequenceExercisesRecoveryAndAuthorization() public {
        handler.sweep(0, 1);
        handler.advanceTime(450);
        handler.setFee(1000);
        handler.rejectFeeChange(1, 0, false);
        handler.rejectFeeChange(2, type(uint256).max, true);
        handler.rejectReinitialization(1);
        handler.approve(0, 1, 10 ether, false);
        handler.transferFrom(0, 1, 2, 10 ether);
        handler.transfer(2, 0, 10 ether);
        handler.sweepWhileUnlocked(2);
        handler.swap(2, false, false, 1, true);
        handler.sweep(1, 2);
        handler.sweep(0, 3);
        invariantFeesAndDonationsAreConservedAndBacked();
        invariantAdminAndLaunchStateRemainBounded();
        invariantWorkAllowancesFollowActorAuthorization();
        for (uint256 i; i < 4; ++i) {
            assertGt(handler.swapCalls(i), 0);
        }
        assertEq(handler.sweepCalls(), 3);
        afterInvariant();
    }
}
