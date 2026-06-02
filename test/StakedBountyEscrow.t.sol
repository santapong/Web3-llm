// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StakedBountyEscrow} from "../src/StakedBountyEscrow.sol";

/// Phase 1 — prove the optimistic settlement + staking machinery is sound:
/// challenge window, permissionless settlement, arbiter disputes, and slashing.
contract StakedBountyEscrowTest is Test {
    StakedBountyEscrow escrow;

    address owner = address(this); // deployer = owner
    address resolver = makeAddr("resolver");
    address arbiter = makeAddr("arbiter");
    address funder = makeAddr("funder");
    address claimant = makeAddr("claimant");
    address challenger = makeAddr("challenger");
    address stranger = makeAddr("stranger");

    bytes32 constant SPEC = bytes32(uint256(1));
    bytes32 constant PR = bytes32(uint256(2));

    uint256 constant PERIOD = 3 days;
    uint256 constant R_BOND = 1 ether; // resolver bond locked/slashed per verdict
    uint256 constant C_BOND = 0.5 ether; // challenger bond

    function setUp() public {
        escrow = new StakedBountyEscrow(resolver, arbiter, PERIOD, R_BOND, C_BOND);
        vm.deal(resolver, 100 ether);
        vm.deal(funder, 100 ether);
        vm.deal(challenger, 100 ether);
        vm.deal(stranger, 100 ether);

        // resolver posts a working stake up front
        vm.prank(resolver);
        escrow.depositStake{value: 5 ether}();
    }

    // ---------------------------------------------------------------- //
    //                          helpers                                 //
    // ---------------------------------------------------------------- //

    function _open(uint256 amount) internal returns (uint256 id) {
        vm.prank(funder);
        id = escrow.createBounty{value: amount}(claimant, SPEC, PR);
    }

    function _propose(uint256 id, bool fulfilled) internal {
        vm.prank(resolver);
        escrow.submitVerdict(id, fulfilled, "reasoned");
    }

    function _challenge(uint256 id) internal {
        vm.prank(challenger);
        escrow.challenge{value: C_BOND}(id);
    }

    // ---------------------------------------------------------------- //
    //                          staking                                 //
    // ---------------------------------------------------------------- //

    function test_DepositStake_IncreasesStakeAndBalance() public {
        assertEq(escrow.resolverStake(), 5 ether);
        assertEq(escrow.freeStake(), 5 ether);
        assertEq(address(escrow).balance, 5 ether);
    }

    function test_DepositStake_ZeroValue_Reverts() public {
        vm.prank(resolver);
        vm.expectRevert(bytes("no value"));
        escrow.depositStake{value: 0}();
    }

    function test_WithdrawStake_FreeOnly() public {
        vm.prank(resolver);
        escrow.withdrawStake(2 ether);
        assertEq(escrow.resolverStake(), 3 ether);
        assertEq(resolver.balance, 100 ether - 5 ether + 2 ether);
    }

    function test_WithdrawStake_ExceedingFree_Reverts() public {
        uint256 id = _open(1 ether);
        _propose(id, true); // locks R_BOND (1 ether), free = 4 ether

        vm.prank(resolver);
        vm.expectRevert(bytes("exceeds free stake"));
        escrow.withdrawStake(4 ether + 1);
    }

    function test_WithdrawStake_OnlyResolver() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not resolver"));
        escrow.withdrawStake(1 ether);
    }

    // ---------------------------------------------------------------- //
    //                        createBounty                              //
    // ---------------------------------------------------------------- //

    function test_CreateBounty_EscrowsAndStores() public {
        uint256 id = _open(1 ether);
        StakedBountyEscrow.Bounty memory b = escrow.getBounty(id);
        assertEq(b.funder, funder);
        assertEq(b.claimant, claimant);
        assertEq(b.amount, 1 ether);
        assertEq(uint256(b.status), uint256(StakedBountyEscrow.Status.Open));
        assertEq(address(escrow).balance, 5 ether + 1 ether); // stake + principal
    }

    function test_CreateBounty_ZeroValue_Reverts() public {
        vm.prank(funder);
        vm.expectRevert(bytes("no funds escrowed"));
        escrow.createBounty{value: 0}(claimant, SPEC, PR);
    }

    function test_CreateBounty_BadClaimant_Reverts() public {
        vm.prank(funder);
        vm.expectRevert(bytes("bad claimant"));
        escrow.createBounty{value: 1 ether}(address(0), SPEC, PR);
    }

    // ---------------------------------------------------------------- //
    //                       submitVerdict                              //
    // ---------------------------------------------------------------- //

    function test_SubmitVerdict_LocksBondAndOpensWindow() public {
        uint256 id = _open(1 ether);
        _propose(id, true);

        StakedBountyEscrow.Bounty memory b = escrow.getBounty(id);
        assertEq(uint256(b.status), uint256(StakedBountyEscrow.Status.Proposed));
        assertTrue(b.fulfilled);
        assertEq(b.bondLocked, R_BOND);
        assertEq(escrow.lockedStake(), R_BOND);
        assertEq(escrow.freeStake(), 5 ether - R_BOND);
        assertEq(b.challengeDeadline, block.timestamp + PERIOD);
    }

    function test_SubmitVerdict_OnlyResolver() public {
        uint256 id = _open(1 ether);
        vm.prank(stranger);
        vm.expectRevert(bytes("not resolver"));
        escrow.submitVerdict(id, true, "x");
    }

    function test_SubmitVerdict_RequiresOpen() public {
        uint256 id = _open(1 ether);
        _propose(id, true);
        vm.prank(resolver);
        vm.expectRevert(bytes("not open"));
        escrow.submitVerdict(id, true, "again");
    }

    function test_SubmitVerdict_InsufficientStake_Reverts() public {
        // drain free stake below the bond
        vm.prank(resolver);
        escrow.withdrawStake(5 ether); // free stake now 0
        uint256 id = _open(1 ether);
        vm.prank(resolver);
        vm.expectRevert(bytes("insufficient stake"));
        escrow.submitVerdict(id, true, "x");
    }

    // ---------------------------------------------------------------- //
    //                     settle (unchallenged)                        //
    // ---------------------------------------------------------------- //

    function test_Settle_True_PaysClaimant_AfterWindow() public {
        uint256 id = _open(1 ether);
        _propose(id, true);

        vm.warp(block.timestamp + PERIOD + 1);
        uint256 before = claimant.balance;
        escrow.settle(id); // permissionless

        assertEq(claimant.balance, before + 1 ether);
        assertEq(escrow.lockedStake(), 0); // bond released back to free stake
        assertEq(escrow.resolverStake(), 5 ether);
        StakedBountyEscrow.Bounty memory b = escrow.getBounty(id);
        assertEq(uint256(b.status), uint256(StakedBountyEscrow.Status.Settled));
    }

    function test_Settle_False_RefundsFunder_AfterWindow() public {
        uint256 id = _open(1 ether);
        _propose(id, false);

        vm.warp(block.timestamp + PERIOD + 1);
        uint256 before = funder.balance;
        escrow.settle(id);
        assertEq(funder.balance, before + 1 ether);
    }

    function test_Settle_BeforeWindow_Reverts() public {
        uint256 id = _open(1 ether);
        _propose(id, true);
        vm.expectRevert(bytes("window open"));
        escrow.settle(id);
    }

    function test_Settle_NotProposed_Reverts() public {
        uint256 id = _open(1 ether);
        vm.expectRevert(bytes("not settleable"));
        escrow.settle(id);
    }

    // ---------------------------------------------------------------- //
    //                          challenge                               //
    // ---------------------------------------------------------------- //

    function test_Challenge_MovesToDisputed() public {
        uint256 id = _open(1 ether);
        _propose(id, true);
        _challenge(id);

        StakedBountyEscrow.Bounty memory b = escrow.getBounty(id);
        assertEq(uint256(b.status), uint256(StakedBountyEscrow.Status.Disputed));
        assertEq(b.challenger, challenger);
        assertEq(b.challengeBondPaid, C_BOND);
        assertEq(address(escrow).balance, 5 ether + 1 ether + C_BOND);
    }

    function test_Challenge_WrongBond_Reverts() public {
        uint256 id = _open(1 ether);
        _propose(id, true);
        vm.prank(challenger);
        vm.expectRevert(bytes("wrong bond"));
        escrow.challenge{value: C_BOND - 1}(id);
    }

    function test_Challenge_AfterWindow_Reverts() public {
        uint256 id = _open(1 ether);
        _propose(id, true);
        vm.warp(block.timestamp + PERIOD + 1);
        vm.prank(challenger);
        vm.expectRevert(bytes("window closed"));
        escrow.challenge{value: C_BOND}(id);
    }

    function test_Challenge_NotProposed_Reverts() public {
        uint256 id = _open(1 ether);
        vm.prank(challenger);
        vm.expectRevert(bytes("not challengeable"));
        escrow.challenge{value: C_BOND}(id);
    }

    function test_Challenge_Twice_Reverts() public {
        uint256 id = _open(1 ether);
        _propose(id, true);
        _challenge(id);
        vm.prank(stranger);
        vm.expectRevert(bytes("not challengeable"));
        escrow.challenge{value: C_BOND}(id);
    }

    // ---------------------------------------------------------------- //
    //                       resolveDispute                             //
    // ---------------------------------------------------------------- //

    function test_ResolveDispute_Upheld_RewardsResolver_PaysOriginal() public {
        uint256 id = _open(1 ether);
        _propose(id, true); // verdict: fulfilled -> claimant should be paid
        _challenge(id);

        uint256 resolverBefore = resolver.balance;
        uint256 claimantBefore = claimant.balance;
        uint256 challengerBefore = challenger.balance;

        vm.prank(arbiter);
        escrow.resolveDispute(id, true); // resolver was right

        // resolver gets the forfeited challenge bond; stake intact
        assertEq(resolver.balance, resolverBefore + C_BOND);
        assertEq(escrow.resolverStake(), 5 ether);
        assertEq(escrow.lockedStake(), 0);
        // original outcome pays the claimant; challenger loses its bond
        assertEq(claimant.balance, claimantBefore + 1 ether);
        assertEq(challenger.balance, challengerBefore); // bond forfeited
        assertEq(address(escrow).balance, 5 ether); // only stake remains
    }

    function test_ResolveDispute_Overturned_SlashesResolver_FlipsOutcome() public {
        uint256 id = _open(1 ether);
        _propose(id, true); // verdict: fulfilled (claimant). Overturn -> funder paid.
        _challenge(id);

        uint256 funderBefore = funder.balance;
        uint256 claimantBefore = claimant.balance;
        uint256 challengerBefore = challenger.balance;

        vm.prank(arbiter);
        escrow.resolveDispute(id, false); // resolver was wrong

        // resolver slashed by the bond
        assertEq(escrow.resolverStake(), 5 ether - R_BOND);
        assertEq(escrow.lockedStake(), 0);
        // challenger refunded its own bond (C_BOND) AND rewarded the slashed resolver bond (R_BOND);
        // net profit over the original 100 ether is exactly R_BOND.
        assertEq(challenger.balance, challengerBefore + C_BOND + R_BOND);
        // outcome flipped: funder refunded, claimant gets nothing
        assertEq(funder.balance, funderBefore + 1 ether);
        assertEq(claimant.balance, claimantBefore);
        assertEq(address(escrow).balance, 5 ether - R_BOND); // remaining stake only
    }

    function test_ResolveDispute_Overturned_FalseVerdict_PaysClaimant() public {
        uint256 id = _open(1 ether);
        _propose(id, false); // verdict: NOT fulfilled (funder). Overturn -> claimant paid.
        _challenge(id);

        uint256 claimantBefore = claimant.balance;
        vm.prank(arbiter);
        escrow.resolveDispute(id, false);

        assertEq(claimant.balance, claimantBefore + 1 ether);
    }

    function test_ResolveDispute_OnlyArbiter() public {
        uint256 id = _open(1 ether);
        _propose(id, true);
        _challenge(id);
        vm.prank(stranger);
        vm.expectRevert(bytes("not arbiter"));
        escrow.resolveDispute(id, true);
    }

    function test_ResolveDispute_NotDisputed_Reverts() public {
        uint256 id = _open(1 ether);
        _propose(id, true);
        vm.prank(arbiter);
        vm.expectRevert(bytes("not disputed"));
        escrow.resolveDispute(id, true);
    }

    // ---------------------------------------------------------------- //
    //                           admin                                  //
    // ---------------------------------------------------------------- //

    function test_SetResolver_OnlyOwner_AndNonZero() public {
        vm.prank(stranger);
        vm.expectRevert(); // OZ Ownable
        escrow.setResolver(stranger);

        vm.expectRevert(bytes("bad resolver"));
        escrow.setResolver(address(0));

        escrow.setResolver(stranger);
        assertEq(escrow.resolver(), stranger);
    }

    function test_SetArbiter_OnlyOwner_AndNonZero() public {
        vm.prank(stranger);
        vm.expectRevert();
        escrow.setArbiter(stranger);

        vm.expectRevert(bytes("bad arbiter"));
        escrow.setArbiter(address(0));

        escrow.setArbiter(stranger);
        assertEq(escrow.arbiter(), stranger);
    }

    function test_SetParams_OnlyOwner_AffectsFutureOnly() public {
        // pin an in-flight bounty under the original terms
        uint256 id = _open(1 ether);
        _propose(id, true);
        StakedBountyEscrow.Bounty memory b = escrow.getBounty(id);
        assertEq(b.bondLocked, R_BOND);

        vm.prank(stranger);
        vm.expectRevert();
        escrow.setParams(1 days, 2 ether, 1 ether);

        escrow.setParams(1 days, 2 ether, 1 ether);
        assertEq(escrow.challengePeriod(), 1 days);
        assertEq(escrow.resolverBond(), 2 ether);
        assertEq(escrow.challengeBond(), 1 ether);

        // the already-proposed bounty keeps its locked bond of R_BOND
        assertEq(escrow.getBounty(id).bondLocked, R_BOND);
    }

    function test_SetParams_ChallengeBondChange_DoesNotAffectInflightDispute() public {
        uint256 id = _open(1 ether);
        _propose(id, true);
        _challenge(id); // challenger paid C_BOND

        // owner raises the challenge bond AFTER the challenge was posted
        escrow.setParams(PERIOD, R_BOND, 5 ether);

        uint256 challengerBefore = challenger.balance;
        vm.prank(arbiter);
        escrow.resolveDispute(id, false); // overturned -> refund original C_BOND, not the new 5 ether

        assertEq(challenger.balance, challengerBefore + R_BOND + C_BOND);
    }

    // ---------------------------------------------------------------- //
    //                       fuzz / property                            //
    // ---------------------------------------------------------------- //

    /// The settled recipient always receives exactly the escrowed principal, for any amount
    /// and either verdict, and the escrow keeps only the resolver's stake afterwards.
    function testFuzz_Settle_PaysExactPrincipal(uint96 amount, bool fulfilled) public {
        amount = uint96(bound(amount, 1, 50 ether));
        vm.prank(funder);
        uint256 id = escrow.createBounty{value: amount}(claimant, SPEC, PR);
        _propose(id, fulfilled);

        address winner = fulfilled ? claimant : funder;
        uint256 before = winner.balance;

        vm.warp(block.timestamp + PERIOD + 1);
        escrow.settle(id);

        assertEq(winner.balance, before + amount, "winner paid exact principal");
        assertEq(address(escrow).balance, 5 ether, "only stake remains");
    }

    receive() external payable {}
}
