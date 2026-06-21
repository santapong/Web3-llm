# Round 1 Proposal — resolver-engineer

**Author:** resolver-engineer  
**Date:** 2026-06-21  
**Scope:** P1 settlement keeper (`settler.ts`) + P2 GitHub content provider (`github.ts`) + canonical-string protocol

---

## What to build

### P1 — `resolver/src/settler.ts` (new file, ~120 lines)

A `Settler` class that:

- Maintains a `Map<bigint, bigint>` of `bountyId → challengeDeadline` (unix seconds as `bigint`)
- Exposes `track(id, deadline)` and `untrack(id)` for wiring into event subscriptions
- Runs a `setInterval` sweep loop (default 5 min) calling `chain.settle(id)` for every bounty whose deadline has passed
- Removes each id from the map _before_ the async `settle()` call to prevent double-submission on slow RPCs
- Catches and logs errors per-bounty without stopping the loop (same isolation pattern as `Resolver`)
- Exposes `start(intervalMs?)` and `stop()` for lifecycle management

### P1 — `resolver/src/chain.ts` (extension to `EscrowChain` interface + `ViemEscrowChain`)

Add one method to `EscrowChain` and its implementation:

```typescript
// Interface addition:
getPastProposedVerdicts(fromBlock: bigint): Promise<Array<{ id: bigint; challengeDeadline: bigint }>>;

// ViemEscrowChain implementation:
async getPastProposedVerdicts(fromBlock: bigint) {
  const logs = await this.publicClient.getContractEvents({
    address: this.address,
    abi: escrowAbi,
    eventName: "VerdictProposed",
    fromBlock,
    toBlock: "latest",
  });
  return logs.map((l) => ({
    id: l.args.id!,
    challengeDeadline: BigInt(l.args.challengeDeadline!),
  }));
}
```

Also add a `watchVerdictProposed` subscription method to `EscrowChain`:

```typescript
watchVerdictProposed(onEvent: (e: { id: bigint; challengeDeadline: bigint }) => void): () => void;
```

This parallels `watchBounties()` and lets `index.ts` subscribe to real-time `VerdictProposed` events for the settler without polling.

### P1 — `resolver/src/abi.ts` (extension)

Add the `VerdictProposed` event entry. The contract already emits it:

```typescript
{
  type: "event",
  name: "VerdictProposed",
  inputs: [
    { name: "id", type: "uint256", indexed: true },
    { name: "fulfilled", type: "bool", indexed: false },
    { name: "challengeDeadline", type: "uint64", indexed: false },
    { name: "reasoning", type: "string", indexed: false },
  ],
}
```

Without this, `getContractEvents({ eventName: "VerdictProposed" })` and `watchContractEvent` will not type-check.

### P1 — `resolver/src/index.ts` (wiring)

After `resolver.start()`, add:

```typescript
import { Settler } from "./settler.js";

const settler = new Settler(chain, { log });

// Replay past VerdictProposed events from startBlock so in-flight bounties survive restarts.
if (config.startBlock !== undefined) {
  const past = await chain.getPastProposedVerdicts(config.startBlock);
  for (const { id, challengeDeadline } of past) settler.track(id, challengeDeadline);
}

// Subscribe to future VerdictProposed events.
const unwatchSettler = chain.watchVerdictProposed(({ id, challengeDeadline }) =>
  settler.track(id, challengeDeadline)
);

settler.start(config.settleIntervalMs); // default 5 min

// shutdown:
const shutdown = () => {
  settler.stop();
  unwatchSettler();
  unwatch();
  process.exit(0);
};
```

### P1 — `resolver/src/config.ts` (addition)

Add optional `settleIntervalMs` (default 300_000 = 5 min) loaded from `RESOLVER_SETTLE_INTERVAL_MS`. No other required env vars for the keeper — it reuses `RESOLVER_PRIVATE_KEY` and `RESOLVER_RPC_URL`.

### P2 — `resolver/src/github.ts` (new file, ~160 lines)

A `GitHubContentProvider` class implementing `ContentProvider`:

