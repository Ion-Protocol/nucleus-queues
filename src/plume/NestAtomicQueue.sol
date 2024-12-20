// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { AtomicQueueUCP } from "../AtomicQueueUCP.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface IAccountantWithRateProviders {
    function getRateInQuote(ERC20 token) external view returns (uint256);
    function vault() external view returns (address);
}

/**
 * @title NestAtomicQueue
 * @notice AtomicQueue implementation for the Nest vault
 * @dev An AtomicQueue that can only redeem a single vault token and withdraw
 * into a single want asset configured in this contract.
 */
contract NestAtomicQueueUCP is AtomicQueueUCP {
    using SafeCast for uint256;
    using FixedPointMathLib for uint256;

    // Constants

    uint256 public constant REQUEST_ID = 0;

    // Public State
    address public vault; // The only vault token the user can redeem.
    address public asset; // The only asset the user can withdraw into.
    
    IAccountantWithRateProviders public accountant;

    uint256 public deadlinePeriod;
    uint256 public pricePercentage; // Must be 4 decimals i.e. 9999 = 99.99%

    // Errors

    error InvalidOwner();
    error InvalidController();

    // Events

    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    // Constructor

    constructor(
        address _owner,
        address[] memory _approvedSolveCallers,
        address _vault,
        address _accountant,
        address _asset,
        uint256 _deadlinePeriod,
        uint256 _pricePercentage
    ) AtomicQueueUCP(_owner, _approvedSolveCallers) {
        vault = _vault;
        accountant = IAccountantWithRateProviders(_accountant);

        asset = _asset;
        deadlinePeriod = _deadlinePeriod;
        pricePercentage = _pricePercentage;
    }

    // Admin Functions

    /**
     * @notice Sets the accountant for the queue. 
     * @dev The accountant must be for the vault, so we enforce the connection
     * on chain. 
     * @param _accountant The new accountant
     */
    function setAccountant(address _accountant) external onlyOwner {
        accountant = IAccountantWithRateProviders(_accountant);
        vault = accountant.vault();
    }

    /**
     * @notice Sets the asset to withdraw into for the queue. 
     * @param _asset The new asset
     */
    function setAsset(address _asset) external onlyOwner {
        asset = _asset;
    }

    // User Functions

    /**
     * @notice Transfer shares from the owner into the vault and submit a request to redeem assets
     * @param shares Amount of shares to redeem
     * @param controller Controller of the request
     * @param owner Source of the shares to redeem
     * @return requestId Discriminator between non-fungible requests
     */
    function requestRedeem(uint256 shares, address controller, address owner) public returns (uint256 requestId) {
        if (owner != msg.sender) {
            revert InvalidOwner();
        }

        if (controller != msg.sender) {
            revert InvalidController();
        }

        // Create and submit atomic request
        AtomicRequest memory request = AtomicRequest({
            deadline: (block.timestamp + deadlinePeriod.toUint64()).toUint64(),
            atomicPrice: accountant.getRateInQuote(ERC20(asset)).mulDivDown(pricePercentage, 10000).toUint88(), // Price per share in terms of asset
            offerAmount: uint96(shares),
            inSolve: false
        });

        updateAtomicRequest(ERC20(vault), ERC20(asset), request);

        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);

        return REQUEST_ID;
    }
}
