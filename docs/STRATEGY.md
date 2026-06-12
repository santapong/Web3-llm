# Strategy — picking the main line, the direction, and how it makes money

> A brainstorm memo by the **warrior** agent (product-direction strategist).
> Owns the answer to: *"We have two versions of the same idea — which one do we
> bet on, where is it going, and how does it earn?"*

---

## TL;DR — the call

We have **two repos that are the same idea**: an AI-judged bounty escrow oracle —
a funder escrows ETH against "did this PR meet these acceptance criteria?", Claude
judges it, and the contract settles. They are not two products; they are two
implementations of one product.

**The decision: `web3-llm` is the main project. `blockllm` ("Verdict") goes on
standby as the R&D lab.**

Why, in one paragraph: `web3-llm` is the stronger *product foundation* — it already
has the accountable v1 contract (`StakedBountyEscrow`: staking, slashing, challenge
window, human arbiter), a 128k-run fuzz + invariant suite, green CI, and a clean
single-stack TypeScript resolver. `blockllm` is the stronger *methodology* — it has
the one thing `web3-llm` is missing: an **eval kill-gate** that actually proves the
AI judge agrees with humans. So we don't throw `blockllm` away — we **harvest its
eval harness and its phased-discipline into `web3-llm`** and keep it parked as the
place we prototype risky ideas before they touch the main line.

