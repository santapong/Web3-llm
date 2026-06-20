# web3-llm — Feature Plan

Synthesized by the `research-lead` from the 10 feature-research reports in
[`docs/research/`](./research/) (tracking board: [`docs/research/TRACKING.md`](./research/TRACKING.md)).
This turns the research into a prioritized, phased build plan. It is downstream of
[`docs/STRATEGY.md`](./STRATEGY.md) — the product direction and monetization thesis.

## The one organizing principle

**Nothing ships until the judge is proven.** Every feature below is sequenced behind
the **P0 eval kill-gate** (does Claude agree with human labels?). Building the
decentralized/financialized layers before that number exists is the exact trap that
put the sibling project (`blockllm`) on standby. The research independently confirmed
this: the highest-priority items are all P0/P1, and the genuinely "decentralized"
items (on-chain quorum, Kleros) all came back **defer to P4**.

## Ranked features (impact × effort, by phase)

| Rank | Feature | Phase | Effort | Go? | Report |
|---|---|---|---|---|---|
| 1 | **Judge-accuracy eval harness** (+ curated labelled set) | P0 | S | ✅ now | [01](./research/01-eval-harness.md) |
| 2 | **Adversarial hardening L1+L4** (spotlight delimiters + injection eval cases) | P0 | S | ✅ now | [07](./research/07-adversarial-robustness.md) |
| 3 | **Automated settlement keeper** (viem cron `Settler`) | P1 | S | ✅ now | [04](./research/04-settlement-keepers.md) |
| 4 | **Deploy to Base Sepolia** (+ `require`→custom errors) | P1 | S | ✅ now | [10](./research/10-l2-gasless.md) |
| 5 | **Fee switch, shipped inert** (`feeBps`/`feeRecipient`/`MAX_FEE_BPS`) | P1 build / P3 activate | S | ✅ build now | [09](./research/09-fee-treasury.md) |
| 6 | **GitHub content provider** (canonical-string protocol) | P2 | S | ✅ at P2 | [02](./research/02-github-integration.md) |
| 7 | **Adversarial L2+L5** (haiku pre-screen + promptfoo red-team in CI) | P1 | M | ✅ at P1 | [07](./research/07-adversarial-robustness.md) |
| 8 | **`EnsembleJudge`, shipped dormant** (3-sample self-consistency) | P2/P3 | S | ✅ dormant now | [05](./research/05-resolver-quorum.md) |
| 9 | **IPFS content storage** (dual commitment: keccak + CID) | P2 | M | ✅ at P2 | [03](./research/03-content-storage.md) |
| 10 | **Frontend dApp** (Next.js + RainbowKit/wagmi/viem) | P3 | M | ⏳ at P2-pass | [06](./research/06-frontend-dapp.md) |
| 11 | **Gasless funder UX** (`permissionless` + Coinbase Paymaster) | P3 | M | ⏳ at P3 | [10](./research/10-l2-gasless.md) |
| 12 | **Multi-model jury** (cross-provider via OpenRouter) | P3 | M | ⏳ at P3 | [05](./research/05-resolver-quorum.md) |
| 13 | **Arbiter → team multisig** (`setArbiter`, zero code) | P3 | XS | ✅ at P3 | [08](./research/08-decentralized-arbitration.md) |
| 14 | **On-chain multi-resolver quorum** | P4 | L | 🛑 defer | [05](./research/05-resolver-quorum.md) |
| 15 | **Kleros ERC-792 arbitration** | P4 | M | 🛑 defer | [08](./research/08-decentralized-arbitration.md) |

## The phased roadmap

