// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract WorkLaunchHook3 {
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant B = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    IPoolManager public immutable poolManager;
    address public immutable token;
    uint256 public openedAt;
    uint256 public standingFee = 200;
    event StandingFee(uint256 fee);
    event SweepFailed(address token);

    constructor(IPoolManager m, address t) {
        require(t != IMD && t != address(0));
        poolManager = m;
        token = t;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }
    modifier onlyPM() {
        require(msg.sender == address(poolManager));
        _;
    }

    function beforeInitialize(address, PoolKey calldata k, uint160) external onlyPM returns (bytes4) {
        address a = Currency.unwrap(k.currency0);
        address b = Currency.unwrap(k.currency1);
        require(
            openedAt == 0 && ((a == IMD && b == token) || (a == token && b == IMD)) && k.fee == 12500
                && k.tickSpacing == 60 && address(k.hooks) == address(this)
        );
        openedAt = block.timestamp;
        return IHooks.beforeInitialize.selector;
    }

    function feeNow() public view returns (uint256) {
        uint256 t = openedAt;
        uint256 s = standingFee;
        if (t == 0 || block.timestamp <= t) return 5000;
        t = block.timestamp - t;
        return t < 900 ? s + (5000 - s) * (900 - t) / 900 : s;
    }

    function setStandingFee(uint256 f) external {
        require(msg.sender == B && f <= 1000);
        standingFee = f;
        emit StandingFee(f);
    }

    function afterSwap(address, PoolKey calldata k, IPoolManager.SwapParams calldata p, BalanceDelta d, bytes calldata)
        external
        onlyPM
        returns (bytes4, int128)
    {
        bool u1 = (p.amountSpecified < 0) == p.zeroForOne;
        int128 a = u1 ? d.amount1() : d.amount0();
        uint256 r = feeNow();
        uint256 f = a < 0 ? uint256(int256(-a)) * r / (10000 - r) : uint256(int256(a)) * r / 10000;
        if (f > 0) poolManager.mint(address(this), (u1 ? k.currency1 : k.currency0).toId(), f);
        return (IHooks.afterSwap.selector, int128(int256(f)));
    }

    function sweep() external {
        for (uint256 i; i < 2; ++i) {
            address x = i == 0 ? IMD : token;
            try poolManager.unlock(abi.encode(x)) {}
            catch {
                emit SweepFailed(x);
            }
            uint256 v = Currency.wrap(x).balanceOfSelf();
            if (v > 0) {
                (bool ok, bytes memory r) = x.call(abi.encodeWithSignature("transfer(address,uint256)", B, v));
                if (!ok || (r.length > 0 && !abi.decode(r, (bool)))) emit SweepFailed(x);
            }
        }
    }

    function unlockCallback(bytes calldata d) external onlyPM returns (bytes memory) {
        Currency x = Currency.wrap(abi.decode(d, (address)));
        uint256 v = poolManager.balanceOf(address(this), x.toId());
        if (v > 0) {
            poolManager.burn(address(this), x.toId(), v);
            poolManager.take(x, B, v);
        }
        return "";
    }
}
