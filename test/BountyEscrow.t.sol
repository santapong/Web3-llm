// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BountyEscrow} from "../src/BountyEscrow.sol";

/// Phase 0 — prove the money moves correctly on command. No AI, no staking.
/// Every test here was validated against the contract's logic before being written.
contract BountyEscrowTest is Test {
    BountyEscrow escrow;

    address owner = address(this); // deployer = owner = resolver (Phase 0 simplest)
    address funder = makeAddr("funder");
    address claimant = makeAddr("claimant");
    address stranger = makeAddr("stranger");

    bytes32 constant SPEC = bytes32(uint256(1));
    bytes32 constant PR = bytes32(uint256(2));

    function setUp() public {
        escrow = new BountyEscrow(owner); // resolver = this contract
        vm.deal(funder, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    // 1. createBounty escrows the exact ETH and stores correct state
    function test_CreateBounty_EscrowsExactAmount() public {
        uint256 funderBefore = funder.balance;

        vm.prank(funder);
        uint256 id = escrow.createBounty{value: 1 ether}(claimant, SPEC, PR);

        (address f, address c, uint256 amt,,, BountyEscrow.Status status) = escrow.bounties(id);
        assertEq(f, funder, "funder wrong");
        assertEq(c, claimant, "claimant wrong");
        assertEq(amt, 1 ether, "amount wrong");
        assertEq(uint256(status), uint256(BountyEscrow.Status.Open), "should be Open");
        assertEq(funder.balance, funderBefore - 1 ether, "funder not debited");
        assertEq(address(escrow).balance, 1 ether, "escrow not funded");
    }

    // 2. verdict TRUE pays the claimant the full amount and marks Resolved
    function test_SubmitVerdict_True_PaysClaimant() public {
        vm.prank(funder);
        uint256 id = escrow.createBounty{value: 1 ether}(claimant, SPEC, PR);

        uint256 claimantBefore = claimant.balance;
        escrow.submitVerdict(id, true, "fulfilled");

        assertEq(claimant.balance, claimantBefore + 1 ether, "claimant not paid in full");
        assertEq(address(escrow).balance, 0, "escrow should be empty");
        (,,,,, BountyEscrow.Status status) = escrow.bounties(id);
        assertEq(uint256(status), uint256(BountyEscrow.Status.Resolved), "should be Resolved");
    }

    // 3. verdict FALSE refunds the funder
    function test_SubmitVerdict_False_RefundsFunder() public {
        vm.prank(funder);
        uint256 id = escrow.createBounty{value: 1 ether}(claimant, SPEC, PR);

        uint256 funderBefore = funder.balance;
        escrow.submitVerdict(id, false, "not fulfilled");

        assertEq(funder.balance, funderBefore + 1 ether, "funder not refunded");
        assertEq(address(escrow).balance, 0, "escrow should be empty");
    }

    // 4. a non-resolver cannot submit a verdict
    function test_SubmitVerdict_NonResolver_Reverts() public {
        vm.prank(funder);
        uint256 id = escrow.createBounty{value: 1 ether}(claimant, SPEC, PR);

        vm.prank(stranger);
        vm.expectRevert(bytes("not resolver"));
        escrow.submitVerdict(id, true, "hijack");
    }

    // 5. a bounty cannot be resolved twice
    function test_SubmitVerdict_DoubleResolve_Reverts() public {
        vm.prank(funder);
        uint256 id = escrow.createBounty{value: 1 ether}(claimant, SPEC, PR);
        escrow.submitVerdict(id, true, "first");

        vm.expectRevert(bytes("already resolved"));
        escrow.submitVerdict(id, true, "second");
    }

    // 6. a bounty with zero value is rejected
    function test_CreateBounty_ZeroValue_Reverts() public {
        vm.prank(funder);
        vm.expectRevert(bytes("no funds escrowed"));
        escrow.createBounty{value: 0}(claimant, SPEC, PR);
    }

    // 7. only the owner can rotate the resolver key
    function test_SetResolver_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        escrow.setResolver(stranger);

        escrow.setResolver(claimant); // owner (this contract) can
        assertEq(escrow.resolver(), claimant, "owner could not set resolver");
    }

    // allow this test contract to receive ETH (it's the resolver/owner in some paths)
    receive() external payable {}
}
