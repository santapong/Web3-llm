# Round 1 — tech-lead proposal (cross-cutting: sequencing, canonical strings, gate, integration)

> Scope = the Next-3 (P0→P1→P2) from `docs/FEATURE_PLAN.md`. My ownership is the
> seams between the silos: build order & dependencies, the GitHub **canonical-string
> protocol**, how the P0 eval gate mechanically blocks P1/P2 in CI, and the
> contract↔resolver↔CI integration. I do not own the eval dataset (eval-engineer),
> the keeper/provider code (resolver-engineer), or the fee/custom-errors contract
> work (contract-engineer) — I own how they fit together and ship in order.

---

## What to build (the cross-cutting pieces / sequencing)

The Next-3 is three already-well-scoped features (each "S/M" per research) plus
**four glue pieces that only the tech-lead can own** because they cross silos:

1. **The P0 gate as a real CI blocker, not a vibe.** A dedicated `eval-gate` job in
   `.github/workflows/ci.yml` whose failure is a *required status check* on `main`.
   The product rule "nothing ships until the judge is proven" has to be enforced by
   branch protection, not by everyone remembering it. Phase gating = job dependency
   graph + branch protection, not human discipline.

2. **The canonical-string protocol** (`resolver/src/canonical.ts`) — the single
   shared, versioned function that turns `(GitHub issue, PR@headSha)` into the exact
   bytes that `keccak256` must reproduce at both bounty-create time and judge time.
   This is the one piece where contract (`specHash`/`prHash` commitment), resolver
   (re-fetch + `withHashVerification`), and a future funder CLI must all agree
   byte-for-byte. It is P2's crux and the highest-risk seam in the whole plan.

3. **A version byte on every committed hash.** Both the spec and PR canonical strings
   get a `vN\n` prefix *inside the hashed bytes*. The contract already commits
   `keccak256(bytes(text))` (see `resolver/src/content.ts` `hashText`), so the version
   rides for free inside the preimage with zero contract change. This lets us evolve
   the serialization later without bricking already-escrowed bounties.

4. **The integration contract between Settler and Resolver (P1).** The keeper
   ([04]) needs `VerdictProposed{id, challengeDeadline}` events and a
   `getPastProposedVerdicts(fromBlock)` replay path. Today `EscrowChain`
   (`resolver/src/chain.ts`) only watches `BountyCreated` and has `settle(id)`. I own
   specifying the one new interface method + the wiring point in `index.ts` so
   resolver-engineer and contract-engineer don't each invent half of it.

Everything else (the harness body, the dataset, `github.ts`, `settler.ts`, the fee
switch, custom errors, Base deploy) is owned by the named specialists; I sequence and
integrate them.

---

## What to use (tech/process choices + why + external citation)

