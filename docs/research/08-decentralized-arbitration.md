# Research #08 — Decentralized / Optimistic Arbitration (P4)

_Researcher: feature-researcher agent. Date: 2026-06-20._
_Stack: Solidity 0.8.26 + OZ v5.6.1 + Foundry; resolver TypeScript + viem._

---

## 1. What & Why for web3-llm

`StakedBountyEscrow` (v1) already implements an optimistic settlement loop: the
Claude resolver posts a verdict, a challenge window opens, and if no one disputes
it the bounty settles automatically. This is good design. The one remaining trust
point is `resolveDispute`: when a challenger does appear, a single **`arbiter`**
address (set by the owner) calls `resolveDispute(id, resolverWasRight)` as the
court of last resort. That address is a human or DAO key — a centralized,
corruptible, capturable single point.

For v0 / early real-world use this is fine: the arbiter is likely the founding
team, the stakes are small, and the accountability story is already strong
(Claude's stake is slashed if it's wrong). But once the product has real economic
weight (P3+), the arbiter becomes the principal attack surface. A DAO treasurer
with $50 k escrowed has a legitimate question: _what's stopping the arbiter from
ruling for whoever bribes them?_

Decentralized arbitration replaces (or backs) the single-key arbiter with a
crypto-economic dispute protocol where the ruling emerges from many independent
actors (jurors, token voters) who are economically penalized for dishonest
decisions. The three mature candidates are:

- **UMA's Optimistic Oracle v3** (OOv3) — assert-and-dispute, final arbitration
  by UMA token-holder DVM voting.
- **Kleros** — ERC-792-standard juror courts, specialized subcourts per domain,
  appeal mechanism.
- **Reality.eth + Kleros proxy** — bond-escalation question oracle with pluggable
  arbitration backend (usually Kleros).

This report compares them for the specific use-case of "did this GitHub PR
fulfill this bounty's acceptance criteria?" — an **intersubjective, qualitative**
question, not a price feed.

---

## 2. How the Leaders Do It

### 2a. UMA Optimistic Oracle v3 (OOv3)

**Sources:**
- UMA OOv3 overview: https://blog.uma.xyz/articles/what-is-umas-optimistic-oracle
- OOv3 developer docs: https://docs.uma.xyz/developers/optimistic-oracle-v3
- In-depth insurance tutorial: https://docs.uma.xyz/developers/optimistic-oracle-v3/in-depth-tutorial-insurance
- Dev quickstart repo: https://github.com/UMAprotocol/dev-quickstart-oov3
- DVM 2.0 docs: https://docs.uma.xyz/protocol-overview/dvm-2.0

**Mechanism.** OOv3 is a "true-or-false" oracle. An _asserter_ posts a
`bytes` claim — an arbitrary UTF-8 statement like _"PR #42 fulfilled the
acceptance criteria described in specHash 0xabcd…"_ — along with an ERC-20 bond
and a _liveness_ window (default: 2 hours, configurable). If nobody disputes the
claim within the liveness window, `settleAssertion()` marks it truthful and
triggers a callback on the integrating contract. If a _disputer_ calls
`disputeAssertion()` with a matching bond, the claim is escalated to the **Data
Verification Mechanism (DVM)** — UMA token holders vote via a commit-reveal
scheme over 48–96 hours. The majority ruling wins; the loser forfeits their bond
and the winner gets it plus half the loser's bond.

**Integration interface (key Solidity surface).**

```solidity
// Integrating contract imports this and stores a reference at construction time.
interface OptimisticOracleV3Interface {
    function assertTruth(
        bytes memory claim,          // UTF-8 statement of the assertion
        address asserter,            // who put up the bond
        address callbackRecipient,   // address that receives callbacks
        address escalationManager,   // 0x0 = no custom escalation
        uint64  assertionLiveness,   // seconds until optimistic settlement
        IERC20  currency,            // bond token (WETH, USDC, etc.)
        uint256 bond,                // bond amount (>= getMinimumBond(token))
        bytes32 identifier,          // ASSERT_TRUTH (UMIP-170) or custom
        bytes32 domainId             // 0 if unused (saves gas)
    ) external returns (bytes32 assertionId);

    function settleAssertion(bytes32 assertionId) external;
    function disputeAssertion(bytes32 assertionId, address disputer) external;
    function getMinimumBond(address token) external view returns (uint256);
}

// The callbackRecipient contract (i.e. StakedBountyEscrow or a wrapper) must implement:
interface OptimisticOracleV3CallbackRecipientInterface {
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;
    function assertionDisputedCallback(bytes32 assertionId) external; // optional but useful
}
```

