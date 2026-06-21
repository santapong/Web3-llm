# Round 2 — contract-engineer (cross-review)

Read: merged `STATE.md` (all R1 + Decision Log + OQ/Conflicts), `r1-security-reviewer.md`,
`r1-resolver-engineer.md`, `r1-devops-engineer.md`, and re-read `src/StakedBountyEscrow.sol`
(`_payout` at L286, `_send` at L293, `settle`/`resolveDispute`). Planning only — no `.sol` edits.

---

## Agreements

I accept these without contest; they tighten my R1 and don't change my owned scope:

- **SEC-2** (`MAX_FEE_BPS` is `constant`, enforced on every write, boundary-tested) — already my
  C2/D-CE2-adjacent design. Confirmed: `uint16 public constant MAX_FEE_BPS = 500`, `setFee` reverts
  `FeeExceedsCap()` for `_feeBps > MAX_FEE_BPS`; tests at `MAX_FEE_BPS` (pass) and `+1` (revert).
- **SEC-3** (invariant re-run with `feeBps>0`, both outcomes + both dispute branches, 128k+) — I owned
  this in R1 (C6). The only update is the formula change below (now that I concede pull).
- **SEC-5 / SEC-6** (injection set as hard gate; never block on suspicion) — not my area; no objection.
- **SEC-4** (keeper key ≠ resolver signing key) — not my contract surface; `settle` is already
  permissionless in the contract (L220, no `onlyResolver`), so the contract already *permits* a
  gas-only keeper EOA. Nothing to change contract-side; this is resolver/devops config. Confirmed.
- **SEC-7** (custom-error refactor must be revert-neutral, line-by-line map, no `require` deleted) —
  this is exactly my B-section method (sequence step 1, mechanical, suite stays green). Agreed; my
  R1 mapping table is the line-by-line artifact SEC-7 asks for.
- **SEC-8 / SEC-9** (fee activation is a separate P3 gate; security holds go/no-go) — agreed; matches
  my "deploy inert, second sign-off before `setFee(>0)`."
- **devops D-DO3**: `feeRecipient` = 2-of-3 Safe on Base Sepolia. Good — but note the whole point of
  the pull concession below is that I no longer have to *trust* that the Safe accepts ETH on the
  settlement hot path. The Safe still must accept ETH before fee activation, just not as a liveness
  precondition for every settle.

---

## SEC-1 / C1 resolution: **CONCEDE — adopt pull-payment for the fee leg.**

I concede. The security-reviewer is right and my own R1 already flagged this (R1 open-question #2:
"possible future hardening = pull-payment for fees"; I just scoped it out as v0-future — that was the
wrong call given we're shipping the fee mechanism *now*, even if inert).

**Why the push design is unsafe (steelmanning their case, agreeing):**
- `_send` is `require(ok, "transfer failed")` (L293–296). Putting `_send(feeRecipient, fee)` inside
  `_payout` means a reverting/gas-griefing `feeRecipient` makes **`_payout` revert**, which makes
  **`settle` AND `resolveDispute` revert for every bounty** while that config is live — a global
  fund-LOCK DoS, not just a stuck fee. My R1 mitigation ("rely on it being a Safe") is an *assumption*,
  not an *invariant*; `setFee` can point `feeRecipient` anywhere, and a Safe can be misconfigured
  (reverting module/guard) or upgraded to revert later. A money contract must not have a liveness
  dependency on an address the protocol doesn't fully control.
- The asymmetry that makes the concession cheap: the *user* payout (`net` → claimant/funder) stays
  **push**. Those are the parties the protocol can't make pull (they're arbitrary EOAs/contracts the
  funder chose), and keeping their leg push is byte-for-byte the current behaviour. Only the *fee*
  leg — the one recipient the protocol *does* control and can require to pull — becomes pull. So
  pull-for-fee removes the DoS without changing user-facing UX at all.

