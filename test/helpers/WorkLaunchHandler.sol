// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Work} from "../../src/Work.sol";
import {WorkLaunchHook3} from "../../src/WorkLaunchHook3.sol";
import {MockIMD} from "./MockIMD.sol";
import {TestRouter} from "./TestRouter.sol";

/// @dev All transfers stay inside the tracked actor/manager/hook/treasury universe.
/// Ghost fees come from the AMM's pre-hook event versus actual trader transfers,
/// never from the claim balance being checked by the invariant.
contract WorkLaunchHandler is Test {
    bytes32 private constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    IPoolManager public immutable manager;
    Work public immutable work;
    MockIMD public immutable imd;
    WorkLaunchHook3 public immutable hook;
    TestRouter public immutable router;
    address public immutable treasury;
    PoolKey private key;
    address[3] public actors;
    mapping(address => uint256) public fees;
    mapping(address => uint256) public donations;
    mapping(address => mapping(address => uint256)) public allowances;
    uint256 public expectedStandingFee = 200;
    uint256[4] public swapCalls;
    uint256 public sweepCalls;

    constructor(
        IPoolManager m,
        Work w,
        MockIMD i,
        WorkLaunchHook3 h,
        TestRouter r,
        PoolKey memory k,
        address[3] memory a
    ) {
        manager = m;
        work = w;
        imd = i;
        hook = h;
        router = r;
        treasury = h.B();
        key = k;
        actors = a;
        for (uint256 n; n < a.length; ++n) {
            vm.startPrank(a[n]);
            w.approve(address(r), type(uint256).max);
            i.approve(address(r), type(uint256).max);
            vm.stopPrank();
        }
    }

    function swap(uint256 actorSeed, bool zeroForOne, bool exactInput, uint256 amount, bool dust) public {
        address actor = actors[actorSeed % actors.length];
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        // At most 100 tokens per swap, versus >290,000 of each in seeded liquidity.
        // Even 96 consecutive one-way swaps remain inside the active tick range.
        amount = bound(amount, 1, dust ? 100 : 100 ether);
        uint256 inBefore = input.balanceOf(actor);
        uint256 outBefore = output.balanceOf(actor);
        uint256 managerIn = input.balanceOf(address(manager));
        uint256 managerOut = output.balanceOf(address(manager));
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        vm.recordLogs();
        vm.prank(actor);
        BalanceDelta delta = router.swap(key, params);
        (uint256 rawIn, uint256 rawOut) = _rawAmounts(zeroForOne);
        uint256 paid = inBefore - input.balanceOf(actor);
        uint256 received = output.balanceOf(actor) - outBefore;
        assertEq(paid, uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1())));
        assertEq(received, uint256(int256(zeroForOne ? delta.amount1() : delta.amount0())));
        assertEq(input.balanceOf(address(manager)) - managerIn, paid);
        assertEq(managerOut - output.balanceOf(address(manager)), received);
        uint256 fee;
        uint256 rate = hook.feeNow();
        if (exactInput) {
            assertEq(paid, amount, "exact input fully filled");
            assertEq(paid, rawIn);
            fee = rawOut - received;
            // The observed fee must be the advertised share of gross output,
            // with less than one token base unit lost to integer rounding.
            assertLe(fee * 10_000, rawOut * rate);
            assertLt(rawOut * rate - fee * 10_000, 10_000);
            fees[Currency.unwrap(output)] += fee;
        } else {
            assertEq(received, amount, "exact output fully filled");
            assertEq(received, rawOut);
            fee = paid - rawIn;
            assertLe(fee * 10_000, paid * rate);
            assertLt(paid * rate - fee * 10_000, 10_000 - rate, "grossed-up fee rounding");
            fees[Currency.unwrap(input)] += fee;
        }
        ++swapCalls[(zeroForOne ? 0 : 2) + (exactInput ? 0 : 1)];
    }

    function donate(uint256 actorSeed, bool isWork, uint256 amount) public {
        address actor = actors[actorSeed % actors.length];
        IERC20 coin = IERC20(isWork ? address(work) : address(imd));
        amount = bound(amount, 0, 100 ether);
        vm.prank(actor);
        assertTrue(coin.transfer(address(hook), amount));
        donations[address(coin)] += amount;
    }

    /// @dev Faults are transient and confined to this call, so later trades can run.
    /// Malformed transfer data and reverting balanceOf are separate reported findings;
    /// they are deliberately not blessed here with an expected whole-sweep revert.
    function sweep(uint256 actorSeed, uint8 mode) public {
        mode = uint8(bound(mode, 0, 3)); // standard / false / revert / no return
        uint256 imdClaim = _claim(address(imd));
        uint256 workClaim = _claim(address(work));
        uint256 imdDirect = imd.balanceOf(address(hook));
        uint256 workDirect = work.balanceOf(address(hook));
        uint256 imdTreasury = imd.balanceOf(treasury);
        uint256 workTreasury = work.balanceOf(treasury);
        imd.setTransferMode(mode);
        vm.prank(actors[actorSeed % actors.length]);
        hook.sweep();
        imd.setTransferMode(0);
        assertEq(_claim(address(work)), 0);
        assertEq(work.balanceOf(address(hook)), 0);
        assertEq(work.balanceOf(treasury) - workTreasury, workClaim + workDirect);
        if (mode == 1 || mode == 2) {
            assertEq(_claim(address(imd)), imdClaim, "failed burn rolls back");
            assertEq(imd.balanceOf(address(hook)), imdDirect);
            assertEq(imd.balanceOf(treasury), imdTreasury);
        } else {
            assertEq(_claim(address(imd)), 0);
            assertEq(imd.balanceOf(address(hook)), 0);
            assertEq(imd.balanceOf(treasury) - imdTreasury, imdClaim + imdDirect);
        }
        ++sweepCalls;
    }

    function sweepWhileUnlocked(uint256 actorSeed) public {
        uint256 imdClaim = _claim(address(imd));
        uint256 workClaim = _claim(address(work));
        uint256 imdDue = imd.balanceOf(treasury) + imd.balanceOf(address(hook));
        uint256 workDue = work.balanceOf(treasury) + work.balanceOf(address(hook));
        vm.prank(actors[actorSeed % actors.length]);
        router.sweepWhileUnlocked(key);
        assertEq(_claim(address(imd)), imdClaim);
        assertEq(_claim(address(work)), workClaim);
        assertEq(imd.balanceOf(treasury), imdDue);
        assertEq(work.balanceOf(treasury), workDue);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(work.balanceOf(address(hook)), 0);
    }

    function advanceTime(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 300);
        uint256 previous = hook.feeNow();
        vm.warp(block.timestamp + elapsed);
        assertLe(hook.feeNow(), previous, "rate decays with standing fee unchanged");
    }

    function setFee(uint256 fee) public {
        fee = bound(fee, 0, 1000);
        vm.prank(treasury);
        hook.setStandingFee(fee);
        expectedStandingFee = fee;
    }

    function rejectFeeChange(uint256 actorSeed, uint256 fee, bool asTreasury) public {
        address caller = asTreasury ? treasury : actors[actorSeed % actors.length];
        if (asTreasury) fee = bound(fee, 1001, type(uint256).max);
        uint256 beforeFee = hook.feeNow();
        vm.prank(caller);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.setStandingFee, (fee)));
        assertFalse(ok, "unauthorized or out-of-range update must fail");
        assertEq(hook.standingFee(), expectedStandingFee);
        assertEq(hook.feeNow(), beforeFee);
    }

    function rejectReinitialization(uint256 actorSeed) public {
        uint256 opened = hook.openedAt();
        vm.prank(actors[actorSeed % actors.length]);
        (bool ok,) = address(manager).call(abi.encodeCall(manager.initialize, (key, uint160(1 << 96))));
        assertFalse(ok);
        assertEq(hook.openedAt(), opened);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, 100 ether);
        uint256 fromBefore = work.balanceOf(from);
        uint256 toBefore = work.balanceOf(to);
        vm.prank(from);
        assertTrue(work.transfer(to, amount));
        assertEq(work.balanceOf(from), from == to ? fromBefore : fromBefore - amount);
        assertEq(work.balanceOf(to), from == to ? toBefore : toBefore + amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = unlimited ? type(uint256).max : bound(amount, 0, 100 ether);
        vm.prank(owner);
        assertTrue(work.approve(spender, amount));
        allowances[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = allowances[owner][spender];
        amount = bound(amount, 0, allowed < 100 ether ? allowed : 100 ether);
        uint256 ownerBefore = work.balanceOf(owner);
        uint256 toBefore = work.balanceOf(to);
        vm.prank(spender);
        assertTrue(work.transferFrom(owner, to, amount));
        if (allowed != type(uint256).max) allowances[owner][spender] -= amount;
        assertEq(work.balanceOf(owner), owner == to ? ownerBefore : ownerBefore - amount);
        assertEq(work.balanceOf(to), owner == to ? toBefore : toBefore + amount);
    }

    function _claim(address coin) private view returns (uint256) {
        return manager.balanceOf(address(hook), uint160(coin));
    }

    function _rawAmounts(bool zeroForOne) private returns (uint256 paid, uint256 received) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                paid = uint256(-int256(zeroForOne ? a0 : a1));
                received = uint256(int256(zeroForOne ? a1 : a0));
                return (paid, received);
            }
        }
        revert("missing PoolManager swap event");
    }
}
