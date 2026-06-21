# Round 1 Proposal — devops-engineer

**Date:** 2026-06-21
**Scope:** CI eval-gate, Base Sepolia deploy pipeline, keeper hosting, secrets & treasury

---

## What to build

### 1. CI eval-gate job (`eval-gate`)

A new job in `.github/workflows/ci.yml` that runs `resolver/eval/run_eval.test.ts` via
vitest on every PR and push to `main`. It:

- Runs **only** when `judge.ts`, `eval/`, or the eval set itself changes — guarded by a
  `dorny/paths-filter` step that sets an output variable; the eval step is
  `if: steps.filter.outputs.eval == 'true'`. A second "pass-through" step always posts
  a `success` status when the filter is false, satisfying branch-protection required
  checks without burning API tokens on unrelated PRs (see "Decisions I own" D1 for the
  PR-blocking vs scheduled trade-off).
- Injects `ANTHROPIC_API_KEY` from a repo-level GitHub Actions secret (already needed
  by developers locally; zero new secret rotation burden).
- Uses `concurrency: group: eval-gate-${{ github.ref }}, cancel-in-progress: true` to
  kill stale runs on force-push without queuing cost.
- Fails the job (exits non-zero) when clear-cut accuracy < 90 % — vitest does this
  natively via the assertion in `run_eval.test.ts`.
- Sets `timeout-minutes: 20` (30 s per case × 15 cases + margin).

**Environment variable names used in the job:**
```
ANTHROPIC_API_KEY   # repo secret → judges
NODE_ENV=test
```

**Path-filter pattern:**
```yaml
eval:
  - 'resolver/src/judge.ts'
  - 'resolver/eval/**'
  - 'resolver/src/verdict*.ts'
```

**Approximate cost per run:** 15 cases × ~1 000 tokens (prompt caching reduces repeat
system-prompt tokens) × `claude-opus-4-8` ≈ $0.15–0.30. Acceptable at the current
PR cadence. Cost grows linearly with dataset size; revisit if dataset exceeds 50 cases.

---

### 2. Base Sepolia deploy pipeline

#### `foundry.toml` additions (no new file, edit existing)

```toml
[rpc_endpoints]
baseSepolia = "${BASE_SEPOLIA_RPC_URL}"

[etherscan]
baseSepolia = { key = "${BASESCAN_API_KEY}", url = "https://api-sepolia.basescan.org/api" }
```

With Etherscan API v2, a single Etherscan key is valid for all Etherscan-family
explorers (BscScan, BaseScan, Polygonscan). Legacy per-chain keys are deprecated.
Store as `BASESCAN_API_KEY` (or reuse `ETHERSCAN_API_KEY`) in `.env.example` and as a
GitHub Actions secret.

#### `.env.example` additions

```
# Base Sepolia deploy
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org        # public; use Alchemy/Quicknode for CI
BASESCAN_API_KEY=<get from basescan.org>

# Contract constructor params (Base Sepolia)
RESOLVER=<resolver EOA address>
ARBITER=<arbiter EOA address>        # same as RESOLVER for testnet
CHALLENGE_PERIOD=86400               # 1 day testnet default
RESOLVER_BOND=100000000000000000     # 0.1 ETH testnet default
CHALLENGE_BOND=50000000000000000     # 0.05 ETH testnet default

# Fee switch (inert at deploy)
FEE_BPS=0
FEE_RECIPIENT=<Safe multisig address — see §4>
```

#### Deploy + verify one-liner (for manual P1 deploy)

```bash
forge script script/DeployStaked.s.sol \
  --rpc-url baseSepolia \
  --broadcast \
  --verify \
  --private-key $RESOLVER_PRIVATE_KEY
```

Note: `--rpc-url baseSepolia` resolves via `foundry.toml`'s `[rpc_endpoints]` block.
`--verify` triggers Basescan verification using the `[etherscan] baseSepolia` entry.
No `--etherscan-api-key` flag needed when the key is in `foundry.toml`.

#### `script/DeployStaked.s.sol` changes needed (from contract-engineer)

`DeployStaked.s.sol` must be extended to accept `FEE_BPS` and `FEE_RECIPIENT` env vars
once the fee switch lands in `StakedBountyEscrow`. Until then, the current script is
correct as-is — no devops change required. Coordinate with contract-engineer.

