# Research #05 — Multi-Resolver Quorum & Model Ensemble (P4)

> **Stack context:** `StakedBountyEscrow` v1 (Solidity 0.8.26 + OZ v5.6.1), resolver in
> TypeScript + viem + Anthropic SDK. Single resolver: one signing key, one `claude-opus-4-8`
> call per bounty via forced `submit_verdict` tool, verdict emitted to event log.
> Roadmap: STRATEGY.md places this at **P4 — explicitly deferred until P0–P3 have real usage.**

---

## 1. What & Why for web3-llm

### The single-judge risk

Today, every settlement decision flows through one process:

```
BountyCreated event
  → AnthropicJudge.judge()          [judge.ts — one claude-opus-4-8 call]
  → ViemEscrowChain.submitVerdict() [chain.ts — one signing key]
  → StakedBountyEscrow.submitVerdict() [Solidity — single resolver address]
```

This creates three compounding failure modes:

1. **Model stochasticity.** At any temperature > 0, the same spec + PR can produce a
   different `fulfilled` outcome on a re-run. For close calls this variance is non-trivial:
   self-consistency research shows LLM judges can flip on 10–20% of borderline inputs across
   runs at temperature 0.7 (Wang et al., 2022; Kim et al., 2026).

2. **Single point of trust.** One signing key means one compromise event or one outage kills
   the entire resolver. Economic accountability from the stake/slash mechanism only helps if
   the resolver ever comes back online to be slashed.

3. **Model provider concentration.** If Anthropic's API is down, or if `claude-opus-4-8` is
   retired, zero bounties can be resolved. No fallback exists.

### Why this is P4, not now

The `StakedBountyEscrow` already has a meaningful backstop: the **challenge window + arbiter**.
A wrong verdict by the single resolver can be caught, disputed, and overturned by a human
within the challenge period. That's not a perfect solution but it is a real one — and it means
multi-resolver quorum is *defense in depth*, not a prerequisite for safety.

STRATEGY.md is explicit: P4 only after P0–P3 prove real usage. The risks above are worth
understanding and designing for — but implementing them before the judge is proven accurate
(P0), the testnet loop runs unattended (P1), and the product has at least one live user (P3)
would be the exact "build the decentralized version too early" trap the strategy warns against.

---

## 2. How the Leaders Do It

### 2a. Model Ensemble — Research Landscape (2025–2026)

#### Self-consistency sampling

The foundational technique (Wang et al., 2022) samples the same model multiple times with
temperature > 0 and picks the majority answer. For code evaluation tasks it yields consistent
gains: +17.9% on GSM8K, +11.0% on SVAMP. For binary verdicts (the web3-llm use case), the
gain is most pronounced on borderline cases where the single-run answer is unreliable.

