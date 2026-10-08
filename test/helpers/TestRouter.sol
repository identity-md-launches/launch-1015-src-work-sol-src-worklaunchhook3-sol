// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WorkLaunchHook3} from "../../src/WorkLaunchHook3.sol";

/// @dev Test-only router: no user slippage/deadline controls; never deploy for trading.
contract TestRouter {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function liquidity(PoolKey memory key, int256 amount) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(amount))), (BalanceDelta));
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(params))), (BalanceDelta));
    }

    function sweepWhileUnlocked(PoolKey memory key) external {
        manager.unlock(abi.encode(uint8(2), msg.sender, key, bytes("")));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, address payer, PoolKey memory key, bytes memory params) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        if (action == 2) {
            WorkLaunchHook3(address(key.hooks)).sweep();
            return "";
        }
        BalanceDelta delta;
        if (action == 0) {
            (delta,) = manager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams(-600, 600, abi.decode(params, (int256)), bytes32(0)), ""
            );
        } else {
            delta = manager.swap(key, abi.decode(params, (IPoolManager.SwapParams)), "");
        }
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-int256(delta))));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(int256(delta)));
        }
    }
}
