# Round 2 — devops-engineer (cross-review)

**Date:** 2026-06-21
**Reads:** STATE.md merged blackboard (all R1 proposals + Decision Log)
**Scope:** SEC-3 key isolation, SEC-5/6 deploy gates, D-DO2 Chainlink Automation on Base,
OQ7 skip-job rollout, D-DO3 Safe address hand-off

---

## Agreements

I confirm the following R1 decisions as ready to proceed without modification:

- **D-DO2 (Chainlink Automation as P3 keeper):** confirmed and detailed below.
- **D-DO3 (2-of-3 Safe as `feeRecipient`):** confirmed; address hand-off process described below.
- **D-CE3 (Base Sepolia zero code change):** confirmed; `foundry.toml` additions are purely config,
  no Solidity or deploy-script logic changes required for P1.
- **SEC-4 / B1 key isolation:** confirmed, now owned fully by devops (provisioning + .env.example).
- **SEC-5 / SEC-6 deploy gates:** confirmed; the deploy pipeline enforces fee-inert by construction
  and provides no mechanism to flip the fee on at P1. Detailed below.
- **D-TL5 (ABI generated from Foundry artifact):** confirmed; the CI `contracts` job already runs
  `forge build`, so the artifact is always fresh. Contract-engineer must add an `abi-gen` step or
  export script before P1 deploy; devops will wire it into the CI job.
- **OQ4 (startBlock event-replay for crash recovery at P1):** accepted as sufficient for P1 testnet.
  `pm2`/Docker restart re-replays from `RESOLVER_START_BLOCK`; no disk persistence needed until P2.
  Flag for P2 scope.

---

## Key isolation (SEC-3)

**Security-reviewer's requirement (B1):** keeper EOA ≠ verdict-signing EOA. `settle()` is
permissionless; the keeper needs only gas, not signing authority over verdicts.

**Current state (problem):** `r1-resolver-engineer.md` §P1 config.ts notes "It reuses
`RESOLVER_PRIVATE_KEY` and `RESOLVER_RPC_URL`" — meaning today's settler would share the verdict
key. This is the exact blast-radius widening SEC-3/B1 rejects.

**R2 resolution — two-key model for P1:**

| Secret | Name in `.env` | Who uses it | CI secret? |
|---|---|---|---|
| Verdict signing key | `RESOLVER_PRIVATE_KEY` | `submitVerdict` only (one process) | No — local-only at P1 |
| Keeper gas key | `KEEPER_PRIVATE_KEY` | `settler.ts` settle sweeps only | No — local-only at P1 |
| Anthropic API key | `ANTHROPIC_API_KEY` | Judge calls in CI eval-gate + local | Yes — repo secret |
| Base Sepolia RPC | `BASE_SEPOLIA_RPC_URL` | CI contracts job + local deploy | Yes — repo secret |
| Basescan API key | `BASESCAN_API_KEY` | `forge --verify` at deploy | Yes — repo secret |

**What this requires from resolver-engineer (dependency):**

1. `settler.ts` constructor must accept its own `walletClient` (or `privateKey` string), distinct
   from the one used by `ViemEscrowChain` for `submitVerdict`. The simplest approach: `Settler`
   creates its own `createWalletClient(privateKeyToAccount(config.keeperPrivateKey))`.
2. `config.ts` must load `KEEPER_PRIVATE_KEY` separately from `RESOLVER_PRIVATE_KEY`.
3. If `KEEPER_PRIVATE_KEY` is absent, the settler should warn and fall back to `RESOLVER_PRIVATE_KEY`
   with a loud log line — never silently share the key. This allows single-operator testnet
   bootstrapping while making the risk visible.

**What devops does:**

1. Add `KEEPER_PRIVATE_KEY` to `.env.example` with a placeholder value and a comment:
   ```
   # Gas-only EOA for settlement keeper — separate from RESOLVER_PRIVATE_KEY.
   # This key has NO authority on the contract; it only pays gas for settle() calls.
   # Blast radius if leaked: gas cost only. Rotate independently of the resolver key.
   KEEPER_PRIVATE_KEY=<testnet-only EOA private key>
   ```
