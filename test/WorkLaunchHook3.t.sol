// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Work} from "../src/Work.sol";
import {WorkLaunchHook3} from "../src/WorkLaunchHook3.sol";
import {MineWorkHook} from "../script/MineWorkHook.s.sol";

import {WorkPoolFixture} from "./helpers/WorkPoolFixture.sol";

contract WorkLaunchHook3Test is WorkPoolFixture {
    function testCreate2AddressPermissionsAndImmutables() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x2044);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(work));
        assertEq(hook.IMD(), IMD);
        assertEq(hook.B(), TREASURY);
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.afterSwap = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(hook.feeNow(), 5000);
        assertEq(hook.standingFee(), 200);
    }

    function testConstructorRejectsIncorrectFlags() public {
        vm.expectRevert();
        new WorkLaunchHook3(manager, address(work));
    }

    function testConstructorRejectsIMDAndZeroToken() public {
        vm.expectRevert();
        new WorkLaunchHook3(manager, IMD);
        vm.expectRevert();
        new WorkLaunchHook3(manager, address(0));
    }

    function testSaltSearchExhaustion() public {
        vm.expectRevert(MineWorkHook.SaltNotFound.selector);
        miner.run(address(this), manager, address(work), 0, 0);
    }

    function testInitializationAcceptsBothTokenSortOrders() public {
        manager.initialize(key, INITIAL_PRICE);
        Work second;
        for (uint256 i; i < 100; ++i) {
            bytes32 initHash = keccak256(type(Work).creationCode);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash))))
            );
            if ((predicted < IMD) != (address(work) < IMD)) {
                second = new Work{salt: bytes32(i)}();
                break;
            }
        }
        assertGt(address(second).code.length, 0);
        WorkLaunchHook3 secondHook = _deployHook(address(second));
        PoolKey memory secondKey = _key(address(second), secondHook);
        manager.initialize(secondKey, INITIAL_PRICE);
        assertEq(secondHook.openedAt(), OPEN_TIME);
        assertTrue((Currency.unwrap(key.currency0) == IMD) != (Currency.unwrap(secondKey.currency0) == IMD));
    }

    function testInitializationByUnprivilegedCallerAndDuplicateRejected() public {
        vm.prank(stranger);
        manager.initialize(key, INITIAL_PRICE);
        assertEq(hook.openedAt(), OPEN_TIME);
        vm.expectRevert();
        manager.initialize(key, INITIAL_PRICE);
        // Even a direct second callback from the authenticated manager is rejected.
        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeInitialize(stranger, key, INITIAL_PRICE);
        assertEq(hook.openedAt(), OPEN_TIME);
    }

    function testRejectsWrongPairAndNativePair() public {
        Work unrelated = new Work();
        PoolKey memory bad = _key(address(unrelated), hook);
        vm.expectRevert();
        manager.initialize(bad, INITIAL_PRICE);
        bad = key;
        bad.currency0 = Currency.wrap(address(0));
        vm.expectRevert();
        manager.initialize(bad, INITIAL_PRICE);
        assertEq(hook.openedAt(), 0);
        _open();
    }

    function testRejectsWrongFeeIncludingDynamicFee() public {
        uint24[3] memory fees = [uint24(0), uint24(3000), uint24(0x800000)];
        for (uint256 i; i < fees.length; ++i) {
            PoolKey memory bad = key;
            bad.fee = fees[i];
            vm.expectRevert();
            manager.initialize(bad, INITIAL_PRICE);
        }
        assertEq(hook.openedAt(), 0);
        _open();
    }

    function testRejectsWrongSpacingAndHook() public {
        PoolKey memory bad = key;
        bad.tickSpacing = 30;
        vm.expectRevert();
        manager.initialize(bad, INITIAL_PRICE);
        bad = key;
        bad.hooks = IHooks(stranger);
        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeInitialize(stranger, bad, INITIAL_PRICE);
        assertEq(hook.openedAt(), 0);
    }

    function testAllCallbacksRejectNonManager() public {
        vm.expectRevert();
        hook.beforeInitialize(address(this), key, INITIAL_PRICE);
        IPoolManager.SwapParams memory params = _params(true, -1 ether);
        vm.expectRevert();
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert();
        hook.unlockCallback(abi.encode(IMD));
    }

    function testFeeScheduleAtBoundaries() public {
        _open();
        assertEq(hook.feeNow(), 5000);
        vm.warp(OPEN_TIME + 1);
        assertEq(hook.feeNow(), 4994);
        vm.warp(OPEN_TIME + 450);
        assertEq(hook.feeNow(), 2600);
        vm.warp(OPEN_TIME + 899);
        assertEq(hook.feeNow(), 205);
        vm.warp(OPEN_TIME + 900);
        assertEq(hook.feeNow(), 200);
        vm.warp(OPEN_TIME + 365 days);
        assertEq(hook.feeNow(), 200);
    }

    function testTreasuryCanOnlySetBoundedStandingFee() public {
        vm.prank(stranger);
        vm.expectRevert();
        hook.setStandingFee(100);
        vm.prank(TREASURY);
        vm.expectRevert();
        hook.setStandingFee(1001);
        assertEq(hook.standingFee(), 200);
        vm.expectEmit(false, false, false, true, address(hook));
        emit StandingFee(0);
        vm.prank(TREASURY);
        hook.setStandingFee(0);
        assertEq(hook.standingFee(), 0);
        assertEq(hook.feeNow(), 5000);
        _open();
        vm.warp(OPEN_TIME + 900);
        assertEq(hook.feeNow(), 0);
        vm.prank(TREASURY);
        hook.setStandingFee(1000);
        assertEq(hook.feeNow(), 1000);
    }

    function testStandingFeeUpdateChangesRampWithoutRestartingIt() public {
        _open();
        vm.warp(OPEN_TIME + 450);
        vm.prank(TREASURY);
        hook.setStandingFee(1000);
        assertEq(hook.feeNow(), 3000);
        assertEq(hook.openedAt(), OPEN_TIME);
        vm.prank(TREASURY);
        hook.setStandingFee(0);
        assertEq(hook.feeNow(), 2500);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFeeMonotonicallyDecays(uint16 standing, uint16 elapsed) public {
        standing = uint16(bound(standing, 0, 1000));
        elapsed = uint16(bound(elapsed, 0, 2000));
        vm.prank(TREASURY);
        hook.setStandingFee(standing);
        manager.initialize(key, INITIAL_PRICE);
        vm.warp(OPEN_TIME + elapsed);
        uint256 current = hook.feeNow();
        assertGe(current, standing);
        assertLe(current, 5000);
        vm.warp(OPEN_TIME + elapsed + 1);
        assertLe(hook.feeNow(), current);
        if (elapsed >= 900) assertEq(current, standing);
    }

    /// @dev Oracle uses actual pre-hook AMM events and actual token transfers.
    function _checkSwap(bool zeroForOne, bool exactInput, uint256 amount, uint160 limit) internal {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        Currency feeCurrency = exactInput ? output : input;
        uint256 claimsBefore = _claim(Currency.unwrap(feeCurrency));
        uint256 otherClaimsBefore = _claim(Currency.unwrap(exactInput ? input : output));
        uint256[4] memory beforeBalances = [
            input.balanceOf(address(this)),
            output.balanceOf(address(this)),
            input.balanceOf(address(manager)),
            output.balanceOf(address(manager))
        ];
        IPoolManager.SwapParams memory params = _params(zeroForOne, exactInput ? -int256(amount) : int256(amount));
        params.sqrtPriceLimitX96 = limit;
        vm.recordLogs();
        BalanceDelta delta = router.swap(key, params);
        (uint256 rawIn, uint256 rawOut) = _rawSwapAmounts(zeroForOne);
        uint256 paid = uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 received = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
        uint256 fee = _claim(Currency.unwrap(feeCurrency)) - claimsBefore;
        uint256 rate = hook.feeNow();
        if (exactInput) {
            assertEq(paid, rawIn);
            assertEq(fee + received, rawOut);
            assertEq(fee, rawOut * rate / 10_000);
            assertLe(paid, amount);
        } else {
            assertEq(received, rawOut);
            assertEq(paid, rawIn + fee);
            // floor rounding: fee is the requested share of total input paid, within one unit.
            assertLt(paid * rate - fee * 10_000, 10_000 - rate);
            assertLe(fee * 10_000, paid * rate);
            assertLe(received, amount);
        }
        uint256 specifiedActual = exactInput ? paid : received;
        if (limit == _params(zeroForOne, 1).sqrtPriceLimitX96) {
            assertEq(specifiedActual, amount, "full fill");
        } else {
            assertLt(specifiedActual, amount, "price limited partial fill");
        }
        assertEq(_claim(Currency.unwrap(exactInput ? input : output)), otherClaimsBefore);
        assertEq(beforeBalances[0] - input.balanceOf(address(this)), paid);
        assertEq(output.balanceOf(address(this)) - beforeBalances[1], received);
        assertEq(input.balanceOf(address(manager)) - beforeBalances[2], paid);
        assertEq(beforeBalances[3] - output.balanceOf(address(manager)), received);
        assertEq(input.balanceOf(address(hook)), 0);
        assertEq(output.balanceOf(address(hook)), 0);
        assertEq(address(manager).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(imd.balanceOf(TREASURY), 0);
        assertEq(work.balanceOf(TREASURY), 0);
    }

    function _rawSwapAmounts(bool zeroForOne) internal returns (uint256 rawIn, uint256 rawOut) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 raw0, int128 raw1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                rawIn = uint256(-int256(zeroForOne ? raw0 : raw1));
                rawOut = uint256(int256(zeroForOne ? raw1 : raw0));
                return (rawIn, rawOut);
            }
        }
        revert("real AMM swap event missing");
    }

    function _matrix(bool zeroForOne, bool exactInput) internal {
        _open();
        uint256[4] memory times = [uint256(0), uint256(450), uint256(899), uint256(900)];
        uint160 limit = _params(zeroForOne, 1).sqrtPriceLimitX96;
        for (uint256 i; i < times.length; ++i) {
            vm.warp(OPEN_TIME + times[i]);
            _checkSwap(zeroForOne, exactInput, 100 ether, limit);
        }
        vm.prank(TREASURY);
        hook.setStandingFee(0);
        _checkSwap(zeroForOne, exactInput, 100 ether, limit);
        vm.prank(TREASURY);
        hook.setStandingFee(1000);
        _checkSwap(zeroForOne, exactInput, 100 ether, limit);
    }

    function testZeroForOneExactInputFees() public {
        _matrix(true, true);
    }

    function testOneForZeroExactInputFees() public {
        _matrix(false, true);
    }

    function testZeroForOneExactOutputGrossUp() public {
        _matrix(true, false);
    }

    function testOneForZeroExactOutputGrossUp() public {
        _matrix(false, false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzRealSwaps(bool zeroForOne, bool exactInput, uint96 amount, uint16 elapsed, uint16 standing)
        public
    {
        _open();
        amount = uint96(bound(amount, 100, 10_000 ether));
        elapsed = uint16(bound(elapsed, 0, 2000));
        standing = uint16(bound(standing, 0, 1000));
        vm.prank(TREASURY);
        hook.setStandingFee(standing);
        vm.warp(OPEN_TIME + elapsed);
        _checkSwap(zeroForOne, exactInput, amount, _params(zeroForOne, 1).sqrtPriceLimitX96);
    }

    function testPriceLimitedPartialFillsInBothModesAndDirections() public {
        _open();
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            bool direction = i < 2;
            uint160 limit = TickMath.getSqrtPriceAtTick(direction ? int24(-60) : int24(60));
            _checkSwap(direction, i % 2 == 0, 100_000 ether, limit);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testDustExactInputRoundsFeeToZero() public {
        _open();
        vm.warp(OPEN_TIME + 900);
        _checkSwap(true, true, 10, _params(true, 1).sqrtPriceLimitX96);
        assertEq(_claim(IMD) + _claim(address(work)), 0);
    }

    function testInvalidSwapAndUnfundedSettlementRevertAtomically() public {
        _open();
        IPoolManager.SwapParams memory params = _params(true, 0);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(key, params);
        params = _params(true, -10 ether);
        vm.prank(stranger);
        vm.expectRevert();
        router.swap(key, params);
        assertEq(_claim(IMD) + _claim(address(work)), 0);
        _checkSwap(true, true, 10 ether, params.sqrtPriceLimitX96);
    }

    function testInvalidInitialPriceRollsBackLaunchTimestamp() public {
        vm.expectRevert();
        manager.initialize(key, 0);
        assertEq(hook.openedAt(), 0);
        assertEq(hook.feeNow(), 5000);
        _open();
    }

    function testUninitializedPoolCannotSwapOrAccrueClaims() public {
        IPoolManager.SwapParams memory params = _params(true, -1 ether);
        vm.expectRevert();
        router.swap(key, params);
        assertEq(hook.openedAt(), 0);
        assertEq(_claim(IMD) + _claim(address(work)), 0);
        _open();
        _checkSwap(true, true, 1 ether, params.sqrtPriceLimitX96);
    }

    function testEmptyLiquiditySwapsCannotCreateClaims() public {
        manager.initialize(key, INITIAL_PRICE);
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            BalanceDelta delta = router.swap(key, _params(i < 2, i % 2 == 0 ? -int256(1 ether) : int256(1 ether)));
            assertEq(BalanceDelta.unwrap(delta), 0);
            assertEq(_claim(IMD) + _claim(address(work)), 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testOneWeiSwapsInBothModesAndDirections() public {
        _open();
        for (uint256 i; i < 4; ++i) {
            _checkSwap(i < 2, i % 2 == 0, 1, _params(i < 2, 1).sqrtPriceLimitX96);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzRepeatedSwapRoundTripsCannotCreateTokens(
        bool direction,
        uint96 amount,
        uint8 cycles,
        uint16 standing
    ) public {
        _open();
        vm.warp(OPEN_TIME + 900);
        vm.prank(TREASURY);
        hook.setStandingFee(bound(standing, 0, 1000));
        amount = uint96(bound(amount, 100, 1000 ether));
        cycles = uint8(bound(cycles, 1, 8));
        Currency input = direction ? key.currency0 : key.currency1;
        Currency output = direction ? key.currency1 : key.currency0;
        for (uint256 i; i < cycles; ++i) {
            uint256 inputBefore = input.balanceOf(address(this));
            uint256 outputBefore = output.balanceOf(address(this));
            router.swap(key, _params(direction, -int256(uint256(amount))));
            uint256 received = output.balanceOf(address(this)) - outputBefore;
            assertGt(received, 0, "bounded round trip must execute both legs");
            router.swap(key, _params(!direction, -int256(received)));
            assertEq(output.balanceOf(address(this)), outputBefore);
            assertLt(input.balanceOf(address(this)), inputBefore, "round trip pays LP and hook fees");
        }
    }

    function _accrueBoth() internal {
        _open();
        router.swap(key, _params(true, -100 ether));
        router.swap(key, _params(false, -100 ether));
        assertGt(_claim(IMD), 0);
        assertGt(_claim(address(work)), 0);
    }

    function testPermissionlessSweepRedeemsBothClaimsAndDirectDonationsExactlyOnce() public {
        _accrueBoth();
        uint256 imdClaim = _claim(IMD);
        uint256 workClaim = _claim(address(work));
        imd.transfer(address(hook), 3 ether);
        work.transfer(address(hook), 7 ether);
        vm.prank(stranger);
        hook.sweep();
        assertEq(imd.balanceOf(TREASURY), imdClaim + 3 ether);
        assertEq(work.balanceOf(TREASURY), workClaim + 7 ether);
        assertEq(_claim(IMD) + _claim(address(work)), 0);
        assertEq(imd.balanceOf(address(hook)) + work.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(stranger) + work.balanceOf(stranger), 0);
        hook.sweep();
        assertEq(imd.balanceOf(TREASURY), imdClaim + 3 ether);
        assertEq(work.balanceOf(TREASURY), workClaim + 7 ether);
    }

    function testIMDClaimFailureKeepsClaimsAndStillSweepsWorkThenRetries() public {
        _accrueBoth();
        uint256 imdClaim = _claim(IMD);
        uint256 workClaim = _claim(address(work));
        imd.setTransferMode(2);
        vm.expectEmit(false, false, false, true, address(hook));
        emit SweepFailed(IMD);
        hook.sweep();
        assertEq(_claim(IMD), imdClaim);
        assertEq(_claim(address(work)), 0);
        assertEq(work.balanceOf(TREASURY), workClaim);
        assertEq(imd.balanceOf(TREASURY), 0);
        imd.setTransferMode(0);
        hook.sweep();
        assertEq(_claim(IMD), 0);
        assertEq(imd.balanceOf(TREASURY), imdClaim);
    }

    function testWorkClaimFailureDoesNotUndoIMDSweep() public {
        _accrueBoth();
        uint256 imdClaim = _claim(IMD);
        uint256 workClaim = _claim(address(work));
        vm.mockCall(address(work), abi.encodeCall(IERC20.transfer, (TREASURY, workClaim)), abi.encode(false));
        vm.expectEmit(false, false, false, true, address(hook));
        emit SweepFailed(address(work));
        hook.sweep();
        assertEq(_claim(IMD), 0);
        assertEq(imd.balanceOf(TREASURY), imdClaim);
        assertEq(_claim(address(work)), workClaim);
        assertEq(work.balanceOf(TREASURY), 0);
        vm.clearMockedCalls();
        hook.sweep();
        assertEq(work.balanceOf(TREASURY), workClaim);
        assertEq(_claim(address(work)), 0);
    }

    function testDirectTokenFalseAndRevertResponsesKeepOtherLegUsable() public {
        for (uint8 mode = 1; mode <= 2; ++mode) {
            uint256 snapshot = vm.snapshotState();
            imd.transfer(address(hook), 3 ether);
            work.transfer(address(hook), 7 ether);
            imd.setTransferMode(mode);
            vm.expectEmit(false, false, false, true, address(hook));
            emit SweepFailed(IMD);
            hook.sweep();
            assertEq(imd.balanceOf(address(hook)), 3 ether);
            assertEq(work.balanceOf(TREASURY), 7 ether);
            imd.setTransferMode(0);
            hook.sweep();
            assertEq(imd.balanceOf(TREASURY), 3 ether);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testNoReturnTokenTransfersSupportedForClaimsAndDirectBalances() public {
        _accrueBoth();
        uint256 imdClaim = _claim(IMD);
        imd.transfer(address(hook), 3 ether);
        imd.setTransferMode(3);
        hook.sweep();
        assertEq(imd.balanceOf(TREASURY), imdClaim + 3 ether);
        assertEq(_claim(IMD) + _claim(address(work)), 0);
    }

    function testSweepWhileManagerUnlockedPreservesClaimsButForwardsDirectBalances() public {
        _accrueBoth();
        uint256 imdClaim = _claim(IMD);
        uint256 workClaim = _claim(address(work));
        work.transfer(address(hook), 7 ether);
        vm.expectEmit(false, false, false, true, address(hook));
        emit SweepFailed(IMD);
        vm.expectEmit(false, false, false, true, address(hook));
        emit SweepFailed(address(work));
        router.sweepWhileUnlocked(key);
        assertEq(_claim(IMD), imdClaim);
        assertEq(_claim(address(work)), workClaim);
        assertEq(work.balanceOf(TREASURY), 7 ether);
        hook.sweep();
        assertEq(work.balanceOf(TREASURY), workClaim + 7 ether);
        assertEq(imd.balanceOf(TREASURY), imdClaim);
    }

    function testReentrantTokenCannotRedeemClaimsOrDirectBalancesTwice() public {
        _accrueBoth();
        uint256 imdClaim = _claim(IMD);
        uint256 workClaim = _claim(address(work));
        imd.transfer(address(hook), 3 ether);
        work.transfer(address(hook), 7 ether);
        imd.setReentryTarget(hook);
        hook.sweep();
        assertGt(imd.reentries(), 0);
        assertEq(imd.balanceOf(TREASURY), imdClaim + 3 ether);
        assertEq(work.balanceOf(TREASURY), workClaim + 7 ether);
        assertEq(_claim(IMD) + _claim(address(work)), 0);
        assertEq(imd.balanceOf(address(hook)) + work.balanceOf(address(hook)), 0);
    }

    function testEmptySweepAndNoNativeLeg() public {
        hook.sweep();
        vm.deal(address(hook), 1 ether);
        uint256 beforeBalance = TREASURY.balance;
        hook.sweep();
        assertEq(address(hook).balance, 1 ether);
        assertEq(TREASURY.balance, beforeBalance);
    }
}
