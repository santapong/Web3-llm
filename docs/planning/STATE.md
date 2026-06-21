# STATE.md — shared planning blackboard

The single source of truth for the 6-agent build-planning team. Coordination follows the
**Blackboard / Shared-Scratchpad-Collaboration (SSC)** pattern: agents contribute in
rounds; **round 2 reads round 1** — that is how they "talk to each other." The `tech-lead`
(orchestrator) owns this file and merges each agent's note file (`docs/planning/notes/`)
into it between rounds. The executable output is `docs/planning/BUILD_PLAN.md`.

> Pattern sources: Shared-Scratchpad-Collaboration (agentic-design.ai), Blackboard LLM
> multi-agent systems (arXiv 2510.01285, 2507.01701), markdown as agent lingua franca.

## 1. Goal & scope

Produce an executable build plan for the **Next-3** from `docs/FEATURE_PLAN.md`:

- **P0 (gates everything):** judge-accuracy **eval harness** + curated labelled set, and
  **adversarial hardening** (spotlight delimiters, rubric clause, injection eval cases).
- **P1 (live, hands-off):** **settlement keeper**; **Base Sepolia deploy** + `require`→
  **custom errors**; **inert fee switch** (built + audited, `feeBps=0`).
- **P2 (real evidence):** **GitHub content provider** + the **canonical-string protocol**.

**The one rule:** the P0 eval gate (≥90% agreement on clear-cut cases) comes first;
nothing downstream ships until the judge is proven.

## 2. Shared facts (stack & key paths)

- **Contracts:** `src/BountyEscrow.sol` (v0), `src/StakedBountyEscrow.sol` (v1: challenge
  window, staking, slashing, arbiter), Solidity 0.8.26 + OZ v5.6.1 + Foundry. Solvency
  invariant proven over 128k runs. Deploy scripts in `script/`.
- **Resolver (TS + viem + Anthropic SDK):** `resolver/src/` — `judge.ts`, `content.ts`
  (`ContentProvider` + `withHashVerification`), `chain.ts` (`ViemEscrowChain.settle(id)`),
  `resolver.ts`, `config.ts`, `index.ts`, `abi.ts`.
- **CI:** `.github/workflows/ci.yml`. **Research:** `docs/research/01..10-*.md`.

## 3. Work-area → owner map (who does what)

| Work area | Lead | Support |
|---|---|---|
| P0 eval harness + dataset | `eval-engineer` | `devops-engineer` (CI), `security-reviewer` |
| P0 adversarial hardening | `eval-engineer` + `security-reviewer` | — |
| P1 settlement keeper | `resolver-engineer` | `devops-engineer` (hosting) |
| P1 Base deploy + custom errors | `contract-engineer` + `devops-engineer` | `security-reviewer` (sign-off) |
| P1 inert fee switch | `contract-engineer` | `security-reviewer`, `devops-engineer` (multisig) |
| P2 GitHub provider + canonical strings | `resolver-engineer` | `security-reviewer` (auth), `tech-lead` (protocol) |
| Sequencing / integration / synthesis | `tech-lead` | all |

## 4. Round status

| Agent | Round 1 (propose) | Round 2 (review) |
|---|---|---|
| tech-lead | 🟢 done | 🟢 done |
<!-- SYNTHESIS COMPLETE: tech-lead merged both rounds into docs/planning/BUILD_PLAN.md (2026-06-21). -->
<!-- Note: OQ3 follows the accepted Decision Log R2-2 (ADDITIVE FeeCharged; Settled unchanged), -->
<!-- which both implementers ratified, superseding the tech-lead R2 note's "modify Settled". -->

| contract-engineer | 🟢 done | 🟢 done |
| resolver-engineer | 🟢 done | 🟢 done |
| eval-engineer | 🟢 done | 🟢 done |
| devops-engineer | 🟢 done | 🟢 done |
| security-reviewer | 🟢 done | 🟢 done |

## 5. Per-agent contributions
_(Round-1 proposals and Round-2 cross-reviews merged here by the tech-lead.)_