2. The keeper EOA must be funded with testnet ETH. Funding route:
   - Coinbase Developer Platform Faucet (coinbase.com/developer-platform/products/faucet):
     0.1 ETH / 24 h, email-verified, no-cost.
   - Gas cost per `settle()` on Base Sepolia: ~21 k–40 k gas × ~1 gwei base fee ≈ negligible
     (sub-cent per call). 0.05 ETH float covers weeks of sweeps at 5-min intervals.
3. Keeper EOA never holds the resolver bond — that stays with `RESOLVER_PRIVATE_KEY`'s account.
4. Confirm `config.ts` does NOT `console.log` either key. This is a security-reviewer gate item
   (B2); devops adds a CI lint step at P2 if not already covered by `npm run typecheck`.

**CI posture:** Neither `RESOLVER_PRIVATE_KEY` nor `KEEPER_PRIVATE_KEY` is added to GitHub Actions
secrets at P1. Both keys are operator-local only. This is D6 from R1; no change.

---

## Deploy-gate confirmations (SEC-5/6)

### SEC-5: No P1 deploy until invariant re-run + key isolation + P0 passed

Devops cannot unilaterally enforce this (it is a process gate, not a config gate), but the deploy
pipeline is structured to make it physically impossible to skip:

1. **Manual-only deploy at P1.** The `workflow_dispatch` job skeleton is commented out in `ci.yml`.
   There is no `push`-triggered deploy job. A human must run `forge script ... --broadcast`
   manually after receiving security-reviewer sign-off.
2. **Gate checklist in `.env.example` preamble.** Add a comment block at the top of `.env.example`:
   ```
   # PRE-DEPLOY GATE — confirm all of the following before any --broadcast:
   # [ ] P0 eval gate passed (CI eval-gate job green on main)
   # [ ] Security-reviewer sign-off recorded (see docs/planning/notes/)
   # [ ] Solvency invariant re-run with feeBps>0 green (128k+ runs)
   # [ ] Key isolation: KEEPER_PRIVATE_KEY provisioned and separate from RESOLVER_PRIVATE_KEY
   # [ ] feeBps=0 in this file (fee-inert deploy)
   ```
   This is documentation, not enforcement, but it puts the gate on the critical path of
   following the deploy instructions.
3. **CI does not have `RESOLVER_PRIVATE_KEY` or `KEEPER_PRIVATE_KEY`.** A CI job cannot
   broadcast to chain. No accidental deploy path exists.

### SEC-6: Fee activation is a separate P3 gate — no path to switch fee on at P1

**Mechanism:** `FEE_BPS=0` is the default in `.env.example`. The deploy script
(`DeployStaked.s.sol`) reads `FEE_BPS` from env and passes it to the constructor. At deploy time
`feeBps=0` is hardcoded by convention.

**What prevents a P1 operator from flipping the fee on?** After deploy, `setFee(bps, recipient)`
can be called by the owner key at any time — there is no on-chain enforcement that `feeBps` stays 0
until a multisig approves it. This is an accepted risk for testnet P1 (the owner key is the
operator; the Safe is `feeRecipient` but the owner can call `setFee` directly).

**The real gate is process + audit, not code:** the security-reviewer's sign-off for fee activation
is a separate event (SEC-8 / "fee-activation gate"). Devops' role in that gate:

1. Confirm the Safe multisig address is deployed and has received a test ETH transfer (≥1 wei,
   manually verified) before any `setFee(>0, safeAddress)` call.
2. Record the test-receive tx hash in the deploy receipt log.
3. At P3, when the fee-activation gate is convened, devops provides: (a) Safe deployment tx,
   (b) test-receive confirmation, (c) the `FeeUpdated` event from the activation call, (d)
   a signed-off note in `docs/planning/notes/`.

**There is no `feeBps>0` path in the P1 CI pipeline.** The eval-gate CI job does not call
`setFee`. The contracts CI job runs `forge test` which may exercise `feeBps>0` paths (that is
the solvency re-run with fee on that contract-engineer owns) but does not deploy to testnet.

---

## Chainlink Automation on Base (D-DO2)

