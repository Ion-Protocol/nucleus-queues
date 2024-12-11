// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.25;

import { AtomicQueueUCP } from "./../src/AtomicQueueUCP.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { Test } from "@forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { MockERC20, MockSolver } from "./Mocks.sol";

contract AtomicQueueUCPTest is Test {
    using FixedPointMathLib for uint256;

    AtomicQueueUCP public queue;
    MockSolver public solver;

    ERC20 public offerToken;
    ERC20 public wantToken;

    address immutable QUEUE_OWNER = makeAddr("QueueOwner");
    address immutable USER_ONE = makeAddr("User1");
    address immutable USER_TWO = makeAddr("User2");
    address immutable USER_THREE = makeAddr("User3");

    function setUp() public {
        // Deploy mock tokens
        offerToken = new MockERC20("Offer Token", "OFFER", 18);
        wantToken = new MockERC20("Want Token", "WANT", 6);

        // Deploy and setup solver
        solver = new MockSolver();
        address[] memory approvedSolvers = new address[](1);
        approvedSolvers[0] = address(solver);

        // Deploy queue
        queue = new AtomicQueueUCP(QUEUE_OWNER, approvedSolvers);

        // Setup initial token balances
        deal(address(offerToken), USER_ONE, 100e18);
        deal(address(offerToken), USER_TWO, 100e18);
        deal(address(offerToken), USER_THREE, 100e18);
        deal(address(wantToken), address(solver), 1000e6);

        // Setup approvals
        vm.startPrank(USER_ONE);
        offerToken.approve(address(queue), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER_TWO);
        offerToken.approve(address(queue), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER_THREE);
        offerToken.approve(address(queue), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(address(solver));
        wantToken.approve(address(queue), type(uint256).max);
        vm.stopPrank();
    }

    function test_UpdateAtomicRequest() public {
        AtomicQueueUCP.AtomicRequest memory request = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 5e6,
            offerAmount: 1e18,
            inSolve: false
        });

        vm.startPrank(USER_ONE);
        queue.updateAtomicRequest(offerToken, wantToken, request);

        AtomicQueueUCP.AtomicRequest memory savedRequest = queue.getUserAtomicRequest(USER_ONE, offerToken, wantToken);

        assertEq(savedRequest.deadline, request.deadline);
        assertEq(savedRequest.atomicPrice, request.atomicPrice);
        assertEq(savedRequest.offerAmount, request.offerAmount);
        assertEq(savedRequest.inSolve, false);
        vm.stopPrank();
    }

    function test_IsAtomicRequestValid() public {
        AtomicQueueUCP.AtomicRequest memory request = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 5e6,
            offerAmount: 1e18,
            inSolve: false
        });

        bool isValid = queue.isAtomicRequestValid(offerToken, USER_ONE, request);
        assertTrue(isValid);
    }

    function test_IsAtomicRequestValid_ExpiredDeadline() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        AtomicQueueUCP.AtomicRequest memory request =
            AtomicQueueUCP.AtomicRequest({ deadline: deadline, atomicPrice: 5e6, offerAmount: 1e18, inSolve: false });

        // Move time forward past the deadline
        vm.warp(deadline + 1);

        bool isValid = queue.isAtomicRequestValid(offerToken, USER_ONE, request);
        assertFalse(isValid);
    }

    function test_IsAtomicRequestValid_InsufficientBalance() public {
        AtomicQueueUCP.AtomicRequest memory request = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 5e6,
            offerAmount: 1000e18, // More than user has
            inSolve: false
        });

        bool isValid = queue.isAtomicRequestValid(offerToken, USER_ONE, request);
        assertFalse(isValid);
    }

    function test_BasicSolve_gas() public {
        AtomicQueueUCP.AtomicRequest memory request = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 5e6,
            offerAmount: 1e18,
            inSolve: false
        });

        address[] memory users = new address[](100);

        for(uint i=0; i < 100; ++i){
            address user = address(uint160(i));
            deal(address(offerToken), user, 100e18);

            vm.startPrank(user);
            offerToken.approve(address(queue), type(uint256).max);

            queue.updateAtomicRequest(offerToken, wantToken, request);
            vm.stopPrank();

            users[i] = user;
        }

        uint256 clearingPrice = 5e6;
        bytes memory runData = abi.encode(clearingPrice);

        uint256 userOfferBalanceBefore = offerToken.balanceOf(USER_ONE);
        uint256 userWantBalanceBefore = wantToken.balanceOf(USER_ONE);
        uint256 solverOfferBalanceBefore = offerToken.balanceOf(address(solver));
        uint256 solverWantBalanceBefore = wantToken.balanceOf(address(solver));

        vm.prank(address(solver));
        queue.solve(offerToken, wantToken, users, runData, address(solver), clearingPrice);  

    }

    function test_BasicSolve() public {
        AtomicQueueUCP.AtomicRequest memory request = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 5e6,
            offerAmount: 1e18,
            inSolve: false
        });

        vm.startPrank(USER_ONE);
        queue.updateAtomicRequest(offerToken, wantToken, request);
        vm.stopPrank();

        address[] memory users = new address[](1);
        users[0] = USER_ONE;

        uint256 clearingPrice = 5e6;
        bytes memory runData = abi.encode(clearingPrice);

        uint256 userOfferBalanceBefore = offerToken.balanceOf(USER_ONE);
        uint256 userWantBalanceBefore = wantToken.balanceOf(USER_ONE);
        uint256 solverOfferBalanceBefore = offerToken.balanceOf(address(solver));
        uint256 solverWantBalanceBefore = wantToken.balanceOf(address(solver));

        vm.prank(address(solver));
        queue.solve(offerToken, wantToken, users, runData, address(solver), clearingPrice);

        assertEq(solver.lastClearingPrice(), clearingPrice);
        assertEq(offerToken.balanceOf(USER_ONE), userOfferBalanceBefore - request.offerAmount);
        assertEq(wantToken.balanceOf(USER_ONE), userWantBalanceBefore + clearingPrice);
        assertEq(offerToken.balanceOf(address(solver)), solverOfferBalanceBefore + request.offerAmount);
        assertEq(wantToken.balanceOf(address(solver)), solverWantBalanceBefore - clearingPrice);
    }

    function test_MultiUserSolve() public {
        AtomicQueueUCP.AtomicRequest memory request1 = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 5e6,
            offerAmount: 1e18,
            inSolve: false
        });

        AtomicQueueUCP.AtomicRequest memory request2 = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 4e6,
            offerAmount: 2e18,
            inSolve: false
        });

        vm.prank(USER_ONE);
        queue.updateAtomicRequest(offerToken, wantToken, request1);

        vm.prank(USER_TWO);
        queue.updateAtomicRequest(offerToken, wantToken, request2);

        address[] memory users = new address[](2);
        users[0] = USER_ONE;
        users[1] = USER_TWO;

        uint256 clearingPrice = 5e6;
        bytes memory runData = abi.encode(clearingPrice);

        vm.prank(address(solver));
        queue.solve(offerToken, wantToken, users, runData, address(solver), clearingPrice);

        assertEq(solver.lastClearingPrice(), clearingPrice);
        assertEq(wantToken.balanceOf(USER_ONE), 5e6);
        assertEq(wantToken.balanceOf(USER_TWO), 10e6);
    }

    function testFail_SolveWithLowerClearingPrice() public {
        AtomicQueueUCP.AtomicRequest memory request = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 5e6,
            offerAmount: 1e18,
            inSolve: false
        });

        vm.prank(USER_ONE);
        queue.updateAtomicRequest(offerToken, wantToken, request);

        address[] memory users = new address[](1);
        users[0] = USER_ONE;

        uint256 clearingPrice = 4e6; // Lower than user's atomic price - should fail
        bytes memory runData = abi.encode(clearingPrice);

        vm.prank(address(solver));
        queue.solve(offerToken, wantToken, users, runData, address(solver), clearingPrice);
    }

    function test_SolveWithHigherClearingPrice() public {
        AtomicQueueUCP.AtomicRequest memory request = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 5e6,
            offerAmount: 1e18,
            inSolve: false
        });

        vm.prank(USER_ONE);
        queue.updateAtomicRequest(offerToken, wantToken, request);

        address[] memory users = new address[](1);
        users[0] = USER_ONE;

        uint256 clearingPrice = 6e6; // Higher than user's atomic price - should succeed
        bytes memory runData = abi.encode(clearingPrice);

        uint256 userOfferBalanceBefore = offerToken.balanceOf(USER_ONE);
        uint256 userWantBalanceBefore = wantToken.balanceOf(USER_ONE);

        vm.prank(address(solver));
        queue.solve(offerToken, wantToken, users, runData, address(solver), clearingPrice);

        assertEq(offerToken.balanceOf(USER_ONE), userOfferBalanceBefore - request.offerAmount);
        assertEq(wantToken.balanceOf(USER_ONE), userWantBalanceBefore + 6e6);
    }

    function test_ViewSolveMetaData() public {
        AtomicQueueUCP.AtomicRequest memory request = AtomicQueueUCP.AtomicRequest({
            deadline: uint64(block.timestamp + 1 hours),
            atomicPrice: 5e6,
            offerAmount: 1e18,
            inSolve: false
        });

        vm.prank(USER_ONE);
        queue.updateAtomicRequest(offerToken, wantToken, request);

        address[] memory users = new address[](1);
        users[0] = USER_ONE;

        (AtomicQueueUCP.SolveMetaData[] memory metaData, uint256 totalAssetsForWant, uint256 totalAssetsToOffer) =
            queue.viewSolveMetaData(offerToken, wantToken, users, 5e6);

        assertEq(metaData[0].user, USER_ONE);
        assertEq(metaData[0].flags, 0);
        assertEq(metaData[0].assetsToOffer, 1e18);
        assertEq(metaData[0].assetsForWant, 5e6);
        assertEq(totalAssetsToOffer, 1e18);
        assertEq(totalAssetsForWant, 5e6);
    }

    function test_ViewSolveMetaData_MultipleFlags() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        AtomicQueueUCP.AtomicRequest memory request =
            AtomicQueueUCP.AtomicRequest({ deadline: deadline, atomicPrice: 5e6, offerAmount: 1e18, inSolve: false });

        vm.prank(USER_ONE);
        queue.updateAtomicRequest(offerToken, wantToken, request);

        // Make balance insufficient for this test
        uint256 balance = offerToken.balanceOf(USER_ONE);
        vm.prank(USER_ONE);
        offerToken.transfer(address(0), balance);

        // Move time forward past the deadline
        vm.warp(deadline + 1);

        address[] memory users = new address[](1);
        users[0] = USER_ONE;

        (AtomicQueueUCP.SolveMetaData[] memory metaData,,) = queue.viewSolveMetaData(offerToken, wantToken, users, 5e6);

        // Should have both deadline expired (bit 0) and insufficient balance (bit 2) flags set
        assertEq(metaData[0].flags, 0x5); // Binary: 101
    }

    function test_ToggleApprovedSolveCallers() public {
        address newSolver = makeAddr("NewSolver");
        address[] memory solvers = new address[](1);
        solvers[0] = newSolver;

        vm.prank(QUEUE_OWNER);
        queue.toggleApprovedSolveCallers(solvers);

        assertTrue(queue.isApprovedSolveCaller(newSolver));
    }

    function testFail_ToggleApprovedSolveCallers_NonOwner() public {
        address newSolver = makeAddr("NewSolver");
        address[] memory solvers = new address[](1);
        solvers[0] = newSolver;

        vm.prank(USER_ONE);
        queue.toggleApprovedSolveCallers(solvers);
    }
}
