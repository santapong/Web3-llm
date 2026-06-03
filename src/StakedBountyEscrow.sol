// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StakedBountyEscrow (v1) — optimistic escrow with a challenge window + resolver staking.
/// @notice Phase 1 of Web3-llm. Where v0 (`BountyEscrow`) trusts the resolver to settle instantly,
/// v1 makes the resolver *optimistic and accountable*:
///
///   1. The funder escrows ETH against a bounty.
///   2. The resolver (an off-chain LLM agent) posts a verdict — but money does NOT move yet.
///      The resolver must have skin in the game: a `resolverBond` of its stake is locked.
///   3. Anyone may `challenge` the verdict within the challenge window by posting a `challengeBond`.
///   4. If unchallenged past the deadline, anyone may `settle` and the verdict pays out.
///   5. If challenged, an `arbiter` (a human / DAO court of last resort) rules on the dispute.
///      - Verdict upheld  → challenger forfeits its bond to the resolver (anti-griefing).
///      - Verdict overturned → the resolver's locked bond is slashed to the challenger, the
///        challenger's own bond is refunded, and the *opposite* outcome pays out.
///
/// Design notes:
///  - Checks-Effects-Interactions + `nonReentrant` on every fund-moving path (Lesson 4).
///  - All admin levers are owner-gated; the resolver/arbiter keys are rotatable (Lesson 5).
///  - Verdict reasoning lives in the event log (cheap), never in storage.
///  - Solvency invariant (see test suite): the contract's ETH balance always equals
///    `held bounty principal + resolverStake + active challenge bonds`.
contract StakedBountyEscrow is Ownable, ReentrancyGuard {
    /// @dev `None` is the zero value so an unknown id is distinguishable from a live `Open` bounty.
    enum Status {
        None,
        Open,
        Proposed,
        Disputed,
        Settled
    }

    struct Bounty {
        address funder;
        address claimant;
        uint256 amount; // escrowed principal
        bytes32 specHash; // hash of acceptance criteria (full text off-chain)
        bytes32 prHash; // hash/ref of the PR under review
        Status status;
        bool fulfilled; // the current (proposed) verdict outcome
        uint64 challengeDeadline; // unix ts; verdict may be challenged until here
        address challenger; // who disputed the verdict (address(0) if none)
        uint256 bondLocked; // resolver stake locked against this verdict
        uint256 challengeBondPaid; // bond the challenger actually posted (terms are pinned per bounty)
    }

    // --- roles ---
    address public resolver; // the off-chain agent's signing address
    address public arbiter; // rules on disputes (human / DAO court of last resort)

    // --- resolver staking ---
    uint256 public resolverStake; // total ETH the resolver has staked
    uint256 public lockedStake; // portion currently locked against open verdicts

    // --- economic parameters (apply to future verdicts/challenges only) ---
    uint256 public challengePeriod; // seconds a verdict stays challengeable
    uint256 public resolverBond; // stake locked — and slashable — per verdict
    uint256 public challengeBond; // ETH a challenger must post to dispute

    // --- bounties ---
    uint256 public nextId;
    mapping(uint256 => Bounty) public bounties;

    // --- events ---
    event BountyCreated(
        uint256 indexed id,
        address indexed funder,
        address indexed claimant,
        uint256 amount,
        bytes32 specHash,
        bytes32 prHash
    );
    event VerdictProposed(uint256 indexed id, bool fulfilled, uint64 challengeDeadline, string reasoning);
    event Challenged(uint256 indexed id, address indexed challenger, uint256 bond);
    event DisputeResolved(uint256 indexed id, bool resolverWasRight, bool finalOutcome);
    event Settled(uint256 indexed id, bool fulfilled, address indexed paidTo, uint256 amount);
    event StakeDeposited(address indexed from, uint256 amount, uint256 totalStake);
    event StakeWithdrawn(address indexed to, uint256 amount, uint256 totalStake);
    event StakeSlashed(uint256 indexed id, address indexed to, uint256 amount);
    event ResolverUpdated(address indexed newResolver);
    event ArbiterUpdated(address indexed newArbiter);
    event ParamsUpdated(uint256 challengePeriod, uint256 resolverBond, uint256 challengeBond);

    modifier onlyResolver() {
        require(msg.sender == resolver, "not resolver");
        _;
    }

    modifier onlyArbiter() {
        require(msg.sender == arbiter, "not arbiter");
        _;
    }

    constructor(
        address _resolver,
        address _arbiter,
        uint256 _challengePeriod,
        uint256 _resolverBond,
        uint256 _challengeBond
    ) Ownable(msg.sender) {
        require(_resolver != address(0), "bad resolver");
        require(_arbiter != address(0), "bad arbiter");
        resolver = _resolver;
        arbiter = _arbiter;
        challengePeriod = _challengePeriod;
        resolverBond = _resolverBond;
        challengeBond = _challengeBond;
    }

    // ------------------------------------------------------------------ //
    //                              admin                                 //
    // ------------------------------------------------------------------ //

    function setResolver(address _resolver) external onlyOwner {
        require(_resolver != address(0), "bad resolver");
        resolver = _resolver;
        emit ResolverUpdated(_resolver);
    }

    function setArbiter(address _arbiter) external onlyOwner {
        require(_arbiter != address(0), "bad arbiter");
        arbiter = _arbiter;
        emit ArbiterUpdated(_arbiter);
    }

    /// @notice Tune economics. Only affects verdicts/challenges created *after* this call;
    /// in-flight bounties keep the terms they were created under (`bondLocked` is stored per bounty).
    function setParams(uint256 _challengePeriod, uint256 _resolverBond, uint256 _challengeBond) external onlyOwner {
        challengePeriod = _challengePeriod;
        resolverBond = _resolverBond;
        challengeBond = _challengeBond;
        emit ParamsUpdated(_challengePeriod, _resolverBond, _challengeBond);
    }

    // ------------------------------------------------------------------ //
    //                         resolver staking                           //
    // ------------------------------------------------------------------ //

    /// @notice Stake that is not currently locked against an open verdict.
    function freeStake() public view returns (uint256) {
        return resolverStake - lockedStake;
    }

    /// @notice Top up the resolver's stake. Permissionless so a sponsor can fund the agent.
    function depositStake() external payable {
        require(msg.value > 0, "no value");
        resolverStake += msg.value;
        emit StakeDeposited(msg.sender, msg.value, resolverStake);
    }

    /// @notice Withdraw free (unlocked) stake. CEI + nonReentrant.
    function withdrawStake(uint256 amount) external onlyResolver nonReentrant {
        require(amount > 0, "no value");
        require(amount <= freeStake(), "exceeds free stake");
        resolverStake -= amount; // EFFECT
        _send(resolver, amount); // INTERACTION
        emit StakeWithdrawn(resolver, amount, resolverStake);
    }

    // ------------------------------------------------------------------ //
    //                            bounties                                //
    // ------------------------------------------------------------------ //

    function createBounty(address claimant, bytes32 specHash, bytes32 prHash) external payable returns (uint256 id) {
        require(msg.value > 0, "no funds escrowed");
        require(claimant != address(0), "bad claimant");
        id = nextId++;
        Bounty storage b = bounties[id];
        b.funder = msg.sender;
        b.claimant = claimant;
        b.amount = msg.value;
        b.specHash = specHash;
        b.prHash = prHash;
        b.status = Status.Open;
        emit BountyCreated(id, msg.sender, claimant, msg.value, specHash, prHash);
    }

    /// @notice Resolver posts a verdict. No money moves; the resolver's bond is locked and a
    /// challenge window opens. Reasoning is logged, not stored.
    function submitVerdict(uint256 id, bool fulfilled, string calldata reasoning) external onlyResolver {
        Bounty storage b = bounties[id];
        require(b.status == Status.Open, "not open");
        require(freeStake() >= resolverBond, "insufficient stake");

        b.bondLocked = resolverBond;
        lockedStake += resolverBond;
        b.fulfilled = fulfilled;
        b.status = Status.Proposed;
        // Safe: a uint64 unix timestamp does not overflow until well past the year 584,000,000,000,
        // and the uint256 addition above already reverts on overflow under solc 0.8 checked math.
        // forge-lint: disable-next-line(unsafe-typecast)
        b.challengeDeadline = uint64(block.timestamp + challengePeriod);

        emit VerdictProposed(id, fulfilled, b.challengeDeadline, reasoning);
    }

    /// @notice Dispute a proposed verdict within the challenge window by posting `challengeBond`.
    /// Permissionless: anyone economically motivated can police the resolver.
    function challenge(uint256 id) external payable {
        Bounty storage b = bounties[id];
        require(b.status == Status.Proposed, "not challengeable");
        // Challenge windows are inherently time-based; a few seconds of validator drift is
        // negligible against a multi-hour/day window, so comparing block.timestamp is safe.
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp <= b.challengeDeadline, "window closed");
        require(msg.value == challengeBond, "wrong bond");

        b.status = Status.Disputed;
        b.challenger = msg.sender;
        b.challengeBondPaid = msg.value;
        emit Challenged(id, msg.sender, msg.value);
    }

    /// @notice Settle a verdict that survived the challenge window unchallenged. Permissionless.
    /// CEI + nonReentrant.
    function settle(uint256 id) external nonReentrant {
        Bounty storage b = bounties[id];
        require(b.status == Status.Proposed, "not settleable");
        // Time-based settlement after the challenge window; see note in challenge() on drift.
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp > b.challengeDeadline, "window open");

        // EFFECTS: release the resolver's bond and finalize.
        lockedStake -= b.bondLocked;
        b.status = Status.Settled;

        _payout(id, b, b.fulfilled); // INTERACTION (guarded)
    }

    /// @notice Arbiter rules on a disputed verdict. CEI + nonReentrant.
    /// @param resolverWasRight true if the original verdict stands; false to overturn it.
    function resolveDispute(uint256 id, bool resolverWasRight) external onlyArbiter nonReentrant {
        Bounty storage b = bounties[id];
        require(b.status == Status.Disputed, "not disputed");

        uint256 bond = b.bondLocked;
        uint256 chalBond = b.challengeBondPaid;
        address challenger = b.challenger;
        bool finalOutcome;

        // EFFECTS first: settle all internal accounting before any transfer.
        b.status = Status.Settled;
        lockedStake -= bond;

        if (resolverWasRight) {
            // Verdict stands. Resolver keeps its (now unlocked) bond; challenger forfeits its bond
            // to the resolver as an anti-griefing reward.
            finalOutcome = b.fulfilled;
        } else {
            // Verdict overturned. Slash the resolver's locked bond and flip the outcome.
            resolverStake -= bond;
            finalOutcome = !b.fulfilled;
        }

        emit DisputeResolved(id, resolverWasRight, finalOutcome);

        // INTERACTIONS last (function is nonReentrant; all state above is final).
        if (resolverWasRight) {
            _send(resolver, chalBond); // forfeited challenger bond rewards the resolver
        } else {
            // challenger gets: slashed resolver bond (reward) + its own bond back.
            emit StakeSlashed(id, challenger, bond);
            _send(challenger, bond + chalBond);
        }

        _payout(id, b, finalOutcome);
    }

    // ------------------------------------------------------------------ //
    //                             views                                  //
    // ------------------------------------------------------------------ //

    function getBounty(uint256 id) external view returns (Bounty memory) {
        return bounties[id];
    }

    // ------------------------------------------------------------------ //
    //                            internals                               //
    // ------------------------------------------------------------------ //

    /// @dev Pay the escrowed principal to the winner of `outcome`.
    function _payout(uint256 id, Bounty storage b, bool outcome) internal {
        address recipient = outcome ? b.claimant : b.funder;
        uint256 amount = b.amount;
        _send(recipient, amount);
        emit Settled(id, outcome, recipient, amount);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "transfer failed");
    }
}
