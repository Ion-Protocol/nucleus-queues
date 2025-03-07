// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.25;

import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";
import { IAtomicSolver } from "./IAtomicSolver.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AtomicQueueUCP
 * @notice Allows users to create `AtomicRequests` that specify an ERC20 asset to `offer`
 *         and an ERC20 asset to `want` in return.
 * @notice Making atomic requests where the exchange rate between offer and want is not
 *         relatively stable is effectively the same as placing a limit order between
 *         those assets, so requests can be filled at a rate worse than the current market rate.
 * @notice It is possible for a user to make multiple requests that use the same offer asset.
 *         If this is done it is important that the user has approved the queue to spend the
 *         total amount of assets aggregated from all their requests, and to also have enough
 *         `offer` asset to cover the aggregate total request of `offerAmount`.
 * @custom:security-contact security@molecularlabs.io
 */
contract AtomicQueueUCP is ReentrancyGuard, Ownable {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // ========================================= STRUCTS =========================================

    /**
     * @notice Stores request information needed to fulfill a users atomic request.
     * @param deadline unix timestamp for when request is no longer valid
     * @param atomicPrice the price in terms of `want` asset the user wants their `offer` assets "sold" at
     * @dev atomicPrice MUST be in terms of `want` asset decimals.
     * @param offerAmount the amount of `offer` asset the user wants converted to `want` asset
     * @param recipient the address to receive want assets
     */
    struct AtomicRequest {
        uint64 deadline; // Timestamp when request expires
        uint96 atomicPrice; // User's limit price in want asset decimals
        uint96 offerAmount; // Amount of offer asset to sell
        address recipient; // Address to receive want assets
    }

    /**
     * @notice Used in `viewSolveMetaData` helper function to return data in a clean struct.
     * @param user the address of the user
     * @param flags 8 bits indicating the state of the user. Multiple flags can be set simultaneously.
     *             Each bit represents a different error condition:
     *             From right to left:
     *             - 0: indicates user deadline has passed
     *             - 1: indicates user request has zero offer amount
     *             - 2: indicates user does not have enough offer asset in wallet
     *             - 3: indicates user has not given AtomicQueue approval
     *             - 4: indicates user's atomic price is above clearing price
     *             A value of 0 means no errors (user is solvable).
     * @param assetsToOffer the amount of offer asset to solve
     * @param assetsForWant the amount of assets users want for their offer assets
     */
    struct SolveMetaData {
        address user; // User's address
        uint8 flags; // Bitfield for various error conditions
        uint256 assetsToOffer; // Amount of offer asset from this user
        uint256 assetsForWant; // Amount of want asset for this user
    }

    // ========================================= ERRORS =========================================

    error AtomicQueue__UserRepeated(address user);
    error AtomicQueue__RequestDeadlineExceeded(uint64 deadline);
    error AtomicQueue__UserNotInSolve(address user);
    error AtomicQueue__ZeroOfferAmount();
    error AtomicQueue__PriceAboveClearing(uint96 price, uint256 clearingPrice);
    error AtomicQueue__UnapprovedSolveCaller(address caller);
    error AtomicQueue__InvalidRecipient(address recipient);
    error AtomicQueue__InvalidRequest();

    // ========================================= EVENTS =========================================

    event AtomicRequestUpdated(
        address user,
        address offerToken,
        address wantToken,
        address recipient,
        uint256 amount,
        uint256 deadline,
        uint256 minPrice,
        uint256 timestamp
    );

    event AtomicRequestFulfilled(
        address user,
        address offerToken,
        address wantToken,
        address recipient,
        uint256 offerAmountSpent,
        uint256 wantAmountReceived,
        uint256 timestamp
    );

    event SolverCallerToggled(address caller, bool isApproved);

    // ========================================= STORAGE =========================================

    /**
     * @notice Maps user address to offer asset to want asset to a AtomicRequest struct.
     */
    mapping(address => mapping(ERC20 => mapping(ERC20 => AtomicRequest))) public userAtomicRequest;

    mapping(address => bool) public isApprovedSolveCaller;

    constructor(address _owner, address[] memory approvedSolveCallers) Ownable(_owner) {
        for (uint256 i; i < approvedSolveCallers.length; ++i) {
            isApprovedSolveCaller[approvedSolveCallers[i]] = true;
            emit SolverCallerToggled(approvedSolveCallers[i], true);
        }
    }

    // ========================================= OWNER FUNCTIONS =========================================

    /**
     * @notice Allows owner to toggle approved solve callers.
     * @param solveCallers an array of addresses to toggle approval for
     */
    function toggleApprovedSolveCallers(address[] memory solveCallers) external onlyOwner {
        bool isApproved;
        for (uint256 i; i < solveCallers.length; ++i) {
            isApproved = !isApprovedSolveCaller[solveCallers[i]];
            isApprovedSolveCaller[solveCallers[i]] = isApproved;
            emit SolverCallerToggled(solveCallers[i], isApproved);
        }
    }

    // ========================================= USER FUNCTIONS =========================================

    /**
     * @notice Get a users Atomic Request.
     * @param user the address of the user to get the request for
     * @param offer the ERC0 token they want to exchange for the want
     * @param want the ERC20 token they want in exchange for the offer
     */
    function getUserAtomicRequest(address user, ERC20 offer, ERC20 want) external view returns (AtomicRequest memory) {
        return userAtomicRequest[user][offer][want];
    }

    /**
     * @notice Helper function that returns either
     *         true: Withdraw request is valid.
     *         false: Withdraw request is not valid.
     * @dev It is possible for a withdraw request to return false from this function, but using the
     *      request in `updateAtomicRequest` will succeed, but solvers will not be able to include
     *      the user in `solve` unless some other state is changed.
     * @param offer the ERC0 token they want to exchange for the want
     * @param user the address of the user making the request
     * @param userRequest the request struct to validate
     */
    function isAtomicRequestValid(
        ERC20 offer,
        address user,
        AtomicRequest calldata userRequest
    )
        external
        view
        returns (bool)
    {
        // Check user has enough balance
        if (userRequest.offerAmount > offer.balanceOf(user)) return false;
        // Check request hasn't expired
        if (block.timestamp > userRequest.deadline) return false;
        // Check sufficient allowance
        if (offer.allowance(user, address(this)) < userRequest.offerAmount) return false;
        // Check non-zero amounts
        if (userRequest.offerAmount == 0) return false;
        if (userRequest.atomicPrice == 0) return false;
        if (userRequest.recipient == address(0)) return false;

        return true;
    }

    /**
     * @notice Allows user to cancel their atomic request easily.
     * @param offer the ERC20 token the user is offering in exchange for the want
     * @param want the ERC20 token the user wants in exchange for offer
     */
    function cancelAtomicRequest(ERC20 offer, ERC20 want) external {
        delete userAtomicRequest[msg.sender][offer][want];

        emit AtomicRequestUpdated(msg.sender, address(offer), address(want), address(0), 0, 0, 0, 0);
    }

    /**
     * @notice Allows user to add/update their withdraw request.
     * @notice It is possible for a withdraw request with a zero atomicPrice to be made, and solved.
     *         If this happens, users will be selling their shares for no assets in return.
     *         To determine a safe atomicPrice, share.previewRedeem should be used to get
     *         a good share price, then the user can lower it from there to make their request fill faster.
     * @param offer the ERC20 token the user is offering in exchange for the want
     * @param want the ERC20 token the user wants in exchange for offer
     * @param userRequest the users request
     */
    function updateAtomicRequest(ERC20 offer, ERC20 want, AtomicRequest calldata userRequest) external nonReentrant {
        // Update user's request in storage
        AtomicRequest storage request = userAtomicRequest[msg.sender][offer][want];

        _checkRecipientAmountDeadline(userRequest);

        request.deadline = userRequest.deadline;
        request.atomicPrice = userRequest.atomicPrice;
        request.offerAmount = userRequest.offerAmount;
        request.recipient = userRequest.recipient;

        // Emit update event with full request details
        emit AtomicRequestUpdated(
            msg.sender,
            address(offer),
            address(want),
            userRequest.recipient,
            userRequest.offerAmount,
            userRequest.deadline,
            userRequest.atomicPrice,
            block.timestamp
        );
    }

    /**
     * @notice Called by solvers in order to exchange offer asset for want asset.
     * @notice Solvers are optimistically transferred the offer asset, then are required to
     *         approve this contract to spend enough of want assets to cover all requests.
     * @dev It is very likely `solve` TXs will be front run if broadcasted to public mem pools,
     *      so solvers should use private mem pools.
     * @param offer the ERC20 offer token to solve for
     * @param want the ERC20 want token to solve for
     * @param users an array of user addresses to solve for
     * @param runData extra data that is passed back to solver when `finishSolve` is called
     * @param solver the address to make `finishSolve` callback to
     * @param clearingPrice the uniform clearing price that all requests will be settled at
     */
    function solve(
        ERC20 offer,
        ERC20 want,
        address[] calldata users,
        bytes calldata runData,
        address solver,
        uint256 clearingPrice
    )
        external
        nonReentrant
    {
        if (!isApprovedSolveCaller[msg.sender]) revert AtomicQueue__UnapprovedSolveCaller(msg.sender);
        uint8 offerDecimals = offer.decimals();
        uint256 assetsToOffer = _handleFirstLoop(offer, want, users, clearingPrice, solver);
        uint256 assetsForWant = _calculateAssetAmount(assetsToOffer, clearingPrice, offerDecimals);

        IAtomicSolver(solver).finishSolve(runData, msg.sender, offer, want, assetsToOffer, assetsForWant);

        _handleSecondLoop(offer, want, users, clearingPrice, solver, offerDecimals);
    }

    function _handleFirstLoop(
        ERC20 offer,
        ERC20 want,
        address[] calldata users,
        uint256 clearingPrice,
        address solver
    )
        internal
        returns (uint256 assetsToOffer)
    {
        for (uint256 i = users.length; i > 0;) {
            unchecked {
                --i;
            }

            address user = users[i];
            AtomicRequest memory request = userAtomicRequest[user][offer][want];
            bytes32 key = keccak256(abi.encode(user, offer, want));

            uint256 isInSolve;
            assembly {
                isInSolve := tload(key)
            }

            if (isInSolve == 1) revert AtomicQueue__UserRepeated(user);
            if (request.atomicPrice > clearingPrice) revert AtomicQueue__PriceAboveClearing(request.atomicPrice, clearingPrice);
            _checkRecipientAmountDeadline(request);

            assembly {
                tstore(key, 1)
            }

            assetsToOffer += request.offerAmount;
            offer.safeTransferFrom(user, solver, request.offerAmount);
        }
    }

    function _handleSecondLoop(
        ERC20 offer,
        ERC20 want,
        address[] calldata users,
        uint256 clearingPrice,
        address solver,
        uint8 offerDecimals
    )
        internal
    {
        for (uint256 i = users.length; i > 0;) {
            unchecked {
                --i;
            }
            address user = users[i];
            AtomicRequest storage request = userAtomicRequest[user][offer][want];
            bytes32 key = keccak256(abi.encode(user, offer, want));

            uint256 isInSolve;
            assembly {
                isInSolve := tload(key)
            }

            if (isInSolve == 0) revert AtomicQueue__UserNotInSolve(user);

            uint256 assetsToUser = _calculateAssetAmount(request.offerAmount, clearingPrice, offerDecimals);
            want.safeTransferFrom(solver, request.recipient, assetsToUser);

            emit AtomicRequestFulfilled(
                user,
                address(offer),
                address(want),
                request.recipient,
                request.offerAmount,
                assetsToUser,
                block.timestamp
            );

            request.offerAmount = 0;
            assembly {
                tstore(key, 0)
            }
        }
    }

    /**
     * @notice Helper function solvers can use to determine if users are solvable, and the required amounts to do so.
     * @notice Repeated users are not accounted for in this setup, so if solvers have repeat users in their `users`
     *         array the results can be wrong.
     * @dev Since a user can have multiple requests with the same offer asset but different want asset, it is
     *      possible for `viewSolveMetaData` to report no errors, but for a solve to fail, if any solves were done
     *      between the time `viewSolveMetaData` and before `solve` is called.
     * @param offer the ERC20 offer token to check for solvability
     * @param want the ERC20 want token to check for solvability
     * @param users an array of user addresses to check for solvability
     * @param clearingPrice the uniform clearing price to check requests against
     */
    function viewSolveMetaData(
        ERC20 offer,
        ERC20 want,
        address[] calldata users,
        uint256 clearingPrice
    )
        external
        view
        returns (SolveMetaData[] memory metaData, uint256 totalAssetsForWant, uint256 totalAssetsToOffer)
    {
        // Cache decimals
        uint8 offerDecimals = offer.decimals();

        // Initialize return array
        metaData = new SolveMetaData[](users.length);

        // Check each user's request
        for (uint256 i; i < users.length; ++i) {
            AtomicRequest memory request = userAtomicRequest[users[i]][offer][want];

            metaData[i].user = users[i];

            // Set appropriate error flags
            if (block.timestamp > request.deadline) {
                metaData[i].flags |= uint8(1);
            }
            if (request.offerAmount == 0) {
                metaData[i].flags |= uint8(1) << 1;
            }
            if (offer.balanceOf(users[i]) < request.offerAmount) {
                metaData[i].flags |= uint8(1) << 2;
            }
            if (offer.allowance(users[i], address(this)) < request.offerAmount) {
                metaData[i].flags |= uint8(1) << 3;
            }
            if (request.atomicPrice > clearingPrice) {
                metaData[i].flags |= uint8(1) << 4;
            }

            // Calculate amounts for this user
            metaData[i].assetsToOffer = request.offerAmount;
            metaData[i].assetsForWant = _calculateAssetAmount(request.offerAmount, clearingPrice, offerDecimals);

            // If no errors, add to totals
            if (metaData[i].flags == 0) {
                totalAssetsForWant += metaData[i].assetsForWant;
                totalAssetsToOffer += request.offerAmount;
            }
        }
    }

    /**
     * @notice Helper function to calculate the amount of want assets a users wants in exchange for
     *         `offerAmount` of offer asset.
     */
    function _calculateAssetAmount(
        uint256 offerAmount,
        uint256 clearingPrice,
        uint8 offerDecimals
    )
        internal
        pure
        returns (uint256)
    {
        return clearingPrice.mulDivDown(offerAmount, 10 ** offerDecimals);
    }

    function _checkRecipientAmountDeadline(AtomicRequest memory request) internal view {
        if (block.timestamp > request.deadline) revert AtomicQueue__RequestDeadlineExceeded(request.deadline);
        if (request.offerAmount == 0) revert AtomicQueue__ZeroOfferAmount();
        if (request.recipient == address(0)) revert AtomicQueue__InvalidRecipient(request.recipient);
    }
}
