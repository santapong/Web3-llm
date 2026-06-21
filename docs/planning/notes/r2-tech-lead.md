# Round 2 — tech-lead (cross-review / orchestration)

**Author:** tech-lead
**Date:** 2026-06-21
**Input:** merged `STATE.md` + all six `r1-*.md`. My job this round: arbitrate **C1**,
resolve **OQ3** and **OQ6**, confirm the build sequence under **D-DO2** (Gelato EOL →
Chainlink) and the **OQ7** CI skip-job risk, and surface what must go to the user.

---

## Agreements

The Round-1 proposals converge cleanly almost everywhere. I'm ratifying these as the
spine of `BUILD_PLAN.md` — no further debate needed:

- **The P0 eval gate is the master kill-gate** and is enforced **mechanically as a CI
  required check** (D-TL4 + D-DO1), not as a milestone someone declares "done." Nothing
  in P1/P2 ships until it's green, including the injection set at **0 successes**
  (SEC-5/D-EV2). Confirmed by eval-engineer, devops, security — unanimous.
- **L1 spotlighting (randomized delimiters + untrusted-content rubric clause) ships
  BEFORE the gate is scored** (SEC C1 / security checklist). Sequencing-critical: an
  undefended judge scored at 90% proves nothing. I'm pinning this as the first P0 task.
- **Injection set is both-directions** (force-approve a bad PR *and* force-reject a good
  PR) plus **spec-side reasoning-hijack**, not just PR-side (SEC-2/C2). The "malicious
  funder wants `fulfilled=false`" framing is correct and non-obvious — it stays.
- **Keeper key ≠ verdict-signing key** (SEC-4/D-... key isolation). `settle()` is
  permissionless, so the keeper runs a **gas-only EOA** (`KEEPER_PRIVATE_KEY`). This is a
  cheap, high-value blast-radius reduction. Resolver-engineer's R1 said the settler reuses
  `RESOLVER_PRIVATE_KEY`; **that is overridden** — settler must take its own key. Adopted.
- **Diff is always SHA-pinned** via the commit endpoint (D-TL3 + D-RE2), never "latest
  PR." Defeats force-push non-determinism and satisfies `withHashVerification`. Confirmed.
- **Custom-error migration is a revert-neutral, behaviour-identical refactor**, sequenced
  as step 1 of the P1 contract sprint, validated by a line-by-line old-string→new-error
  map and a fully green suite (D-CE1/SEC-7). Adopted.
- **Deploy fee-INERT** (`feeBps=0`); fee activation is a **separate P3 gate** (SEC-6/SEC-8),
  never folded into P1. Adopted. Base Sepolia = zero contract/foundry-code change (D-CE3).
- **Canonical strings are versioned + fixed-field deterministic** (D-TL1/D-TL2); the
  serializer is the P2 critical path and is built chain-free during P1.

---

## Conflict resolutions

### C1 — fee leg: push vs pull → **PULL (SEC-1 wins). Decision: accept SEC-1.**

**Decision:** The fee leg uses **pull-payment** (`feeOwed[feeRecipient] += fee` accrued
in `_payout`; a separate `withdrawFees()`). The **user payout (`net`) stays push** — the
claimant/funder are EOAs they control, so push is correct and preserves current behaviour.

**Rationale:**
1. **Security owns go/no-go, and they are not wrong here — they're right.** SEC-1 is a
   textbook push-payment DoS: a single reverting/misconfigured `feeRecipient` bricks
   `settle()` and `resolveDispute()` for **every** bounty, locking principal protocol-wide,
   not just the fee. Contract-engineer's own R1 (open-question #2) and C2-rationale concede
   the risk and explicitly name "pull-payment for fees" as the hardening — they only
   deferred it as "out of scope v0." The conflict is therefore narrower than it looks: both
   agents agree pull is safer; they disagree on whether it's worth doing now.
2. **It is worth doing now, because the cost is low and the mechanism ships in P1.** We are
   building and auditing the fee switch in P1 (even though inert). Doing it push-now /
   pull-later means a *second* audited contract change later, on the money core, to fix a
   known HIGH. Cheaper to land the safe version once.
