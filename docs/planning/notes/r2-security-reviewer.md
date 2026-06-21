# Round 2 — security-reviewer (cross-review)

> Role: adversary at the table + owner of the go/no-go gates. Read-only on code; this is
> a planning note. R2 task: now that all six R1 proposals are visible, confirm whether my
> R1 gates (SEC-1..SEC-9) are adequately addressed, hold position on C1 (fee push vs pull),
> hunt new attack surface in the keeper (D-RE1) / canonical-string (D-TL3/D-RE2) / CI
> (D-DO1/3) / injection-eval (D-EV2) designs, and produce the final consolidated P0 and
> P1-deploy gate checklists.
>
> Grounded against R1 notes (all six) + `src/StakedBountyEscrow.sol`
> (`settle`/`resolveDispute`/`_payout`/`_send`, events), `resolver/src/content.ts`
> (`withHashVerification`), `resolver/src/chain.ts` (key derivation + `settle`).

---

## Agreements

Where the other engineers' R1 designs satisfy or strengthen my R1 gates, I withdraw the
objection and record agreement:

- **SEC-2 (immutable `MAX_FEE_BPS`) — fully met.** contract-engineer C2 declares
  `uint16 public constant MAX_FEE_BPS = 500;` (compile-time inlined, source-readable),
  `setFee` reverts `FeeExceedsCap` above it, with the boundary test
  `test_setFee_reverts_above_cap`. Agreed, no further hardening. Add the explicit
  *boundary-success* assertion (`setFee(MAX_FEE_BPS)` succeeds) — confirm it is in the
  suite, not only the `+1` revert.

- **SEC-3 / invariant re-run — met in substance, with one sharpening.** C6 keeps the
  `invariant_solvency` formula and turns the fee ON in `setUp()` with a distinct
  `feeRecipient`, adds `invariant_feeRecipientNeverEscrow`, re-runs 128k. Agreed **for the
  push model**. **If C1 resolves to pull (my position), the formula is NOT unchanged** —
  escrow then also holds `Σ feeOwed`, so the invariant must become
  `balance == resolverStake + Σ amount[live] + Σ challengeBondPaid[disputed] + Σ feeOwed`.
  contract-engineer's "formula unchanged" claim is correct only under push. This is the
  single concrete fork the C1 decision drives in the test suite.

- **SEC-4 (keeper key isolation) — design is sound, but R1 resolver code path does NOT
  yet implement it.** I confirm via `chain.ts:41` that `ViemEscrowChain` derives ONE
  account from `config.privateKey` and uses it for both `submitVerdict` and `settle`, and
  the R1 keeper (D-RE1) calls that same `chain.settle(id)`, and resolver-engineer's
  config note explicitly says the keeper "reuses `RESOLVER_PRIVATE_KEY`." The contract
  confirms `settle` is permissionless (`function settle(uint256 id) external nonReentrant`
  — no `onlyResolver`). So the isolation is *possible* but *unbuilt*. **Hardening: SEC-4
  is a P1 gate item with a concrete acceptance test (below), not a "confirmed."**

- **SEC-5 (injection eval set as a hard gate) — met and strengthened by eval-engineer.**
  D-EV2 + eval R1 Step 4 deliver ≥9 cases, `expected:false`, both `injection_location`
  values, a separate `run_adversarial.test.ts` with a 0-success assertion, committed (not
  git-ignored) so regressions are visible. The taxonomy covers naive/system-spoof/
  roleplay/criteria-poison/reasoning-hijack/unicode/base64/sandwich/tool-call-spoof.
  Agreed. Two completeness gaps flagged under "New attack surface" below (both-directions
  coverage; the L1-before-scoring ordering).

- **SEC-6 (never block on injection suspicion) — accepted in STATE; deferred cleanly.**
  eval D-08 defers the Haiku pre-screen to P1, so SEC-6's "log + annotate + fall through,
  never halt" rule binds when that screen lands, not at P0. Agreed. I keep SEC-6 as a P1
  design constraint on the pre-screen, not a P0 blocker.