#### Faucet

Coinbase Developer Platform Faucet: `coinbase.com/developer-platform/products/faucet`
— 0.1 ETH / 24 h, no account required beyond email verification. Sufficient for
testnet resolver staking (0.1 ETH bond default) + bounty creation + gas float.

#### CI integration (optional, `deploy` job — manual trigger only for P1)

Deployment is a manual `workflow_dispatch` for P1; automated deploy on merge to `main`
is a P3 concern. Add a commented-out `deploy` job skeleton now so the shape is visible.

---

### 3. Keeper hosting (settler.ts)

**P1: self-hosted cron inside the resolver process.** `settler.ts` (built by
resolver-engineer) runs as a `setInterval` loop inside the same Node.js process as the
main watcher. Hosting options by phase:

| Phase | Runtime | Restart policy | Liveness alert |
|---|---|---|---|
| P1 (now) | Same process as resolver, local / any VPS | `pm2 restart settler` / `docker restart --policy=always` | Dead-man's switch: `pm2` sends email on crash; or a 5-min health-check ping to UptimeRobot free tier |
| P2 | Docker Compose service (`settler` container) alongside `resolver` | Docker restart policy `always` | UptimeRobot HTTP health endpoint or `curl`-based dead-man |
| P3 | **Chainlink Automation time-based upkeep** on Base Sepolia / Base Mainnet — replaces single-operator risk | N/A (decentralized executor network) | Chainlink dashboard |

**Why Chainlink for P3 instead of Gelato?** Gelato Web3 Functions reached end-of-life
March 31, 2026 and is no longer operational. Chainlink Automation explicitly supports
Base Sepolia (registry: `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3`) with time-based
upkeeps (cron syntax, no `IAutomationCompatible` interface required on the contract —
fits `settle()` which is permissionless). Testnet LINK available at `faucets.chain.link/base-sepolia`.

**P3 Chainlink time-based upkeep design:**
- Target function: `settle(uint256 id)` is called per-bounty; a sweep-wrapper contract
  (thin proxy, ~30 lines Solidity) can batch-iterate open bounties and call `settle()`
  for each expired one, returning early once a live one is found. This wrapper is the
  upkeep target.
- Cron: `*/15 * * * *` (every 15 min) — sufficient for a 24 h challenge window.
- LINK funding: pre-fund upkeep with 1–2 LINK on testnet (from faucet); on mainnet
  budget ~0.1 LINK / execution × expected daily executions.
- No Solidity changes to `StakedBountyEscrow` required. The sweep-wrapper is a
  separate, non-upgradeable contract.

**Key isolation for P1:**
- Resolver EOA holds only testnet ETH (no mainnet keys ever in env).
- `.env` is git-ignored; `.env.example` is committed with placeholder values only.
- `RESOLVER_PRIVATE_KEY` in GitHub Actions secrets for any CI-triggered ops (currently
  none; placeholder for P3 automated deploy).
- Never log private keys: confirm `config.ts` does not `console.log` the key (it
  should not — check with security-reviewer).

---

### 4. Secrets & treasury

#### Secret hygiene rules (enforced now)

| Secret | Where stored | Who uses it |
|---|---|---|
| `ANTHROPIC_API_KEY` | GitHub Actions repo secret + local `.env` | eval-gate CI job, local dev |
| `RESOLVER_PRIVATE_KEY` | Local `.env` only (never in CI for P1) | resolver watcher + settler |
| `BASE_SEPOLIA_RPC_URL` | `.env` + GitHub Actions repo secret | CI contracts job (fork tests), deploy |
| `BASESCAN_API_KEY` | `.env` + GitHub Actions repo secret | forge deploy --verify |

For P1, `RESOLVER_PRIVATE_KEY` stays local-only (manual deploy). Adding it to CI is a P3
concern and requires a security-reviewer sign-off on key scoping.

`.env.example` template is the canonical list of all required vars. Any new var added to
`.env` must land in `.env.example` first, in the same PR. Enforced by code-review convention
(no automation tooling needed at P1 scale).

#### `feeRecipient` Safe multisig (for contract-engineer's fee switch)

A **2-of-3 Safe multisig** on Base Sepolia serves as `feeRecipient` for the inert fee
switch. Steps to set it up:

1. Go to `app.safe.global`, connect to Base Sepolia (chain ID 84532).
2. Create a new Safe: 3 owner addresses (e.g., three team EOAs on Base Sepolia testnet),
   threshold = 2.
3. Gas for Safe deployment on Base Sepolia is near-zero and sponsorable via Safe's own
   testnet sponsorship (shown during creation flow at `app.safe.global`).
4. Record the Safe address → set as `FEE_RECIPIENT` in `.env` and pass to
   `DeployStaked.s.sol` at deploy time (when fee switch lands).

Safe supports Base (mainnet and testnet) natively via `app.safe.global`. For mainnet
P3, the same 2-of-3 setup applies with real keys; increase to 3-of-5 before holding
significant protocol revenue (per Safe's own security guidance for treasuries >$100 K).

The Safe address is **not a secret** — it is a public contract address committed to `.env.example`
and to the deploy receipt. Only the signer EOA private keys are secret, and those are
held by individual team members, never in a shared env file.

---

## What to use

| Area | Tool / Service | Why | Source |
|---|---|---|---|
| CI eval gate | GitHub Actions + vitest (already present) | Zero new dependencies; vitest is in `devDependencies`; native `exit 1` on assertion failure gates PRs | [vitest-evals Sentry blog](https://blog.sentry.io/evals-are-just-tests-so-why-arent-engineers-writing-them/) |
| Path filtering | `dorny/paths-filter@v3` | Job-level conditional prevents burning API tokens on unrelated PRs while still satisfying required-check branch protection | [dorny/paths-filter](https://github.com/dorny/paths-filter) |
| Concurrency control | `concurrency: cancel-in-progress: true` | Kills stale eval runs on force-push; prevents queue buildup | [GitHub Actions concurrency docs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency) |
| Base Sepolia RPC | `https://sepolia.base.org` (public) / Alchemy for CI | Public endpoint for local dev; Alchemy/Quicknode for rate-limit-sensitive CI jobs | [Base network info](https://docs.base.org/base-chain/network-information/network-faucets) |
| Contract verification | Basescan via Etherscan API v2 | Single Etherscan key works for all Etherscan-family explorers; `foundry.toml` `[etherscan]` block handles it | [Etherscan v2 verify with Foundry](https://docs.etherscan.io/etherscan-v2/contract-verification/verify-with-foundry) |
| Testnet ETH faucet | Coinbase Developer Platform Faucet | 0.1 ETH / 24 h, email-verified, no-cost; first-party on Base | [Base network faucets](https://docs.base.org/base-chain/network-information/network-faucets) |
| P1 keeper | Self-hosted `setInterval` in resolver process | Zero new deps; `ViemEscrowChain.settle()` already exists; adequate for testnet | [Research #04](../research/04-settlement-keepers.md) |
| P3 keeper | Chainlink Automation time-based upkeep | Gelato Web3 Functions EOL March 2026; Chainlink supports Base Sepolia (registry `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3`); no contract changes needed for time-based mode | [Chainlink Automation Base Sepolia](https://automation.chain.link/base-sepolia) · [LINK faucet](https://faucets.chain.link/base-sepolia) |
| Treasury / fee recipient | Safe 2-of-3 multisig via `app.safe.global` | Industry standard for protocol treasury; supports Base natively; gas-sponsorable on testnet | [Safe global](https://safe.global/) · [Safe Deep Dive 2026](https://eco.com/support/en/articles/15254042-safe-wallet-deep-dive-2026-multisig-and-smart-accounts) |
| Process supervisor (P1) | pm2 or Docker `restart: always` | Keeps resolver + settler alive across crashes; cheap or free; no infra dependency | N/A (operational standard) |

---

## How to build

### Step 1 — eval-gate CI job (P0, do first)

1. Confirm `resolver/eval/eval_set.json` exists (or guard with `[ ! -f eval/eval_set.json ] && exit 1`).
2. Add `dorny/paths-filter@v3` step to `.github/workflows/ci.yml` with the filter
   patterns listed above.
3. Add `eval-gate` job with `if: needs.filter.outputs.eval == 'true'` conditional.
4. Add pass-through `eval-skip` job with `if: needs.filter.outputs.eval == 'false'`
   that posts a skipped-but-green status (necessary for branch protection required checks
   when path filter fires `false`).
5. Add `ANTHROPIC_API_KEY` to repository secrets (Settings → Secrets → Actions).
6. Test by opening a PR that touches `resolver/src/judge.ts` — confirm the eval job
   fires and passes (or fails descriptively on disagreements).

### Step 2 — `foundry.toml` and `.env.example` updates (P1, alongside contract work)

1. Add `[rpc_endpoints]` and `[etherscan]` blocks to `foundry.toml` as shown above.
2. Add all new Base Sepolia vars to `.env.example`.
3. Obtain testnet ETH from Coinbase faucet into the resolver EOA.
4. Run: `forge script script/DeployStaked.s.sol --rpc-url baseSepolia --broadcast --verify --private-key $RESOLVER_PRIVATE_KEY`
5. Confirm contract appears on `sepolia.basescan.org` with verified source.
6. Record deployed address → update `.env` → restart resolver with new `CONTRACT_ADDRESS`.

### Step 3 — Safe multisig setup (P1, prerequisite for fee switch)

1. Get testnet ETH for three signers' EOA wallets (Coinbase faucet, or transfer).
2. Create 2-of-3 Safe on Base Sepolia at `app.safe.global`.
3. Record Safe address → add to `.env.example` as `FEE_RECIPIENT` placeholder.
4. Pass address to `DeployStaked.s.sol` when fee switch lands (contract-engineer
   handles the Solidity; we just need the address ready at deploy time).

### Step 4 — Keeper hosting (P1)

1. Wire `settler.ts` (built by resolver-engineer) into the resolver `npm start` process.
2. Add `pm2` or Docker `restart: always` to the hosting environment.
3. Add a dead-man health check: simple HTTP `/health` endpoint in `index.ts` that
   UptimeRobot or similar polls every 5 min.
4. Confirm `RESOLVER_START_BLOCK` env var is set so settler replays `VerdictProposed`
   events on restart and does not miss in-flight bounties.

### Step 5 — Chainlink Automation upkeep (P3, defer until mainnet planning)

- Design the thin sweep-wrapper contract.
- Register time-based upkeep at `automation.chain.link/base-sepolia`.
- Fund with testnet LINK from `faucets.chain.link/base-sepolia`.
- This is out of scope until the P1 loop is proven.

---

## Decisions I own

| # | Decision | Options | Proposed answer | Rationale |
|---|---|---|---|---|
| D1 | **eval-gate: PR-blocking vs scheduled** | (a) Required check on every PR touching judge.ts/eval/ — blocks merge on failure; (b) Scheduled nightly run, non-blocking | **(a) PR-blocking on path-filtered PRs** — but use `dorny/paths-filter` so it only fires on relevant PRs; unrelated PRs auto-pass via skip job | Eval accuracy is the P0 kill-gate; regressions must block merges; cost is manageable (~$0.25 / run) at current cadence. Re-evaluate if PR volume makes cost prohibitive. | 
| D2 | **eval-gate: vitest-evals library vs plain vitest** | vitest-evals (Sentry) adds GitHub Check-run reporting; plain vitest is already present | **Plain vitest** for now | vitest-evals adds a dep and `GITHUB_TOKEN` wiring for zero functional gain at P0; the assertion already exits non-zero. Add vitest-evals at P2 if the team wants PR check annotations. |
| D3 | **RPC provider for CI** | Public `sepolia.base.org` (rate-limited) vs Alchemy/Quicknode (free tier, rate-limit-tolerant) | **Alchemy free tier** for CI; public endpoint for local dev | The `contracts` CI job runs fork-mode tests; the public RPC rate-limits under CI load. Alchemy free tier is 300 M compute units/month — adequate. Add `BASE_SEPOLIA_RPC_URL` secret pointing to Alchemy URL. |
| D4 | **P3 keeper: Chainlink vs alternative** | Chainlink Automation (supported on Base Sepolia) vs rebuild Gelato alternative (KeeperHub, self-hosted) | **Chainlink Automation time-based upkeep** | Gelato Web3 Functions is EOL March 2026. Chainlink is live on Base Sepolia with confirmed registry address. No contract changes needed for time-based mode. LINK available from faucet. |
| D5 | **Safe threshold for testnet treasury** | 1-of-1 (single signer, no multisig), 2-of-3 (minimal multisig), 3-of-5 | **2-of-3 on testnet / 3-of-5 on mainnet** | 2-of-3 proves the multisig flow on testnet without requiring 3 team members to be online simultaneously. Upgrade to 3-of-5 before mainnet P3 per Safe's security guidance for larger treasuries. |
| D6 | **`RESOLVER_PRIVATE_KEY` in CI** | Store in GitHub Actions secrets (enables automated deploy) vs keep local-only (manual deploy) | **Local-only for P1** | No automated on-chain ops needed in CI at P1. Adding the key to CI is a security surface that requires security-reviewer sign-off. Re-evaluate at P3. |

---

## Dependencies on other agents

| Dependency | Needed from | Blocks what here | Urgency |
|---|---|---|---|
| `resolver/eval/run_eval.test.ts` and `resolver/eval/eval_set.json` exist | eval-engineer | eval-gate CI job (Step 1) | P0 — needed before CI job is useful |
| `AnthropicJudge` accepts `ANTHROPIC_API_KEY` from env without additional config | resolver-engineer | eval-gate can run in CI | P0 |
| `StakedBountyEscrow` fee switch (`feeBps`, `feeRecipient`, `setFee()`) in Solidity | contract-engineer | Need Safe address at deploy time; `DeployStaked.s.sol` must be extended to accept `FEE_RECIPIENT` env var | P1 — deploy blocked until contract is ready |
| `settler.ts` implemented and exported from `resolver/src/` | resolver-engineer | Keeper hosting (Step 4) | P1 |
| Security-reviewer sign-off on fee switch `_payout` path | security-reviewer | Before any non-zero `feeBps` deploy; Safe address can be set inert now | Pre-P3 |
| Confirmation that `config.ts` does not log `RESOLVER_PRIVATE_KEY` | security-reviewer | Key isolation claim in this proposal | P1 |

---

## Open questions / risks

| # | Question / Risk | Severity | Notes |
|---|---|---|---|
| OQ1 | **Eval-gate flakiness from API non-determinism.** If `claude-opus-4-8` returns borderline verdicts that flip across runs, the gate becomes unreliable. | Medium | Eval-engineer should set `temperature: 0` on judge calls (or verify it is already 0). I can add `retry: 1` at the CI step level but this is a prompt-engineering fix, not a CI fix. |
| OQ2 | **`dorny/paths-filter` + required branch protection.** GitHub does not let a PR merge when a required check is *skipped* (only *passed*). The skip-job workaround (a separate always-green job) must be wired correctly or every unrelated PR will be blocked. Confirm with eval-engineer before enabling branch protection for `eval-gate`. | High | The fix is to make the pass-through job report `success`, not `skipped`. Need to test on a real PR before flipping the required check on. |
| OQ3 | **Basescan API key scope.** Etherscan API v2 deprecates per-chain keys but some Foundry versions may still require a chain-specific key. Confirm `forge --version` compatibility before relying on a single `ETHERSCAN_API_KEY`. | Low | If verification fails, fall back to `--etherscan-api-key` flag with the Etherscan key. |
| OQ4 | **Chainlink LINK faucet limits for P3.** The testnet LINK faucet may have low rate limits. For a 15-min cron on a 24 h challenge window, expected executions are ~96/day. At ~0.01 LINK/execution, that is ~1 LINK/day. Faucet drip rate must cover this. | Low (P3 concern) | Self-hosted fallback cron bot remains active alongside Chainlink as a redundant settler — idempotent by contract. |
| OQ5 | **Public Base Sepolia RPC rate limits in CI.** `forge test --fork-url https://sepolia.base.org` will hit rate limits under concurrent CI runs. | Medium | Mitigated by D3 (Alchemy for CI). Reminder: add `BASE_SEPOLIA_RPC_URL` as a required Actions secret before the `contracts` job uses fork mode. |
| OQ6 | **Safe testnet gas sponsorship reliability.** Safe's testnet creation gas sponsorship (shown during `app.safe.global` creation flow) may not always be available. | Low | Resolver EOA can pay the ~0.0001 ETH gas for Safe deploy from its Coinbase faucet balance. Not a blocker. |
| OQ7 | **Gelato migration timing.** Any existing Gelato-based automation (from prior experiments) stopped working March 31, 2026. Confirm with resolver-engineer that no live Gelato tasks exist referencing this repo. | Low | Research report #04 recommended Gelato as P3 path; that path is now closed. Chainlink replaces it. |