3. **The contract-engineer's main argument for push — "solvency invariant formula is
   unchanged" — does not survive.** Under pull, escrow legitimately holds `Σ feeOwed`, so
   the invariant formula **gains a `+ Σ feeOwed` term** (SEC-3). This is a *clarification*,
   not a regression: the invariant still proves solvency, it just accounts for the accrued-
   but-unwithdrawn fees that now correctly rest in the contract.

**What this changes for contract-engineer (R3 implementation):**
- `_payout`: replace `if (fee != 0) _send(feeRecipient, fee)` with
  `if (fee != 0) feeOwed[feeRecipient] += fee;`. Keep `_send(recipient, net)` (push).
- Add `mapping(address => uint256) public feeOwed;` and
  `withdrawFees()` (pull; CEI + `nonReentrant`; zero-out before `_send`).
- **Invariant test:** adopt SEC-3's formula:
  `balance == resolverStake + Σ amount[live] + Σ challengeBondPaid[disputed] + Σ feeOwed`.
  Re-run 128k with `feeBps>0`, both outcomes, both dispute branches, plus a malicious-
  `feeRecipient` reentrancy test on `withdrawFees`. **This re-run is the artifact security
  signs off on** before any broadcast (D-CE2 superseded by the SEC-3 formula).
- Contract-engineer's C1 decision-log entry (push) is **superseded**; C2 (feeBps=0 off-
  switch, `MAX_FEE_BPS=500` constant cap), C3 (separate state var, set post-deploy), C5,
  C6 (with the SEC-3 formula amendment), C7 all stand.
- **Bonus:** pull also retires contract-engineer's open-question #2 (fee-recipient griefing)
  entirely — there is no longer a settlement-blocking recipient.

> Note: there is no fee actually flowing in P1 (`feeBps=0`), so this is a *latent* design
> choice — but the audited bytecode is what we deploy, and we deploy the safe one.

### OQ3 — modify `Settled` vs additive `FeeCharged` → **Modify `Settled` (add `fee`, `amount`→net).**

**Decision:** Modify the existing `Settled` event to `Settled(id, outcome, recipient,
amount /*=net*/, fee)`. Do **not** add a separate `FeeCharged` event.

**Rationale (integration call, my area per the work-map):**
1. **One ABI bump, atomically, with the audited change** (D-TL5): `abi.ts` is regenerated
   from the Foundry artifact in the same change that lands fee + custom errors, before the
   Sepolia broadcast. We pay the decode-update cost exactly once.
2. **At `feeBps=0` (all of P1) `Settled.fee == 0` and `amount == principal`** — byte-for-
   byte the current values. So the "breaking" change is invisible until a fee is actually
   switched on at P3. The resolver/indexer reads truthful numbers at every rate.
3. **An additive `FeeCharged` is *more* total surface, not less:** consumers would have to
   join two events to learn the net paid, and `Settled.amount` would silently mean
   "principal" in some mental models and "net" in others. One event with explicit `fee`
   and net `amount` is less ambiguous for an LLM-adjacent codebase where we re-read events.
4. **Cost is contained:** the only consumer today is `resolver/src/abi.ts` (D-TL5:
   generated, never hand-edited). Resolver-engineer must confirm nothing asserts
   `Settled.amount == bounty.amount` (contract-engineer flagged this); my read is the
   settler keys off `VerdictProposed`/`Challenged`, not `Settled`, so the blast radius is
   the ABI decode only.

> If resolver-engineer surfaces a concrete external indexer that can't tolerate the field
> change, we revisit — but there is none in-repo, so modify-in-place is the call.

### OQ6 — add a funder-side `hash-content.ts` CLI to P2 scope → **YES, in P2 scope.**

**Decision:** Add a small CLI (resolver-engineer proposed `resolver/scripts/hash-content.ts`,
~30 lines) to **P2 scope**. It imports the *same* canonical serializer the resolver uses
and emits `specHash`/`prHash` (+ the pointer-file JSON stub) from a GitHub issue/PR.

**Rationale:**
1. **It's on the P2 critical path, not gold-plating.** The whole P2 win condition is
   "judge a live PR by URL," which requires `keccak256(spec)/keccak256(PR)` to reproduce
   byte-for-byte on **both** sides (funder-at-create, resolver-at-judge). Without a shared
   tool, the funder hand-rolls the hash and `withHashVerification` fails on the first real
   bounty — the gate is unreachable. Resolver-engineer correctly calls it "blocks the P2
   gate."