The `assertionResolvedCallback` is the key hook: `assertedTruthfully == true`
means the assertion stood unchallenged _or_ the DVM voted for it; `false` means
the DVM overturned it.

**Practical example (from the insurance tutorial).** A claim looks like:

```
"Insurance contract is claiming that insurance event <insuredEvent>
had occurred as of <timestamp>."
```

For web3-llm, this maps naturally to:

```
"Bounty #<id>: the pull request at <prHash> fulfilled the acceptance
criteria described in specHash <specHash> as judged by the Verdict
resolver on <timestamp>."
```

The asserter would be the resolver's signing address; the bond would be drawn
from resolver stake (ERC-20 approval needed, since OOv3 pulls via transferFrom).

**Cost & latency.**
- Happy path (no dispute): liveness window (configurable 2 h+), ~$5–20 in gas
  on Ethereum mainnet, near-zero on an L2.
- Disputed path: DVM voting takes 48–96 hours total (debate + commit + reveal
  phases). Bond size at Polymarket's production deployment is ~$750 USDC; smaller
  deployments can set lower minimums via `getMinimumBond`.
- ~1.5% of OOv3 assertions are disputed in production (Polymarket data).

**Suitability for "did this PR meet criteria?".** OOv3 was explicitly designed
for _intersubjective_ data (it calls this out in UMIP-170). Polymarket uses it
for subjective questions like election outcomes. The DVM voters must evaluate the
claim text against publicly available evidence — which means the PR diff and spec
text must be publicly accessible or embedded in the claim. UMA governance can
also reject disputes they find frivolous (via the escalation manager). The
principal risk is that DVM voters are token holders optimizing for token price,
not domain experts in software quality — they may resolve ambiguous "did this PR
fulfill criteria X?" questions based on superficial reading.

---

### 2b. Kleros (ERC-792 Arbitration Standard)

**Sources:**
- ERC-792 standard: https://docs.kleros.io/developer/arbitration-development/erc-792-arbitration-standard
- ERC-792 GitHub: https://github.com/kleros/erc-792
- Kleros Court smart contract integration: https://docs.kleros.io/integrations/types-of-integrations/1.-dispute-resolution-integration-plan/smart-contract-integration
- Kleros 2026 project update: https://blog.kleros.io/kleros-project-update-2026/
- Court V2 integration: https://blog.kleros.io/court-v2-integration-sneak-peek/

**Mechanism.** Kleros is a decentralized juror court. Jurors stake **PNK**
tokens to be randomly drawn (probability weighted by stake) into cases. Drawn
jurors vote in a commit-reveal scheme; those voting with the majority keep their
stake and earn the arbitration fee. Dissenters are slashed. The appeal mechanism
doubles the juror count each round, making corruption increasingly expensive.

Kleros provides _specialized subcourts_: a "Software Development" court exists
where jurors are required to hold PNK staked specifically for technical cases,
creating at least nominal domain filtering. Court v2 launched on Arbitrum One
in November 2024, with expansion to Base, Polygon, and zkSync through 2025, and
dramatically lower gas costs than mainnet v1.

**Integration interface (ERC-792 standard).** Any contract wishing to use
Kleros (or any ERC-792 arbitrator) must implement the `IArbitrable` interface:

```solidity
interface IArbitrable {
    // Called by the Arbitrator after a final ruling is given.
    function rule(uint256 _disputeID, uint256 _ruling) external;

    event Ruling(IArbitrator indexed _arbitrator, uint256 indexed _disputeID, uint256 _ruling);
    event DisputeCreation(uint256 indexed _disputeID, IArbitrable indexed _arbitrable);
    event AppealPossible(uint256 indexed _disputeID, IArbitrable indexed _arbitrable);
    event AppealDecision(uint256 indexed _disputeID, IArbitrable indexed _arbitrable);
}

interface IArbitrator {
    enum DisputeStatus { Waiting, Appealable, Solved }

    function arbitrationCost(bytes calldata _extraData) external view returns (uint256);
    function createDispute(uint256 _choices, bytes calldata _extraData)
        external payable returns (uint256 disputeID);
    function appeal(uint256 _disputeID, bytes calldata _extraData) external payable;
    function appealCost(uint256 _disputeID, bytes calldata _extraData) external view returns (uint256);
    function appealPeriod(uint256 _disputeID) external view returns (uint256 start, uint256 end);
    function disputeStatus(uint256 _disputeID) external view returns (DisputeStatus);
    function currentRuling(uint256 _disputeID) external view returns (uint256);
}
```

To create a dispute, the integrating contract calls:

```solidity
uint256 cost = arbitrator.arbitrationCost(extraData);
uint256 disputeId = arbitrator.createDispute{value: cost}(2, extraData);
// _choices = 2: ruling 1 = resolver was right, ruling 2 = resolver was wrong
```

The Kleros court will eventually call back `rule(disputeId, ruling)` on the
arbitrable contract. The `_extraData` bytes encode the target subcourt and number
of initial jurors (e.g. 3).

**Cost & latency.**
- Arbitration fee is `feePerJuror × numberOfJurors`; currently a few tens of
  dollars per dispute on Arbitrum/Gnosis, near-zero gas.
- Resolution time: ~3–7 days for a first-round ruling; appeals add more rounds.
- Juror fees are stablecoin-denominated on v2 networks, so costs are predictable.

**Suitability.** Kleros is the best match for subjective qualitative disputes
because it specifically offers a Software Development subcourt and supports
attaching evidence (via ERC-1497). Jurors are expected to read the PR, the spec,
and the Claude reasoning log before ruling. The commit-reveal with Schelling-
point incentives handles ambiguous cases better than DVM token voting, because
the jurors' job description is specifically "evaluate this dispute" rather than
"vote to maintain token value." The appeal mechanism gives both parties a
recourse path if the first round is clearly wrong.

The weakness: Kleros jurors are anonymous humans who may not actually be software
engineers. A highly technical dispute about whether a distributed caching layer
meets performance criteria requires domain expertise that random PNK stakers
may not have. The Software Development court has policies that jurors are
supposed to follow, but enforcement is by economic incentive alone.

---

### 2c. Reality.eth (Realitio) + Kleros Arbitrator Proxy

**Sources:**
- Reality.eth docs: https://realitio.github.io/docs/html/
- Arbitrator docs: https://realitio.github.io/docs/html/arbitrators.html
- Reality.eth from contract: https://reality.eth.link/app/docs/html/contracts.html
- Kleros Reality.eth + Kleros guide: https://docs.kleros.io/integrations/types-of-integrations/1.-dispute-resolution-integration-plan/channel-partners/how-to-use-reality.eth-+-kleros-as-an-oracle
- Kleros Reality.eth proxy v2: https://github.com/kleros/reality-v2

**Mechanism.** Reality.eth is a bond-escalation question oracle. A _questioner_
(a smart contract or user) calls `askQuestion(...)` posting a question text
(`"Did PR #42 fulfill the acceptance criteria in specHash 0xabcd...? [Yes/No]"`)
and a small reward. Answerers post bonds to claim the current best answer; each
new conflicting answer must double the previous bond, creating an escalating-cost
game that incentivizes correct answers. After a timeout with no bond challenge,
the final answer becomes canonical.

