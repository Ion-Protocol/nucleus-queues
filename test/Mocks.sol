// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.25;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IAtomicSolver } from "./../src/IAtomicSolver.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) { }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockSolver is IAtomicSolver {
    uint256 public assetsToReturn;
    bool public shouldRevert;
    uint256 public lastClearingPrice;
    mapping(address => mapping(address => uint256)) public tokenPairClearingPrices;

    event SolveExecuted(
        address offer, address want, uint256 clearingPrice, uint256 assetsToOffer, uint256 assetsForWant
    );

    function setAssetsToReturn(uint256 amount) external {
        assetsToReturn = amount;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setClearingPrice(address offer, address want, uint256 price) external {
        tokenPairClearingPrices[offer][want] = price;
    }

    function getClearingPrice(address offer, address want) external view returns (uint256) {
        return tokenPairClearingPrices[offer][want];
    }

    function finishSolve(
        bytes calldata runData,
        address initiator,
        ERC20 offer,
        ERC20 want,
        uint256 assetsToOffer,
        uint256 assetsForWant
    )
        external
    {
        if (shouldRevert) {
            revert("MockSolver: forced revert");
        }

        // Decode clearing price from runData if provided
        uint256 clearingPrice;
        if (runData.length > 0) {
            clearingPrice = abi.decode(runData, (uint256));
            tokenPairClearingPrices[address(offer)][address(want)] = clearingPrice;
        } else {
            clearingPrice = tokenPairClearingPrices[address(offer)][address(want)];
        }

        lastClearingPrice = clearingPrice;

        emit SolveExecuted(address(offer), address(want), clearingPrice, assetsToOffer, assetsForWant);
    }

    receive() external payable { }
}

contract MockAtomicQueue {
    mapping(address => mapping(address => uint256)) public userBalances;

    function setUserBalance(address user, address token, uint256 amount) external {
        userBalances[user][token] = amount;
    }

    function getUserBalance(address user, address token) external view returns (uint256) {
        return userBalances[user][token];
    }
}

contract RevertingSolver is IAtomicSolver {
    function finishSolve(bytes calldata, address, ERC20, ERC20, uint256, uint256) external pure {
        revert("RevertingSolver: always reverts");
    }
}

contract CallbackSolver is IAtomicSolver {
    uint256 public lastClearingPrice;

    event CallbackReceived(
        address initiator,
        address offer,
        address want,
        uint256 clearingPrice,
        uint256 assetsToOffer,
        uint256 assetsForWant
    );

    function finishSolve(
        bytes calldata runData,
        address initiator,
        ERC20 offer,
        ERC20 want,
        uint256 assetsToOffer,
        uint256 assetsForWant
    )
        external
    {
        uint256 clearingPrice = abi.decode(runData, (uint256));
        lastClearingPrice = clearingPrice;

        emit CallbackReceived(initiator, address(offer), address(want), clearingPrice, assetsToOffer, assetsForWant);
    }
}

contract GasOptimizedSolver is IAtomicSolver {
    function finishSolve(bytes calldata runData, address, ERC20, ERC20, uint256, uint256) external pure {
        // Decode clearing price but don't store it for gas optimization demo
        abi.decode(runData, (uint256));
    }
}
