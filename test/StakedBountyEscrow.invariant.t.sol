// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StakedBountyEscrow} from "../src/StakedBountyEscrow.sol";

/// Drives the escrow through random, bounded action sequences. The handler plays every role
/// (resolver/arbiter/funder/challenger) so the invariants below judge only the *accounting*,
/// independent of who holds the keys.
contract Handler is Test {
    StakedBountyEscrow public escrow;
    uint256[] public ids;
    address constant CLAIMANT = address(0xCAFE);

    constructor(StakedBountyEscrow _escrow) {
        escrow = _escrow;
    }

    function deposit(uint96 amt) public {
        amt = uint96(bound(amt, 1, 10 ether));
        escrow.depositStake{value: amt}();
    }

    function withdraw(uint96 amt) public {
        uint256 free = escrow.freeStake();
        if (free == 0) return;
        amt = uint96(bound(amt, 1, free));
        escrow.withdrawStake(amt);
    }

    function createBounty(uint96 amt) public {
        amt = uint96(bound(amt, 1, 10 ether));
        ids.push(escrow.createBounty{value: amt}(CLAIMANT, bytes32(0), bytes32(0)));
    }

    function propose(uint256 seed, bool fulfilled) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        if (escrow.getBounty(id).status != StakedBountyEscrow.Status.Open) return;
        if (escrow.freeStake() < escrow.resolverBond()) return;
        escrow.submitVerdict(id, fulfilled, "");
    }

    function challengeOne(uint256 seed) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        StakedBountyEscrow.Bounty memory b = escrow.getBounty(id);
        if (b.status != StakedBountyEscrow.Status.Proposed) return;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > b.challengeDeadline) return;
        escrow.challenge{value: escrow.challengeBond()}(id);
    }

    function settleOne(uint256 seed) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        StakedBountyEscrow.Bounty memory b = escrow.getBounty(id);
        if (b.status != StakedBountyEscrow.Status.Proposed) return;
        // Test-only: jump past the window to exercise the settle path deterministically.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= b.challengeDeadline) vm.warp(uint256(b.challengeDeadline) + 1);
        escrow.settle(id);
    }

    function resolveOne(uint256 seed, bool right) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        if (escrow.getBounty(id).status != StakedBountyEscrow.Status.Disputed) return;
        escrow.resolveDispute(id, right);
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function idAt(uint256 i) external view returns (uint256) {
        return ids[i];
    }

    receive() external payable {}
}

contract StakedBountyEscrowInvariantTest is Test {
    StakedBountyEscrow escrow;
    Handler handler;

    function setUp() public {
        // handler is resolver + arbiter; this test contract is the owner.
        escrow = new StakedBountyEscrow(address(this), address(this), 3 days, 1 ether, 0.5 ether);
        handler = new Handler(escrow);
        escrow.setResolver(address(handler));
        escrow.setArbiter(address(handler));

        vm.deal(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    /// The escrow's ETH balance is always fully backed: resolver stake + escrowed principal of
    /// live bounties + challenge bonds locked in active disputes. Never more, never less.
    function invariant_solvency() public view {
        uint256 expected = escrow.resolverStake();
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            StakedBountyEscrow.Bounty memory b = escrow.getBounty(handler.idAt(i));
            if (
                b.status == StakedBountyEscrow.Status.Open || b.status == StakedBountyEscrow.Status.Proposed
                    || b.status == StakedBountyEscrow.Status.Disputed
            ) {
                expected += b.amount;
            }
            if (b.status == StakedBountyEscrow.Status.Disputed) {
                expected += b.challengeBondPaid;
            }
        }
        assertEq(address(escrow).balance, expected, "escrow balance must be fully backed");
    }

    /// Locked stake equals the sum of bonds on verdicts still in flight — bond locking and
    /// unlocking are always balanced.
    function invariant_lockedStakeMatchesOpenVerdicts() public view {
        uint256 lockedExpected;
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            StakedBountyEscrow.Bounty memory b = escrow.getBounty(handler.idAt(i));
            if (b.status == StakedBountyEscrow.Status.Proposed || b.status == StakedBountyEscrow.Status.Disputed) {
                lockedExpected += b.bondLocked;
            }
        }
        assertEq(escrow.lockedStake(), lockedExpected, "lockedStake must match in-flight verdicts");
        assertLe(escrow.lockedStake(), escrow.resolverStake(), "cannot lock more than staked");
    }
}
