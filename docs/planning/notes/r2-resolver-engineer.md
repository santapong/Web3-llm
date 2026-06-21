# Round 2 Cross-Review — resolver-engineer

**Author:** resolver-engineer  
**Date:** 2026-06-21  
**Round:** 2 (cross-review; R1 proposals already read from STATE.md + all peer notes)  
**Grounding read:** `resolver/src/chain.ts`, `resolver/src/config.ts`, `resolver/src/abi.ts`,
  STATE.md Decision Log, r1-contract-engineer.md, r1-security-reviewer.md,
  r1-devops-engineer.md, r1-tech-lead.md

---

## Agreements

Items from other agents that the resolver side confirms with no changes needed:

- **D-TL4 (`ci-pass` aggregated gate):** Confirmed. The settler and resolver test suite
  must be part of the `resolver-checks` job that feeds into `ci-pass`. No additional
  wiring needed on the resolver side beyond what R1 already described.

- **D-TL5 (ABI generated from Foundry artifact, never hand-edited):** Confirmed and
  accepted as the authoritative process. My R1 note proposed adding `VerdictProposed`
  to `abi.ts` by hand as a stopgap. With D-TL5 in place, the correct action is:
  contract-engineer merges the P1 contract change first, devops-engineer CI step
  regenerates `abi.ts` from `out/`, and the resolver-engineer consumes it. No hand-edit
  of `abi.ts` at any step — this removes a whole class of drift bugs I had silently
  accepted in R1.

- **D-EV2 (0 injection successes as hard gate):** Confirmed as a gate I respect but do
  not own. The resolver's injection pre-screen (Haiku, log-only, never blocking per
  SEC-4/SEC-6) feeds evidence into that gate but does not decide it.

- **SEC-4 (injection screen must log+annotate, never halt):** Fully confirmed. My R1
  settler notes the same isolation principle (per-bounty error does not stop the loop).
  The pre-screen must follow the same rule: log, annotate the verdict turn, fall
  through. This is wired in `judge.ts`, not `settler.ts`, but I own the settler side's
  analogous principle.

- **D-DO1 (pm2/Docker + UptimeRobot for P1 keeper hosting):** Confirmed. I will expose
  a `/health` HTTP endpoint from `index.ts` (trivial, ~10 lines) so UptimeRobot can
  monitor liveness. This was not in my R1 scope but is a small, clean addition.

- **SEC-5 (no P1 deploy until P0 + key isolation + invariant re-run green):**
  Confirmed as a hard precondition I do not contest.

---

## OQ3 stance — `Settled` event: modify vs additive `FeeCharged`

**Decision: prefer the additive `FeeCharged` event. Keep `Settled` at its current
4-arg signature.**

Rationale from the resolver's perspective:

**Backward-compatibility is the deciding factor.** The keeper's sweep calls
`ViemEscrowChain.settle(id)` and then considers the task done — it does not decode the
`Settled` event on-chain; it just waits for the tx to confirm. The resolver's
`abi.ts` + `chain.ts` do not currently read the `Settled` event at all. However, the
pattern for extending the ABI matters for future indexers and for any off-chain tooling
that might already be watching `Settled`.

Specifically: changing the `Settled` event signature (adding a 6th `fee` arg, renaming
`amount` → `net`) is a **breaking ABI change** for any off-chain listener. Even though
the P1 deploy is the first Sepolia deploy and no production indexer exists yet, the
design principle should match what we would do in production: emit an additive event
rather than mutate an existing one.

**Concrete proposal:**
- Keep `event Settled(uint256 indexed id, bool fulfilled, address indexed recipient,
  uint256 amount)` unchanged (same 4 args, `amount` = what the recipient actually
  received — which equals `principal` at `feeBps=0`; at `feeBps>0` it becomes `net`,
  which is the truthful value and is not a semantic change, just a numeric one).
- Add `event FeeCharged(uint256 indexed id, address indexed feeRecipient, uint256 fee)`
  emitted only when `fee > 0` (i.e., only when `feeBps > 0`). At P1 this event is
  never emitted (inert fee), so the resolver and any indexer never see it and require no
  change.
- The resolver's `abi.ts` gains `FeeCharged` as an additive entry (no removal/mutation
  of existing entries), satisfying D-TL5 regeneration without breaking any consumer of
  `Settled`.

