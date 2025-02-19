// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.25;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IAtomicSolver } from "./../src/IAtomicSolver.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) { }
}

contract MockSolver is IAtomicSolver {
    uint256 public lastClearingPrice;

    function finishSolve(bytes calldata runData, address, ERC20, ERC20, uint256, uint256) external {
        lastClearingPrice = abi.decode(runData, (uint256));
    }

    receive() external payable { }
}