2. **It enforces D-TL2/D-RE2 mechanically.** A single CLI that *is* the canonical
   serializer is the cheapest way to guarantee create-side and judge-side agree. This is
   exactly why I want the serializer extracted to its own module (see below) — so both the
   CLI and `github.ts` import one source of truth, not two copies that drift.
3. **It is not the frontend.** The one-rule guard (don't build the decentralized/UI version
   early) is not triggered: this is a dev-facing 30-line script, not a funder web app. It
   stays a CLI; no UI, no DB, no IPFS.

**Integration directive (resolves resolver-engineer's "where does `canonicalPrText` live"
dependency on me):** Extract the canonical serializer to a dedicated
**`resolver/src/canonical.ts`** module (versioned, chain-free, no octokit import), built
during **P1**. Both `github.ts` (P2) and `hash-content.ts` (P2) import from it. This is the
de-risking I flagged in R1 — `canonical.ts` lands first and standalone, `github.ts` consumes
it. Overrides resolver-engineer's D5 ("export `canonicalPrText` from `github.ts`"): the
serializer must **not** live in the octokit-coupled file, so the CLI can hash without
pulling the GitHub client. Same function, better home.

---

## Sequence / integration updates

The R1 spine **holds**. Confirmed sequence:

```
P0:  L1 spotlighting (delimiters + rubric)  →  eval set (clear-cut + injection, both dirs)
     →  CI eval-gate (paths-filter + skip-job, validated on a real PR)  →  GATE GREEN
P1:  custom-errors refactor (revert-neutral)  →  fee switch (PULL leg) + setFee + cap
     →  invariant re-run @ feeBps>0 w/ +ΣfeeOwed formula  →  security sign-off
     →  Base Sepolia deploy (fee-INERT)  →  settler.ts (own gas key) + canonical.ts
     →  live hands-off loop proven
P2:  github.ts (imports canonical.ts)  →  hash-content.ts CLI  →  judge a live PR by URL
P3 (not now): fee activation gate · Chainlink Automation keeper · timelock owner · IPFS
```

**D-DO2 (Gelato EOL → Chainlink) — confirmed, with one correction to propagate.**
Gelato Web3 Functions EOL'd 2026-03-31; the P3 keeper upgrade is **Chainlink Automation
time-based upkeep** on Base Sepolia (no contract change for time-based mode; redundant with
the self-hosted bot, which is idempotent by contract). This is a **P3** concern and does
**not** touch the P1 self-hosted `setInterval` path, so **the build sequence is unaffected.**
- **Action item for resolver-engineer (R3):** your R1 still names Gelato as the P3 upgrade
  ("Gelato Web3 Functions is the P3 upgrade path" in the keeper section, and the OQ4-area
  fallback). **D-DO2 supersedes that** — strike Gelato, the P3 path is Chainlink. Also drop
  the "Why not Chainlink Automation?" rejection rationale; it was premised on a P1 framing,
  and Chainlink is now the agreed P3 target. No P1 code changes.

**OQ7 (CI skip-job + required check) — confirmed as a gating risk; do NOT enable branch
protection blind.** devops's D-DO1 is "proposed (test skip-job first)" and OQ2/OQ7 both
flag that GitHub blocks merges when a required check is **skipped** (not **passed**). The
pass-through job must report **`success`**, not `skipped`, or every unrelated PR is
permanently un-mergeable.
- **Directive:** the order is **(1) build the eval-gate + skip-job, (2) validate on a
  throwaway real PR that an unrelated change auto-passes the required check, THEN (3) turn
  on branch protection.** Branch protection is the *last* step, never enabled before the
  skip-job is proven green on a real PR. devops owns this; I'm sequencing it as the final
  P0 action, after the gate exists. This keeps D-TL4 ("`ci-pass` aggregate required check")
  safe to land.
- Also fold in devops OQ1: confirm the judge runs at **`temperature: 0`** before scoring the
  gate, so the gate isn't flaky across reruns (eval-engineer to verify). A flaky gate is as
  bad as no gate.

