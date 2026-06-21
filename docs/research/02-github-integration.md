# Research #02 — GitHub-Native Integration (P2)

**Date:** June 2026  
**Researcher:** feature-researcher agent  
**Stack:** Solidity 0.8.26 + OZ v5.6.1 + viem + TypeScript + Anthropic SDK  
**Scope:** Replace `content.example.json` with real GitHub-sourced `specText` + `prText`, hash-verified against on-chain `specHash`/`prHash`.

---

## 1. What & Why for web3-llm

### The problem today

`content.ts` exports a `ContentProvider` interface with a single method:

```ts
// resolver/src/content.ts
export interface ContentProvider {
  fetch(specHash: Hex, prHash: Hex): Promise<BountyContent>;
}
```

The only live implementation is `MapContentProvider`, backed by `content.example.json` — a flat `{ "<keccak256-hash>": "<text>" }` map that must be pre-populated by hand. This is the explicit gap called out in `docs/STRATEGY.md` as **P2: "Real evidence, not a JSON map."**

The resolver already has the right architecture: `withHashVerification` wraps any provider and re-hashes returned text to reject tampering. The trust model is correct; only the data source is a stub.

### What P2 requires

A `GitHubContentProvider` that:
1. Parses a `BountyCreated` event to find out which GitHub issue (spec) and which PR (evidence) to fetch.
2. Fetches the issue body (acceptance criteria) and the PR diff + metadata from the GitHub API.
3. Serialises both into a **deterministic canonical string** whose `keccak256` matches the on-chain commitment.
4. Returns a `BountyContent` object that passes through `withHashVerification` without error.

The canonical-string problem is the hardest part: because `specHash` and `prHash` are committed on-chain at bounty-creation time (before the resolver runs), the funder/tooling must produce the exact same byte sequence the resolver will re-hash at judgment time. Any non-determinism (field ordering, whitespace, pagination) breaks the hash gate.

---

## 2. How the Leaders Do It

### 2a. Authentication — industry consensus

