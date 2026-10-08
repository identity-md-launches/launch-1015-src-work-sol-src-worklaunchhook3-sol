// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Work} from "../../src/Work.sol";
import {WorkLaunchHook3} from "../../src/WorkLaunchHook3.sol";
import {MineWorkHook} from "../../script/MineWorkHook.s.sol";
import {TestRouter} from "./TestRouter.sol";
import {MockIMD} from "./MockIMD.sol";

abstract contract WorkPoolFixture is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant TREASURY = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    uint160 internal constant INITIAL_PRICE = 79228162514264337593543950336;
    uint256 internal constant OPEN_TIME = 1_800_000_000;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    PoolManager internal manager;
    Work internal work;
    MockIMD internal imd;
    WorkLaunchHook3 internal hook;
    TestRouter internal router;
    MineWorkHook internal miner;
    PoolKey internal key;
    address internal stranger;

    event StandingFee(uint256 fee);
    event SweepFailed(address token);

    function setUp() public virtual {
        vm.warp(OPEN_TIME);
        stranger = makeAddr("permissionless caller");
        manager = new PoolManager(address(this));
        work = new Work();
        MockIMD template = new MockIMD();
        vm.etch(IMD, address(template).code);
        imd = MockIMD(IMD);
        imd.mint(address(this), 1_000_000_000 ether);
        miner = new MineWorkHook();
        hook = _deployHook(address(work));
        key = _key(address(work), hook);
        router = new TestRouter(manager);
        // Finite approvals cover all bounded test trades and liquidity operations.
        work.approve(address(router), work.totalSupply());
        imd.approve(address(router), imd.totalSupply());
    }

    function _deployHook(address token) internal returns (WorkLaunchHook3 deployed) {
        (bytes32 salt, address predicted) = miner.run(address(this), manager, token, 0, 200_000);
        deployed = new WorkLaunchHook3{salt: salt}(manager, token);
        assertEq(address(deployed), predicted);
    }

    function _key(address token, WorkLaunchHook3 h) internal pure returns (PoolKey memory) {
        (address a, address b) = token < IMD ? (token, IMD) : (IMD, token);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 12500, 60, IHooks(address(h)));
    }

    function _open() internal {
        assertEq(manager.initialize(key, INITIAL_PRICE), 0);
        assertEq(hook.openedAt(), OPEN_TIME);
        router.liquidity(key, 10_000_000 ether);
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _claim(address currency) internal view returns (uint256) {
        return manager.balanceOf(address(hook), uint160(currency));
    }
}