```typescript
import { Octokit } from "octokit";
import type { ContentProvider, BountyContent } from "./content.js";
import type { Hex } from "viem";

export interface GitHubPointer {
  owner: string;
  repo: string;
  issueNumber: number;
  prNumber: number;
  prHeadSha: string; // pinned at bounty-creation time; locks the diff
}

export type PointerStore = Map<string, GitHubPointer>; // key: lowercase specHash

export class GitHubContentProvider implements ContentProvider {
  private readonly octokit: Octokit;
  constructor(token: string, private readonly pointers: PointerStore) {
    this.octokit = new Octokit({ auth: token });
  }
  async fetch(specHash: Hex, prHash: Hex): Promise<BountyContent> { ... }
  private async fetchSpec(ptr: GitHubPointer): Promise<string> { ... }
  private async fetchPr(ptr: GitHubPointer): Promise<string> { ... }
}
```

Also export:
- `loadPointerStore(path: string): Promise<PointerStore>` — reads a JSON pointer file
- `canonicalPrText(pr: PRMeta, diff: string): string` — the canonical-string function (shared with funder tooling)
- `GitHubPointer` type (for the funder CLI)

### P2 — `resolver/src/config.ts` (additions)

```typescript
githubToken?: string;        // GITHUB_TOKEN env var (fine-grained PAT; P2) or installation token (P3+)
githubPointersFile?: string; // GITHUB_POINTERS_FILE env var — path to pointer JSON
```

`githubToken` is optional: when absent, `index.ts` falls back to `MapContentProvider` (current path; no regression).

### P2 — `content.github.json` (new file, operator-managed)

Schema:
```json
{
  "0xabc123...": {
    "owner": "myorg",
    "repo": "myproject",
    "issueNumber": 47,
    "prNumber": 123,
    "prHeadSha": "a1b2c3d4e5f6..."
  }
}
```

This is the pointer store. It is not committed (git-ignored); operators populate it when creating a bounty. The funder CLI (out of my scope) must produce both this file and the on-chain `specHash`/`prHash` from the same canonical-string functions.

### P2 — `.env.example` (additions)

```
GITHUB_TOKEN=github_pat_...
GITHUB_POINTERS_FILE=./content.github.json
```

### npm dependencies

- **P1:** No new packages. `viem` is already present; `setInterval` is Node built-in.
- **P2:** `npm install octokit` (~100 kB, MIT, ESM-compatible). No other new packages at P2. For P3 GitHub App upgrade: additionally `@octokit/auth-app`.

---

## What to use

### P1 keeper — `setInterval` + viem `watchContractEvent` + `getContractEvents`

