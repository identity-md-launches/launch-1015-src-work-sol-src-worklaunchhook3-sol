// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {WorkLaunchHook3} from "../src/WorkLaunchHook3.sol";

/// @notice Read-only CREATE2 salt search. The factory must use exactly this init code.
contract MineWorkHook {
    error SaltNotFound();

    function run(address factory, IPoolManager manager, address token, uint256 start, uint256 attempts)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(WorkLaunchHook3).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash)))));
            if (uint160(predicted) & 0x3fff == 0x2044) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
