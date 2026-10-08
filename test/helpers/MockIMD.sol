// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WorkLaunchHook3} from "../../src/WorkLaunchHook3.sol";

/// @dev Used only at the mandated IMD address in the isolated test EVM.
contract MockIMD is ERC20 {
    uint8 public transferMode;
    WorkLaunchHook3 public reentryTarget;
    bool private entering;
    uint256 public reentries;

    constructor() ERC20("Test IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferMode(uint8 mode) external {
        transferMode = mode;
    }

    function setReentryTarget(WorkLaunchHook3 target) external {
        reentryTarget = target;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint8 mode = transferMode;
        if (mode == 1) return false;
        require(mode != 2, "test transfer failure");
        bool ok = super.transfer(to, amount);
        if (address(reentryTarget) != address(0) && !entering) {
            entering = true;
            ++reentries;
            reentryTarget.sweep();
            entering = false;
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == 4) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return ok;
    }
}