If either party calls `requestArbitration()` (and pays the arbitrator's fee),
the question is frozen and handed to a pluggable arbitrator — in practice almost
always the **Kleros Reality.eth proxy**, which creates a Kleros Court dispute and
reports the ruling back as the final answer. The key addition vs. direct Kleros
integration is the **bond-escalation pre-filter**: most disputes are resolved
cheaply by the bond game without ever involving Kleros at all.

**Integration interface.**

```solidity
interface IRealityETH {
    function askQuestion(
        uint256 template_id,      // 0 = binary yes/no (uint: 0 or 1)
        string calldata question, // question text
        address arbitrator,       // the arbitrator contract (Kleros proxy)
        uint32  timeout,          // seconds of inactivity to finalize
        uint32  opening_ts,       // timestamp from which answers are accepted
        uint256 nonce             // for uniqueness
    ) external payable returns (bytes32 question_id);

    function submitAnswer(
        bytes32 question_id,
        bytes32 answer,           // bytes32(1) = Yes, bytes32(0) = No
        uint256 max_previous      // anti-frontrunning: max acceptable prev bond
    ) external payable;

    function getFinalAnswer(bytes32 question_id) external view returns (bytes32);
    function isFinalized(bytes32 question_id) external view returns (bool);
    function getArbitrator(bytes32 question_id) external view returns (address);
}
```

After `isFinalized(question_id)` returns true, the consuming contract reads
`getFinalAnswer(question_id)` — `bytes32(uint256(1))` = Yes (fulfilled),
`bytes32(0)` = No (not fulfilled).

**Kleros proxy contract** (deployed on mainnet at `0x728cba71a3723caab33ea416cb46e2cc9215a596` for General Court; also on Polygon, Arbitrum) is what you pass as `arbitrator`.

**Cost & latency.**
- Happy path (no dispute, bond game resolves it): small reward (configurable,
  even 0 for permissioned setups) + gas. Fast: timeout can be set as low as 24 h.
- Arbitration path (Kleros): pay arbitrator fee (~few tens of dollars) + 3–7 days.
- There is no minimum bond enforced by the protocol; the integrator sets the
  opening bond via the first `submitAnswer` call.

**Suitability.** Reality.eth is excellent when the question can be phrased as
a yes/no and the "crowd" can answer it correctly without intervention. For PR
fulfillment this is plausible: after Claude publishes its reasoning on-chain,
anyone can read the PR diff + spec + reasoning and submit an answer. The bond-
escalation filter catches low-quality disputes before they reach Kleros. However,
Reality.eth has no native evidence attachment standard; the quality of community
responses depends entirely on the question being self-contained. Template 1
(binary yes/no) is the right template_id.

---

## 3. Recommended Approach in This Stack

### 3a. Why not Reality.eth

Reality.eth adds a second oracle layer between web3-llm and Kleros. That adds
complexity (two contracts to integrate, two bond pools to reason about) without
clear benefit for this use-case. The bond-escalation pre-filter is valuable when
_anyone_ in the crowd can answer; for "did this PR meet criteria?" the relevant
people are already the challenger (who has already posted `challengeBond` in
`StakedBountyEscrow`) and the funder. The double-bond game mostly just adds
latency and UX friction. Verdict: use Kleros directly, not via Reality.eth.

### 3b. Why not UMA OOv3 as the primary

UMA is the right choice when you need an optimistic path with DVM as backstop
and you don't need specialized human judgment. For web3-llm's dispute question,
DVM voters (UMA token holders) are not software engineers and have no obligation
to read a 2,000-line diff carefully. In production (Polymarket), UMA works well
for factual questions ("who won the election?") that have unambiguous verifiable
answers. "Did this PR fulfill these acceptance criteria?" is inherently
qualitative. DVM voters optimizing to vote with the majority on a technical
question they don't understand create a Schelling point around whatever Claude
said — making the decentralized arbiter effectively a rubber stamp for Claude.
That defeats the purpose.

**However, UMA OOv3 is the right internal component to replace the `Proposed →
Disputed` transition**, not the dispute resolution itself. The existing v1
`challenge()` + `challengeDeadline` logic is already structurally identical to
OOv3's liveness window. If web3-llm wanted to become a general UMA integration
(e.g. to tap UMA's existing liquidity and tooling), the `submitVerdict` path
could be replaced by `assertTruth`. This is a separate architectural decision
from who adjudicates disputes.

### 3c. Recommended: Kleros ERC-792 integration (when the time comes)

Kleros is the best fit because:
1. The Software Development subcourt has domain-filtered jurors.
2. ERC-792 is a clean, stable standard — the interface is 4 functions.
3. Court v2 on Arbitrum drastically cuts cost and latency vs. mainnet v1.
4. The appeal mechanism is genuinely adversarial, not just "the majority wins."
5. On-chain evidence attachment (ERC-1497) allows the Claude reasoning log
   (already in event logs) to be presented to jurors as admissible evidence.

**Concrete Solidity changes to `StakedBountyEscrow`.**

The minimal change adds an `IArbitrator` reference and overhauls `resolveDispute`
into a Kleros-triggered callback:

```solidity
// New file: src/interfaces/IArbitrator.sol
// (copy IArbitrator + IArbitrable from github.com/kleros/erc-792)
import {IArbitrator} from "./interfaces/IArbitrator.sol";
import {IArbitrable} from "./interfaces/IArbitrable.sol";

contract StakedBountyEscrow is Ownable, ReentrancyGuard, IArbitrable {

    IArbitrator public arbitrator;           // e.g. Kleros Court on Arbitrum
    bytes       public arbitratorExtraData;  // encodes subcourt + juror count
    mapping(uint256 => uint256) public disputeIdToBountyId;  // Kleros ID → bounty ID

    // Replace onlyArbiter resolveDispute with:

    /// @notice Called by challenger after status == Disputed, pays Kleros fee.
    function escalateToArbitrator(uint256 bountyId) external payable nonReentrant {
        Bounty storage b = bounties[bountyId];
        require(b.status == Status.Disputed, "not disputed");
        require(msg.value >= arbitrator.arbitrationCost(arbitratorExtraData), "fee too low");

        uint256 klerosId = arbitrator.createDispute{value: msg.value}(
            2,                    // 2 choices: ruling 1 = uphold, 2 = overturn
            arbitratorExtraData
        );
        disputeIdToBountyId[klerosId] = bountyId;
        // Emit evidence event (ERC-1497) so Kleros UI picks up the reasoning log
        emit Evidence(arbitrator, klerosId, msg.sender, string(abi.encodePacked(
            "bountyId=", Strings.toString(bountyId)
        )));
    }

    /// @notice ERC-792 callback from Kleros after jurors rule.
    function rule(uint256 _disputeID, uint256 _ruling)
        external override nonReentrant
    {
        require(msg.sender == address(arbitrator), "not arbitrator");
        uint256 bountyId = disputeIdToBountyId[_disputeID];
        Bounty storage b = bounties[bountyId];
        require(b.status == Status.Disputed, "not disputed");

        // ruling 1 = resolver was right; ruling 2 = resolver overturned; 0 = refused to rule
        bool resolverWasRight = (_ruling == 1);
        _finalizeDispute(bountyId, b, resolverWasRight);
        emit Ruling(arbitrator, _disputeID, _ruling);
    }

    // _finalizeDispute is the existing resolveDispute logic, extracted:
    function _finalizeDispute(uint256 id, Bounty storage b, bool resolverWasRight)
        internal { /* existing CEI logic from resolveDispute */ }
}
```

**Key files to create/modify:**

| File | Change |
|------|--------|
| `src/StakedBountyEscrow.sol` | Add `IArbitrable`, `arbitrator` storage, `escalateToArbitrator`, `rule` callback; extract `_finalizeDispute`; keep old `resolveDispute` as a transitional human-arbiter path or remove it |
| `src/interfaces/IArbitrator.sol` | Copy from `github.com/kleros/erc-792` (MIT) |
| `src/interfaces/IArbitrable.sol` | Copy from `github.com/kleros/erc-792` (MIT) |
| `test/StakedBountyEscrow.Kleros.t.sol` | New test file: mock IArbitrator, test `escalateToArbitrator`, `rule` callback with both outcomes; extend fuzz/invariant suite |
| `script/DeployKleros.s.sol` | Set `arbitrator` to Kleros Court address (Arbitrum: `0x...`) and encode `arbitratorExtraData` with Software Dev subcourt ID + juror count |

**Dependencies.**

```toml
# foundry.toml / remappings.txt
# No new npm package needed — copy two .sol files from kleros/erc-792 (MIT)
# OR install via forge:
# forge install kleros/erc-792 --no-commit
```

The ERC-792 interfaces are tiny (< 100 lines), MIT-licensed, and stable. No SDK
or off-chain component is required; Kleros's court UI automatically picks up
ERC-1497 evidence events and displays them to jurors.

**Off-chain changes (TypeScript resolver).** None required for the arbitration
path itself — `escalateToArbitrator` is called by the challenger, not the
resolver. The resolver only needs to ensure its `VerdictProposed` event log
(which already contains the full reasoning string) is indexable by the Kleros
Evidence Display. In P4, a small `evidence-builder` module could be added to the
resolver to construct a structured ERC-1497 evidence JSON pointing to the
on-chain reasoning.

---

## 4. Effort, Dependencies, Risks

**Effort: M (Medium) — roughly 2–3 weeks of focused work.**

Breakdown:
- Copy ERC-792 interfaces, wire `IArbitrable` into `StakedBountyEscrow`: ~2 days.
- Write `escalateToArbitrator` + `rule` callback with full CEI safety: ~2 days.
- Extend the invariant test suite (the existing 128k-run fuzz suite needs the new
  state transitions covered): ~3 days.
- Security audit pass on the new dispute path before any deploy: ~1 week (see
  risks below).
- Deploy on Sepolia with a Kleros testnet court; run an end-to-end dispute test:
  ~2 days.

**Dependencies.**

| Dependency | Notes |
|------------|-------|
| Kleros Court v2 on Arbitrum | Production deployment exists. Testnet: Arbitrum Sepolia. |
| ERC-792 interfaces | 2 tiny MIT .sol files; no new library. |
| PNK token (for jurors) | Not a developer dependency — jurors provide their own stake. The integrating contract only needs ETH (or MATIC/ARB) for `arbitrationCost`. |
| Kleros Evidence Display | Off-chain UX; jurors see it automatically if ERC-1497 events are emitted. No code required for v1 integration. |
| This project's P0–P2 phases | Kleros integration is meaningless if the judge hasn't been proven accurate (P0) and real disputes are happening (P3+). |

**Risks.**

1. **Reentrancy through the `rule` callback.** The Kleros Court calls `rule` as
   an external call. The existing `nonReentrant` modifier must be applied to
   `rule`, and the call must follow CEI. This is the single highest-severity
   risk in the integration. The security-auditor must sign off before deploy.

2. **Juror quality for technical disputes.** Kleros jurors in the Software Dev
   subcourt may still not have the domain knowledge to evaluate a complex PR.
   Mitigant: the Claude reasoning log (already on-chain in the `VerdictProposed`
   event) is the primary evidence; jurors are evaluating whether Claude's
   reasoning is sound, not re-reading the entire diff themselves. This is an
   easier task.

3. **Kleros fee must be paid by someone.** `escalateToArbitrator` requires the
   caller to pay `arbitrationCost` in addition to the `challengeBond` they
   already posted. This changes the challenger's cost model and may suppress
   legitimate challenges. Design option: the `challengeBond` is sized to cover
   both the anti-griefing bond _and_ the Kleros fee, and the contract forwards
   the fee to Kleros automatically on `challenge()`.

4. **Protocol upgrade risk.** Kleros is migrating from v1 (mainnet) to v2
   (Arbitrum). The `arbitrator` address is owner-upgradeable in v1's design
   (`setArbiter` exists), so a Kleros version migration is a one-transaction
   owner operation. Low risk.

5. **UMA alternative not entirely ruled out.** If web3-llm pivots toward a
   multi-oracle design (P4/P5), integrating both Kleros (for subjective disputes)
   and UMA OOv3 (as the settlement assertion layer, replacing the current
   `Proposed` state) is architecturally coherent. That is a separate decision.

---

## 5. Verdict — Roadmap Phase Fit

### Phase fit: **P4** — correctly deferred

STRATEGY.md's assessment is exactly right:

> _"P4 — Decentralize (optional, only if demand pulls it). [...] Explicitly
> deferred — don't touch it until P0–P3 have real usage."_

The single-key arbiter is a reasonable trust model for P0–P3 because:

- At P0–P2, the product is not handling significant ETH. A trusted team key is
  fine for a beta.
- At P3 (judge-as-a-service with a thin UI), the arbiter can be a transparent
  multi-sig, which is standard for early-stage DeFi and removes the single-key
  risk without the complexity of Kleros integration.
- Kleros is most valuable when (a) the stakes are high enough to justify juror
  fees and multi-day latency, (b) the team wants to reduce their own governance
  surface, and (c) there is an existing user base who would be suspicious of
  a team-controlled key. None of these conditions hold before P3 has traction.

The pre-condition for this work is: the judge has passed the P0 eval kill-gate,
the product has live usage on mainnet (P3), and disputes are actually occurring
at a rate and value that makes decentralized arbitration economically worth it.

### Go / no-go: **NO-GO now; PLAN for P4**

Do not build this before P3 closes. The correct action today is:

1. Document this research (done here) so the design decision is not re-litigated.
2. At P3, upgrade the `arbiter` to a multi-sig as an interim trust upgrade (zero
   contract code change, owner calls `setArbiter(multiSig)`).
3. At P4, implement Kleros ERC-792 integration as described in §3c.

### Priority: **2 / 5**

Important enough to have a concrete plan (this report), not important enough to
touch before the judge is proven and the core product has paying users. Priority
1 items (P0 eval gate, P1 auto-settle bot) are the genuine blockers. This is
sound future architecture that the product will eventually need — but building
it now before disputes are happening in production is the exact scope-creep trap
that the `blockllm` discipline warns against.

---

## Summary Table

| Dimension | UMA OOv3 | Kleros | Reality.eth + Kleros |
|-----------|-----------|--------|----------------------|
| Dispute type fit | Intersubjective but better for factual | Best for qualitative/subjective | Good, adds bond-escalation pre-filter |
| Integration surface | 1 interface + 2 callbacks | 2 interfaces + 1 callback | 3 contracts + bridge |
| Latency (disputed) | 48–96 h (DVM) | 3–7 days (Kleros) | Bond game + 3–7 days |
| Cost (disputed) | ~$750 bond loss risk (Polymarket scale) | ~$20–100 fee on Arbitrum v2 | Bond + Kleros fee |
| Juror domain expertise | None (token voters) | Software Dev subcourt | Same (Kleros backend) |
| Liveness happy path | 2 h default (configurable) | N/A (direct dispute) | 24 h+ (configurable) |
| EVM stack fit | Solidity + ERC20 bond | Solidity + ETH fee | Solidity + ETH fee |
| On Sepolia testnet | Yes | Arbitrum Sepolia | Arbitrum Sepolia |
| Recommendation | Secondary (assertion layer) | **Primary for disputes** | Overkill for this use-case |

**Recommended path:** Kleros ERC-792 direct integration for `resolveDispute`,
implemented at P4 after P0–P3 demonstrate real usage and dispute volume.

---

_Sources (cited throughout):_
- UMA blog: https://blog.uma.xyz/articles/what-is-umas-optimistic-oracle
- UMA OOv3 docs: https://docs.uma.xyz/developers/optimistic-oracle-v3
- UMA insurance tutorial: https://docs.uma.xyz/developers/optimistic-oracle-v3/in-depth-tutorial-insurance
- UMA DVM 2.0: https://docs.uma.xyz/protocol-overview/dvm-2.0
- UMA dev quickstart: https://github.com/UMAprotocol/dev-quickstart-oov3
- UMA bond/liveness params: https://docs.uma.xyz/developers/setting-custom-bond-and-liveness-parameters
- Polymarket resolution overview: https://rocknblock.io/blog/how-prediction-markets-resolution-works-uma-optimistic-oracle-polymarket
- Kleros ERC-792 standard: https://docs.kleros.io/developer/arbitration-development/erc-792-arbitration-standard
- Kleros ERC-792 GitHub: https://github.com/kleros/erc-792
- Kleros smart contract integration: https://docs.kleros.io/integrations/types-of-integrations/1.-dispute-resolution-integration-plan/smart-contract-integration
- Kleros Court v2 sneak peek: https://blog.kleros.io/court-v2-integration-sneak-peek/
- Kleros 2026 update: https://blog.kleros.io/kleros-project-update-2026/
- Reality.eth docs: https://realitio.github.io/docs/html/
- Reality.eth + Kleros guide: https://docs.kleros.io/integrations/types-of-integrations/1.-dispute-resolution-integration-plan/channel-partners/how-to-use-reality.eth-+-kleros-as-an-oracle
- Kleros Reality.eth proxy v2: https://github.com/kleros/reality-v2
- Arbitration blog on Kleros: https://www.arbitrationblog.org/post/smart-contracts-kleros-and-new-arbitration-platforms-what-already-works-and-where-practice-is-hea