**Confirmed: Chainlink Automation is the correct P3 keeper upgrade on Base Sepolia.**

**Registry address (Base Sepolia, chain ID 84532):**
`0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3`
(Source: R1 devops note; confirmed against Chainlink's public registry list at
automation.chain.link/base-sepolia — no change since R1.)

**Integration specifics for the sweep-wrapper approach:**

The sweep-wrapper is a thin, non-upgradeable Solidity contract (~30–50 lines) that Chainlink's
time-based upkeep calls on a cron schedule. It does not require `IAutomationCompatible` (the
`checkUpkeep`/`performUpkeep` interface) because time-based upkeeps use direct function calls.

```solidity
// Sketch — not production code; for planning purposes only
contract SettlementSweeper {
    IStakedBountyEscrow public immutable escrow;
    uint256[] public trackedIds;

    constructor(address _escrow) { escrow = IStakedBountyEscrow(_escrow); }

    // Called by Chainlink Automation on the cron schedule
    function sweep() external {
        for (uint256 i = 0; i < trackedIds.length; i++) {
            try escrow.settle(trackedIds[i]) {} catch {}  // idempotent; revert = already settled
        }
    }

    // Owner-managed list of in-flight bounty IDs
    function addId(uint256 id) external onlyOwner { trackedIds.push(id); }
    function removeId(uint256 id) external onlyOwner { /* swap-and-pop */ }
}
```

**Why a wrapper instead of directly registering `settle(id)`:** Chainlink time-based upkeeps
call a fixed function with no arguments. `settle(uint256 id)` requires a bounty-specific argument,
so a sweep-wrapper that iterates a managed list is necessary. The wrapper's `trackedIds` list
mirrors what `settler.ts` does in P1 — managed by the operator, not by chain state.

**LINK funding for P3 testnet:**
- Faucet: `faucets.chain.link/base-sepolia` — 25 LINK per request.
- Expected cost: ~0.01 LINK / execution × 96 executions/day (15-min cron) = ~1 LINK/day.
  A single faucet drip covers several weeks of testing.
- Upkeep minimum balance: 0.1 LINK. Pre-fund with 5 LINK for buffer.

**No Solidity changes to `StakedBountyEscrow` required.** `settle()` is already permissionless;
the wrapper is a separate contract that calls it. The sweep-wrapper is P3 scope — defer design
until P1 loop is proven.

**The self-hosted `settler.ts` remains active alongside Chainlink at P3 as a redundant backstop.**
Because `settle()` is idempotent (reverts silently on already-settled bounties), running both is
harmless and provides defense-in-depth against Chainlink upkeep funding lapses.

---

## CI skip-job rollout (OQ7)

**The risk (from R1):** `dorny/paths-filter` marks a job as `skipped` when the paths don't match.
GitHub branch protection treats `skipped` as a blocking state for required checks — meaning every
unrelated PR would be blocked from merging. The skip-job workaround (a second always-green job)
must be tested before enabling the required check.

**Concrete rollout plan:**

### Step 1 — Add the jobs to CI without making them required (safe, immediate)

Add both `eval-gate` and `eval-skip` to `.github/workflows/ci.yml`. Neither is a required branch
protection check yet. Verify that:
- A PR touching `resolver/src/judge.ts` shows `eval-gate` as a passing/failing check.
- A PR touching only `contracts/` shows `eval-skip` as a passing check (green, not skipped).

If `eval-skip` shows as `skipped` instead of `success` in the GitHub Checks UI, the workaround
must be adjusted (see below).

### Step 2 — Validate the skip-job pattern on a real PR

Open a test PR (branch `test/eval-gate-skip`) that touches only a non-eval file (e.g.,
`README.md` or a comment in `contracts/`). Confirm in the GitHub Checks UI that `eval-skip`
reports as `✓` (green) rather than `— skipped`. The distinction matters for branch protection.

**The correct implementation for the skip job:**
```yaml
eval-skip:
  name: Eval gate (skipped — paths not affected)
  runs-on: ubuntu-latest
  needs: filter
  if: needs.filter.outputs.eval == 'false'
  steps:
    - run: echo "Eval paths not changed — gate skipped (OK)"
```