The moat of this product is **not the escrow contract** (that's a commodity). It's
**provable judge accuracy (evals) + economic accountability (stake/slash)**. One
repo has half of that built; the other has the other half. The plan unifies them.

---

## The two projects at a glance

| | **`web3-llm`** → MAIN | **`blockllm` / "Verdict"** → standby |
| --- | --- | --- |
| **Resolver stack** | TypeScript (viem + Anthropic SDK) | Python |
| **Contracts** | v0 `BountyEscrow` + v1 `StakedBountyEscrow` — staking, slashing, challenge window, arbiter | v0 `BountyEscrow` + `BountyEscrowV2` (challenge/stake), security-audited |
| **Contract testing** | unit + fuzz + **invariant (128k runs, solvency proven)** | 41 forge tests, audit pass (no Critical/High) |
| **LLM judge** | forced `submit_verdict` tool-call, cached rubric, injection-resistant | forced tool-use schema, MCP evidence tools |
| **The trust moat** | economic accountability (stake/slash) ✅ | **eval kill-gate harness (judge-accuracy gate)** ✅ |
| **Process / discipline** | clean MVP, CI green | `PROJECT_BRIEF.md` source-of-truth, phased kill-gates, 7-agent team |
| **Biggest gap** | no proof the *judge* is accurate | Phase 1 judge-gate never actually run; built P2–P3 ahead of it |
| **Maturity** | closer to a deployable MVP | strong scaffolding, less finished product |

The honest summary: **`web3-llm` is more built; `blockllm` is more disciplined.**
Bet on the more-built one and import the discipline.

---

## Why `web3-llm` wins as the base

1. **The hard contract is already done — and proven.** `StakedBountyEscrow` is the
   accountable design (optimistic settlement → challenge window → arbiter → slash).
   The 128k-run invariant suite proves the solvency property *funds can never leak
   or get trapped* — that is the single scariest risk in any escrow, retired.
2. **One language end-to-end-ish.** The resolver is TypeScript with viem; one stack
   is easier to deploy, host, and hire for than a Python-resolver-plus-Solidity split.
3. **CI is green and real.** Foundry build/test + resolver typecheck/test run on
   every push. The project is already in a "keep it green" posture, not a "make it
   build" posture.
4. **The accountability story is the commercial story.** "An AI judge that *pays*
   when it's wrong" is the line that makes a DAO treasurer comfortable. `web3-llm`
   ships that; it's the harder half to retrofit.

`blockllm`'s contracts are good too — but they're a *second* implementation of what
`web3-llm` already has finished. Maintaining both is the trap. Pick one.

---

## What to harvest from `blockllm` (the standby's real value)

`blockllm` is not dead weight — it holds the assets `web3-llm` most needs. Port
these *into* `web3-llm`:

1. **The eval kill-gate harness** — `blockllm/evals/run_eval.py` + its labelled set.
   This is the crown jewel. `web3-llm` has *no* harness proving the judge is right.
   Port it to TS/vitest (or call it from CI as-is): a labelled set of real
   `(criteria, PR) → fulfilled?` pairs, scored for agreement with human labels. A
   judge that can't clear the gate doesn't ship. **This is the product's moat made
   measurable.**
2. **The `PROJECT_BRIEF` + phased kill-gate discipline.** `blockllm`'s "don't build
   the decentralized version before the core loop works" rule is exactly the
   discipline `web3-llm` should adopt as it grows. Each roadmap phase below gets a
   kill-gate, copied from this culture.
3. **The agent-team convention.** `blockllm`'s `.claude/agents/` specialist roster
   is a good operating model. `web3-llm` gets at least the `warrior` (this memo's
   author) now, and can grow the rest as needed.

Everything else in `blockllm` (its duplicate contracts, its Python resolver) stays
parked. We don't port code we already have a better version of.

---

## The opportunity — positioning

**One line:** *Trustworthy, accountable AI settlement for objective, code-checkable
work.*

The wedge is **money that should move when a clearly-specified piece of software
work is done, but today waits on a human reviewer.** That human is the bottleneck:
slow, subjective, and expensive. We replace them with a judge that is (a) *provably*
accurate on clear-cut cases (evals) and (b) *economically* accountable when it's
wrong (stake/slash), with a human arbiter only as the court of last resort.

**Target users (in order of how reachable they are):**
1. **Open-source bounty programs** — the native fit. Issues already have acceptance
   criteria; PRs already exist; payouts already happen. We automate the approval.
2. **DAOs & grant programs** — they pay contributors from a treasury and *need*
   defensible, auditable settlement. On-chain reasoning logs are a feature for them.
3. **Hackathons** — bounded, judgeable, high-volume, low-stakes: the ideal eval and
   demo ground.
4. **Freelance milestone escrow** (later) — "release on acceptance" for contract
   software work; bigger stakes, needs the accountability layer to be trusted first.

**Why we win / the moat:** anyone can fork an escrow contract. The defensible assets
are (1) a **curated, growing eval set** that proves and tunes judge accuracy in this
domain, and (2) the **accountability mechanism + arbiter reputation** that makes
people trust an automated payout. Both compound with usage. The contract does not.

---

## Beyond-capstone roadmap (each phase has a kill-gate)

The capstone is *done* — v1 + resolver + tests + CI exist. "Beyond" means turning a
proven loop into something people actually route money through. Phased, gated,
`blockllm`-style:

- **P0 — Prove the judge.** Port the eval kill-gate from `blockllm`. Assemble a
  labelled set of *real* `(criteria, PR)` pairs and run it.
  **Gate:** ≥ 90% agreement with human labels on clear-cut cases. *Until this passes,
  nothing else ships.* (This is precisely the gate `blockllm` defined but never ran.)
- **P1 — Live on testnet, end-to-end, hands-off.** Deploy `StakedBountyEscrow` to
  Sepolia; run the resolver against it; add the missing **auto-`settle` bot** that
  finalizes a bounty after the challenge window with no human.
  **Gate:** a real bounty created → judged → challenge window → settled, fully
  unattended, with the reasoning readable on-chain.
- **P2 — Real evidence, not a JSON map.** Replace `content.example.json` with real
  **content providers**: fetch criteria + PR diff from the GitHub API (and/or IPFS),
  still hash-verified against the on-chain commitment.
  **Gate:** judge a live GitHub PR by URL, no manual content staging.
- **P3 — Productize: judge-as-a-service + a thin UI.** A hosted resolver other people
  can point a bounty at, plus a minimal funder/claimant web UI (create bounty, see
  verdict + reasoning, challenge). This is where it stops being a repo and becomes a
  service.
  **Gate:** a third party (not us) creates and settles a bounty through the UI.
- **P4 — Decentralize (optional, only if demand pulls it).** Multi-resolver quorum,
  and *only then* consider a token for staking/governance. **Explicitly deferred** —
  this is the exact "build the decentralized version too early" trap `blockllm`
  warns against. Don't touch it until P0–P3 have real usage.

---

## Monetization — all the models, then the pick

### The options

1. **SaaS / platform fee (per-settlement + hosted judge).**
   Take a small fee on each settled bounty (e.g. **1–3% of the payout**, or a flat
   per-verdict fee), and/or sell a **hosted "AI-judge-as-a-service"** subscription to
   bounty platforms, DAOs, and grant programs that don't want to run their own
   resolver. *Pros:* clearest, fastest path to revenue; aligns price with value
   delivered (a settled payout); no token, minimal regulatory surface. *Cons:* needs
   volume; we host infra and eat API cost.
2. **Protocol token / staking.**
   A token for resolver staking, fee capture, and governance. *Pros:* crypto-native,
   highest theoretical upside, "goes beyond capstone" hard. *Cons:* heavy to build,
   real **regulatory + securities risk**, and it's putting the financializaton cart
   before the product horse. Wrong first move.
3. **Open protocol + paid services.**
   Keep the protocol open and free; monetize **hosted resolvers, integrations,
   custom eval-set tuning, and security/audit support.** *Pros:* credibility-first,
   builds trust and ecosystem, low friction to adopt. *Cons:* slower, more
   consulting-shaped revenue.

### The recommendation

- **Primary: per-settlement platform fee + hosted judge SaaS** (model 1), aimed
  first at **DAOs and grant programs.** They have a treasury, a real pain (defensible
  contributor payouts), and tolerance for a small fee on money that's already moving.
  Price the fee on *value delivered* (the settlement), not on API calls.
- **Complement: open protocol + paid services** (model 3). Open-source the contracts
  and resolver to win trust and adoption; charge for the **hosted** convenience,
  integrations (GitHub app, Gitcoin/grant-stack plug-ins), and bespoke eval tuning.
  Open core, paid hosting — the two reinforce each other.
- **Defer: the token** (model 2) until there's real settlement volume *and*
  regulatory clarity. It's a P4 question, not a launch question.

### First revenue experiment

Run **one paid pilot with a single DAO or grant program**: they fund a batch of
real bounties; our hosted judge settles them; we charge a **flat per-settlement fee**
(simpler than a percentage to start). Success metric: they'd pay to do the *next*
batch without us asking. That single retained pilot validates the whole thesis
faster than any amount of token design.

---

## Immediate next steps

1. **Port the eval kill-gate** from `blockllm/evals/` into `web3-llm` (TS/vitest or
   invoked in CI) and wire it as a required check. *(Owner: eval work / warrior to scope.)*
2. **Assemble ~15 real labelled `(criteria, PR)` pairs** — 5 fulfilled, 5 not, 5
   ambiguous — and **run P0's gate.** Don't proceed until it clears.
3. **Stand up the auto-`settle` bot** so the v1 loop runs unattended (closes the one
   obvious gap before a Sepolia demo).
4. **Deploy `StakedBountyEscrow` to Sepolia** and run one real bounty end-to-end.
5. **Line up one DAO/grant pilot** as the target for the first paid settlement.

> The discipline to keep: **don't build P4 before P0 passes.** That mistake is
> exactly why `blockllm` is the standby and not the main line. Let the judge prove
> itself first; everything commercial is downstream of that number.