| Area | Choice | Why | Source |
|---|---|---|---|
| Canonical PR/spec serialization | **Versioned, fixed-field, explicit-delimiter string** (NOT free-form concat); pin to PR **head SHA**; raw `vnd.github.diff` verbatim | The reproducibility failure mode is non-determinism (field order, whitespace, pagination, mutable PR after commit). The discipline RFC 8785 (JCS) codifies — *one logical input ⇒ one byte sequence* — is exactly what we need; we apply its **principle** (eliminate every non-deterministic degree of freedom, pin numbers/ordering) to a plaintext string rather than adopting JSON-JCS wholesale, because the judge reads prose+diff, not JSON. | [RFC 8785 JCS](https://www.rfc-editor.org/info/rfc8785/), [JCS guide (Jsonic)](https://jsonic.io/guides/json-canonicalization) |
| Why not full JCS/CBOR | **Plaintext canonical string, JCS as the design rule of thumb** | The hashed artifact must double as the judge's prompt input — it has to stay human/LLM-readable. dCBOR/JCS are the right reference for *what determinism requires* (no incidental encoding choices), but a binary or key-sorted-JSON envelope would force a second "render for the LLM" step and a second failure surface. Borrow the determinism rules, keep the artifact as text. | [Determinism (CBOR book)](https://cborbook.com/part_2/determinism.html), [RFC 8785](https://datatracker.ietf.org/doc/html/rfc8785) |
| Version the preimage | **`v1\n…` prefix inside the hashed bytes** | Content-addressing best practice: identifiers must be *auditably reconstructible*; a schema/version tag inside the hashed payload lets the format evolve without ambiguity over which serializer produced a given hash. Free because the contract already hashes opaque `bytes`. | [JCS/content-addressing best practices (search synthesis)](https://jsonic.io/guides/json-canonicalization) |
| P0 gate mechanics | **`eval-gate` job + a single aggregated `ci-pass` required check**; downstream contract/resolver jobs `needs:` it on `main`/PR | The known monorepo trap is making per-area jobs "required" directly; the robust pattern is a change-detect + an aggregated gate job that is the *only* required check, so a green merge provably means the gate ran. | [Required GitHub Actions jobs in a monorepo (Scheufler)](https://brunoscheufler.com/2022-04-24-required-github-actions-jobs-in-a-monorepo/), [Enforcing required checks on conditional CI jobs (Mixpanel)](https://medium.com/mixpaneleng/enforcing-required-checks-on-conditional-ci-jobs-in-a-github-monorepo-8d4949694340) |
| Hash convention | **Keep `keccak256(utf8Bytes(text))`** (already in `content.ts`) | It already matches Solidity `keccak256(bytes(text))` and `withHashVerification` is already the trust boundary. No reason to change it; the canonical-string work feeds *into* this unchanged function. | (in-repo: `resolver/src/content.ts`) |
| Settler trigger | **viem self-hosted cron in-process** (per [04]) | Zero new deps, `settle()` already on `EscrowChain`, matches P1 testnet scope; Gelato is the documented P3 upgrade. I only own the event/interface seam, not the choice. | [04-settlement-keepers.md] |

---

## How to build (P0→P1→P2 order with dependencies; canonical-string design)

### The build spine (strict order; each arrow is a hard dependency)

```
P0  eval harness + adversarial L1/L4 + 15 real cases
        │  (gate ≥90% clear-cut must be GREEN in CI before any P1/P2 merge)
        ▼
P1  settler ─┐
    Base Sepolia deploy + require→custom errors ─┤→ end-to-end unattended loop
    inert fee switch (feeBps=0, re-run 128k invariants, security sign-off) ─┘
        │  (live hands-off loop proven on testnet)
        ▼
P2  canonical.ts  →  github.ts (GitHubContentProvider)  →  judge a live PR by URL
```

**Why this order, with the non-obvious dependencies called out:**

- **P0 first, and it is a CI gate, not a milestone.** Wire `eval-gate` *before*
  collecting all 15 cases (it can fail loudly on a stub). The job must be a required
  check so a regression in the judge prompt or a model bump that drops accuracy
  *blocks the merge that caused it*. This is the single mechanism that makes the "one
  rule" real.
- **P1 fee switch is gated by the security-reviewer, and that gate is on the
  critical path of the deploy** — the inert fee touches `_payout()`, so the 128k
  invariant suite must be re-run and signed off *before* the Base Sepolia broadcast,
  not after. Build fee + custom errors in the *same* contract change so there is one
  audit, one deploy, one ABI bump.
- **The ABI is the contract→resolver seam and it changes twice.** (a) `require→custom
  errors` changes revert encoding; the resolver's `abi.ts` must be regenerated and any
  error-string assertions in resolver tests updated. (b) the fee adds `feeBps`/
  `feeRecipient` (likely new events/getters). **Decision: `resolver/src/abi.ts` is
  generated from the Foundry build artifact, never hand-edited**, so these two changes
  propagate mechanically. devops-engineer should add a CI check that `abi.ts` is
  in sync with `out/`.
- **P2 depends on P1 only operationally** (no point fetching real GitHub evidence
  before the loop runs live), but `canonical.ts` can be *designed and unit-tested*
  during P1 with no chain — so I recommend writing the canonical-string spec + tests
  early as a parallel low-risk track, then `github.ts` lands it at P2.

### The canonical-string protocol (the design I own)

**Goal:** the funder's tooling (at create time) and the resolver (at judge time)
independently produce identical bytes, so `keccak256` matches and
`withHashVerification` passes. Every non-deterministic degree of freedom must be
pinned. New module `resolver/src/canonical.ts`, exporting two pure functions used by
*both* `github.ts` and the future funder CLI (single source of truth).

**Inputs are pinned, not live:** the pointer committed at create time carries
`{owner, repo, issueNumber, prNumber, prHeadSha}`. The PR diff is always fetched
**by `prHeadSha`** (commit-pinned), never "latest PR state" — a force-push or new
commit after creation must not change the hash. (Mitigates research [02]'s HIGH risk.)

**`canonicalSpec(issueBody: string): string`**
```
verdict-spec/v1
<issue body, raw markdown from application/vnd.github.raw, verbatim>
```
- Line 1 is a literal version sentinel (inside the hashed bytes).
- Issue body is taken verbatim, no trimming/normalization (the funder commits exactly
  what the API returns; both sides use the same media type → same bytes).

**`canonicalPr({number, title, body, headSha, diff}): string`**
```
verdict-pr/v1
repo: <owner>/<repo>
pr: #<number>
head: <full 40-char head SHA>
title: <title>

<pr.body or empty>

----- DIFF (application/vnd.github.diff @ <headSha>) -----
<raw unified diff, verbatim>
```

**Determinism rules (the JCS principle applied to plaintext):**
1. **Fixed field order**, every field on its own labeled line — no map/JSON whose key
   order could drift.
2. **Pin the commit SHA**; fetch the diff by that SHA. The diff for a fixed commit is
   byte-stable and GitHub-cached.
3. **No whitespace normalization, no sorting, no transforms** on body/diff — verbatim
   in, verbatim out. The only bytes we *add* are the fixed scaffold lines, which both
   sides emit identically.
4. **LF newlines only** in the scaffold; never CRLF (a classic cross-platform hash
   break). Document that the funder tool must write LF.
5. **Version sentinel in the preimage** → format can become `v2` later; old bounties
   keep verifying against `v1` because their committed hash encodes which serializer
   was used.

**Integration:** `GitHubContentProvider.fetch()` builds these strings, returns
`{specText, prText}`, and is wrapped by the *existing, unchanged* `withHashVerification`
— which re-hashes and rejects any mismatch. The trust boundary is already correct
(`content.ts`); I am only standardizing what goes into it. An **integration test**
hashes a real fixture issue+PR on the "funder" side and asserts the resolver path
reproduces the identical hash (research [02] §4 MEDIUM risk → closed by this test).

### The P0-gate CI mechanics (the seam I own)

- One job `eval-gate` (resolver working-dir, `ANTHROPIC_API_KEY` secret), runs the
  vitest harness; non-zero exit = fail. Hard-fail if `eval/eval_set.json` is absent
  (never let it silently pass on the example set).
- One aggregated `ci-pass` job that `needs: [forge, resolver-checks, eval-gate]`;
  **`ci-pass` is the only required status check** in branch protection. This is the
  monorepo-correct way to make "the gate ran and was green" a merge precondition
  without fragile per-job required-check config.
- Cost/flake controls (from [01]): gate on PR + `main` only; `temperature: 0` on the
  verdict call; pin the model id in the harness so a model bump can't silently change
  the number.

---

## Decisions I own (candidate decision-log entries)

| # | Decision | Rationale | Status |
|---|---|---|---|
| D-TL1 | **Canonical strings are versioned, fixed-field, commit-SHA-pinned plaintext** built by a shared `resolver/src/canonical.ts`; `keccak256(utf8)` unchanged. | One serializer, both sides; pin every non-deterministic DOF (JCS principle) while keeping the artifact LLM-readable. | proposed |
| D-TL2 | **A `vN\n` version sentinel lives inside the hashed preimage** of both spec and PR. | Lets the serialization evolve without bricking escrowed bounties; free (contract hashes opaque bytes). | proposed |
| D-TL3 | **Diff is always fetched by pinned `prHeadSha`, never "latest PR".** | A force-push/new commit after create must not move the hash; closes [02]'s HIGH determinism risk. | proposed |
| D-TL4 | **P0 is enforced by an aggregated `ci-pass` required check that `needs: eval-gate`**, not by per-job required checks or convention. | Makes "nothing ships until the judge is proven" a mechanical merge precondition; standard monorepo gate pattern. | proposed |
| D-TL5 | **`resolver/src/abi.ts` is generated from the Foundry artifact, never hand-edited; CI checks it's in sync.** | custom-errors + fee both change the ABI in P1; mechanical propagation removes the contract↔resolver drift bug class. | proposed |
| D-TL6 | **Build order is strictly P0→P1→P2; fee switch + custom errors ship as one audited contract change before the Base Sepolia broadcast.** | One audit/one deploy/one ABI bump; security sign-off is on the deploy critical path, not after it. | proposed |
| D-TL7 | **`canonical.ts` + its tests are written during P1 (chain-free), `github.ts` lands it at P2.** | De-risks the hardest seam early without violating phase order (no live GitHub fetch until P2). | proposed |

---

## Dependencies on other agents

- **eval-engineer:** owns the harness body + the 15 real cases + the gate threshold
  number. I need the harness to **exit non-zero below threshold** and to **hard-fail
  if the real `eval_set.json` is missing** so my `ci-pass` gate is meaningful. Confirm
  `temperature:0` + pinned model in the harness.
- **contract-engineer:** I need (a) a `VerdictProposed{id, challengeDeadline}` event
  the Settler can latch onto; (b) `require→custom errors` + fee switch in **one**
  change; (c) confirmation the fee exits `_payout()` atomically so the solvency
  invariant holds. Tell me the final event/getter signatures so I can freeze the ABI
  seam.
- **resolver-engineer:** owns `settler.ts` and `github.ts`. Please consume
  `canonical.ts` (do not re-serialize inline), add the `getPastProposedVerdicts`
  replay path + a `watchVerdictProposed` subscription to `EscrowChain`, and update
  `abi.ts` from the artifact (not by hand) after the contract change.
- **devops-engineer:** wire the `eval-gate` + aggregated `ci-pass` job, set it as the
  sole required check in branch protection, add the `ANTHROPIC_API_KEY` secret, add an
  "abi.ts in sync with out/" CI check, and own the Base Sepolia env (`RESOLVER_RPC_URL`
  + faucet). The deploy must be **after** security sign-off.
- **security-reviewer:** sign-off on the fee-touched `_payout()` + re-run 128k
  invariants is a **blocking** node on the P1 deploy path. Also confirm the canonical
  string can't smuggle an injection past the rubric (couples to adversarial L1/L4).

---

## Open questions / risks

1. **Where does the pointer `{owner,repo,issueNumber,prNumber,prHeadSha}` live?**
   Research [02] proposes a JSON file (P2) vs on-chain/IPFS (P3). For P2 I lean
   JSON-file, but it must be the *committed* source of `prHeadSha` so create-time and
   judge-time agree. Open: do we also commit a pointer hash on-chain so the resolver
   can't be fed a different PR? (leans yes, but may be P3 — flag to contract-engineer.)
2. **Issue/PR-body mutability between create and judge.** We pin the *diff* by SHA,
   but the **issue body and PR title/body are still mutable** on GitHub. If the funder
   edits the issue after committing `specHash`, re-fetch fails the hash check (correct,
   but a UX papercut). Mitigation: document "do not edit the spec issue after funding";
   consider snapshotting body text into the pointer at P3. Risk: MEDIUM.
3. **Large diffs vs context window.** [02] notes `vnd.github.diff` isn't truncated but
   can be huge; the hash is over the full diff, but the *judge* may need truncation —
   and any truncation must be deterministic and **inside** the canonical string or the
   hash breaks. Open: do we cap diff size in `canonical.ts` (deterministic head-N-bytes
   rule) or reject oversized PRs? Needs eval-engineer + llm-verdict input.
4. **Does `require→custom errors` break resolver error-string assertions?** Custom
   errors change revert data; any resolver test asserting on a revert string will fail.
   Flagged so resolver-engineer + contract-engineer coordinate the ABI/test update in
   the same PR.
5. **CI cost/flake of the gate on every PR.** Real Anthropic calls per PR cost money
   and can flake on latency. Mitigation already in [01] (temperature 0, PR+main only,
   per-case timeout). Open: do we allow a `[skip-eval]` escape hatch for docs-only PRs?
   (lean: change-detect so docs-only PRs skip `eval-gate` but `ci-pass` still passes.)

---

### Sources
- [RFC 8785 — JSON Canonicalization Scheme (JCS)](https://www.rfc-editor.org/info/rfc8785/) ·
  [datatracker](https://datatracker.ietf.org/doc/html/rfc8785)
- [JSON Canonicalization guide (Jsonic)](https://jsonic.io/guides/json-canonicalization)
- [Determinism — why consistent encodings matter (CBOR/dCBOR book)](https://cborbook.com/part_2/determinism.html)
- [Required GitHub Actions jobs in a monorepo (Bruno Scheufler)](https://brunoscheufler.com/2022-04-24-required-github-actions-jobs-in-a-monorepo/)
- [Enforcing required checks on conditional CI jobs in a GitHub monorepo (Mixpanel Eng)](https://medium.com/mixpaneleng/enforcing-required-checks-on-conditional-ci-jobs-in-a-github-monorepo-8d4949694340)
- In-repo grounding: `resolver/src/content.ts`, `judge.ts`, `chain.ts`; `docs/research/01,02,04,09,10`.