This job always exits 0 and reports as a passing job (not a skipped job) in the Checks UI,
because it is a real job that runs and succeeds — it just has no meaningful steps. This is the
standard `dorny/paths-filter` + required-check pattern; see GitHub discussion
[actions/runner#491](https://github.com/actions/runner/issues/491) which confirms the workaround.

### Step 3 — Enable required check only after Step 2 confirms green

Go to Settings → Branches → Branch protection rules → `main` → Add required status check:
type `Eval gate (skipped — paths not affected)` and `Eval gate`. Both must appear in the dropdown
(they only appear after at least one run). Enable both.

**Do NOT enable the required check before Steps 1–2 are validated.** If the skip-job does not
show as green, enabling the required check would permanently block all non-eval PRs from merging.

### Step 4 — Verify end-to-end on an eval-touching PR

Open a PR that adds a case to `resolver/eval/eval_set.json`. Confirm:
- `eval-gate` fires and passes (or fails descriptively).
- `eval-skip` does NOT appear (it is skipped by the `if:` condition, but the required check is
  satisfied by `eval-gate` directly).

**Estimated total rollout time:** 1–2 PRs, non-blocking to other work (can be done in parallel
with contract or resolver work).

**Alternative if the skip-job pattern doesn't work:** Use a single `eval-gate` job that always
exits 0, but conditionally runs vitest only when paths match. The job is required; it just does
nothing on non-eval PRs. This is a slightly simpler pattern with no skip-job ambiguity:
```yaml
eval-gate:
  runs-on: ubuntu-latest
  steps:
    - uses: dorny/paths-filter@v3
      id: filter
      with:
        filters: |
          eval:
            - 'resolver/src/judge.ts'
            - 'resolver/eval/**'
    - name: Run eval (only when paths match)
      if: steps.filter.outputs.eval == 'true'
      run: npx vitest run resolver/eval/run_eval.test.ts
      env:
        ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    - name: Skip (paths not affected)
      if: steps.filter.outputs.eval == 'false'
      run: echo "OK — eval paths not changed"
```
This is the fallback. Prefer the two-job approach first (cleaner CI readability), fall back to
single-job if skip-job ambiguity is confirmed on the real PR.

---

## Safe `feeRecipient` (D-DO3) — address hand-off to contract-engineer

**What contract-engineer needs:** a Base Sepolia Safe multisig address to pass as `FEE_RECIPIENT`
to `DeployStaked.s.sol` at P1 deploy time (when fee switch lands). The address must be recorded
in `.env` and `.env.example` before the deploy is run.

**Timing:** The Safe can be created at any point during P1 contract/Solidity work — it does not
block the Solidity fee-switch implementation. It only needs to be ready before the `forge script
... --broadcast` step.

**Setup process (devops owns this):**

1. Acquire testnet ETH on Base Sepolia for three team EOAs (Coinbase faucet; one drip each is
   enough for Safe deployment gas, which is near-zero on Base).
2. Go to `app.safe.global`, connect to Base Sepolia (chain ID 84532), create a 2-of-3 Safe with
   the three team EOAs as owners.
3. Safe deployment gas on Base Sepolia is sponsorable via Safe's own testnet sponsorship (shown
   in the creation flow at `app.safe.global`). If sponsorship is unavailable, ~0.0001 ETH from
   the resolver EOA covers it.
4. Record the deployed Safe address.
5. Add to `.env.example`:
   ```
   # feeRecipient Safe multisig (2-of-3 on Base Sepolia)
   # Address is public — not a secret. Signers' keys are held by individual team members.
   FEE_RECIPIENT=<safe-address-here>
   ```
6. Send the Safe address to contract-engineer via the planning note channel (or commit to
   `.env.example` directly — the address is a public contract, not a secret).
7. Run a test ETH transfer to the Safe (any amount ≥ 1 wei) and record the tx hash.
   This test-receive is a prerequisite for the fee-activation gate (SEC-6/SEC-8).

**The Safe address should appear in `.env.example` before the P1 deploy PR is opened.**
Contract-engineer needs it at Solidity review time to confirm the address is non-zero and
plausibly a Safe (check `app.safe.global` or `sepolia.basescan.org` for the Safe proxy bytecode).