**Diminishing returns warning:** A 2025 study found accuracy gains from self-consistency
plateau early while costs scale linearly — and at high sample counts, performance sometimes
regressed ([Self-Consistency Is Losing Its Edge](https://arxiv.org/html/2511.00751)). For
binary classification like `fulfilled: true/false`, the inflection point is around 3–5 samples.
Beyond 5, you pay for marginal improvement.

**Adaptive stopping (2026):** Kim et al.'s Reliability-Aware Self-Consistency halts early when
all samples agree, achieving 70–80% cost savings vs naive fixed-N sampling.
([Certified Self-Consistency](https://arxiv.org/pdf/2510.17472))

#### Multi-model jury / LLM-as-judge ensemble

Running several *different* models independently and aggregating avoids the correlated-error
problem of same-model sampling. Research from orq.ai and others shows:

- A 3-model jury (e.g., Opus + Gemini Pro + GPT-4o) on close-call evals measurably reduces
  false negatives vs any single judge.
- **Critical finding from May 2026 ([Nine Judges, Two Effective Votes](https://arxiv.org/html/2605.29800)):**
  Correlated training data between top-frontier models means 9 judges from similar providers
  can yield the informational equivalent of only ~2 independent votes. Diversity of *training
  lineage* (Anthropic / Google / OpenAI) matters more than number of judges.
- Disagreement is signal, not noise: when judges disagree, you've found the ambiguous case
  that most benefits from human review — exactly what the arbiter path in `StakedBountyEscrow`
  is designed for.

#### Meta-judge / judge-of-judges

A secondary model receives all primary verdicts + reasoning chains and synthesizes a final
ruling, optionally flagging low-confidence cases for human escalation.
([Meta-Judging with LLMs, 2025](https://arxiv.org/html/2601.17312))

OpenRouter Fusion uses this pattern in production: parallel calls to N mid-tier models →
synthesis call → final output. Their claim: equivalent quality to a single frontier model call
at roughly half the cost for some tasks. 
([OpenRouter Fusion Launch](https://byteiota.com/openrouter-fusion-launches-multi-llm-api-at-half-the-cost/))

#### Iterative Consensus Ensemble (ICE)

Three models critique each other's verdicts in a debate loop until convergence — up to +27%
accuracy on GPQA-diamond (PhD-level reasoning), raising a 46.9% base to 68.2%.
([Six Sigma Agent paper](https://arxiv.org/pdf/2601.22290))

For a binary fulfilled/not-fulfilled verdict on code criteria, this is almost certainly
over-engineered. ICE shines on complex open-ended reasoning, not binary spec-checking.

---

### 2b. Multi-Resolver Quorum — Decentralized Oracle Networks

#### Chainlink DON (Decentralized Oracle Network) + OCR

Chainlink's Off-Chain Reporting (OCR) protocol is the reference implementation for
multi-resolver quorum in production:

- N nodes (typically 16–31 for production feeds) observe the same data independently off-chain.
- Nodes elect a leader per round; leader aggregates signed observations from a quorum (F+1 of
  3F+1 nodes; typically 2/3 + 1) off-chain into a single report.
- One transaction posts the aggregated report on-chain — O(1) gas regardless of node count.
- Economic accountability: LINK staking (Staking v0.2+) with slashing for malicious or
  negligent nodes.

For an AI resolver, the "observation" step is an LLM call, not a price feed read — the
structural pattern maps directly. The key difference is latency: a Chainlink price-feed round
is ~30s; an Opus call is 5–20s, so an AI-resolver DON round would be 20–60s per verdict.
([Chainlink 2.0 Whitepaper](https://research.chain.link/whitepaper-v2.pdf))

#### UMA Optimistic Oracle

UMA's architecture is structurally very similar to the *existing* `StakedBountyEscrow` design:

1. **Assert phase:** A single proposer posts a data assertion + bond (`resolverBond` in v1).
2. **Liveness period:** Anyone can dispute by posting a counter-bond (`challengeBond`). Only
   ~1.5% of assertions are ever disputed.
3. **DVM escalation:** If disputed, UMA tokenholders vote on the correct outcome over 2–5 days.

The key insight: UMA's design achieves decentralization *on the dispute path only* — the happy
path (no challenge) is still a single proposer. This matches `StakedBountyEscrow` v1 almost
exactly. It's an argument that the existing contract is already following best practice for
this stage.
([UMA Oracle Docs](https://docs.uma.xyz/protocol-overview/how-does-umas-oracle-work))

#### API3 dAPIs

API3 runs first-party oracle nodes (data providers run their own Airnode) and aggregates
multiple on the same chain using a median/mean aggregation. The "first-party" distinction
matters for trust: there is no intermediary relay layer — each provider signs their own data.
For an AI resolver, the first-party analogy would be each resolver running its own LLM
infrastructure and signing its verdict directly.
([API3 Oracle Guide](https://whisperui.com/cryptocoins/api3-oracle))

#### Chainlink Functions (AI compute verifiable)

Chainlink Functions lets smart contracts call arbitrary off-chain compute (including LLM APIs)
and returns the result through OCR-backed consensus. In early 2026, Chainlink announced
partnerships with 24 banks to use AI oracles for unstructured data, with 100% consensus
enforced through decentralized verification. A web3-llm integration could use Chainlink
Functions as the coordination layer instead of building quorum from scratch — at the cost of
lock-in to Chainlink's infrastructure.
([Chainlink AI Oracle Blog](https://blog.chain.link/ai-oracles/))

---

## 3. Recommended Approach for This Stack

The recommendations are ordered by effort and value, from smallest/soonest to largest/latest.

### Option A — Self-consistency sampling (model ensemble, within one resolver) [S]

**What:** Call `buildVerdictRequest()` 3–5 times in parallel with `temperature: 0.7`; aggregate
by majority vote; only submit the verdict if all 3+ agree; else flag as high-uncertainty and
route to arbiter (emit a special event, pause submission).

**Where:** `resolver/src/judge.ts` — wrap `AnthropicJudge.judge()` in a new
`EnsembleJudge` class that implements `VerdictModel`. No contract changes.

```typescript
// Sketch — resolver/src/judge.ts addition
export class EnsembleJudge implements VerdictModel {
  constructor(
    private readonly base: VerdictModel,
    private readonly runs: number = 3,        // 3 is the sweet spot; 5 for high-value bounties
    private readonly requireUnanimous = false, // false = majority; true = all-agree or escalate
  ) {}

  async judge(input: JudgeInput): Promise<Verdict & { consensus: boolean }> {
    const verdicts = await Promise.all(
      Array.from({ length: this.runs }, () => this.base.judge(input))
    );
    const trueCount = verdicts.filter(v => v.fulfilled).length;
    const falseCount = this.runs - trueCount;
    const majority = trueCount > falseCount;
    const consensus = trueCount === this.runs || falseCount === this.runs;

    if (this.requireUnanimous && !consensus) {
      // Escalate: caller should route to arbiter instead of submitting
      throw new EnsembleDisagreementError(verdicts);
    }
    // Pick the reasoning from the majority side (longest/most detailed)
    const chosen = verdicts.filter(v => v.fulfilled === majority)
      .sort((a, b) => b.reasoning.length - a.reasoning.length)[0];
    return { ...chosen, consensus };
  }
}
```

**Cost impact:** 3× API cost per verdict (~$0.045–$0.15 per verdict at Opus rates); latency
adds ~5–10s for parallel calls (Promise.all, not sequential).

**Contract impact:** None. `StakedBountyEscrow` is unchanged.

**When disagreement occurs:** Emit a structured log event; the resolver can skip
`chain.submitVerdict()` and instead alert an operator to use the `arbiter` path manually. This
uses the existing `resolveDispute()` function.

---

### Option B — Multi-model jury (cross-provider diversity) [M]

**What:** Query Opus + Gemini Pro + GPT-4o in parallel. Aggregate by majority. Flag
2-vs-1 splits for escalation. This addresses the correlated-error problem that same-provider
self-consistency sampling cannot.

**Where:** New provider adapters in `resolver/src/judge.ts`. The `VerdictModel` interface
already supports this — just add `GoogleJudge` and `OpenAIJudge` implementations alongside
`AnthropicJudge`.

```typescript
// OpenRouter as a unified gateway for multi-provider calls (avoids 3 SDKs)
import OpenAI from 'openai'; // OpenRouter is OpenAI-compatible

export class OpenRouterJudge implements VerdictModel {
  private client: OpenAI;
  constructor(private readonly model: string) {
    this.client = new OpenAI({
      baseURL: 'https://openrouter.ai/api/v1',
      apiKey: process.env.OPENROUTER_API_KEY,
    });
  }
  async judge(input: JudgeInput): Promise<Verdict> { /* ... */ }
}
```

**Cost impact:** Roughly equal to 3× Opus if using Gemini Pro + GPT-4o (similar tier). If
Gemini Flash and GPT-4o-mini are used as the non-Anthropic judges, cost drops to ~1.3× Opus.

**Contract impact:** None.

**Provider management:** OpenRouter ([openrouter.ai](https://openrouter.ai)) gives unified
access to 400+ models under one API key + billing account, making multi-provider calls
operationally simple without maintaining three separate SDK dependencies.

---

### Option C — On-chain multi-resolver quorum (true decentralization) [L]

This requires contract surgery and is the genuine P4 feature.

#### Contract changes needed in `StakedBountyEscrow.sol`

**Current:** `resolver` is a single `address`; `submitVerdict()` has `onlyResolver` modifier.

**Required changes:**

1. Replace `address public resolver` with `address[] public resolvers` + `uint256 public quorumThreshold` (e.g., 2-of-3 or 3-of-5).
2. Add per-bounty vote tracking: `mapping(uint256 => mapping(address => Vote)) votes` where `Vote = { bool fulfilled; bool cast; }`.
3. `submitVerdict()` becomes `castVote(uint256 id, bool fulfilled, string calldata reasoning)` — callable by any registered resolver, idempotent per resolver, reverts if already cast.
4. `castVote` checks whether quorum is reached; if yes, it records the majority outcome and opens the challenge window (reusing existing `Proposed` state machine).
5. Bond locking applies per-resolver per-vote: each resolver locks `resolverBond / quorumThreshold` or a flat amount.
6. `setResolver(address)` becomes `addResolver(address)` / `removeResolver(address)` with appropriate access control.

**Gas impact:** N resolver votes = N transactions, each ~50–80k gas. For a 3-of-5 quorum on
Sepolia/mainnet this adds meaningful cost vs the single-transaction path. Off-chain aggregation
(Chainlink OCR style, one tx submitting an aggregated signed report) would reduce this to O(1)
but requires a coordination layer between resolvers.

**Security note:** Multi-resolver quorum introduces new attack surfaces: Sybil registration
(owner must gate `addResolver`), vote-buying, and collusion. The `security-auditor` agent must
review any implementation before deploy.

#### Coordination layer between resolvers

For the simple (non-OCR) on-chain pattern:
- Each resolver runs the existing TypeScript pipeline independently and calls `castVote` when
  its LLM returns a verdict.
- The contract tallies votes and opens the challenge window once quorum threshold is met.
- No off-chain coordination required; resolvers don't need to know about each other.

For an OCR-style off-chain aggregation (reduces gas from N→1 tx):
- This requires a coordinator role, BLS/threshold signatures, and significant new infrastructure.
  Far out of scope until at least P5.

---

## 4. Effort, Dependencies, Risks

### Effort

| Option | Size | Time Estimate |
|---|---|---|
| A — Self-consistency sampling (same model, 3 runs) | S | 0.5–1 day |
| B — Multi-model jury (OpenRouter, 3 providers) | M | 2–3 days |
| C — On-chain multi-resolver quorum | L | 2–3 weeks (contract + tests + security review + deploy) |

### Dependencies

| Option | Dependencies |
|---|---|
| A | No new deps; uses existing `AnthropicJudge` + `Promise.all` |
| B | `openai` npm package (OpenRouter is OpenAI-compatible); `OPENROUTER_API_KEY` env var |
| C | Security audit; significant contract refactor; resolver-to-resolver coordination mechanism; new deploy |

### Risks

**Option A:**
- Cost 3× without proportional reliability gain if the single-model self-consistency has
  already converged. The 2025 "diminishing returns" finding applies: for clear-cut cases (the
  majority of real bounties), one Opus call already gives the right answer; sampling 3 times
  wastes tokens.
- Mitigation: gate ensemble sampling on bounty size (run ensemble only for bounties above a
  threshold, e.g., >0.1 ETH).

**Option B:**
- Cross-model disagreement is more common than same-model disagreement — and harder to predict.
  A 2-vs-1 split on every tenth bounty that routes to the human arbiter adds operational load.
- The `Nine Judges, Two Effective Votes` finding (May 2026) warns that even diverse-appearing
  models from Anthropic/OpenAI/Google share significant training data bias; true independence
  requires academic/open-weight models too.
- Mitigation: treat disagreement as routing signal to the existing arbiter path, not as a
  blocker. The contract already supports this.

**Option C (the big one):**
- **Sybil attack on resolver set:** If `addResolver` is not tightly owner-gated and slashing
  is insufficient, a single actor can register multiple resolver addresses and control quorum.
- **Liveness risk:** A quorum-gated contract that can't reach quorum (resolvers offline) means
  no bounties settle. The current single-resolver design fails open (one outage = zero
  throughput); a 3-of-5 quorum fails open at 3 resolver outages simultaneously.
- **Gas cost amplification:** 3 `castVote` transactions per bounty vs 1 `submitVerdict` today.
  At Ethereum mainnet gas prices this could be prohibitive for small bounties.
- **Contract complexity amplification:** Every new code path is a new attack surface. The
  existing 128k-run invariant suite would need full re-characterization.

---

## 5. Verdict — Roadmap Phase Fit

### Phase fit

| Option | Earliest Phase | Reasoning |
|---|---|---|
| A — Self-consistency (same model) | P2–P3 | Zero contract changes; pure resolver-side. Can be added as a config flag (`ENSEMBLE_RUNS=3`) without breaking anything. Low-risk enhancement once the single judge is proven (P0). |
| B — Multi-model jury | P3 | Appropriate when the product has real usage and there is economic justification for 2–3× API cost. Requires multi-provider key management. |
| C — On-chain multi-resolver quorum | P4 | Correct classification in STRATEGY.md. Only warranted when: (1) the single resolver has accumulated a track record, (2) the platform has enough volume to attract multiple independent resolver operators, and (3) the economic parameters (bond sizes, slashing) can be calibrated against real data. |

### Go / No-Go

**Option A: Go at P2–P3** — implement as an optional `EnsembleJudge` wrapper in
`resolver/src/judge.ts`, gated by a `ENSEMBLE_RUNS` env var (default `1` = current behavior).
Zero contract changes, zero new dependencies, low implementation risk. The adaptive early-exit
optimization (stop sampling once all N agree) cuts the expected cost increase to ~1.5× rather
than 3×.

**Option B: Conditional Go at P3** — implement when there is a high-value bounty segment or
a platform customer that demands multi-provider independence. OpenRouter makes the integration
straightforward. The security benefit (cross-provider bias reduction) is real but not critical
before the arbiter path has had a chance to exercise on a live dispute.

**Option C: Stay Deferred (P4)** — the STRATEGY.md call is correct. The existing
challenge + arbiter mechanism is a viable substitute for quorum consensus until real usage
reveals whether the single-resolver path actually fails in practice. Build it when there is
demand from resolver operators wanting to participate, or when the contract's challenge rate
reveals a systematic judge-accuracy problem that the arbiter cannot handle at scale.

### Priority (1–5)

| Option | Priority |
|---|---|
| A — Self-consistency sampling | **3 / 5** — worth implementing but not urgent; defer until P0 eval gate passes |
| B — Multi-model jury | **2 / 5** — real value but only at P3+ scale; not a near-term priority |
| C — On-chain multi-resolver quorum | **1 / 5** — genuinely P4; do not touch until P0–P3 are proven |

### Bottom line

Do not build Option C now. Do design Option A now (the `EnsembleJudge` interface wrapper is
a one-day addition that can sit dormant behind `ENSEMBLE_RUNS=1` until P2). Option B is a
clean medium-term upgrade once the product has paying users who justify the cost.

The strongest argument for staying deferred: `StakedBountyEscrow` v1 already implements a
functional equivalent of UMA's optimistic oracle design — single proposer, challenge window,
human escalation path. That pattern covers >98% of the honest-operation case (UMA data: only
~1.5% of assertions are disputed). The gap this research covers is real, but it is a P4 gap,
not a P0 gap.

---

## Sources

- [Self-Consistency Is Losing Its Edge (2025)](https://arxiv.org/html/2511.00751)
- [Certified Self-Consistency: Statistical Guarantees (2025)](https://arxiv.org/pdf/2510.17472)
- [Nine Judges, Two Effective Votes: Correlated Errors in LLM Panels (May 2026)](https://arxiv.org/html/2605.29800)
- [Six Sigma Agent — Iterative Consensus Ensemble, ICE (Jan 2026)](https://arxiv.org/pdf/2601.22290)
- [Meta-Judging with LLMs: Concepts, Methods, Challenges (2025)](https://arxiv.org/html/2601.17312)
- [Harnessing Consistency for Robust Test-Time LLM Ensemble (2025)](https://arxiv.org/pdf/2510.13855)
- [Towards Reliable LLM Grading Through Self-Consistency (MDPI 2026)](https://www.mdpi.com/2504-4990/8/3/74)
- [LLM Juries in Practice — orq.ai](https://orq.ai/blog/llm-juries-in-practice)
- [Awesome-LLM-Ensemble — GitHub survey](https://github.com/junchenzhi/Awesome-LLM-Ensemble)
- [Chainlink 2.0 Whitepaper — OCR consensus](https://research.chain.link/whitepaper-v2.pdf)
- [What is a Chainlink DON?](https://chain.link/article/what-is-a-decentralized-oracle-network-don)
- [Chainlink Verifiable AI Stack (2026)](https://chain.link/article/verifiable-ai-stack)
- [Chainlink AI Oracle Blog](https://blog.chain.link/ai-oracles/)
- [UMA Protocol — How Does the Oracle Work?](https://docs.uma.xyz/protocol-overview/how-does-umas-oracle-work)
- [UMA Optimistic Oracle — Polymarket Resolution Explained](https://rocknblock.io/blog/how-prediction-markets-resolution-works-uma-optimistic-oracle-polymarket)
- [API3 Oracle Guide — First-Party dAPIs](https://whisperui.com/cryptocoins/api3-oracle)
- [OpenRouter Fusion Launch](https://byteiota.com/openrouter-fusion-launches-multi-llm-api-at-half-the-cost/)
- [OpenRouter Review 2025](https://skywork.ai/blog/openrouter-review-2025/)
- [Self-Consistency Prompting: +17.9% Reasoning Accuracy](https://www.adaline.ai/blog/what-is-self-consistency-prompting)
- [Kinde LLM Fan-Out 101: Self-Consistency, Consensus, and Voting Patterns](https://www.kinde.com/learn/ai-for-software-engineering/workflows/llm-fan-out-101-self-consistency-consensus-and-voting-patterns/)