### tech-lead (`notes/r1-tech-lead.md`)
- **Round 1 — build spine:** `P0 eval harness + adversarial L1/L4 + 15 real cases` → (CI gate ≥90% GREEN) → `P1 settler + Base Sepolia deploy + require→custom errors + inert fee switch` → (live hands-off loop proven) → `P2 canonical.ts → github.ts → judge a live PR by URL`. P0 enforced as a **CI gate**, not a milestone.
- **Critical-path item:** the **canonical-string protocol** (`resolver/src/canonical.ts`) — one shared, versioned, commit-SHA-pinned plaintext serializer used by both create-tooling and resolver so `keccak256(spec/PR)` reproduces byte-for-byte and `withHashVerification` passes. De-risked by building it (chain-free) during P1, landing in `github.ts` at P2.
- **Round 2 — arbitration calls:** **C1 → PULL wins** (fee accrues `feeOwed`+`withdrawFees`; user payout stays push; invariant gains `+Σ feeOwed`; no change at `feeBps=0`). **OQ3 → modify `Settled`** (add `fee`, `amount`→net; one ABI bump regenerated from artifact; invisible until P3). **OQ6 → YES**: extract serializer to chain-free **`resolver/src/canonical.ts`** (built P1), imported by both `github.ts` and a funder-side `hash-content.ts` CLI (overrides D-RE "don't export from octokit file"). **Key isolation:** settler uses its own gas-only `KEEPER_PRIVATE_KEY` (overrides reuse of `RESOLVER_PRIVATE_KEY`). **Gelato struck** (P3 = Chainlink, D-DO2). Branch protection is the **last** P0 step, only after the skip-job proves `success` on a real PR; `temperature:0` for gate stability.