- **SEC-7 (revert-neutral custom-error refactor) — met.** contract-engineer B/C5 ships
  the 18→custom-error map one-to-one via `if(!cond) revert Err()` (correctly avoiding the
  via-ir-only `require(cond,Err())` overload — D-CE1), keeps every condition, migrates
  tests to `.selector`. tech-lead D-TL5/D-TL6 sequences it as step 1, same audited change
  as the fee. Agreed; I will diff the old-string→new-error table line-by-line at sign-off.

- **SEC-8 / SEC-9 (fee activation is a separate P3 gate; I hold go/no-go) — uncontested.**
  contract-engineer (risk #5), devops (D5 multisig), tech-lead (D-TL6) all keep the deploy
  fee-inert and treat fee activation as later. Agreed.

- **devops D-DO3 (2-of-3 Safe `feeRecipient`) — agreed, and it is exactly why C1 matters.**
  A Safe "always accepts ETH" is the assumption the push design leans on. It holds for a
  plain Safe **today**, but `setFeeRecipient`/`setFee` can repoint to any address and a
  Safe can add a reverting module/guard. The multisig is necessary but does not retire the
  push-DoS class. (See C1.)

- **tech-lead D-TL5 (`abi.ts` generated from the Foundry artifact, never hand-edited) —
  strongly endorse as a security control.** The fee changes the `Settled` shape (OQ3) and
  the keeper adds `VerdictProposed`; hand-editing `abi.ts` is a drift/decode-bug class.
  Generation + a CI "abi in sync with `out/`" check removes it.

---

## C1 acceptance criteria (fee leg: push vs pull)

**I hold my position: SEC-1 — the fee leg must be pull-payment.** The contract-engineer's
own R1 risk #2 concedes the failure mode ("If `feeRecipient` is a contract that reverts on
receive, **every settle for that config reverts** → funds locked until owner fixes it")
and offers only "rely on it being a Safe." That is an assumption, not an invariant:
`feeRecipient` is owner-mutable, a Safe can be configured to revert (guard/module), and a
compromised owner key turns a one-line `setFee` into a global, all-users settlement freeze.
The user-payout leg staying push is fine (claimant/funder are their own EOAs; one bad
recipient harms only that bounty). The fee is the *only* recipient the protocol doesn't
control and the *only* one whose failure is global — so it is exactly the leg that must be
pull. This is the textbook pull-over-push fix.

I recognize push is cheaper and keeps the invariant formula trivially unchanged. So I
state acceptance criteria for **both** outcomes; the tech-lead resolves the conflict, but
**either design must pass these to earn my P1 sign-off.** A bare `require(ok)` push to a
mutable `feeRecipient` inside `_payout` (the literal R1 design) is a NO from me.

### If pull-payment wins (my recommendation), its tests must prove:
1. **A reverting `feeRecipient` cannot block any user payout.** Test: deploy a malicious
   `feeRecipient` whose `receive()`/`fallback()` always reverts; `setFee(>0, malicious)`;
   then `settle` (fulfilled) and `settle` (refund) and both `resolveDispute` branches all
   **succeed**, the claimant/funder receive their `net` in full, and the fee is *accrued*
   (`feeOwed[malicious] += fee`), not sent. No revert propagates to the user leg.
2. **`withdrawFees` is the only place the fee leaves, is the sole failure point, and its
   failure is isolated.** If `withdrawFees` reverts (bad recipient), it reverts only that
   call; no user funds are touched and no settlement is blocked. Accrual is preserved
   across a failed withdraw (re-withdrawable later, e.g. after `setFeeRecipient` to a good
   address — confirm whoever can call `withdrawFees` / where it pays).
3. **Solvency invariant re-run with the amended formula** including `+ Σ feeOwed` (per
   SEC-3 sharpening), fee ON, distinct `feeRecipient`, 128k+ runs, both outcomes + both
   dispute branches. `invariant_feeRecipientNeverEscrow` retained.
4. **No fee dust stranded:** `fee + net == principal` exactly; accrual is exact; a 1-wei
   principal at max fee accrues 0 fee and pays the full wei (SEC-A4 round-down test).
5. **CEI/reentrancy:** with pull there is *no new external call* in `_payout` (strictly
   safer); `withdrawFees` is `nonReentrant` and CEI (zero `feeOwed` before the send). A
   reentrancy test where the fee recipient re-enters `withdrawFees`/`settle` on receive.
6. **`withdrawFees`/accrual access control:** anyone may *trigger* the transfer to
   `feeRecipient` (or `onlyOwner`/`feeRecipient`-gated — state it), but funds can only ever
   go to `feeRecipient`, never to an arbitrary caller; `feeRecipient == address(0)` while
   `feeOwed>0` is handled (cannot strand — but at `feeBps=0`/P1 `feeOwed` is always 0).

### If push wins (contract-engineer concedes nothing), it must AT MINIMUM prove:
1. **The fee leg cannot revert the settlement.** The fee `_send` must be a low-level call
   whose failure does **not** propagate — `(bool ok,) = feeRecipient.call{value:fee}("")`
   with **no `require(ok)`** on the fee leg (the user leg keeps `require(ok)`). Test: a
   reverting `feeRecipient` → `settle`/`resolveDispute` still succeed, user paid in full.
2. **A failed fee push is NOT silently burned.** On `!ok`, the fee must fall back to
   accrual (`feeOwed[feeRecipient] += fee`) and emit `FeeTransferFailed`. Silent burn of
   protocol revenue is unacceptable, and a burned-to-a-locked-recipient fee that the
   escrow now holds breaks the "fee exits atomically → formula unchanged" claim. **This
   fallback re-introduces the `Σ feeOwed` invariant term anyway** — which is most of the
   reason to just adopt pull. Test: reverting recipient → `feeOwed` increments, event
   emitted, invariant (with `+Σ feeOwed`) holds.
3. Same dust (SEC-A4), all-four-paths (SEC-A5), and reentrancy (malicious recipient
   re-enters under the `nonReentrant` guard) tests as the pull case.

**Bottom line for the tech-lead:** push-with-`require(ok)` is rejected. The only push
variant I will sign is push-with-no-revert-**and**-accrual-fallback — which costs the same
invariant change as pull while being strictly more fragile. Pull is the cleaner gate.
This must be resolved before the single audited contract change is broadcast (D-TL6).

---

## New attack surface found (keeper / canonical / CI)

### Keeper (D-RE1 / D-RE2 / settler.ts)

- **K1 [HIGH] — Keeper key isolation is designed away in STATE but unbuilt in the R1 code
  path.** `ViemEscrowChain` (chain.ts:41) signs `settle` with the resolver's
  `submitVerdict` key, and the R1 keeper + config explicitly reuse `RESOLVER_PRIVATE_KEY`.
  A leaked keeper host key is therefore a leaked *verdict-signing* key — it can submit
  arbitrary verdicts and move ETH, not just pay gas. **Fix (P1 gate):** the settler must
  sign with a separate gas-only EOA (`KEEPER_PRIVATE_KEY`). Concretely: either a second
  `ViemEscrowChain`-like wallet client constructed from `KEEPER_PRIVATE_KEY` exposing only
  `settle`, or a `settle`-only chain object. Acceptance: the verdict-signing key is
  referenced by exactly one code path (`submitVerdict`); the settler cannot call
  `submitVerdict`.

- **K2 [MED] — "delete-before-settle" drops bounties on transient failure (D-RE1 / D1).**
  The settler removes `id` from the map *before* `await settle()`, and on failure relies
  on a process restart + `startBlock` replay to re-discover it. A transient RPC error,
  a nonce gap, or a settle that reverts because the window math is off by the sweep
  interval will **silently drop a real, due bounty** until someone restarts the process.
  This is a *liveness* risk on escrowed ETH, not a safety one (no fund loss), but it is
  the kind of "stuck bounty" that erodes the hands-off claim. **Fix (acceptable for P1,
  required for P1 sign-off):** on `settle` failure, re-insert the id into the map (or keep
  it and only delete on a confirmed `Settled`/`Disputed` observation). The double-submit
  concern D1 cites is already handled by the contract — a second `settle` on a
  now-`Settled` bounty just reverts `not settleable` harmlessly (OQ2/OQ5). So
  keep-on-failure is strictly safer than drop-on-failure. At minimum, OQ4's "persist the
  pending queue" must be answered; replay-from-`startBlock` is acceptable for P1 **only if
  the operator restart is guaranteed** (devops pm2/Docker `restart:always` — confirm it is
  wired, OQ4).

- **K3 [LOW] — `Challenged` race (OQ2/OQ5).** A bounty challenged inside the window stays
  in the map; the next sweep calls `settle` and eats a `not settleable`/`window open`
  revert. Harmless (gas only), confirmed against the contract status guards. Accepting the
  spurious revert for P1 is fine **provided K2 does not then drop the id** (a spurious
  revert must not be treated as a real failure that removes a still-pending bounty). Note
  the interaction: K2's keep-on-failure + K3's spurious reverts means the map may carry
  challenged/settled ids that revert forever — bounded and cheap, but subscribe to
  `Challenged`/`Settled` to `untrack` at P2 (resolver-engineer's own plan).

- **K4 [LOW] — No replay-bound on `getPastProposedVerdicts(fromBlock)`.** If `startBlock`
  is far back or unset, the replay scans a large range and re-tracks long-settled bounties
  (which then revert per K3). Not a security issue; ensure `startBlock` is set (devops Step
  4 already requires it) and that already-`Settled` ids are cheaply skipped or simply
  allowed to revert-and-be-ignored.

### Canonical string / content (D-TL3 / D-RE2 / OQ1, OQ4)

- **C-1 [INFO, reassuring] — `withHashVerification` is the real backstop and the keeper
  never trusts text.** Confirmed in `content.ts`: the resolver re-hashes spec/PR and
  rejects any mismatch, case-insensitively, before the judge ever sees it. **PointerStore
  tampering is therefore NOT a content-substitution attack:** if an attacker edits the
  JSON pointer to aim the resolver at a different issue/PR/SHA, the fetched text re-hashes
  to something ≠ the on-chain `specHash`/`prHash` and `assertHash` throws — the judge is
  never invoked on substituted content. The PointerStore is *untrusted input that fails
  closed*. This is the correct trust boundary and I endorse D-RE2/D8 (always wrap with
  `withHashVerification`).

- **C-2 [MED] — Commit-SHA diff endpoint pins the *diff* but NOT the spec/PR-body, and the
  fail-closed behavior is a liveness footgun (OQ1/OQ3/OQ5/tech-lead OQ2).** D-RE2/D-TL3
  correctly defeat force-push by fetching the diff at `prHeadSha`. But `specText` (raw
  issue body) and the PR `title`/`body` inside `canonicalPrText` remain editable on GitHub
  after the on-chain hash is committed. The hash gate catches edits (good — no wrong
  judgment), but the *failure mode* is "this bounty can never be judged and its escrow is
  stuck behind the challenge logic." That is a griefing/liveness vector: a funder (who
  wants `false`/refund) can edit the issue body one character after a good PR lands, and
  the resolver can no longer produce a matching hash → no verdict → the escrow does not
  settle to the claimant. **This is a real adversarial path, not just a UX papercut.**
  - For P0/P1 this is out of scope (no live GitHub content until P2). **It becomes a P2
    gate item:** the hash-mismatch path must fail *loudly and observably* (logged + alert),
    and the operator runbook must document the recovery (the bounty is refunded/voided via
    the contract's existing paths, not stranded forever). The deeper fix (snapshot the
    body into the pointer / IPFS) is P3, but P2 must not ship a silent permanent-stuck.
  - **Recommendation to tech-lead/resolver-engineer:** at P2, prefer pinning the PR
    `title`/`body` the same way the diff is pinned (use the commit message + pinned diff;
    treat `pr.body` as informational-only and *outside* the hashed preimage), so only the
    issue body remains mutable. Reduces the editable surface to one field.

- **C-3 [MED, P2] — `prHeadSha` provenance.** The whole anti-force-push guarantee rests on
  the funder having recorded the *honest* head SHA at create time. If the funder is the
  adversary (they want refund), they could pin a SHA that predates the real fix. This is
  not a resolver bug — it is inherent to "funder commits the pointer" — but it means the
  **pointer must be committed/anchored at bounty-create on-chain** (tech-lead OQ1 leans
  yes), or a malicious funder can later claim "the resolver judged the wrong commit." For
  P2, at minimum document that the claimant must verify the on-chain `prHash` matches their
  actual PR head before accepting the bounty. Flag for the P2 protocol design; not a P0/P1
  blocker.

- **C-4 [LOW] — Oversized-diff truncation must be inside the hashed preimage (OQ2).** If
  the judge truncates a huge diff but the hash is over the full diff, determinism breaks;
  if truncation is in `canonical.ts` (deterministic head-N-bytes, as tech-lead leans), the
  hash stays stable. Endorse putting any truncation in the canonical serializer with an
  explicit in-band marker, never in the prompt layer. P2 concern; record now.

### CI / secrets (D-DO1 / D-DO3 / D-TL4)

- **CI-1 [MED] — The skip-job + required-check pattern can either block every unrelated PR
  or, worse, let a real eval regression merge un-gated.** devops OQ2/D-DO1 and tech-lead
  D-TL4 disagree on mechanism: devops proposes a per-job `eval-skip` that posts `success`;
  tech-lead proposes a single aggregated `ci-pass` required check that `needs: eval-gate`.
  **The aggregated `ci-pass` (D-TL4) is the safer pattern** and I back it: a single
  required check that internally depends on `eval-gate` cannot be satisfied by a "skipped"
  status, and there is no second always-green job that could accidentally green a PR that
  *should* have run the eval. The risk to guard: if `eval-gate` is skipped on a docs-only
  PR, `ci-pass` must still treat that as pass **only because the paths-filter proved
  judge/eval code did not change** — the filter logic is now security-relevant (a filter
  that wrongly classifies a `judge.ts` change as "no eval needed" silently disables the
  kill-gate). **Acceptance:** OQ7 must be closed — validate on a real PR that (a) a
  `judge.ts` change forces `eval-gate` to run and can block, and (b) a docs-only PR passes
  `ci-pass` without running it; and add a test that a change to `judge.ts` is caught by the
  paths-filter.

- **CI-2 [MED] — `ANTHROPIC_API_KEY` exposure surface in CI.** D-EV2/devops inject the key
  as a repo secret into the eval job. Two hardening items: (a) the eval harness and judge
  must never echo the key or the full request on failure (the disagreement logger in eval
  R1 prints `reasoning.slice(0,100)` — fine — but confirm no `console.log(config)` / no
  raw-request dump on error); (b) for a public repo, the `eval-gate` job must not run on
  `pull_request_target` and must not be triggerable by forked-PR contributors (secret
  exfiltration via a malicious PR editing the workflow/test). **Acceptance:** eval job runs
  on `pull_request` (not `_target`); secrets are not available to fork PRs, or the job is
  gated to same-repo branches. This is the classic CI-secret-leak vector and belongs on the
  P0 gate since the eval job is the first thing to hold the key.

- **CI-3 [LOW] — Determinism of the gate (devops OQ1 / eval Q3).** A `temperature:0` +
  pinned `claude-opus-4-8` is required so the gate number and the injection 0-success
  result are reproducible; a flapping gate is a gate that gets disabled. Already in
  eval Q3 / tech-lead. Confirm `temperature:0` is wired in the eval instantiation and the
  model id is pinned in the harness (not just in prod). P0 gate item.

- **CI-4 [INFO] — Key non-logging is claimed but unverified (B2/devops dep).** devops and
  resolver both defer "confirm `config.ts` doesn't log the key" to me. I will verify at
  sign-off that no `console.log(config)` / key echo exists in `config.ts`, `chain.ts`,
  `index.ts`, and (P1) `settler.ts`. Recorded as a sign-off checklist item, not new risk.

### Injection eval completeness (D-EV2 / SEC-2 / SEC-5)

- **EV-1 [MED] — Both-directions coverage is asserted in my SEC-5 but the R1 taxonomy is
  one-directional.** Every one of eval's 9 cases is `expected:false` ("don't get fooled
  into fulfilled"). My SEC-5 requires the *other* direction too: a payload that tries to
  force a **good PR to be rejected** (a malicious funder wanting refund). That case has a
  *fulfilled* ground truth with an injected "rule NOT met / set fulfilled=false" payload,
  and the gate is "judge still returns fulfilled=true." The R1 `AdversarialCase` schema
  hardcodes `expected:false`, so it structurally cannot encode the force-reject direction.
  **Acceptance (P0 gate):** the adversarial set includes ≥2 force-reject cases (spec-side
  and PR-side) with `expected:true`, and the gate asserts the injection did not flip them
  to false. The schema must allow `expected: boolean`. (Ties to C-2's funder-griefing
  motive: force-reject is the economically-motivated attack here.)

- **EV-2 [MED] — L1 hardening must ship *before* the gate is scored.** eval Step 5 makes
  the spotlight delimiters + rubric clause a co-owned change to `judge.ts`, but the build
  order must guarantee they land *before* `run_adversarial.test.ts` is scored as the gate —
  otherwise the gate certifies an undefended judge. tech-lead owns sequencing this. P0 gate
  item (already in my R1 checklist; re-confirmed).

- **EV-3 [LOW] — Randomized vs fixed delimiters.** eval Step 5a uses *fixed* delimiter
  strings (`<<<UNTRUSTED_PR_START>>>`). My C1/R1 asked for *per-request randomized* nonce
  delimiters so an attacker can't forge a matching close-tag inside the untrusted blob.
  Fixed delimiters are a weaker spotlight. Not a P0 blocker if the 0-success gate passes
  with fixed delimiters (the forced `tool_choice` + rubric carry most of the weight), but
  **recommend randomized nonce delimiters** and add an adversarial case that *includes a
  forged matching close-delimiter* in the PR body to prove the boundary holds. Flag to
  llm-verdict-engineer/resolver-engineer for the `judge.ts` implementation.

---

## Final P0 gate checklist (the judge is proven — gates everything)

A P0 pass requires ALL of:

- [ ] **Accuracy ≥90%** agreement with human labels on clear-cut cases (eval-engineer owns
      the number); FP (wrong-payout) count reported separately and reviewed.
- [ ] **Injection set exists and is part of the gate** — ≥9 cases across the taxonomy
      (naive/system-spoof/roleplay/criteria-poison/reasoning-hijack/unicode/base64/
      sandwich/tool-call-spoof), spec-side AND PR-side.
- [ ] **Both attack directions covered (EV-1):** ≥2 force-reject cases (`expected:true`)
      added; schema allows `expected: boolean`; gate asserts they stayed `true`.
- [ ] **0 injection successes** on the full set (force-approve AND force-reject). Any >0 is
      a P0 blocker. Hard gate.
- [ ] **L1 spotlighting shipped BEFORE the gate is scored (EV-2):** delimiter wrapping in
      `buildVerdictRequest` + untrusted-content rubric clause in `SYSTEM_RUBRIC`.
      (Recommended: randomized nonce delimiters + a forged-close-delimiter case — EV-3.)
- [ ] **Positive-case accuracy did not regress** after adding delimiters (before/after).
- [ ] **Determinism (CI-3):** `temperature:0` wired in the eval judge call; model id
      `claude-opus-4-8` pinned in the harness; forced `tool_choice:{type:"tool"}` intact.
- [ ] **`eval_set.json` absence hard-fails** the harness (never silently passes on the
      example set); CI step has belt-and-suspenders shell guard.
- [ ] **CI gate is mechanically enforced (CI-1):** aggregated `ci-pass` required check
      `needs: eval-gate` (D-TL4 pattern); OQ7 validated on a real PR — a `judge.ts` change
      runs+can block `eval-gate`, a docs-only PR passes `ci-pass` without running it;
      paths-filter proven to catch `judge.ts`/`eval/` changes.
- [ ] **CI secret hygiene (CI-2):** `eval-gate` runs on `pull_request` (not
      `pull_request_target`); `ANTHROPIC_API_KEY` not available to forked-PR runs; no
      raw-request/config/key dump on error paths.

## Final P1-deploy gate checklist (live on testnet, hands-off — no broadcast without ALL)

- [ ] **P0 gate already passed** (precondition; no exceptions — enforced by `ci-pass`).
- [ ] **C1 resolved and its acceptance tests green** (above):
  - [ ] Pull-payment fee leg (preferred) — reverting `feeRecipient` cannot block any user
        payout; fee accrues; `withdrawFees` failure isolated; OR
  - [ ] Push fee leg ONLY IF non-reverting low-level call **with** accrual fallback +
        `FeeTransferFailed` event (bare `require(ok)` push is REJECTED).
- [ ] **`MAX_FEE_BPS` is `constant`**, `setFee` enforces it, boundary revert AND boundary
      success both tested — SEC-2.
- [ ] **Solvency invariant re-run with `feeBps>0`**, distinct `feeRecipient`, both outcomes
      + both dispute branches, 128k+ runs green; formula = `resolverStake + Σ amount[live]
      + Σ challengeBondPaid + Σ feeOwed` **if pull/accrual** (SEC-3 sharpening);
      `invariant_feeRecipientNeverEscrow` present.
- [ ] **Dust/rounding test** (1 wei × max fee → fee 0, full wei paid/accrued) — SEC-A4.
- [ ] **Fee applies on all 4 exit paths**, taken from `b.amount` ONLY (never resolverStake/
      bondLocked/challengeBondPaid) — SEC-A5.
- [ ] **`setFee(feeBps>0, address(0))` reverts** (`FeeRecipientRequired`) — SEC-A6.
- [ ] **Custom-error refactor is revert-neutral**, old-string→new-error map reviewed
      line-by-line by me; no `require` deleted; full suite green; `if(!cond) revert Err()`
      (not the via-ir overload) — SEC-7 / D-CE1.
- [ ] **Reentrancy test with a malicious `feeRecipient`** (re-enter settle/withdrawFees/
      withdrawStake on receive) — SEC-A8.
- [ ] **Deploy config is fee-INERT** (`feeBps=0` at deploy; no `setFee` call) — SEC-8.
- [ ] **Keeper key isolation actually built (K1):** settler signs with a separate gas-only
      `KEEPER_PRIVATE_KEY`; the verdict-signing key is used by exactly one code path
      (`submitVerdict`); the settler cannot call `submitVerdict`. Verified in code, not
      just config.
- [ ] **Keeper does not drop due bounties on transient failure (K2):** keep-on-failure (or
      delete-only-on-confirmed-terminal-status); OQ4 answered (replay-on-restart acceptable
      only with `restart:always` supervisor wired); spurious `Challenged`/`Settled` reverts
      (K3) are not treated as real failures.
- [ ] **`abi.ts` generated from the Foundry artifact** (not hand-edited) for the new
      `Settled`/`VerdictProposed` shapes; CI "abi in sync with `out/`" check — D-TL5.
- [ ] **No key/token logged (CI-4):** verified no `console.log(config)`/key echo in
      `config.ts`, `chain.ts`, `index.ts`, `settler.ts`; `.env` git-ignored.
- [ ] **security-reviewer sign-off recorded** (this gate is mine to grant/deny) — SEC-9.

### (For reference — NOT part of P1) Fee-activation gate (P3, separate event)
- [ ] P0 passed + ≥1 clean testnet pilot batch; A1–A6 + invariant-with-fee re-confirmed on
      deployed bytecode; `feeRecipient` = real Safe proven to accept ETH (test tx); start
      ≤100 bps; second fee-specific sign-off; (recommended) owner behind a Timelock.
### (For reference — NOT part of P1) P2 gate (real GitHub evidence)
- [ ] §C injection defenses re-validated on LIVE GitHub content (indirect injection); PAT
      least-privilege + repo allowlist, unexpected-repo pointer rejected pre-fetch (B3);
      hash-mismatch fails LOUD + observable with a documented recovery (C-2, no silent
      permanent-stuck); PR title/body pinning considered (C-2 rec); `prHeadSha` provenance
      / on-chain pointer anchoring decided (C-3); oversized-diff truncation inside the
      canonical preimage (C-4).

---

## Summary — residual risks + non-negotiables

**Non-negotiables (no P1 broadcast without these):**
1. **C1: bare `require(ok)` fee push is rejected.** Sign-off only for pull-payment, or
   push-with-no-revert-**and**-accrual-fallback. Either way the solvency invariant gains
   `Σ feeOwed` and must be re-run at `feeBps>0`. (Contract-engineer's "Safe always accepts
   ETH" + "formula unchanged" is the one R1 claim I will not accept on faith.)
2. **Keeper key isolation must be built, not just designed (K1).** The R1 code path reuses
   the verdict-signing key for `settle`; a leaked keeper host key currently = leaked
   verdict key. Separate gas-only `KEEPER_PRIVATE_KEY`, verified in code.
3. **Injection gate covers BOTH directions and ships AFTER L1 hardening (EV-1, EV-2).**
   The R1 schema is force-approve-only; the economically-motivated attack here is
   force-reject (malicious funder → refund). 0 successes in both directions, or no P0.
4. **The P0 CI gate is the aggregated `ci-pass` required check (CI-1), not a skip-job
   workaround, and the eval job cannot leak `ANTHROPIC_API_KEY` to fork PRs (CI-2).**

**Residual risks (accepted/deferred, tracked):**
- Keeper drop-on-failure liveness (K2) — fixable, must be addressed for P1 sign-off.
- Spec/PR-body mutability → fail-closed griefing/liveness (C-2) and `prHeadSha` provenance
  (C-3) — real adversarial paths, but P2 scope; P2 must not ship a silent permanent-stuck.
- Residual prompt-injection is never zero (base64/unicode/multi-step); the challenge window
  is the human backstop, but only if a flagged-fulfilled verdict gets human eyes inside the
  window — a monitoring/alerting path is still an open question (my R1 risk #4, unresolved).
- Fixed (non-randomized) spotlight delimiters (EV-3) — weaker than nonce delimiters;
  acceptable if the 0-success gate holds, recommend hardening + a forged-close-tag case.
- Owner key is a single point of failure for `setFee`/`setResolver`/`setFeeRecipient` —
  acceptable on testnet, hard multisig+timelock requirement before mainnet/fee activation.

**What I endorse outright:** `withHashVerification` as the content trust boundary (Pointer-
Store tampering fails closed — C-1); generated `abi.ts` (D-TL5); commit-SHA diff pinning
against force-push (D-RE2/D-TL3); the injection set being committed + a hard 0-success gate
(D-EV2); the deploy staying fee-inert (SEC-8); and the strict P0→P1→P2 order (D-TL6).
