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
| tech-lead | ⏳ (orchestrates) | ⏳ |
| contract-engineer | 🟡 dispatched | — |
| resolver-engineer | 🟡 dispatched | — |
| eval-engineer | 🟡 dispatched | — |
| devops-engineer | 🟡 dispatched | — |
| security-reviewer | 🟡 dispatched | — |

## 5. Per-agent contributions
_(Round-1 proposals and Round-2 cross-reviews merged here by the tech-lead.)_

### contract-engineer
- Round 1: _pending_
- Round 2: _pending_

### resolver-engineer
- Round 1: _pending_
- Round 2: _pending_

### eval-engineer
- Round 1: _pending_
- Round 2: _pending_

### devops-engineer
- Round 1: _pending_
- Round 2: _pending_

### security-reviewer
- Round 1: _pending_
- Round 2: _pending_

## 6. Tech-choices table
_(choice · why · external source adapted — filled from round 1.)_

| Area | Choice | Why | Source |
|---|---|---|---|
| _pending_ | | | |

## 7. Decision Log (append-only)
_(decision · owner · rationale · status: proposed / accepted / contested)_

| # | Decision | Owner | Rationale | Status |
|---|---|---|---|---|
| — | _pending round 1_ | | | |

## 8. Open Questions / Conflicts

- _pending round 1_