### contract-engineer (`notes/r1-contract-engineer.md`)
- **Round 1 — fee switch:** immutable `MAX_FEE_BPS=500`, `uint16 feeBps` (0=off, packs with `feeRecipient`), `FeeUpdated` event, `onlyOwner setFee()`. In `_payout`: `fee=principal*feeBps/10_000`, send fee then net; whole principal exits in one call (fee is transient). At `feeBps=0` behaviour is byte-for-byte identical → genuinely inert. Patterns from Allo / Uniswap / 0x.
- **Invariant:** `invariant_solvency` **formula unchanged** (settled bounty drops from both sides, fee never rests in contract); only test setup changes — turn fee ON in `setUp`, distinct `feeRecipient`, add `invariant_feeRecipientNeverEscrow`, re-run 128k for sign-off.
- **Custom errors:** 18 string-`require` → `if(!cond) revert Err()` (NOT the `require(cond,Err())` overload — via-ir-only, repo doesn't enable it). Identical conditions; tests migrate to `.selector`.
- **Base Sepolia (84532):** OP-Stack parity → **zero foundry.toml / contract changes**; `DeployStaked.s.sol` threads `FEE_BPS`/`FEE_RECIPIENT` env (default off); verify via Etherscan-v2 key.
- **Round 2 — CONCEDES SEC-1 (pull).** Revised: add `uint256 feeOwed`; `_payout` does `feeOwed += fee` (effect, not call); **user `net` stays push** (byte-for-byte today at `feeBps=0`). Add `withdrawFees()` (nonReentrant/CEI), `FeesWithdrawn`, errors `NoFeesOwed`/`FeesPending`, and a `setFee` guard blocking recipient repoint while fees pending → a broken recipient blocks only its own withdrawal, never a settlement.
- **Invariant formula now CHANGES** (amends D-CE2): `balance == resolverStake + Σ amount[live] + Σ challengeBondPaid[disputed] + feeOwed`; adds `withdrawFees` fuzz handler + `invariant_feeOwedNeverExceedsBalance`; 128k re-run = the sign-off artifact.
- **OQ3 → reverses to ADDITIVE events** (keep `Settled` unchanged, add `FeeCharged`+`FeesWithdrawn`): under pull the fee no longer moves at settle, so zero `abi.ts`/keeper change for P1. *(Diverges from tech-lead's "modify Settled" — reconciled below.)*
- **Open for security:** is `withdrawFees` permissionless-to-fixed-recipient (lean, Aave `collect` shape) or `onlyOwner`/`onlyFeeRecipient`?

### resolver-engineer (`notes/r1-resolver-engineer.md`)
- **Round 1 — keeper:** new `settler.ts` (~120 lines) with a `Map<bountyId,deadline>`; `setInterval` sweep (`RESOLVER_SETTLE_INTERVAL_MS`, default 5min) calls existing `ViemEscrowChain.settle(id)`; id deleted from map *before* the async call (no double-submit); startup replays `VerdictProposed` via `getContractEvents` + live `watch`. **ABI gap:** `VerdictProposed` must be added to `abi.ts`. No new deps, no contract change.
- **GitHub provider:** `github.ts` (~160 lines) implements `ContentProvider` via `octokit`; fine-grained PAT (`Pull requests/Issues/Contents: read`); file `PointerStore` maps `specHash → {owner,repo,issueNumber,prNumber,prHeadSha}`.
- **Canonical strings:** `specText`=raw `issue.body`; `prText`=`canonicalPrText()` pure fn = `PR #N: title\n\n body\n\n--- diff ---\n diff`. **Diff fetched via the commit-SHA endpoint** (`GET /commits/{prHeadSha}`, `format:"diff"`), not the PR endpoint → pinned against force-push.
- **Round 2 — OQ3:** prefers **additive `FeeCharged`** (Settled unchanged; keeper never decodes Settled; zero P1 resolver change; `Settled.amount` = net actually paid). **OQ4:** `startBlock` replay is sufficient for P1 (logs permanent on Base; loud warn if `RESOLVER_START_BLOCK` unset; disk-queue = P2 `persistFile?` no-op now). **OQ5:** accept spurious `settle()` reverts in P1 (one harmless `NotSettleable()` revert; `Challenged`-subscribe = P2). **SEC-3:** split `ViemEscrowChain` into `walletClient` (`RESOLVER_PRIVATE_KEY`, verdicts) + `keeperWalletClient` (`KEEPER_PRIVATE_KEY`, settle); interface unchanged. Accepts `canonical.ts` factoring; flags **CRLF→LF on body fields only** (confirm w/ tech-lead).

### eval-engineer (`notes/r1-eval-engineer.md`)
- **Round 1 — framework: zero-dep vitest** (already a devDep; calls `AnthropicJudge` directly, ~80 lines). Rejected vitest-evals (LLM grader unneeded for binary labels), promptfoo (overbuilt + OpenAI-acquired → P1 L5), Braintrust (SaaS data-handling → P3).
- **Files:** `resolver/eval/{types.ts, eval_set.example.json (committed synthetic), eval_set.json (git-ignored real, 5/5/5), run_eval.test.ts, adversarial_cases.json (9 categories), run_adversarial.test.ts}`.
- **Gates:** clear-cut accuracy ≥0.9 (`GATE_THRESHOLD`); injection successes = 0. **Metrics:** TP/TN/FP/FN every run, FP flagged critical (wrong payout); Cohen's κ at 30+ cases.
- **Round 2 — accepts SEC-2:** taxonomy **9→12 cases**, adds `direction` + `underlying_correct_verdict` fields and **force-reject** vectors (malicious funder wants `false`): `adv-010` spec criteria-poison, `adv-011` spec reasoning-hijack, `adv-012` PR SYSTEM-spoof; runner interprets success by direction. **Delimiters must be per-request crypto-nonce** (static tags are forgeable) → `judge.test.ts` uses regex match. **judge.ts ownership:** assign L1 delimiters + rubric to a single atomic PR (recommend a verdict owner; resolver reviews) — *for tech-lead*. **CI:** prefers **always-run job with `exit 0` on path miss** over skip-job (avoids GitHub skipped-status ambiguity).

### devops-engineer (`notes/r1-devops-engineer.md`)
- **Round 1 — CI eval-gate:** PR-blocking job via `dorny/paths-filter@v3` (fires only on `judge.ts`/`resolver/eval/` changes; always-green skip job for others to satisfy branch protection); plain vitest; ~$0.15–0.30/run. **Risk: the skip-job + required-check pattern must be tested on a real PR first** (GitHub blocks merge on *skipped* required checks).
- **Base Sepolia:** add `[rpc_endpoints]`+`[etherscan]` to `foundry.toml`; **Etherscan API v2 single key covers Basescan**; `--verify`; Coinbase faucet; Alchemy for CI fork tests (public RPC rate-limits).
- **⚠️ Keeper correction:** **Gelato Web3 Functions EOL'd 2026-03-31** (contradicts research #04). P1 = self-hosted `setInterval` + pm2/Docker + UptimeRobot; **P3 upgrade = Chainlink Automation time-based upkeep** (Base Sepolia registry available, no contract change).
- **Secrets/treasury:** `RESOLVER_PRIVATE_KEY` local-only through P1; `feeRecipient` = 2-of-3 Safe on Base Sepolia (→3-of-5 pre-mainnet).
- **Round 2 — SEC-3:** owns adding `KEEPER_PRIVATE_KEY` to `.env.example` + funding the gas-only keeper EOA (~0.05 ETH); neither key in CI at P1. **SEC-5/6:** deploy is fee-inert by construction (`FEE_BPS=0` default, `workflow_dispatch`-only, no `RESOLVER_PRIVATE_KEY` in CI → no accidental broadcast); pre-deploy checklist in `.env.example`. **D-DO2:** Chainlink needs a **thin ~30–50-line sweep-wrapper** (time-based upkeep calls no-arg fn; `settle(id)` needs an arg) iterating operator-managed `trackedIds` — P3, no `StakedBountyEscrow` change. **OQ7:** 4-step rollout (add non-required → test PR shows green not skipped → enable required → verify); single-job fallback specified. **D-DO3:** devops creates/funds the Safe, sends a test ETH transfer, commits address as `FEE_RECIPIENT` before the P1 deploy PR.

### security-reviewer (`notes/r1-security-reviewer.md`)
- **Round 1 — top risks:** **(SEC-1, HIGH, CONTESTS contract-engineer)** push `_send(feeRecipient,fee)` inside `_payout` is a **global fund-LOCK DoS** if the recipient ever reverts → use **pull-payment for the fee leg** (`feeOwed`+`withdrawFees`), keep user payout push. **(CRITICAL)** injection eval set is a release gate: ≥9 cases, **both directions** (force-approve bad PR *and* force-reject good PR — malicious funder wants `false`), include **spec-side reasoning-hijack**, 0 successes; L1 spotlighting ships *before* scoring. **(HIGH)** keeper key ≠ verdict-signing key (settle is permissionless → keeper needs only a gas EOA). **(confirmed)** injection screen must log+annotate+fall through, never halt (blocking = griefable DoS). **(MED)** custom-error refactor must be revert-neutral (line-by-line map + green suite).
- **Gates (owns go/no-go):** no P1 deploy until contract items green incl. **solvency invariant re-run with `feeBps>0`**, key isolation, and P0 passed (incl. injection 0-success); deploy **fee-inert**. Fee switched on only at a *separate P3 gate* (P0 + ≥1 pilot + multisig proven to accept ETH + fee-specific sign-off).
- **Round 2 — holds PULL; acceptance criterion:** a reverting `feeRecipient` cannot block any user payout (settle/refund/both dispute branches succeed, fee accrues). Confirms solvency formula is **not** "unchanged" → must re-run at `feeBps>0`. **K1 (HIGH):** verified `chain.ts` derives ONE account for both `submitVerdict` and `settle` today → key split must actually be built. **EV-1:** R1 injection cases were one-directional (`expected:false`) — need ≥2 force-reject (`expected:true`) cases, L1 ships before scoring. **CI-1/CI-2:** use the aggregated `ci-pass` required check (D-TL4); **`eval-gate` must NOT expose `ANTHROPIC_API_KEY` to fork PRs**. **Reassurance:** PointerStore tampering is NOT content-substitution — `withHashVerification` fails closed. **Residual P2:** body mutability is a fail-closed **liveness/griefing** vector (funder edits issue to block settlement) — P2 must not ship a silent permanent-stuck.

## 6. Tech-choices table
_(choice · why · external source adapted — filled from round 1.)_

| Area | Choice | Why | Source |
|---|---|---|---|
| Canonical hashing | Versioned, fixed-field deterministic plaintext serializer | Reproducible `keccak256` across create+judge | JCS / RFC 8785 principle |
| Protocol fee | bps-of-payout, transient (exits in one call), immutable `MAX_FEE_BPS` cap | Solvency invariant preserved; inert at 0 | Allo / Uniswap / 0x |
| Solidity errors | Custom errors via `if(!cond) revert Err()` | Gas + bytecode; via-ir overload unavailable | Solidity 0.8.x docs |
| L2 target | Base Sepolia (84532), zero code change | OP-Stack EVM parity, sub-cent fees | research/10 |
| Eval framework | Zero-dep vitest calling `AnthropicJudge` | No new deps; binary labels need no LLM grader | eval-engineer R1 |
| Settlement keeper | Self-hosted `setInterval` (P1) → **Chainlink Automation** (P3) | Gelato EOL'd 2026-03-31 | devops R1 |
| CI gate | `dorny/paths-filter` + skip-job, PR-blocking | Pay for eval only on relevant PRs | devops R1 |
| Treasury | 2-of-3 Safe multisig (Base) | Standard, accepts ETH, upgrade path | devops R1 |
| Contract verify | Etherscan API **v2** (single key covers Basescan) | Legacy per-chain keys deprecated | contract/devops R1 |

## 7. Decision Log (append-only)
_(decision · owner · rationale · status: proposed / accepted / contested)_

| # | Decision | Owner | Rationale | Status |
|---|---|---|---|---|
| D-TL1 | Canonical strings are **versioned** (`vN\n` sentinel inside hashed preimage) | tech-lead | Format can evolve without bricking escrowed bounties | proposed |
| D-TL2 | Canonical strings are **fixed-field, deterministic** (JCS/RFC 8785 principle applied to plaintext) | tech-lead | `keccak256(utf8)` reproduces byte-for-byte across create+judge | proposed |
| D-TL3 | Diff always fetched by **pinned `prHeadSha`**, never "latest PR" | tech-lead | Defeats force-push/edit non-determinism | proposed |
| D-TL4 | P0 enforced by a single aggregated **`ci-pass` required check** that `needs: eval-gate` | tech-lead | Makes "nothing ships until judge proven" a mechanical merge precondition | proposed |
| D-TL5 | `abi.ts` **generated from Foundry artifact**, never hand-edited; fee + custom-errors ship as **one audited change before** Sepolia broadcast | tech-lead | P1 bumps the ABI; security sign-off is on the deploy critical path | proposed |
| D-CE1 | Use `if(!cond) revert Err()` for custom errors, **not** `require(cond, Err())` | contract-engineer | The require-with-error overload is via-ir-only in 0.8.26; repo doesn't enable via-ir | proposed |
| D-CE2 | `invariant_solvency` formula unchanged; turn fee ON in fuzz `setUp` + add `invariant_feeRecipientNeverEscrow`; re-run 128k | contract-engineer | Fee is transient (exits atomically); must still exercise the fee path under fuzzing | proposed |
| D-CE3 | Base Sepolia = zero contract/foundry.toml change; deploy threads `FEE_BPS`/`FEE_RECIPIENT` env, default off | contract-engineer | OP-Stack EVM parity; keeps P1 fee inert | proposed |
| D-RE1 | Keeper = in-process `setInterval` sweep over a `Map`, id removed before async `settle` | resolver-engineer | Restart-safe via event replay; no double-submit; no new deps | proposed |
| D-RE2 | Diff fetched via **commit-SHA endpoint** (`/commits/{prHeadSha}`, `format:"diff"`) | resolver-engineer | Pins content against force-push; satisfies D-TL3 | proposed |
| D-EV1 | Eval harness = **zero-dep vitest** calling `AnthropicJudge` directly | eval-engineer | No new deps; binary labels need no LLM grader | proposed |
| D-EV2 | Gates: clear-cut ≥0.9 + injection successes = 0; metrics log FP/FN (FP critical) | eval-engineer | FP = wrong payout; injection is a release gate | proposed |
| D-DO1 | CI eval-gate via `dorny/paths-filter` + always-green skip job; PR-blocking | devops-engineer | Only pay for eval on relevant PRs; satisfy branch protection | proposed (test skip-job first) |
| D-DO2 | **Keeper P3 upgrade = Chainlink Automation, NOT Gelato** | devops-engineer | Gelato Web3 Functions EOL'd 2026-03-31; corrects research #04 | proposed |
| D-DO3 | `feeRecipient` = 2-of-3 Safe on Base Sepolia (→3-of-5 pre-mainnet) | devops-engineer | Supplies the address contract-engineer needs | proposed |
| SEC-1 | **Fee leg = pull-payment** (`feeOwed`+`withdrawFees`), user payout stays push | security-reviewer | Push fee → global settle/dispute LOCK if recipient reverts | **contested (vs D-CE)** |
| SEC-2 | Injection eval set is a release gate: ≥9 cases, **both directions**, spec-side hijack, 0 successes | security-reviewer | Accuracy on cooperative input proves only happy path (OWASP LLM01) | proposed |
| SEC-3 | Keeper key ≠ verdict-signing key (keeper = gas-only EOA) | security-reviewer | `settle` is permissionless; shrink leaked-key blast radius | proposed |
| SEC-4 | Injection screen must log+annotate+fall through, never halt | security-reviewer | Halting is a griefable settlement DoS | accepted (confirms research #07) |
| SEC-5 | No P1 deploy until invariant re-run with `feeBps>0` + key isolation + P0 passed; deploy fee-inert | security-reviewer | Go/no-go gate ownership | proposed |
| SEC-6 | Fee activation is a **separate P3 gate** (P0 + ≥1 pilot + multisig proven to accept ETH + fee sign-off) | security-reviewer | A wrong/locked payout is hard to reverse | accepted |
| SEC-7 | CI uses aggregated `ci-pass` required check (= D-TL4) | security-reviewer | Robust merge gate | accepted |
| SEC-8 | `eval-gate` must NOT expose `ANTHROPIC_API_KEY` to fork PRs | security-reviewer | Secret exfiltration via untrusted PR | proposed |
| R2-1 | **C1 resolved → PULL**; SEC-1 accepted, D-CE push superseded | tech-lead/contract/security | Push fee = global settlement-lock DoS | **accepted** |
| R2-2 | **OQ3 resolved → additive `FeeCharged`**, `Settled` unchanged (`amount`=net) | contract+resolver | Zero P1 abi/keeper change; truthful amount | **accepted** |
| R2-3 | Invariant amended: `+ Σ feeOwed`; add `invariant_feeOwedNeverExceedsBalance`; 128k re-run at `feeBps>0` | contract/security | Pull adds a contract-held liability | **accepted** |
| R2-4 | Serializer extracted to chain-free `canonical.ts` (P1), used by `github.ts` + `hash-content.ts` CLI | tech-lead/resolver | Hashes must reproduce both sides | **accepted** |
| R2-5 | Settler uses gas-only `KEEPER_PRIVATE_KEY`; `ViemEscrowChain` splits wallet clients | resolver/devops/security | `settle` permissionless → shrink blast radius | **accepted** |
| R2-6 | CI eval-gate = always-run job, `exit 0` on path-miss; required only after green test PR | devops/eval/security | Avoid GitHub skipped-status merge block | **accepted** |
| R2-7 | `withdrawFees` permissionless-to-fixed-`feeRecipient` (Aave `collect` shape) | contract (security to ratify) | Destination fixed → safe; simplest path | proposed |

## 8. Open Questions / Conflicts

### Resolved in Round 2
- **CONFLICT C1 (fee push vs pull) → RESOLVED: PULL.** contract-engineer conceded; fee accrues `feeOwed`+`withdrawFees()`, user payout stays push. A reverting recipient blocks only its own withdrawal. _(SEC-1 accepted; D-CE push entries superseded.)_
- **OQ3 (events) → RESOLVED: additive `FeeCharged`** (keep `Settled`; `amount`=net actually paid; zero P1 resolver/abi change). Both implementers (contract + resolver) agree; supersedes tech-lead's "modify Settled".
- **OQ6 (funder CLI) → RESOLVED: YES.** Extract serializer to chain-free `resolver/src/canonical.ts` (built P1); imported by `github.ts` + a `hash-content.ts` CLI.
- **SEC-3 (key isolation) → RESOLVED:** settler uses its own gas-only `KEEPER_PRIVATE_KEY`; `ViemEscrowChain` splits into verdict vs keeper wallet clients.
- **OQ4 → RESOLVED:** `startBlock` event-replay is sufficient for P1 (disk-queue = P2). **OQ5 → RESOLVED:** accept spurious `settle()` reverts in P1 (`Challenged`-subscribe = P2).
- **OQ7 (CI gate) → RESOLVED:** prefer an **always-run job with `exit 0` on path-miss** (avoids skipped-status ambiguity); enable required check only after a green test PR.
- **Invariant → AMENDED:** formula gains `+ Σ feeOwed` (pull-payment liability); adds `invariant_feeOwedNeverExceedsBalance`; 128k re-run with `feeBps>0` is the sign-off artifact.

### Still open (non-blocking, post-gate / P2–P3)
- **OQ1:** issue/PR-**body** mutability — diff is SHA-pinned but bodies editable → P2: document + fail-loud (hash mismatch rejects).
- **OQ2:** oversized-diff truncation policy in `canonical.ts`.
- **OQ8:** CRLF→LF normalization on body fields only — confirm with tech-lead before landing.
- **OQ9:** `withdrawFees` permissioning — permissionless-to-fixed-recipient (lean) vs `onlyOwner`/`onlyFeeRecipient` — one-line ruling from security-reviewer (R2 pending).
- **OQ10 (judge.ts ownership):** L1 delimiters + rubric land as one atomic PR — tech-lead to assign the owner.