---

## Items for the user

These need a human call or a human action — they are not resolvable inside the agent team:

1. **Fee design is now PULL (C1 resolution).** This is the one place I overrode the
   contract-engineer in favour of security. It adds `feeOwed` + `withdrawFees()` and changes
   the invariant formula (`+ Σ feeOwed`). No behaviour change at `feeBps=0`. Flagging because
   it's a money-core design decision the user may want to bless. **Recommended: accept.**
2. **Treasury signer identities.** devops needs **three Base Sepolia EOAs** for the 2-of-3
   Safe (`feeRecipient`). Only needed before fee activation (P3), but the user must decide
   who holds the keys. Not on the P1 critical path.
3. **Secrets the user must provision** (testnet-only, never committed): `ANTHROPIC_API_KEY`
   (repo secret, for the CI gate), `KEEPER_PRIVATE_KEY` (new — gas-only EOA, distinct from
   `RESOLVER_PRIVATE_KEY`), `BASESCAN_API_KEY` / Etherscan-v2 key, an Alchemy Base-Sepolia
   RPC URL for CI fork tests, and (P2) a fine-grained GitHub PAT (`issues:read`,
   `pull_requests:read`, `contents:read`) with an **explicit repo allowlist** (SEC-B3).
4. **Branch-protection toggle is a one-way-ish GitHub setting** — the user (repo admin) must
   flip the required check **after** the skip-job is validated (OQ7). Agents can prepare it;
   only an admin enables it.
5. **Scope confirmation:** P3 items (fee activation, Chainlink keeper, timelock owner, IPFS
   snapshots, GitHub App auth, on-chain CID pointers) are all parked. The user should confirm
   they agree these stay out of the Next-3 so we don't drift.

---

## Remaining open questions

Carried forward (not blocking the P0/P1 spine; owners noted):

- **OQ1 / OQ5 / OQ3-resolver (body mutability):** issue body and PR body remain editable
  after the on-chain hash is committed; the diff is SHA-pinned but bodies are not. The hash
  commitment makes this **safe** (mismatch → fail loud), but the *failure mode* is a
  liveness/UX issue (a good bounty can't be judged if the funder edits the issue).
  **My call for P2: document the "don't edit after create" constraint** (resolver-engineer
  OQ3 option 1) + have `withHashVerification` fail loudly with a clear message; snapshotting
  bodies into the pointer file or IPFS is **P3**. Confirm resolver-engineer wires the
  mismatch to a loud, non-stranding error (security OQ3).
- **OQ2 (oversized diffs vs context window):** put deterministic truncation in
  `canonical.ts` (not the prompt) with a reproducible truncation marker, so the hash stays
  stable. **P2 if it bites; otherwise P3.** (tech-lead/resolver-engineer.)
- **OQ4 (keeper crash recovery):** for **P1, `startBlock` event-replay is sufficient**
  (with pm2/Docker `restart: always` + UptimeRobot). Disk-persisting the pending queue is
  **P3**. Accepts resolver-engineer D1 (drop-on-fail, recover-on-restart) as adequate for
  testnet. (resolver ↔ devops — I'm calling it: replay is enough for P1.)
- **OQ5-resolver (`Challenged` untracking):** for **P1, accept the spurious `settle()`
  revert** (harmless, costs a little gas); subscribe to `Challenged` to `untrack()` at
  **P2**. Same applies to the `resolveDispute → Settled` transition. (resolver D-RE-area.)
- **Monitoring backstop (security OQ4):** a flagged-but-judged-fulfilled verdict needs human
  eyes *within* the challenge window for the challenge mechanism to be a real backstop. For
  P1 this is the UptimeRobot/log path; a proper alerting hook on injection-annotated verdicts
  is a **P2/P3** hardening. Flagging so it isn't forgotten — the challenge window is only a
  backstop if someone watches.
- **`additionalProperties:false` enforcement (security OQ6):** confirm the SDK/model actually
  enforces the verdict tool schema so an injection can't smuggle ignored fields. (llm-verdict-
  engineer / eval-engineer to verify under the injection set.)

All of the above are **post-gate or P2/P3**; none block the P0 eval gate or the P1 contract
sprint, which are clear to proceed under the resolutions above.