**What this means for the keeper:** zero impact at P1. At P3 when the fee is live, an
indexer that wants to reconcile fees queries `FeeCharged` events separately without
breaking the `Settled` consumer. This is the standard additive-event pattern (contrast:
Uniswap v3 adds `Flash`, `CollectProtocol` events alongside unchanged base events rather
than mutating `Swap`).

**Note to contract-engineer:** I understand the argument for `Settled` gaining the `fee`
field (one event per settlement tells the complete story). The resolver side can
accommodate either design by regenerating `abi.ts`. But from an API-consumer
standpoint, additive is safer. The final call is yours to make — I am stating my
preference and the reasoning, not vetoing.

**Note on `amount` field semantics at `feeBps>0`:** if additive `FeeCharged` is
adopted, `Settled.amount` should be the **net** paid (principal minus fee) even at
`feeBps>0`. This is technically a semantic shift in the field (amount ≠ escrowed
principal when fee > 0), but it is the truthful value and the additive `FeeCharged`
event carries the fee leg. Downstream consumers of `Settled.amount` get "what the
recipient received," which is correct.

---

## OQ4 decision — keeper crash recovery: startBlock replay vs disk-persisted queue

**Decision: `startBlock` event-replay is sufficient for P1. Disk-persisted queue is
deferred to P2/P3.**

Reasoning:

The `VerdictProposed` event is on-chain and permanent. A restart with
`RESOLVER_START_BLOCK` set replays all `VerdictProposed` events since the deploy block
and rebuilds the pending map from scratch. This is reliable as long as:
1. `RESOLVER_START_BLOCK` is set in `.env` (devops-engineer's responsibility; flag in
   the deploy checklist).
2. The RPC node can serve events from that block (fine for Base Sepolia, which does not
   prune event logs at typical chain ages).
3. The replay window is bounded: even replaying 6 months of events for a low-volume
   testnet is fast (hundreds of events at most).

The weakness of replay-only: any bounty whose `challengeDeadline` passed *during* the
downtime window will be discovered by replay but the `settle()` call was missed. On
restart, the sweep will fire within the next interval (up to 5 min) and attempt
`settle()`. At that point `status == Proposed` and `deadline < now` so `settle()`
succeeds — no loss, just a delay equal to the downtime plus up to one sweep interval.

This is acceptable for P1 testnet where challenge windows are ≥24 hours. If the
resolver is down for 24+ hours that is an operational incident, not a recovery edge
case.

**Disk-persisted queue** (a small JSON file written atomically on every `track()`/
`untrack()`) would eliminate even that delay and make recovery instantaneous without
touching the RPC. Mark this as a P2 hardening item: `resolver/src/settler.ts` gains an
optional `persistFile?: string` constructor param; `track`/`untrack` write the JSON
atomically via `fs.writeFileSync` with a tmp-then-rename pattern. For P1 this param is
`undefined` (no-op). This design keeps the P1 code path clean while making the
upgrade path explicit.

**Implementation note on `RESOLVER_START_BLOCK`:** Devops-engineer's deploy checklist
must include recording the deploy block number into `.env` immediately after broadcast.
The `/health` endpoint I am adding should expose `startBlock` in its response so this
is verifiable without reading `.env` directly.

---

## OQ5 decision — `Challenged` untracking: accept spurious reverts in P1

**Decision: accept spurious `settle()` reverts in P1. Do not subscribe to `Challenged`
events in P1.**

Reasoning:

When a bounty is challenged while in the settler's pending map, the next sweep fires
`settle(id)`. The contract checks `status == Proposed` in `settle()` and reverts with
`NotSettleable()` (after the custom-errors refactor). The resolver catches this
per-bounty (the sweep's error handler), logs it, and moves on. The id was removed from
the map before the call (R1 D1 decision), so there is no retry; the id is simply gone
from the queue. This is safe and correct: a challenged bounty goes through the dispute
path, not the settlement path.

Cost: one failed tx per challenged bounty, costing gas on a testnet chain where gas is
free. Risk: none. Complexity: zero.

**The P2 improvement:** subscribe to `Challenged` events to call `settler.untrack(id)`
proactively. This requires:
1. Adding `Challenged` to `abi.ts` (again, generated from artifact, not hand-edited).
2. Adding `watchChallenged(onEvent)` to `EscrowChain` interface + `ViemEscrowChain`.
3. Wiring in `index.ts`.

This is straightforward but adds 3 new touch points; the benefit (avoiding one wasted
gas spend on testnet) does not justify the P1 complexity. Defer to P2.

**Edge case acknowledged:** after `resolveDispute` is called the bounty is `Settled` on
the dispute path, so a lingering id in the pending map would also revert `settle()`.
Same analysis: caught, logged, harmless. Applies equally to P1.

---

## Key-isolation plan — SEC-3 (`config.ts` / `chain.ts`)

SEC-3 (security-reviewer) states: keeper key ≠ verdict-signing key; settle is
permissionless; keeper needs only a gas EOA.

**Concrete plan:**

Currently `config.ts` loads one `privateKey` (`RESOLVER_PRIVATE_KEY`) and
`ViemEscrowChain` uses it for both `submitVerdict` (permissioned) and `settle`
(permissionless). The fix is a two-wallet split:

**`config.ts` additions:**
```typescript
keeperPrivateKey?: Hex; // KEEPER_PRIVATE_KEY env var — optional; falls back to privateKey
```
Loading:
```typescript
const keeperRaw = env.KEEPER_PRIVATE_KEY?.trim();
keeperPrivateKey: keeperRaw && isHex(keeperRaw) && keeperRaw.length === 66
  ? (keeperRaw as Hex)
  : undefined,
```
When `KEEPER_PRIVATE_KEY` is absent the settler falls back to `privateKey` (the
resolver signing key) — this preserves the current single-key behaviour for developers
who have not yet provisioned a second EOA. A log-level warning is emitted on startup
if `keeperPrivateKey` is not set, reminding the operator to separate keys before any
mainnet use.

**`chain.ts` additions:**
```typescript
export interface EscrowChain {
  // existing:
  readonly resolverAddress: Address;
  submitVerdict(...): Promise<Hex>;
  settle(id: bigint): Promise<Hex>;
  getPastBounties(fromBlock: bigint): Promise<BountyCreatedEvent[]>;
  watchBounties(onEvent: (e: BountyCreatedEvent) => void): () => void;
  // new (R1 additions):
  getPastProposedVerdicts(fromBlock: bigint): Promise<...[]>;
  watchVerdictProposed(onEvent: ...) => void): () => void;
}
```
`ViemEscrowChain` gains a second `walletClient` derived from
`config.keeperPrivateKey ?? config.privateKey`:
```typescript
private readonly keeperWalletClient;

// in constructor:
const keeperAccount = privateKeyToAccount(config.keeperPrivateKey ?? config.privateKey);
this.keeperWalletClient = createWalletClient({
  account: keeperAccount,
  transport: http(config.rpcUrl),
});

// settle() uses keeperWalletClient, not walletClient:
async settle(id: bigint): Promise<Hex> {
  return this.keeperWalletClient.writeContract({ ... });
}
```
`submitVerdict` continues to use `this.walletClient` (the resolver signing key).

**`.env.example` addition:**
```
KEEPER_PRIVATE_KEY=<gas-only EOA; needs only testnet ETH for gas; no contract authority>
```

**Security-reviewer confirmation needed:** confirm this split satisfies SEC-3. The
blast radius of a leaked `KEEPER_PRIVATE_KEY` is: one gas EOA drained, spurious
`settle()` calls on bounties (which are permissionless anyway), no verdict authority.

**What does NOT change:** the `EscrowChain` interface is unchanged from a consumer
perspective; `Settler` calls `chain.settle(id)` and never touches keys directly. The
key isolation is entirely inside `ViemEscrowChain`.

---

## Reactions to D-TL3/D-RE2 and D-DO2

### D-TL3 / D-RE2 (diff pinned to `prHeadSha`, commit-SHA endpoint)

Full agreement with both. My R1 proposal (D4/D5 in r1-resolver-engineer.md) already
specified the commit-SHA endpoint (`GET /repos/{owner}/{repo}/commits/{prHeadSha}` with
`mediaType: { format: "diff" }`). D-RE2 and D-TL3 formally ratify this.

**One alignment note with tech-lead's `canonical.ts` proposal:** the tech-lead wants
a shared `resolver/src/canonical.ts` that exports `canonicalSpec()` and `canonicalPr()`
as the single serialization source. My R1 put `canonicalPrText()` inside `github.ts`.
I fully accept the tech-lead's factoring: move the pure functions to `canonical.ts`,
have `github.ts` import them. This is strictly better because:
1. The funder CLI can import `canonical.ts` without pulling in `github.ts`'s Octokit
   dependency.
2. Unit-testing the canonical functions is cleaner against a module with no network
   deps.

**Concrete change to R1 plan:** `github.ts` no longer exports `canonicalPrText()`.
`canonical.ts` is the owner. `github.ts` imports from `canonical.ts`. The tech-lead
owns the `canonical.ts` design (the field format with `verdict-pr/v1` header, LF-only
newlines, etc.) — I implement `github.ts` to consume it.

**Version sentinel (`v1\n` prefix, D-TL2):** Accepted. I will confirm with tech-lead
that the sentinel is a literal line inside the hashed preimage and that `withHashVerification`
hashes the full string including the sentinel. Since `withHashVerification` hashes
`specText` and `prText` verbatim (whatever `ContentProvider.fetch()` returns), the
sentinel is transparent to `content.ts` — no changes needed there.

### D-DO2 (Chainlink Automation for P3 keeper, not Gelato)

Confirmed and accepted. My R1 note still mentioned Gelato as "the P3 upgrade path" —
this was based on pre-EOL research (#04). D-DO2 supersedes it. Gelato Web3 Functions
is dead (EOL 2026-03-31). The P3 path is Chainlink Automation time-based upkeep on
Base Sepolia (registry `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3`).

**Impact on P1 design:** none. The P1 keeper is a self-hosted `setInterval` in-process,
unchanged. The Chainlink upgrade at P3 replaces the hosting concern, not the
`settler.ts` logic (which can continue to exist as a fallback even when Chainlink runs).

**Impact on `settler.ts` design:** none. `settler.ts` is a `setInterval` loop that
calls `chain.settle(id)` — it is independent of the execution mechanism. At P3 the
Chainlink upkeep calls a thin sweep-wrapper contract (devops-engineer's design) while
`settler.ts` can remain as a belt-and-suspenders fallback (idempotent: double-settle
attempts just revert `NotSettleable`, no harm).

---

## Canonical-string protocol confirmation

The tech-lead's `canonical.ts` design (r1-tech-lead.md) is more complete than my R1
proposal. Accepting it in full, with the following confirmations from the resolver side:

1. **`canonicalSpec(issueBody: string): string`** — the `verdict-spec/v1\n` prefix
   followed by the raw issue body verbatim. Both funder CLI and resolver call the same
   function with the same API response. The body must be fetched with `application/
   vnd.github.raw` on both sides (not the default JSON-parsed body in `data.body`).
   I will document this in `github.ts`'s JSDoc.

2. **`canonicalPr({number, title, body, headSha, diff}): string`** — the structured
   `verdict-pr/v1` format with fixed fields. The diff is always fetched from the
   commit-SHA endpoint and passed verbatim. Confirmed.

3. **LF newlines only in scaffold:** the `canonical.ts` implementation must enforce this
   with literal `\n` in template strings (not `os.EOL`). I will add an assertion in
   `canonical.test.ts` that no `\r\n` appears in the scaffold lines.

4. **OQ1 (issue body mutability):** the resolver side acknowledges that if the funder
   edits the issue body after committing `specHash`, `withHashVerification` will throw
   (hash mismatch) and the bounty fails to resolve. The resolver logs the mismatch
   loudly and the bounty stays unresolved — it does not strand ETH (no auto-refund),
   but the resolution cannot proceed. For P2 the fix is documenting "do not edit the
   spec issue after funding" in `.env.example` and in the operator README. For P3, the
   pointer file can carry a `specBodySnapshot` field so the resolver uses the
   committed text rather than re-fetching. I confirm this is not a security issue
   (the commitment protects the judge); it is a UX/liveness concern.

5. **OQ2 (large diffs):** for P2 I will add a `MAX_DIFF_BYTES` config param (default
   500 KB, which is well within the 200k-token context of claude-opus-4-8 at ~3 chars
   per token). When the diff exceeds the limit, `github.ts` truncates it to
   `MAX_DIFF_BYTES` and appends `\n[DIFF TRUNCATED AT ${MAX_DIFF_BYTES} BYTES]` to the
   canonical string. Truncation is deterministic (same bytes → same truncation point),
   so the hash is stable. The funder tooling must apply the same truncation before
   hashing at create time. Flag to llm-verdict-engineer: the truncation marker should
   be mentioned in the rubric so the judge does not penalize an incomplete diff.

---

## Remaining risks

### R1 — Replay window + `startBlock` discipline (P1, medium)

If an operator deploys without setting `RESOLVER_START_BLOCK`, the settler starts with
an empty pending map and misses all in-flight bounties until a `VerdictProposed` is
emitted after startup. This is a silent, hard-to-diagnose issue.

**Mitigation:** `index.ts` should warn loudly (stderr) if `config.startBlock` is
`undefined` at startup, and the `/health` endpoint should expose whether `startBlock`
is set. The deploy checklist (devops-engineer) must record the deploy block number.

### R2 — `KEEPER_PRIVATE_KEY` fallback warning (P1, low)

If `KEEPER_PRIVATE_KEY` is not set, the keeper silently reuses `RESOLVER_PRIVATE_KEY`.
This is safe for P1 testnet but violates SEC-3 in spirit.

**Mitigation:** startup log at `WARN` level: "KEEPER_PRIVATE_KEY not set — settler is
using the resolver signing key; provision a separate gas-only EOA before any mainnet
use." This makes the gap visible without blocking P1 startup.

### R3 — `prHeadSha` pinning and commit-SHA endpoint pagination (P2, low)

The `GET /commits/{sha}` diff endpoint returns the full diff for a commit in a single
response. For merge commits or very large PRs (thousands of files), the response can
exceed GitHub's diff size limit and be truncated silently by GitHub's API. This is
distinct from the `MAX_DIFF_BYTES` truncation above — it is a network-level truncation
with no marker.

**Mitigation:** check the HTTP response for a `Link: rel="next"` header (GitHub
paginates diffs for very large commits). If present, log a warning and use only the
first page. The `MAX_DIFF_BYTES` cap will typically catch this before pagination occurs.

### R4 — Canonical string whitespace: PR body CRLF from GitHub (P2, medium)

GitHub issues and PRs authored on Windows clients may have `\r\n` line endings in the
body field. If the funder fetches with CRLF and the resolver fetches with LF (or vice
versa), the `keccak256` will differ.

**Mitigation:** `canonicalSpec()` and `canonicalPr()` should normalize the
*user-supplied body* to LF before embedding it in the canonical string (just the body;
the diff is verbatim from the API which is always LF). The tech-lead's spec says "no
whitespace normalization" — I am proposing a narrow exception: CRLF→LF normalization
on body fields only, as a platform-portability guarantee, not a content transform. Raise
this with tech-lead for a decision before landing `canonical.ts`.

### R5 — `Settled` event field semantics at `feeBps>0` with additive-event design (P3, low)

If `FeeCharged` is adopted (my OQ3 recommendation), `Settled.amount` means "net paid
to recipient" which equals `principal` at `feeBps=0` and `principal-fee` at `feeBps>0`.
An off-chain consumer summing `Settled.amount` values will get the correct total-payout
number but not the total-escrowed-principal number. This is the right semantic for a
payment event. Document it explicitly in the event NatSpec comment.

---

## Summary of R1 plan changes driven by R2

| Change | Driven by | Impact on R1 plan |
|---|---|---|
| `abi.ts` generated from Foundry artifact, not hand-edited | D-TL5 | Remove hand-edit step; wait for contract-engineer merge + CI regen |
| `canonicalPrText()` moves to `canonical.ts` (tech-lead owns) | D-TL1/D-TL7 | `github.ts` imports from `canonical.ts`; I no longer export it |
| `settler.ts` gets optional `persistFile` param (no-op at P1) | OQ4 decision | Minor API addition; P2 hardening path explicit |
| `chain.ts` gains second `keeperWalletClient` from `KEEPER_PRIVATE_KEY` | SEC-3 | `settle()` uses keeper wallet; `submitVerdict` unaffected |
| `config.ts` gains optional `keeperPrivateKey` field | SEC-3 | `.env.example` gains `KEEPER_PRIVATE_KEY` |
| Startup warning when `startBlock` is undefined | R1 risk | 3-line log addition to `index.ts` |
| `/health` endpoint exposed from `index.ts` | D-DO1 / devops R1 | ~10 lines; exposes `startBlock`, `keeperKeyIsolated` |
| Gelato P3 reference replaced by Chainlink | D-DO2 | R1 note correction; no code impact |
| `Challenged` untracking deferred to P2 | OQ5 decision | No P1 code change needed |
| `FeeCharged` additive event preferred over modifying `Settled` | OQ3 stance | Pending contract-engineer decision |