I considered the "weaker" SEC-1 alternative (non-reverting low-level fee `call` + fallback accrual on
failure). I **reject** it in favour of full pull: a try/ignore push has two code paths (success path +
accrual-on-failure path) that both need fuzzing and create a "was the fee paid or accrued?" ambiguity
for indexers; pure pull is one path, strictly simpler to prove, and is the industry-standard
(Uniswap/Aave collect-style). Simpler is safer here.

### Revised fee design (pull-payment)

**Storage** (replaces R1's `feeBps`/`feeRecipient` pair with the same pair *plus* an accrual ledger):
```solidity
uint16  public constant MAX_FEE_BPS = 500;     // immutable 5% ceiling (unchanged)
uint16  public feeBps;                          // 0 = OFF (unchanged); packs with feeRecipient
address public feeRecipient;                    // treasury (Safe); pull target
uint256 public feeOwed;                         // NEW: accrued, unwithdrawn protocol fees (liability)
```
`feeOwed` is a single global accumulator (not a `mapping(address=>uint256)`): there is exactly one
`feeRecipient` at a time, so a scalar is sufficient and cheaper. Edge case handled below
(recipient change with a non-zero balance).

**`_payout` — accrue instead of send (no new external call):**
```solidity
function _payout(uint256 id, Bounty storage b, bool outcome) internal {
    address recipient = outcome ? b.claimant : b.funder;
    uint256 principal = b.amount;
    uint256 fee = (feeBps == 0) ? 0 : (principal * feeBps) / 10_000;
    uint256 net = principal - fee;        // fee <= principal (feeBps <= 500); no underflow
    if (fee != 0) feeOwed += fee;         // EFFECT (accrue liability) — NOT an interaction
    _send(recipient, net);                // the ONLY interaction (user payout stays push)
    emit Settled(id, outcome, recipient, net, fee);
}
```
Net effect on the hot path: **the fee leg is now a storage write, not an external call.** A broken
`feeRecipient` can no longer block any settlement. This is strictly safer for CEI/reentrancy too
(SEC-A8): `_payout` now has *one* interaction instead of two, and `feeOwed += fee` is an effect that
happens before the single `_send`.

**New withdrawal function (the pull):**
```solidity
function withdrawFees() external nonReentrant {
    uint256 owed = feeOwed;
    if (owed == 0) revert NoFeesOwed();
    feeOwed = 0;                          // EFFECT first (CEI)
    _send(feeRecipient, owed);            // INTERACTION
    emit FeesWithdrawn(feeRecipient, owed);
}
```
- Permissionless on purpose: anyone can *trigger* the sweep, but funds can only ever go to the
  current `feeRecipient`, so there's no theft surface and a stuck keeper can't strand the fee. (If
  we prefer least-surprise we can gate it `onlyOwner`/`onlyFeeRecipient`; I lean permissionless-to-a-
  fixed-destination, the Aave `collect` shape. Flagging for security to bless either; both are safe.)
- `nonReentrant` + CEI (`feeOwed=0` before send) — a reverting `feeRecipient` now only reverts *its
  own* withdrawal, never a settlement. The DoS blast radius shrinks from "all funds" to "the fee
  recipient can't pull until it's fixed," which is exactly the acceptable failure mode.

**`setFee` (unchanged guards) + recipient-change safety:**
```solidity
function setFee(uint16 _feeBps, address _feeRecipient) external onlyOwner {
    if (_feeBps > MAX_FEE_BPS) revert FeeExceedsCap();
    if (_feeBps != 0 && _feeRecipient == address(0)) revert FeeRecipientRequired();
    // Safety: don't strand already-accrued fees by repointing the destination.
    if (feeOwed != 0 && _feeRecipient != feeRecipient) revert FeesPending(); // sweep first
    feeBps = _feeBps;
    feeRecipient = _feeRecipient;
    emit FeeUpdated(_feeBps, _feeRecipient);
}
```
The `feeOwed != 0 && recipient changing` guard prevents an owner from accidentally redirecting fees
that were accrued *for the previous recipient* — the owner must `withdrawFees()` first. This is a new
check the push model didn't need (push had no resting balance). Cheap and closes a footgun.

**New errors:** `NoFeesOwed()`, `FeesPending()` (in addition to R1's `FeeExceedsCap()`,
`FeeRecipientRequired()`). All declared at contract top per D-CE1 (`if(!cond) revert`).

**New event:** `event FeesWithdrawn(address indexed feeRecipient, uint256 amount);`

**Net delta vs R1 (push):** add `uint256 feeOwed` storage, add `withdrawFees()`, add
`FeesWithdrawn` event, add `NoFeesOwed`/`FeesPending` errors, add the `FeesPending` guard to
`setFee`, and change `_payout`'s `_send(feeRecipient,fee)` → `feeOwed += fee`. Inert behaviour at
`feeBps=0` is unchanged: `fee=0`, nothing accrues, `withdrawFees` reverts `NoFeesOwed` until a fee is
ever charged — byte-for-byte identical to today on the settlement path.

**New tests this adds (on top of R1's fee tests):**
- `test_fee_accrues_not_sent_on_settle` — after settle with fee on, `feeOwed == fee`, escrow balance
  retains exactly `fee` more than the push model would.
- `test_withdrawFees_pays_recipient_and_zeros` — `feeOwed` → 0, recipient balance += owed.
- `test_withdrawFees_reverts_when_zero` → `NoFeesOwed`.
- `test_reverting_feeRecipient_does_NOT_block_settle` — the headline DoS test: `feeRecipient` is a
  contract whose `receive()` reverts; `settle`/`resolveDispute` still succeed and `feeOwed` grows;
  only `withdrawFees()` reverts. (This is the test that proves SEC-1 is closed.)
- `test_setFee_reverts_when_fees_pending_and_recipient_changes` → `FeesPending`.
- `withdrawFees` reentrancy test (malicious recipient re-enters `withdrawFees`/`settle`) — guarded.

---

## OQ3 recommendation: keep `Settled` **additive**, do NOT repurpose `amount`.

OQ3 = "modify the existing `Settled` (add `fee`, make `amount`→net) **vs** keep `Settled` and add a
separate `FeeCharged` event." In R1 I leaned toward modifying `Settled` to 6 args; on cross-review I
**reverse to the additive option**, for three reasons that resolver-engineer's R1 made concrete:

1. **Pull changes the truth of "amount paid."** Under pull, the fee does **not** move during settle —
   it accrues. So redefining `Settled.amount` as "net paid" while the fee sits in `feeOwed` is now
   semantically muddier: at settle time the only ETH that *left* is `net`, but the *fee* leaves later
   via `FeesWithdrawn`. Two separate money-movements → two separate events is the honest encoding.
2. **Additive is non-breaking for `abi.ts`.** resolver-engineer's keeper (R1: D-RE1) and any indexer
   decode `Settled`; D-TL5 says `abi.ts` is generated from the artifact, but a *field reorder/retype*
   on `Settled` silently breaks every consumer that positionally reads `amount`. Keeping `Settled`'s
   4-arg signature identical means the keeper and existing decode paths are untouched by the fee work.
3. **It cleanly separates the two gates.** At P1 (`feeBps=0`) `FeeCharged`/`FeesWithdrawn` simply never
   fire — zero behavioural or ABI change to anything that consumes `Settled`. The fee events only
   appear when the fee is activated at P3, so the resolver doesn't have to handle them until then.

**Concrete recommendation:**
- **Keep `Settled` exactly as today:** `event Settled(uint256 indexed id, bool fulfilled, address indexed paidTo, uint256 amount)` where `amount == net` actually transferred (at `feeBps=0`, `net == principal`, so unchanged).
- **Add** `event FeeCharged(uint256 indexed id, address indexed feeRecipient, uint256 fee);` emitted in
  `_payout` only when `fee != 0`.
- Keep `FeesWithdrawn` (the pull event) separate, as above.

So `Settled.amount` becomes "net paid," but the *signature is unchanged*, so it's not an ABI break —
only a value-semantics note for the (P3) day a fee is live. resolver-engineer: this means **your keeper
and `abi.ts` need no change for P1**; you only add `FeeCharged`/`FeesWithdrawn` to `abi.ts` when fee
activation is scheduled (P3). Please confirm you'd rather consume two additive events than a widened
`Settled` — I believe this is the cheaper path for you and it's my recommendation. (Supersedes my R1
C4, which proposed widening `Settled`.)

---

## Revised invariant accounting

**The formula DOES change now** (this is the one place where conceding pull moves my R1 claim — and
security-reviewer's SEC-3 predicted exactly this).

- **R1 (push) claim:** formula unchanged, because the fee exited atomically in the same call (a
  `Settled` bounty contributed 0 to both sides). **That claim is now void** because the fee no longer
  exits at settle — it *rests in the contract* as `feeOwed` until `withdrawFees`.

- **R1 baseline invariant** (`invariant_solvency`):
  ```
  balance == resolverStake + Σ amount[Open|Proposed|Disputed] + Σ challengeBondPaid[Disputed]
  ```

- **R2 (pull) invariant — add the `feeOwed` liability term:**
  ```
  balance == resolverStake
           + Σ amount[Open|Proposed|Disputed]
           + Σ challengeBondPaid[Disputed]
           + feeOwed                              // NEW: accrued, unwithdrawn protocol fees
  ```
  `feeOwed` is now a tracked liability held by the contract; it must appear on the expected side or the
  invariant will (correctly) flag the contract as holding more ETH than the old formula explains. After
  a `withdrawFees()`, `feeOwed` → 0 and `balance` drops by the same `owed`, so equality is preserved.

- **Why this is still trivially solvent:** every wei is accounted on the right-hand side at all times —
  principal (live bounties), resolver stake, active challenge bonds, and now accrued fees. `fee + net ==
  principal` per settle, with `net` leaving immediately (balance −net) and `fee` moving from the
  `Σ amount[live]` term into the `feeOwed` term (a *reclassification within the contract*, balance
  unchanged by the fee leg at settle). At `withdrawFees`, `feeOwed` and `balance` decrease together. No
  path lets `balance` drop below the sum of liabilities.

- **Invariant test changes (concrete, for the 128k re-run):**
  - `setUp()`: `setFee(100, feeRecipient)` with a dedicated `feeRecipient` distinct from
    `address(escrow)` (as in R1).
  - **Add `feeOwed` to the expected-balance computation** in the invariant handler/ghost accounting
    (this is the formula change above).
  - **Add `withdrawFees()` as a fuzzable handler action** so the suite exercises both accrual and
    sweep under fuzzing (otherwise `feeOwed` only ever grows and the withdraw path is unproven).
  - Keep `invariant_feeRecipientNeverEscrow` (feeRecipient != address(escrow)) from R1.
  - **New invariant `invariant_feeOwedNeverExceedsBalance`:** `feeOwed <= address(escrow).balance` — a
    cheap sanity bound that the accrued-but-unpaid fee never claims more ETH than the contract holds.
  - Run both outcomes (fulfilled/refund) and both dispute branches (upheld/overturned), 128k+ runs,
    capture output for security sign-off. This is the artifact SEC-3 gates on.

So: **C6/D-CE2 is amended** — formula is *not* unchanged under pull; it gains `+ feeOwed`. Everything
else about the re-run (live fee in `setUp`, dedicated recipient, both branches, 128k) stands.

---

## Custom-error + Base-deploy items: confirmed, still stand

- **Custom errors (B / D-CE1):** unchanged and uncontested. SEC-7 *endorses* my method (revert-neutral,
  line-by-line map, no `require` deleted, suite green). My R1 18-error table stands; pull adds 2 more
  (`NoFeesOwed`, `FeesPending`) on top of R1's `FeeExceedsCap`/`FeeRecipientRequired`, all via
  `if(!cond) revert Err()` (the `require(cond,Err())` overload is via-ir-only; repo doesn't enable
  via-ir). No conflict with any other agent. **Sequence still: custom-error refactor as step 1
  (mechanical), fee switch as step 2.**
- **Base Sepolia (C7 / D-CE3):** confirmed against devops R1 with **one reconciliation**. My R1 said
  "zero `foundry.toml` change (alias block optional)"; devops R1 (D-DO-deploy) wants the
  `[rpc_endpoints]` + `[etherscan]` block *added* and uses Etherscan **v2** single-key for Basescan.
  No conflict — devops owns the deploy, so I **defer to devops**: add the alias + etherscan block.
  Contract/bytecode is still zero-change (OP-Stack EVM parity), which is the part I own. Deploy stays
  fee-inert (`FEE_BPS=0`, `FEE_RECIPIENT=address(0)` → no `setFee` call at all), satisfying SEC-8.
  Etherscan-v2 key item stands and matches the tech-choices table (row 10).
- **No constructor change** for fee (configured post-deploy by owner tx) — unchanged from R1; keeps
  deploy bytecode/flow identical and the treasury address off the deploy critical path.

---

## Remaining risks

1. **`withdrawFees` access control — confirm with security.** I lean *permissionless-to-fixed-
   destination* (Aave `collect` shape; anyone triggers, funds only ever reach `feeRecipient`). If
   security prefers `onlyOwner`/`onlyFeeRecipient`, both are safe — flagging for a one-line ruling so
   I don't re-litigate in R3.
2. **`feeOwed` now rests in the contract** — this is a *new resting balance* the push model never had.
   It is fully accounted by the revised invariant, but it does mean the contract's ETH balance is no
   longer "principal + stake + bonds" alone. Anyone reasoning about the contract (security, an indexer,
   a future `sweep`/migration) must include `feeOwed`. Documented in the invariant; flagging so it's
   not a surprise.
3. **Recipient-change footgun** is closed by the `FeesPending` guard, but it means the operational
   runbook gains a step: "to change `feeRecipient` with a non-zero balance, `withdrawFees()` first."
   devops should capture this in the fee-activation runbook (P3).
4. **All of the above is P3-latent.** At P1 `feeBps=0`: `feeOwed` is always 0, `withdrawFees` always
   reverts `NoFeesOwed`, `FeeCharged`/`FeesWithdrawn` never fire, the invariant's `+feeOwed` term is
   always `+0`. So the *deployed P1 contract* behaves identically to a no-fee contract; the pull
   machinery is built+audited but dormant — exactly the "inert switch" posture SEC-8/D-CE3 require.
5. **`uint16 feeBps` + `address feeRecipient` still slot-pack; `uint256 feeOwed` takes its own slot.**
   One extra cold SSTORE on the first fee accrual and on each `withdrawFees`. Negligible, and only paid
   when the fee is live (P3). Noting for completeness.

---

### Decision-log deltas I'm proposing (for tech-lead to merge)

| # | Was | Now (R2) |
|---|---|---|
| D-CE-fee (was C1/SEC-1 conflict) | push `_send(feeRecipient,fee)` in `_payout` | **CONCEDE → pull-payment:** `feeOwed` accrues in `_payout`, `withdrawFees()` sweeps; user payout stays push. **Resolves C1 / SEC-1.** |
| C4 (events) | widen `Settled` to 6 args (`fee`; `amount`→net) | **Additive instead:** `Settled` signature unchanged; add `FeeCharged` + `FeesWithdrawn`. Non-breaking for `abi.ts`. **Resolves OQ3.** |
| C6 / D-CE2 (invariant) | formula **unchanged** | formula **gains `+ feeOwed`**; add `withdrawFees` handler + `invariant_feeOwedNeverExceedsBalance`; re-run 128k with fee on. |
| C5 / D-CE1 (custom errors) | 18+2 errors | unchanged; +2 more (`NoFeesOwed`, `FeesPending`) for the pull path. |
| C7 / D-CE3 (Base) | alias block optional | defer to devops: add `[rpc_endpoints]`+`[etherscan]`; contract/bytecode still zero-change; deploy fee-inert. |