| Library | Why | Source |
|---|---|---|
| `setInterval` (Node built-in) | Simplest possible periodic sweep; zero deps; `clearInterval` for clean shutdown | Node.js stdlib |
| `viem publicClient.getContractEvents()` | Replay past `VerdictProposed` events from `startBlock` on restart; full type-safety with ABI | [viem getLogs docs](https://viem.sh/docs/actions/public/getLogs.html), [getContractEvents](https://v1.viem.sh/docs/contract/getContractEvents.html) |
| `viem publicClient.watchContractEvent()` | Real-time `VerdictProposed` subscription; auto-falls back from eth_newFilter to polling on RPCs without filter support | [viem watchContractEvent docs](https://viem.sh/docs/contract/watchContractEvent) |
| `ViemEscrowChain.settle(id)` (existing) | Already implemented at `chain.ts:61`; no new contract call logic needed | Existing codebase |

**Why not Chainlink Automation?** Adds LINK token dependency and registration UI; no benefit over a self-hosted bot when `settle()` is permissionless and P1 is testnet-only. Gelato Web3 Functions is the P3 upgrade path (TypeScript-native, 1Balance gas model, no new token).

**Why not OpenZeppelin Defender?** EOL July 1, 2026. Do not use.

### P2 GitHub provider — `octokit`

| Library | Why | Source |
|---|---|---|
| `octokit` (meta-package) | All-batteries GitHub SDK; typed wrappers for `issues.get`, `pulls.get`, `pulls.listFiles`; `mediaType: { format: "diff" }` on `pulls.get` returns raw unified diff string; MIT, ESM-compatible | [octokit README](https://github.com/octokit/octokit.js/), [PR diff discussion](https://github.com/orgs/community/discussions/24460), [REST pulls API](https://actions-cool.github.io/octokit-rest/api/pulls/) |
| Fine-grained PAT (not OAuth, not classic PAT) | Scoped to specific repos + `Pull requests: read` + `Issues: read`; 5,000 req/hour; no user login flow; correct for headless resolver | [GitHub fine-grained PAT docs](https://github.blog/security/application-security/introducing-fine-grained-personal-access-tokens-for-github/), [permissions docs](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens) |

**PAT permissions required:**
- `Pull requests: Read-only` — for `pulls.get` (metadata + diff)
- `Issues: Read-only` — for `issues.get` (spec body)
- `Contents: Read-only` — the diff endpoint technically requires this in addition to pull_requests; confirmed by GitHub's `X-Accepted-GitHub-Permissions` header behavior

**P3 upgrade path:** Replace PAT with `@octokit/auth-app` (installation tokens; auto-refresh; 5,000–15,000 req/hour per installation; no user login flow; correct for multi-tenant hosted judge).

---

## How to build

### Keeper (P1) — step by step

1. **Add `VerdictProposed` to `abi.ts`** (one object in the array). This unblocks type-safe event queries. Verify the ABI matches the contract: `uint64 challengeDeadline`, not `uint256`.

2. **Add `getPastProposedVerdicts(fromBlock)` and `watchVerdictProposed(onEvent)` to `EscrowChain` interface and `ViemEscrowChain`** in `chain.ts`. Mirror the pattern of `getPastBounties` / `watchBounties` exactly.

3. **Write `settler.ts`:**
   - Constructor takes `(chain: EscrowChain, opts?: { log?: Logger })`
   - `track(id, deadline)` sets `pending.set(id, deadline)` and logs at info level
   - `untrack(id)` deletes from `pending` (used if a `Challenged` or `Settled` event is observed — see open questions)
   - `sweep()` (private async): iterates `pending`, finds `nowSec > deadline`, deletes before calling `chain.settle()` to prevent double-call, catches per-bounty errors without propagating
   - `start(intervalMs = 300_000)` calls `setInterval(() => void this.sweep(), intervalMs)`
   - `stop()` calls `clearInterval`

4. **Wire into `index.ts`:** instantiate `Settler` after `chain`, replay past verdicts, subscribe to new ones, call `settler.start()`, extend shutdown to `settler.stop()` + `unwatchSettler()`.

5. **Add `settleIntervalMs` to `config.ts`** from `RESOLVER_SETTLE_INTERVAL_MS` env var with `parseInt` and a 300_000 default.

6. **Unit tests** (new file `resolver/src/settler.test.ts`):
   - Fake `EscrowChain` that records `settle(id)` calls
   - Test: `track()` + `sweep()` after deadline calls `settle` exactly once
   - Test: `sweep()` before deadline does NOT call `settle`
   - Test: error in `settle()` doesn't propagate / doesn't double-call
   - Test: `stop()` prevents further sweeps

### GitHub provider (P2) — step by step

1. **Install `octokit`:** `npm install octokit`

2. **Write `resolver/src/github.ts`** with the structure above. Key implementation details:
   - `fetchSpec(ptr)`: `octokit.rest.issues.get({ owner, repo, issue_number: ptr.issueNumber })` — return `data.body ?? ""`
   - `fetchPr(ptr)`: two calls — (a) `octokit.rest.pulls.get(...)` for title + body; (b) same endpoint with `mediaType: { format: "diff" }` cast as `unknown as string` (TypeScript types don't reflect diff format; this is the standard workaround per the community discussion) — then assemble canonical string
   - Both methods should use the `prHeadSha` pin (see canonical-string protocol below)

3. **Export `canonicalPrText()`** as a pure function — this is the most critical piece for hash reproducibility. It must be called identically by both the funder tooling and the resolver. See canonical-string protocol below.

4. **Write `loadPointerStore(path)`** — reads JSON, validates schema, returns `Map<string, GitHubPointer>`.

5. **Add config fields and `.env.example` entries** (see above).

6. **Wire into `index.ts`**: if `config.githubToken` and `config.githubPointersFile` are set, build `withHashVerification(new GitHubContentProvider(token, store))` instead of `MapContentProvider`. Fall back to current path when not set.

7. **Unit tests** (new file `resolver/src/github.test.ts`):
   - Mock Octokit with `vi.mock('octokit')` or a fake `Octokit` class
   - Test `canonicalPrText()` produces identical output when called twice with same inputs
   - Test `loadPointerStore()` with a fixture JSON

8. **Integration test** (manual, not automated): hash a real GitHub issue + PR diff using `canonicalPrText()` / `hashText()` on the funder side; confirm `GitHubContentProvider.fetch()` re-hashes to the same value.

### Canonical-string protocol

This is the contract between the funder CLI and the resolver. Both must call the same functions with the same inputs to produce matching keccak256 hashes.

**`specText` (acceptance criteria, from GitHub issue body):**

```
specText = issue.body  // raw markdown, exactly as returned by issues.get with mediaType: { format: "raw" }
```

No transforms. No trimming. The funder fetches `issue.body` at bounty-creation time; the resolver re-fetches at judgment time. The issue body must not be edited after commitment — this is a social contract between funder and claimant, not enforced on-chain (see open questions).

**`prText` (PR evidence):**

```typescript
export function canonicalPrText(
  prNumber: number,
  prTitle: string,
  prBody: string | null,
  diff: string,
): string {
  return [
    `PR #${prNumber}: ${prTitle}`,
    "",
    prBody ?? "",
    "",
    "--- diff ---",
    diff,
  ].join("\n");
}
```

Fixed field order. No trailing-whitespace stripping. The `diff` string is the raw response from `pulls.get` with `mediaType: { format: "diff" }` — verbatim, no transforms.

**HEAD SHA pinning** (the critical stability guarantee):

The funder must record `prHeadSha` at bounty-creation time (the value of `pr.head.sha` from `pulls.get`). The resolver must re-fetch the diff pinned to that commit:

```typescript
// Fetch diff pinned to the head SHA recorded at creation time — not the current PR head
const { data: diff } = await octokit.request(
  "GET /repos/{owner}/{repo}/commits/{commit_sha}",
  {
    owner: ptr.owner,
    repo: ptr.repo,
    commit_sha: ptr.prHeadSha,
    mediaType: { format: "diff" },
  }
) as unknown as { data: string };
```

Using the commit SHA endpoint (not the PR endpoint) ensures the diff is stable even if the PR author force-pushes or a maintainer adds a merge commit. This is the most important non-obvious implementation detail.

**Why the commit diff endpoint, not the PR diff endpoint for resolution?**

The `GET /repos/{owner}/{repo}/pulls/{pull_number}` endpoint with `application/vnd.github.diff` returns the diff against the current base — which changes if the base branch advances. The `GET /repos/{owner}/{repo}/commits/{sha}` endpoint with the same diff media type returns the diff of exactly that commit's tree against its parent(s). This is the stable, pinned representation.

---

## Decisions I own

| # | Decision | Rationale | Status |
|---|---|---|---|
| D1 | `Settler` removes `id` from the pending map **before** calling `chain.settle()` | Prevents double-call on slow/retrying RPCs; if `settle()` fails, the bounty is dropped from the queue (acceptable: the resolver can be restarted from `startBlock` to re-discover it) | proposed |
| D2 | Settler uses `setInterval` (not a cron library like `node-cron`) | Zero new deps; Node built-in; cron expression parsing is not needed for a fixed 5-min interval; can be changed to `node-cron` later without API changes | proposed |
| D3 | Settler's sweep interval defaults to 5 minutes | Sufficiently frequent for multi-hour/multi-day challenge windows; does not spam RPC with `settle` calls; configurable via env var | proposed |
| D4 | `GitHubContentProvider` uses the **commit SHA endpoint** (not the PR endpoint) to fetch the pinned diff | Ensures diff is stable even after force-push or base-branch advance; the PR endpoint's diff can shift when the base moves | proposed |
| D5 | `canonicalPrText()` is **exported as a pure function from `github.ts`** | Funder CLI must call the same function to produce matching hashes; keeping it in the resolver repo makes it the single source of truth | proposed |
| D6 | **Fine-grained PAT for P2** (not a GitHub App, not a classic PAT) | Minimal blast radius: scoped to specific repos; `Pull requests: read` + `Issues: read` + `Contents: read`; 5,000 req/hour adequate at P2 volumes; GitHub App is the P3 upgrade | proposed |
| D7 | `PointerStore` backed by a **JSON file** at P2 (not on-chain, not IPFS) | Simplest possible; funder writes the file, resolver reads it; zero new infrastructure; on-chain pointer emission is a P3 concern tied to IPFS CID fields on `BountyCreated` (research #03) | proposed |
| D8 | `GitHubContentProvider` is **always wrapped with `withHashVerification`** before injection into `Resolver` | This is the existing trust boundary; GitHub's API is treated as untrusted (like any other content source); hash mismatch → exception → bounty fails gracefully | proposed |

---

## Dependencies on other agents

| Dependency | Need | Owner |
|---|---|---|
| **`VerdictProposed` event ABI shape** | Need to confirm the exact field types: `challengeDeadline` is `uint64` in the contract. The settler reads this field. If contract-engineer changes the event signature (e.g. adds a field), the ABI in `abi.ts` must be updated in sync. | contract-engineer |
| **`BountyCreated` event: no new fields needed for P1** | The settler only watches `VerdictProposed`, not `BountyCreated`. No contract change required for P1 keeper. | (none) |
| **`BountyCreated` event: `specCid`/`prCid` fields for P3** | Research #03 recommends adding IPFS CID fields to `BountyCreated` so the pointer store can be derived from chain state. This is a P3 contract change — NOT needed for P2 (file-based pointer store suffices). When contract-engineer adds these fields, `EscrowChain` and `abi.ts` will need extensions. Flag this now so it's on the contract-engineer's radar. | contract-engineer (P3) |
| **Canonical-string function visibility** | The funder CLI (if built before P3 frontend) must import `canonicalPrText()` from the resolver package, or it must be extracted to a shared utility. The tech-lead should decide whether a `resolver/src/canonical.ts` separate module is better than exporting from `github.ts`. | tech-lead |
| **PAT scope security review** | The `GITHUB_TOKEN` is a credential. Security-reviewer should confirm: (a) it is only read via env var and never logged; (b) the fine-grained PAT minimum permission set is documented in `.env.example`; (c) the PAT cannot be extracted from resolver logs even on error paths. | security-reviewer |
| **Settler key reuse** | The `Settler` uses `RESOLVER_PRIVATE_KEY` (via `ViemEscrowChain`) to call `settle()`. Security-reviewer should confirm there is no access control on `settle()` that would make this fail (confirmed: `settle()` is permissionless — but worth an explicit sign-off in the security review). | security-reviewer |

---

## Open questions / risks

### OQ1: What to do when `settle()` fails after removal from pending?

Current proposal: drop the bounty. Restart from `RESOLVER_START_BLOCK` recovers it. This relies on the operator restarting the resolver (or pm2/Docker doing it automatically). For production, consider persisting the pending queue to disk (a small JSON file) so crashes don't require a `startBlock` replay. Flag for P3.

**Question for tech-lead:** Is crash-recovery-via-replay acceptable for P1 testnet? Or should we persist the pending queue to disk?

### OQ2: `Challenged` and `Settled` events — should Settler listen to them for `untrack()`?

If a bounty is challenged while it's in the settler's pending map, the settler's next sweep will call `settle()` and get a `"not settleable"` revert (because `status == Disputed`, not `Proposed`). This is harmless but wasteful. Subscribing to `Challenged` events to call `settler.untrack(id)` would clean this up.

**Proposal:** For P1, accept the spurious revert (harmless, costs a little gas). For P2, subscribe to `Challenged` events and untrack. This requires adding `Challenged` to `abi.ts` and a `watchChallenged` method to `EscrowChain`.

**Question for contract-engineer:** Are there other state transitions (e.g. `DisputeResolved` → `Settled`) that would cause a spurious `settle()` revert? (Yes: once `resolveDispute` is called, `status == Settled`, so `settle()` would revert with "not settleable". Same analysis applies.)

### OQ3: Issue body mutability between creation and judgment

The canonical-string protocol for `specText` is the raw issue body. If the funder edits the GitHub issue after committing the `specHash` on-chain, the resolver's re-fetch will produce a different hash and `withHashVerification` will throw — the bounty will fail to resolve.

This is a **trust and UX concern**, not a security concern (the hash commitment protects the resolver). Options:
1. Document it in `.env.example` / operator README: "do not edit the issue body after creating the bounty"
2. At P2, store the `specText` snapshot in the pointer file alongside the pointer metadata
3. At P3, use IPFS to store an immutable snapshot

**For P2:** option 1 (document the constraint). Option 2 can be added if it proves painful in testing.

### OQ4: Large diffs and context window

GitHub's diff via `vnd.github.diff` can be large for big PRs. `claude-opus-4-8` has a 200k-token context. A 10 MB diff would overflow it. For P2 this is probably fine (testnet PRs are small). For P3, add a `MAX_DIFF_BYTES` config and truncate with a note in the canonical string.

**Flag for tech-lead / llm-verdict-engineer:** Should the truncation live in `canonicalPrText()` or in the judge prompt? I lean toward `canonicalPrText()` with a clear truncation marker so the hash is stable and the truncation is reproducible.

### OQ5: `prText` hash pinning — PR body vs. commit body

The current canonical form uses `pr.body` (the PR description field from `pulls.get`). This field can be edited by the author after the PR is created. The diff is pinned by `prHeadSha`, but the PR body is not pinned. Should the canonical `prText` omit `pr.body` and use only the commit message + diff?

**Proposal:** Keep `pr.body` for now (it's informative for the judge). Document that editing the PR body after bounty creation will break the hash. The funder tooling should capture and store a snapshot in the pointer file. Flag as a P3 improvement (store PR body snapshot in IPFS CID).

### OQ6: Coordination with `canonicalPrText` in funder tooling

The funder CLI is not in this repo yet (P3 frontend / P2 tooling). Until it exists, the funder must manually compute the keccak256 hash using the same `canonicalPrText()` function. This means the resolver package must be importable by external tooling, or a standalone CLI script must be provided.

**Request to tech-lead:** Add a `resolver/scripts/hash-content.ts` CLI to the P2 work scope so funders can compute `specHash`/`prHash` without writing code. This is ~30 lines and blocks the P2 gate.

---

## Summary of new files and env vars

| File | Status | Notes |
|---|---|---|
| `resolver/src/settler.ts` | New (P1) | ~120 lines |
| `resolver/src/github.ts` | New (P2) | ~160 lines; includes `canonicalPrText()` |
| `content.github.json` | New (P2, operator-managed) | Git-ignored; pointer store |
| `resolver/src/chain.ts` | Modified (P1) | Add `getPastProposedVerdicts`, `watchVerdictProposed` to interface + impl |
| `resolver/src/abi.ts` | Modified (P1) | Add `VerdictProposed` event |
| `resolver/src/config.ts` | Modified (P1+P2) | Add `settleIntervalMs`, `githubToken`, `githubPointersFile` |
| `resolver/src/index.ts` | Modified (P1+P2) | Wire Settler; conditionally wire GitHubContentProvider |

| Env var | Phase | Purpose |
|---|---|---|
| `RESOLVER_SETTLE_INTERVAL_MS` | P1 | Settler sweep interval; default 300000 (5 min) |
| `GITHUB_TOKEN` | P2 | Fine-grained PAT (`github_pat_...`); `Pull requests: read`, `Issues: read`, `Contents: read` |
| `GITHUB_POINTERS_FILE` | P2 | Path to pointer JSON; default undefined (MapContentProvider fallback) |

---

## External citations

- [Octokit PR diff (community discussion)](https://github.com/orgs/community/discussions/24460)
- [Octokit REST pulls API](https://actions-cool.github.io/octokit-rest/api/pulls/)
- [Octokit.js README](https://github.com/octokit/octokit.js/)
- [viem watchContractEvent](https://viem.sh/docs/contract/watchContractEvent)
- [viem getLogs](https://viem.sh/docs/actions/public/getLogs.html)
- [viem getContractEvents (v1)](https://v1.viem.sh/docs/contract/getContractEvents.html)
- [GitHub fine-grained PAT intro (GitHub Blog)](https://github.blog/security/application-security/introducing-fine-grained-personal-access-tokens-for-github/)
- [Permissions required for fine-grained PATs (GitHub Docs)](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)
- [Research #04 — Settlement Keepers](../research/04-settlement-keepers.md)
- [Research #02 — GitHub Integration](../research/02-github-integration.md)
- [Research #03 — Content Storage](../research/03-content-storage.md)