### P0 — Prove the judge *(gates everything)*
- **Eval harness** [01]: ~80-line vitest runner calling the existing `AnthropicJudge` over a labelled JSON set (reuse `blockllm`'s `eval_set` schema 1:1). Add an `eval-gate` job to `.github/workflows/ci.yml`. **Gate: ≥90% agreement on clear-cut cases.**
- **Adversarial L1+L4** [07]: wrap untrusted spec/PR in randomized spotlight delimiters in `buildVerdictRequest`, extend `SYSTEM_RUBRIC` with an untrusted-content policy, and add `evals/adversarial_cases.json` (≥9 injection cases). **Gate: 0 injection successes.** Ships in the *same sprint* as the harness — near-zero cost, tightly coupled.
- **The real work** is assembling ~15 *real* labelled `(criteria, PR diff)` cases. That dataset is the moat, not the code.

### P1 — Live on testnet, hands-off
- **Settlement keeper** [04]: ~100-line `resolver/src/settler.ts` cron calling the already-permissionless `settle(id)` after the challenge window; wire into `index.ts`. Unblocks the "fully unattended loop" gate.
- **Base Sepolia deploy** [10]: OP Stack = zero code changes; only `RESOLVER_RPC_URL` changes. Swap the 16 `require(..., "string")` for custom errors while here.
- **Fee switch (inert)** [09]: add `feeBps`/`feeRecipient`/immutable `MAX_FEE_BPS=500` to `_payout()`; deploy with `feeBps=0`. Solvency invariant preserved (fee exits atomically). Re-run the 128k invariant suite; **security-auditor sign-off required**.
- **Adversarial L2+L5** [07]: `claude-haiku-4-5` injection pre-screen + `promptfoo` red-team in CI.

### P2 — Real evidence (no manual staging)
- **GitHub provider** [02]: `resolver/src/github.ts` (`octokit`) implementing the `ContentProvider` interface; the crux is a **canonical-string protocol** (pinned head SHA + `vnd.github.diff` + issue body, fixed order) so keccak hashes are reproducible. Fine-grained PAT now.
- **IPFS storage** [03]: add `specCid`/`prCid` to `BountyCreated` + an `IpfsGatewayContentProvider`; `withHashVerification` still catches tampering.
- **Activate `EnsembleJudge`** [05] (`ENSEMBLE_RUNS=3`) for the accuracy bump.
- **Gate: judge a live GitHub PR by URL, no manual content staging.**

### P3 — Productize (judge-as-a-service)
- **Frontend dApp** [06]: thin Next.js app (connect / create / list / verdict+reasoning / challenge), importing the resolver's `abi.ts` for end-to-end types; reasoning read from `VerdictProposed` logs.
- **Activate the fee** [09] + **gasless funder UX** [10] + **multi-model jury** [05] + **arbiter → 2-of-3 multisig** [08].
- **Gate: a third party settles a bounty through the UI.**

### P4 — Decentralize *(only if demand pulls)*
- On-chain multi-resolver quorum [05] and Kleros ERC-792 arbitration [08]. Both confirmed premature until there's real dispute volume. v1 already behaves like UMA's optimistic oracle (~1.5% of assertions are ever disputed).

## Recommended next 3 (start now)

1. **Build the eval harness + adversarial L1/L4, and assemble the labelled set** (P0).
   *First step:* port `blockllm/evals/eval_set.example.json` schema into `resolver/eval/`, write the vitest runner against `AnthropicJudge`, add the `eval-gate` CI job, then collect 15 real cases. This is the gate and the moat.
2. **Stand up the settlement keeper + deploy to Base Sepolia** (P1).
   *First step:* write `resolver/src/settler.ts`, point `.env` at Base Sepolia (Coinbase faucet), run one real bounty create→judge→window→auto-settle end-to-end.
3. **Add the GitHub content provider** (P2).
   *First step:* implement `resolver/src/github.ts` + the canonical-string spec, prove a live PR judges with stable hashes.

> Build the **inert fee switch** [09] opportunistically alongside the P1 contract work so the monetization rail is deployed and audited before there's ever a fee to turn on.

## Explicitly deferred (and why)
- **On-chain quorum [05] & Kleros [08] → P4:** decentralizing arbitration/resolution before the judge is proven and disputes actually occur is cost with no return. Bridge with a multisig arbiter at P3.
- **Token:** not in any feature report; per `STRATEGY.md` it's a P4 question, gated on volume + regulatory clarity.

## How this funds the business
The monetization thesis in `STRATEGY.md` (per-settlement fee + hosted judge SaaS) is
realized by a specific chain of features here: **[09] fee switch** is the on-chain
revenue rail; **[02] GitHub** + **[03] IPFS** + **[06] frontend** + **[10] gasless**
together make it a *hosted product a DAO can actually use*; and **[01] eval harness**
+ **[07] hardening** are what let us charge for it at all — *you cannot take a fee on a
judge of unproven accuracy.* Prove the judge (P0), make the loop live and cheap (P1),
make it usable (P2–P3), then turn on the fee.