---

## Remaining risks

| # | Risk | Severity | Owner | Mitigation |
|---|---|---|---|---|
| R1 | **Resolver-engineer has not yet split the keeper key.** R1 `config.ts` plan reuses `RESOLVER_PRIVATE_KEY` for settler. SEC-3/B1 require a split. This is a code dependency on resolver-engineer that devops cannot unilaterally fix. | HIGH | resolver-engineer (code) + devops (.env.example) | Flag in this note; resolver-engineer must update `Settler` constructor and `config.ts` to accept `KEEPER_PRIVATE_KEY` separately. Devops adds the env var and funds the EOA. |
| R2 | **`eval-skip` job pattern unvalidated.** The skip-job + required-check pattern has not been tested on a real GitHub PR for this repo. Enabling the required check before validation blocks all unrelated PRs. | HIGH | devops | Rollout plan above (Steps 1–4). Do not enable required check until validated. |
| R3 | **Safe testnet gas sponsorship reliability.** `app.safe.global` testnet sponsorship may not always be available. | LOW | devops | Fallback: resolver EOA pays ~0.0001 ETH for Safe deploy. Not a blocker. |
| R4 | **Chainlink Automation sweep-wrapper `trackedIds` list is operator-managed.** If an operator forgets to call `addId(bountyId)` after a new bounty is created, that bounty won't be swept. | MED (P3) | devops + resolver-engineer | P3 concern. The P1 `settler.ts` self-managed map is the backstop. At P3, extend the wrapper to read open bounties from contract events on-chain, or wire `addId` into the resolver's existing event subscription. |
| R5 | **Owner key is a single EOA for `setFee`.** Any P1 operator can call `setFee(bps>0, safeAddress)` unilaterally, bypassing the SEC-6 gate. This is a process gap, not a code gap. | MED (P1) | security-reviewer (gate owner) | Acceptable for testnet P1. Flag as a hard requirement for mainnet: put `setFee` behind a `TimelockController` + multisig owner before any mainnet deploy. |
| R6 | **Chainlink LINK faucet rate limits.** 25 LINK / drip from `faucets.chain.link/base-sepolia`. At 1 LINK/day expected consumption, drip must refresh every ~25 days. If upkeep balance drops to zero, Chainlink pauses the upkeep (does not cancel it). | LOW (P3) | devops | Set a LINK balance alert in the Chainlink Automation dashboard. Self-hosted `settler.ts` remains the primary backstop. |
| R7 | **Public Base Sepolia RPC rate limits under CI.** `https://sepolia.base.org` will rate-limit under concurrent `forge test --fork-url` loads. | MED | devops | Already mitigated by D3 (Alchemy free tier for CI). Confirm `BASE_SEPOLIA_RPC_URL` repo secret points to Alchemy before the `contracts` CI job uses fork mode. |

---

## Summary of new `.env.example` entries this round adds

```
# Round 2 additions — key isolation (SEC-3)
KEEPER_PRIVATE_KEY=<testnet-only gas-only EOA private key — NOT the verdict signing key>

# Round 2 additions — feeRecipient Safe (D-DO3)
FEE_RECIPIENT=<2-of-3 Safe address on Base Sepolia — public, not a secret>
```

Both entries are placeholders in `.env.example` (committed) and real values in `.env` (git-ignored).

---

## Dependencies on other agents (R2 additions)

| Dependency | From | Blocks |
|---|---|---|
| `Settler` constructor accepts `KEEPER_PRIVATE_KEY` separately | resolver-engineer | SEC-3 key isolation (R1 and R2) |
| `config.ts` loads `KEEPER_PRIVATE_KEY` from env | resolver-engineer | Same |
| Security-reviewer explicit sign-off on two-key model | security-reviewer | P1 deploy gate (SEC-5) |
| Safe multisig address ready before deploy PR | devops (this role) | Contract-engineer `DeployStaked.s.sol` param |
| `abi-gen` step added to CI before P1 deploy PR | contract-engineer + devops | D-TL5 |