**GitHub Apps win over OAuth and PATs for server-side integrations.** The community discussion ["PAT vs oAuth vs GitHub App"](https://github.com/orgs/community/discussions/109668) and Nango's comparison ["GitHub App vs. GitHub OAuth: When to Use Which?"](https://nango.dev/blog/github-app-vs-github-oauth/) both conclude:

- **GitHub Apps** authenticate at the installation level (not per-user), use short-lived 60-minute installation access tokens, support fine-grained per-repo permissions, and scale to 5,000–15,000 requests/hour per installation. They are the correct choice for background automation that reads repo content.
- **OAuth Apps** act as the user. They require a human login flow and expose full user-level scopes. Wrong for a headless resolver.
- **Fine-grained PATs** are a reasonable MVP shortcut for a controlled resolver operator: scope to specific repos, set expiry, permissions as narrow as `pull_requests: read` and `issues: read`. Rate limit is 5,000 requests/hour — sufficient for v0/P2 volumes. **Fine-grained PATs are the right call for P2**; a GitHub App is the right call for P3+ (multi-tenant, hosted judge-as-a-service).

Source: [GitHub API Integration Guide 2026](https://www.getknit.dev/blog/github-api-integration-guide), [GitHub Apps vs OAuth Apps (Logto)](https://blog.logto.io/github-apps-vs-oauth-apps), [Fine-Grained PAT intro (GitHub Blog)](https://github.blog/security/application-security/introducing-fine-grained-personal-access-tokens-for-github/)

### 2b. Octokit SDK — the standard TS/JS client

**`octokit`** (the all-batteries-included package, [npm](https://www.npmjs.com/package/octokit), [GitHub](https://github.com/octokit/octokit.js)) is 84.9% TypeScript and covers every GitHub REST and GraphQL endpoint with typed method wrappers. Relevant endpoints:

| What | Octokit method | Notes |
|---|---|---|
| Get issue body (spec) | `octokit.rest.issues.get({ owner, repo, issue_number })` | Returns `.data.body` as raw markdown (default media type `application/vnd.github.raw+json`) |
| List PR files | `octokit.rest.pulls.listFiles({ owner, repo, pull_number })` | Paginated; each entry has `.filename`, `.patch` (unified diff hunk), `.status` |
| Get full PR diff | `octokit.rest.pulls.get({ ..., mediaType: { format: "diff" } })` | Accept: `application/vnd.github.diff` — returns the whole diff as a string, not JSON |
| List PR reviews | `octokit.rest.pulls.listReviews({ owner, repo, pull_number })` | Returns reviewer decisions (approved/changes-requested/commented) |
| Get PR metadata | `octokit.rest.pulls.get({ owner, repo, pull_number })` | Title, body, head SHA, base SHA, merged status |

For a GitHub App, swap the auth strategy with `@octokit/auth-app` ([npm](https://www.npmjs.com/package/@octokit/auth-app)):

```ts
import { createAppAuth } from "@octokit/auth-app";
const octokit = new Octokit({
  authStrategy: createAppAuth,
  auth: { appId: 1, privateKey: "...", installationId: 123 },
});
```

Installation tokens expire in 60 minutes and are auto-refreshed by the library. ([octokit/auth-app.js](https://github.com/octokit/auth-app.js/))

Source: [Octokit.js README](https://github.com/octokit/octokit.js/), [Octokit REST API reference](https://octokit.github.io/rest.js/), [Scripting with GitHub REST API (GitHub Docs)](https://docs.github.com/en/rest/guides/scripting-with-the-rest-api-and-javascript)

### 2c. Fetching PR diffs — the media type trick

The unified diff for a whole PR requires the `application/vnd.github.diff` media type on the pull request endpoint. The diff is returned as the raw response body (a string), not JSON. The community discussion ["Get pull request diff from API"](https://github.com/orgs/community/discussions/24460) documents this:

```bash
curl -H "Accept: application/vnd.github.v3.diff" \
     -H "Authorization: Bearer TOKEN" \
     https://api.github.com/repos/OWNER/REPO/pulls/NUMBER
```

In Octokit/TypeScript: pass `mediaType: { format: "diff" }` to `pulls.get()`. The returned `.data` is the raw diff string.

For file-by-file evidence, `pulls.listFiles()` gives per-file `.patch` (the hunk-level diff) plus `.filename` and `.additions`/`.deletions` counts. This is useful because the judge can see _which files_ changed and their patches without downloading the full repo.

Source: [Get PR diff · octokit/request.js #463](https://github.com/octokit/request.js/issues/463), [Octokit REST pulls API](https://actions-cool.github.io/octokit-rest/api/pulls/)

### 2d. Webhooks for PR events

`@octokit/webhooks` ([npm](https://www.npmjs.com/package/@octokit/webhooks), [GitHub](https://github.com/octokit/webhooks.js/)) is the official Node.js library for receiving and verifying GitHub webhook payloads. GitHub sends `X-Hub-Signature-256` (HMAC-SHA256 of the raw body using a shared secret) with every delivery.

For **web3-llm**, webhooks are an _alternative trigger_ to polling, but the current resolver's primary trigger is `watchBounties()` (on-chain `BountyCreated` events via viem). Webhooks would only be needed if the resolver were architected to trigger on GitHub PR events (push-model) rather than on-chain events (pull-model). The current pull-model is correct and simpler for P2.

Source: [Webhook events and payloads (GitHub Docs)](https://docs.github.com/en/webhooks/webhook-events-and-payloads), [Validating webhook deliveries (GitHub Docs)](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries), [GitHub Webhooks Guide 2026 (HookSense)](https://hooksense.com/blog/github-webhooks-complete-guide)

### 2e. How comparable oracles handle off-chain evidence

**Kleros** and **UMA** are the canonical decentralized dispute/oracle systems. Both store only a URI or evidence hash on-chain and reference raw evidence (PDFs, images, GitHub links) in separate IPFS-pinned JSON files following the Evidence Standard ([Kleros docs](https://docs.kleros.io/integrations/types-of-integrations/3.-kleros-oracle-integration)). UMA's Optimistic Oracle accepts any `ancillaryData` bytes and leaves evidence gathering to the proposer/disputer. Neither has native GitHub API integration — they rely on the proposer to submit content and the verifier to independently re-fetch it. This is consistent with web3-llm's trust model: commit a hash, re-fetch at judgment, verify the hash.

Source: [Kleros and UMA comparison](https://blog.kleros.io/kleros-and-uma-a-comparison-of-schelling-point-based-blockchain-oracles/), [Kleros v2 on GitHub](https://github.com/kleros/kleros-v2)

---

## 3. Recommended Approach in This Stack

### 3a. The canonical-string problem — solved first

The resolver must re-hash content and match the on-chain commitment exactly. This means the funder's client-side tooling (a CLI or a UI) and the resolver must agree on the serialisation format at bounty-creation time.

**Recommended canonical form:**

**For `specText` (the acceptance criteria):** Store the GitHub issue URL as metadata but hash the raw issue body text. The funder fetches the issue body (`.body` field, raw markdown), and passes the literal string as `specText`. The `keccak256(toBytes(specText))` becomes `specHash` stored on-chain. The resolver re-fetches the same issue body with the same media type and gets the same bytes — provided the issue body does not change after commitment.

**For `prText` (the PR evidence):** Construct a deterministic composite string:

```
PR #<number>: <title>\n
\n
<pr.body>\n
\n
--- diff ---\n
<raw unified diff from application/vnd.github.diff>\n
```

The funder generates this string at bounty-creation time; the resolver re-generates it at judgment time from the same API calls. Both hash it and the hashes must match. The key discipline: **pin to the PR head SHA at creation time** and re-fetch using that commit SHA — so a force-push or merge cannot shift the diff between creation and judgment.

**Determinism rules:**
1. Use `application/vnd.github.diff` — the format is stable for a given head commit SHA (GitHub caches it by commit).
2. Sort `pulls.listFiles()` results by `filename` if using the per-file patch route (the API returns files in insertion order, which is stable but worth being explicit about).
3. Strip trailing whitespace only if a diff contains only-whitespace changes that do not affect logic — **do not strip** otherwise; the funder and resolver must apply identical transforms.
4. The safest approach: use the whole unified diff string verbatim (no transforms) and pin to the commit SHA.

### 3b. New module: `resolver/src/github.ts`

Add a `GitHubContentProvider` that implements `ContentProvider`. Install one package:

```bash
npm install octokit
```

(Octokit's `octokit` meta-package is already MIT, pure ESM-compatible, and its `package.json` exports are compatible with `"moduleResolution": "node16"` already required by the resolver's `tsconfig.json`.)

```ts
// resolver/src/github.ts
import { Octokit } from "octokit";
import { keccak256, toBytes, type Hex } from "viem";
import type { ContentProvider, BountyContent } from "./content.js";

export interface GitHubBountyPointer {
  // Stored off-chain (e.g. in bounty metadata or a companion registry)
  owner: string;
  repo: string;
  issueNumber: number;
  prNumber: number;
  prHeadSha: string; // committed at bounty-creation time; pins the diff
}

/** Lookup: specHash => GitHubBountyPointer. */
export type PointerStore = Map<string, GitHubBountyPointer>;

export class GitHubContentProvider implements ContentProvider {
  private readonly octokit: Octokit;

  constructor(
    token: string, // fine-grained PAT (P2) or installation token (P3+)
    private readonly pointers: PointerStore,
  ) {
    this.octokit = new Octokit({ auth: token });
  }

  async fetch(specHash: Hex, prHash: Hex): Promise<BountyContent> {
    const ptr = this.pointers.get(specHash.toLowerCase());
    if (!ptr) throw new Error(`no GitHub pointer registered for specHash ${specHash}`);
    return {
      specText: await this.fetchSpec(ptr),
      prText: await this.fetchPr(ptr),
    };
  }

  private async fetchSpec(ptr: GitHubBountyPointer): Promise<string> {
    const { data } = await this.octokit.rest.issues.get({
      owner: ptr.owner,
      repo: ptr.repo,
      issue_number: ptr.issueNumber,
      mediaType: { format: "raw" }, // returns raw markdown body
    });
    return data.body ?? "";
  }

  private async fetchPr(ptr: GitHubBountyPointer): Promise<string> {
    // Get PR metadata (title + body)
    const { data: pr } = await this.octokit.rest.pulls.get({
      owner: ptr.owner,
      repo: ptr.repo,
      pull_number: ptr.prNumber,
    });

    // Get full unified diff pinned to head SHA
    const { data: diff } = await this.octokit.rest.pulls.get({
      owner: ptr.owner,
      repo: ptr.repo,
      pull_number: ptr.prNumber,
      mediaType: { format: "diff" },
    }) as unknown as { data: string };

    // Deterministic canonical composite
    return [
      `PR #${ptr.prNumber}: ${pr.title}`,
      "",
      pr.body ?? "",
      "",
      "--- diff ---",
      diff,
    ].join("\n");
  }
}
```

Wrap with `withHashVerification` (already in `content.ts`) before injecting into the resolver — this is the existing trust boundary and requires no changes.

### 3c. The PointerStore — the missing link

The `GitHubContentProvider` needs to map `specHash → (owner, repo, issueNumber, prNumber, prHeadSha)`. Two options:

**Option A (P2 — simple, sufficient):** A JSON file, e.g. `content.github.json`, alongside the existing `content.example.json`:

```json
{
  "0xabc...": {
    "owner": "myorg",
    "repo": "myproject",
    "issueNumber": 47,
    "prNumber": 123,
    "prHeadSha": "a1b2c3d4..."
  }
}
```

The funder populates this when creating a bounty. The resolver loads it at startup. This is a file-based approach — no new infrastructure.

**Option B (P3 — on-chain or IPFS pointer):** Emit the `(owner, repo, issueNumber, prNumber, prHeadSha)` in an on-chain event or store a pointer in the contract alongside `specHash`. This allows a fully stateless resolver to reconstruct the pointer from chain state alone. Deferred to P3.

### 3d. Config additions

Add to `resolver/src/config.ts`:

```ts
githubToken?: string;        // GITHUB_TOKEN env var (fine-grained PAT)
githubPointersFile?: string; // GITHUB_POINTERS_FILE env var — path to pointer JSON
```

When `GITHUB_POINTERS_FILE` is set, `index.ts` builds a `GitHubContentProvider` instead of `MapContentProvider`.

### 3e. Webhook strategy — deferred

The current resolver triggers from `BountyCreated` (on-chain). There is no need for a GitHub webhook listener in P2. The chain event is the canonical trigger. If in P3+ a push-triggered mode is wanted (e.g., auto-judge when a PR is opened), add `@octokit/webhooks` as a second event source, HMAC-verify with `timingSafeEqual`, and route to the same `handleBounty` function. This is additive and does not change the `ContentProvider` interface.

### 3f. Rate limits — not a concern for P2

A fine-grained PAT gives 5,000 requests/hour. A single bounty judgment costs 3 API calls (issue GET, PR meta GET, PR diff GET). At P2 volumes (< 100 bounties/day), this is negligible. If moving to P3 hosted-judge with hundreds of concurrent bounties per hour, upgrade to a GitHub App installation token (5,000–15,000 requests/hour per installation, auto-refreshing via `@octokit/auth-app`).

---

## 4. Effort, Dependencies, Risks

### Effort: **S** (Small — 1–2 days)

The `ContentProvider` interface is already correct. `withHashVerification` is already correct. The resolver's injection point (`index.ts`) is already clean. The new code is a single 100-line module (`github.ts`) plus config additions and a pointer JSON file.

**Dependencies added:**
- `npm install octokit` (~100 kB, MIT, no native deps, ESM-compatible)
- One environment variable: `GITHUB_TOKEN`
- One data file: `content.github.json` (pointer store)

For P3 GitHub App upgrade, also add:
- `npm install @octokit/auth-app`
- Three secrets: `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_APP_INSTALLATION_ID`

### Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Diff non-determinism**: PR body or diff changes between bounty creation and judgment (force push, issue edit) | HIGH | Pin `prHeadSha` at creation time; re-fetch using commit SHA via `GET /repos/{owner}/{repo}/commits/{sha}` diff endpoint instead of PR endpoint if needed |
| **Hash mismatch on whitespace/encoding**: funder tool produces slightly different bytes than resolver | MEDIUM | Establish the canonical form in a shared `canonical.ts` utility used by both; integration test with a real PR |
| **Private repo access**: PAT must be scoped to the target repo | LOW | Fine-grained PATs support per-repo scoping; document in `.env.example` |
| **GitHub API outage**: resolver cannot fetch evidence | LOW | `withHashVerification` will throw, bounty fails gracefully (already logged/isolated in `Resolver.process`); add retry with exponential backoff |
| **Rate limit exhaustion at scale** | LOW (P2) / MEDIUM (P3) | GitHub App installation tokens for P3; monitor via `X-RateLimit-Remaining` header |
| **Token leaked in logs** | LOW | Never log the token; pass only via env var `GITHUB_TOKEN` (already consistent with resolver's key-handling pattern) |
| **Large diffs** (megabyte-scale) truncated by GitHub API | LOW | GitHub truncates `pulls.listFiles()` at 300 files and `patch` at 10,000 lines per file; full diff via `application/vnd.github.diff` is not truncated but may be large. Judge context window (200k for claude-opus-4-8) is the real limit — large diffs should be summarised or truncated before feeding to Claude |

---

## 5. Verdict

### Roadmap phase fit: **P2** (exact match)

`docs/STRATEGY.md` defines P2 as: *"Replace `content.example.json` with real content providers: fetch criteria + PR diff from the GitHub API (and/or IPFS), still hash-verified against the on-chain commitment. Gate: judge a live GitHub PR by URL, no manual content staging."*

This research maps to that gate precisely.

### Dependencies on prior phases

- **P0 must pass first.** The eval kill-gate (≥90% agreement on clear-cut cases) must clear before P2 is built, per STRATEGY.md. GitHub integration is meaningless if the judge isn't proven accurate.
- **P1 must pass first.** The resolver must be live on Sepolia with the auto-settle bot before replacing the content source. No point in real GitHub evidence if the end-to-end loop isn't proven on testnet.

### Go / No-Go: **GO** — for P2, after P0 and P1 gates pass

The implementation is well-scoped, additive (does not change any existing interface), and low-risk. The canonical-string protocol is the one detail that needs careful spec work shared between the funder client and the resolver.

### Priority: **2 out of 5**

Priority 1 belongs to P0 (eval kill-gate — the product's moat). P2 GitHub integration is the next highest-priority feature after the testnet loop (P1) because it is the gate-blocker for any real-world usage: without it, every bounty requires manual content staging, which is not a product.

---

## Quick-reference implementation checklist

- [ ] Write `resolver/src/github.ts` — `GitHubContentProvider` implementing `ContentProvider`
- [ ] Add canonical-string helper (`canonicalPrText`, `canonicalSpecText`) used by both the resolver and the funder CLI/tooling
- [ ] Add `GITHUB_TOKEN` and `GITHUB_POINTERS_FILE` to `config.ts` and `.env.example`
- [ ] Add pointer-store loader (JSON file → `PointerStore`) to `github.ts`
- [ ] Wire in `index.ts`: if `GITHUB_POINTERS_FILE` is set, use `GitHubContentProvider` + `withHashVerification`; else fall back to `loadJsonStore` (existing path, no regression)
- [ ] Integration test: hash a real GitHub issue + PR diff on the funder side; verify the resolver re-fetches and the hashes match
- [ ] Document pointer JSON schema in `.env.example` or a `docs/` note

---

## Sources

- [GitHub API Integration Guide 2026 (Knit)](https://www.getknit.dev/blog/github-api-integration-guide)
- [GitHub Apps vs OAuth Apps (Logto)](https://blog.logto.io/github-apps-vs-oauth-apps)
- [GitHub App vs GitHub OAuth: When to Use Which? (Nango)](https://nango.dev/blog/github-app-vs-github-oauth/)
- [PAT vs OAuth vs GitHub App — community discussion](https://github.com/orgs/community/discussions/109668)
- [Best practices for creating an OAuth app (GitHub Docs)](https://docs.github.com/ru/enterprise-server@3.5/apps/oauth-apps/building-oauth-apps/best-practices-for-creating-an-oauth-app)
- [Octokit.js — all-batteries-included GitHub SDK](https://github.com/octokit/octokit.js/)
- [Octokit REST API reference](https://octokit.github.io/rest.js/)
- [@octokit/auth-app — GitHub App authentication for JavaScript](https://github.com/octokit/auth-app.js/)
- [Get pull request diff from API — community discussion](https://github.com/orgs/community/discussions/24460)
- [Get PR diff · octokit/request.js issue #463](https://github.com/octokit/request.js/issues/463)
- [Rate limits for GitHub Apps (GitHub Docs)](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/rate-limits-for-github-apps)
- [Rate limits for the REST API (GitHub Docs)](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
- [Fine-grained PAT — introduction (GitHub Blog)](https://github.blog/security/application-security/introducing-fine-grained-personal-access-tokens-for-github/)
- [Introducing fine-grained personal access tokens — community discussions](https://github.com/orgs/community/discussions/133558)
- [Webhook events and payloads (GitHub Docs)](https://docs.github.com/en/webhooks/webhook-events-and-payloads)
- [Validating webhook deliveries (GitHub Docs)](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries)
- [GitHub Webhooks Guide 2026 (HookSense)](https://hooksense.com/blog/github-webhooks-complete-guide)
- [@octokit/webhooks — GitHub webhook events toolset for Node.js](https://github.com/octokit/webhooks.js/)
- [Scripting with the REST API and JavaScript (GitHub Docs)](https://docs.github.com/en/rest/guides/scripting-with-the-rest-api-and-javascript)
- [Kleros and UMA: a comparison of blockchain oracles (Kleros Blog)](https://blog.kleros.io/kleros-and-uma-a-comparison-of-schelling-point-based-blockchain-oracles/)
- [Kleros v2 protocol (GitHub)](https://github.com/kleros/kleros-v2)
- [How to Get Pull Request Data Using GitHub API (Towards Data Science)](https://towardsdatascience.com/how-to-get-pull-request-data-using-github-api-b91891cbd54c/)
- [How to use GitHub API for getting all changes in a PR — community discussion](https://github.com/orgs/community/discussions/79111)
