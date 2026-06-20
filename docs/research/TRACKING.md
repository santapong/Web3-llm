# Feature-Research Team — live tracking board

Status of the 10 research agents scouting what to build next for **web3-llm**.
Owned by the `research-lead` agent. Each row links to that agent's full report once done.

**Legend:** 🟡 running · 🟢 done · 🔴 failed

_Last updated: **all 10 complete** — synthesized plan in `docs/FEATURE_PLAN.md`._

| # | Research area | Roadmap fit | Status | Report | Headline finding |
|---|---|---|---|---|---|
| 01 | Judge-accuracy eval harness | P0 (moat) | 🟢 done | `01-eval-harness.md` | **P0 gate.** ~80-line vitest harness calling `AnthropicJudge` on a labelled JSON set (reuse blockllm schema 1:1); gate ≥90% on clear-cut + CI `eval-gate` job. Harness is trivial — the moat is the curated dataset. Effort S, priority 1. |
| 02 | GitHub-native integration | P2 | 🟢 done | `02-github-integration.md` | Add one `GitHubContentProvider` (`resolver/src/github.ts`, ~100 lines, `octokit`); key challenge is a **canonical-string protocol** (pin head SHA + `vnd.github.diff` + issue body, fixed order) so keccak hashes stay stable. Fine-grained PAT now → GitHub App at P3. Effort S, priority 2 (P2). |
| 03 | Decentralized content storage | P2 | 🟢 done | `03-content-storage.md` | **Dual commitment:** keep keccak as authority, add IPFS CIDs to `BountyCreated` + an `IpfsGatewayContentProvider` (Pinata/Storacha; Arweave/Irys for disputes). Existing `withHashVerification` still catches tampering. Effort M, priority 3 (P2). |
| 04 | Automated settlement keepers | P1 | 🟢 done | `04-settlement-keepers.md` | **P1 blocker.** Add a ~100-line self-hosted viem cron `Settler` (`resolver/src/settler.ts`) calling the already-permissionless `settle(id)`; Gelato as the P3 upgrade. Effort S, priority 1. |
| 05 | Multi-resolver quorum & ensemble | P4 | 🟢 done | `05-resolver-quorum.md` | **P4 deferral is correct** (v1 already ≈ UMA optimistic oracle; ~1.5% disputed). Add a *dormant* `EnsembleJudge` (3-sample self-consistency, `ENSEMBLE_RUNS`) now, activate at P2/P3; multi-model jury at P3; on-chain quorum stays P4. Effort S/M/L. |
| 06 | Frontend dApp | P3 | 🟢 done | `06-frontend-dapp.md` | Thin Next.js 15 + RainbowKit/wagmi/viem dApp (5 screens) on Vercel; import resolver's `abi.ts` directly for end-to-end types; read reasoning from `VerdictProposed` logs; no subgraph needed. Effort M, priority 2 — **No-Go until P2 passes**. |
| 07 | Prompt-injection & robustness | cross-cutting | 🟢 done | `07-adversarial-robustness.md` | Forced `tool_choice` already locks output *shape*; gaps: no spotlighting delimiters, no pre-screen, no injection eval cases. Ship **L1 delimiters + L4 adversarial eval cases at P0** (near-zero cost), haiku pre-screen + promptfoo red-team at P1. Effort S→M, priority 2. |
| 08 | Decentralized / optimistic arbitration | P4 | 🟢 done | `08-decentralized-arbitration.md` | **Kleros ERC-792** (Software Dev subcourt, real appeals, ERC-1497 evidence) > UMA (token voters rubber-stamp). But **defer to P4**: single arbiter → team multisig at P3 (`setArbiter`, no code), wire Kleros only if disputes occur at volume. Effort M, priority 2, **No-Go now**. |
| 09 | On-chain fee & treasury (monetization) | monetization | 🟢 done | `09-fee-treasury.md` | ~25 lines in `_payout()`: `feeBps`/`feeRecipient`/immutable `MAX_FEE_BPS=500`; fee exits atomically so solvency invariant holds. Deploy **inert (feeBps=0)** now, flip at P3 after P0 gate. Recipient = 2-of-3 Safe. Effort S, priority 2. |
| 10 | L2 deployment, gas & gasless UX | P1/P3 | 🟢 done | `10-l2-gasless.md` | **Deploy to Base** (Base Sepolia at P1 → mainnet at P3): OP Stack = zero code changes, first-party Coinbase Paymaster, sub-cent fees. Swap 16 `require` strings → custom errors (S). Gasless funder UX via `permissionless` + CDP Paymaster at P3. Priority 1/2/3. |

**Progress: 10 / 10 done. ✅**

When all rows are 🟢, the synthesized cross-cutting plan lands in `docs/FEATURE_PLAN.md`.
