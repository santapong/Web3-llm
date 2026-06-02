// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BountyEscrow (v0) — escrow settled by a single trusted AI resolver.
/// Funder escrows ETH against a bounty; an off-chain LLM resolver posts a verdict;
/// the escrow auto-settles to the claimant (fulfilled) or refunds the funder (not).
/// Staking, disputes, and challenge windows are LATER phases — not here.
contract BountyEscrow is Ownable, ReentrancyGuard {
    enum Status {
        Open,
        Resolved
    }

    struct Bounty {
        address funder;
        address claimant;
        uint256 amount;
        bytes32 specHash; // hash of acceptance criteria (full text lives off-chain)
        bytes32 prHash; // hash/ref of the PR under review
        Status status;
    }

    address public resolver; // the off-chain agent's signing address
    uint256 public nextId;
    mapping(uint256 => Bounty) public bounties;

    event BountyCreated(
        uint256 indexed id,
        address indexed funder,
        address indexed claimant,
        uint256 amount,
        bytes32 specHash,
        bytes32 prHash
    );
    event VerdictSubmitted(uint256 indexed id, bool fulfilled, string reasoning); // reasoning in the LOG (cheap), not storage
    event Settled(uint256 indexed id, bool fulfilled, address paidTo, uint256 amount);
    event ResolverUpdated(address indexed newResolver);

    modifier onlyResolver() {
        require(msg.sender == resolver, "not resolver");
        _;
    }

    constructor(address _resolver) Ownable(msg.sender) {
        resolver = _resolver;
    }

    // access-controlled — only owner can rotate the resolver key (Lesson 5)
    function setResolver(address _resolver) external onlyOwner {
        resolver = _resolver;
        emit ResolverUpdated(_resolver);
    }

    function createBounty(address claimant, bytes32 specHash, bytes32 prHash) external payable returns (uint256 id) {
        require(msg.value > 0, "no funds escrowed");
        require(claimant != address(0), "bad claimant");
        id = nextId++;
        bounties[id] = Bounty(msg.sender, claimant, msg.value, specHash, prHash, Status.Open);
        emit BountyCreated(id, msg.sender, claimant, msg.value, specHash, prHash);
    }

    /// v0: the verdict settles escrow immediately. CEI + nonReentrant (Lesson 4).
    function submitVerdict(uint256 id, bool fulfilled, string calldata reasoning) external onlyResolver nonReentrant {
        Bounty storage b = bounties[id];
        require(b.status == Status.Open, "already resolved");
        b.status = Status.Resolved; // EFFECT before interaction
        emit VerdictSubmitted(id, fulfilled, reasoning);

        address payable recipient = payable(fulfilled ? b.claimant : b.funder);
        uint256 amount = b.amount;
        (bool ok,) = recipient.call{value: amount}(""); // INTERACTION last
        require(ok, "payout failed");
        emit Settled(id, fulfilled, recipient, amount);
    }
}
