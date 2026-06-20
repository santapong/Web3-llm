# #03 — Decentralized Content Storage

**Roadmap phase:** P2
**Research date:** June 2026

---

## 1. What & Why for web3-llm

### The current situation

`BountyEscrow` and `StakedBountyEscrow` store only two `bytes32` fields on-chain:
`specHash` (keccak256 of the acceptance-criteria text) and `prHash` (keccak256 of
the PR diff). The full texts live off-chain. Today that means a flat JSON map loaded
from `RESOLVER_CONTENT_FILE` — literally `content.example.json` — staged manually
by whoever runs the resolver.

The `ContentProvider` interface in `resolver/src/content.ts` is clean and already
designed for substitution. The `withHashVerification` wrapper correctly re-hashes
returned text and rejects anything that does not match the on-chain commitment, so
the integrity story is sound. The only missing piece is **where the text durably
lives** so that the funder, claimant, challenger, and arbiter can each independently
fetch it without going through a centralized server we operate.

### Why this matters for the trust model

The product's value proposition is accountable, tamper-evident AI settlement. If the
spec or PR text only lives on our server, three problems arise:

1. **Censorship / availability:** we can take it down, or our server can go down,
   making it impossible to challenge or verify a verdict.
2. **Trust:** a challenger cannot independently verify the exact text the judge saw
   without trusting us.
3. **Arbitration:** if a dispute goes to a human arbiter, they need the original
   text. A mutable off-chain source undermines that.

Decentralized, content-addressed storage removes the centralized server as a single
point of failure and trust. The `withHashVerification` fence remains the integrity
guarantee regardless of which storage backend is used — the storage layer just needs
to be durable and publicly readable.

### Scope boundary

This is a P2 concern per the roadmap (`docs/STRATEGY.md`). P0 (judge accuracy) and
P1 (live on testnet end-to-end) should prove the core loop before investing in
storage decentralization. P2's kill-gate is: "judge a live GitHub PR by URL, no
manual content staging." Decentralized storage is a complement to, not a
replacement for, direct GitHub API fetching (research area #02). The two work
together: GitHub provides the live text; content storage provides the durable,
hash-verified archive the contract's commitment points to.

---

## 2. How the Leaders Do It

### 2a. IPFS — content addressing

IPFS ([ipfs.tech](https://ipfs.tech)) is a peer-to-peer hypermedia protocol that
uses **content identifiers (CIDs)** instead of location addresses. A CID encodes
the hash of the data and a codec indicating how to decode it. CIDv0 encodes a
multihash of sha2-256; CIDv1 is more flexible (base32-encoded, supports any hash
function specified in the multihash prefix).

Key property: the CID *is* a content commitment. If you fetch a CID and the
content's sha2-256 hash doesn't match the CID, the IPFS node rejects it. This is
similar in spirit to web3-llm's `withHashVerification`, but using sha2-256 rather
than keccak256.

**IPFS implementations in TypeScript (2025-2026):**

- **Helia** ([github.com/ipfs/helia](https://github.com/ipfs/helia)) — the actively
  maintained, lean TypeScript/ESM implementation. Replaces the deprecated
  `js-ipfs`. Packages `@helia/strings` and `@helia/json` provide typed add/get
  helpers. Runs in Node.js and browser.
- **js-kubo-rpc-client** ([github.com/ipfs/js-kubo-rpc-client](https://github.com/ipfs/js-kubo-rpc-client))
  — HTTP-RPC client for a running Kubo daemon (the Go implementation).
- **@helia/verified-fetch** — wraps standard `fetch` to verify CID integrity on
  retrieval.

**Pinning services (IPFS content exists only while at least one node pins it):**

- **Pinata** ([pinata.cloud](https://pinata.cloud)) — dominant IPFS pinning service
  in 2026. Has a TypeScript SDK (`npm i pinata`). Free tier (1 GB), then paid.
  Returns CIDs on upload. Custom dedicated gateways available.
  - Source: [pinata.cloud/ipfs](https://pinata.cloud/ipfs)
- **Storacha** (formerly web3.storage) ([storacha.network](https://storacha.network))
  — rebranded and now backed by Filecoin for provable persistence. Uses UCAN
  (User-Controlled Authorization Networks) for delegation. TypeScript SDK:
  `@web3-storage/w3up-client`. Returns IPFS CIDs; data replicated to Filecoin for
  durability. "Decentralized hot storage" positioning.
  - Source: [Web3.Storage Review 2026: Storacha](https://cryptoadventure.com/web3-storage-review-2026-storacha-ucan-spaces-and-ipfs-plus-filecoin-storage/)
- **Filebase** — S3-compatible API on top of IPFS; enterprise focus.
- **Cloudflare IPFS Gateway** — public read-only gateway; no upload API.

**The fundamental IPFS availability risk:** content only persists while at least one
node is pinning it. If a paid pinning service shuts down (web3.storage dropped IPFS
pinning before the Storacha pivot) or stops pinning, CIDs become unreachable. Two
independent pins (e.g., Pinata + Storacha) dramatically reduce but do not eliminate
this risk.

Sources:
- [IPFS Persistence, permanence, and pinning](https://docs.ipfs.tech/concepts/persistence/)
- [IPFS Gateway Market Outlook 2026-2032](https://www.intelmarketresearch.com/ipfs-gateway-market-23179)
- [Pinata is NOT a Viable Long-Term Solution (critical analysis)](https://medium.com/web-design-web-developer-magazine/pinata-is-not-a-viable-long-term-solution-for-facilitating-decentralized-nft-file-storage-on-ipfs-f27896da2ea5)

### 2b. CID vs keccak256 — the reconciliation problem

**The mismatch:** IPFS CIDs use sha2-256 by default; Ethereum uses keccak256.
These are different hash functions. A CID is not the same value as a keccak256 hash
of the same bytes.

**Three patterns** in use:

1. **Store CID on-chain, verify content via CID on fetch.** The smart contract
   emits the CID string (or its bytes32 encoding). The resolver fetches by CID and
   IPFS verifies sha2-256 integrity automatically. No keccak256 commitment on-chain.
   Used by: most NFT metadata contracts, OpenSea, many DeFi governance systems.
   **Problem for web3-llm:** the contract already uses keccak256 commitments and
   changing this is not backward-compatible. The v0 contracts are deployed.

2. **Store keccak256 on-chain; emit CID as an event field.** The contract stores
   `keccak256(text)` (current design) and also emits the IPFS CID as an indexed
   event log field. The resolver fetches the CID, IPFS verifies sha2-256, then
   `withHashVerification` re-checks keccak256 against the on-chain commitment.
   **Two independent integrity checks, complementary algorithms.** This is the
   additive pattern — the on-chain keccak256 is the authoritative commitment; the
   CID is the retrieval pointer.

3. **Store keccak256 on-chain; store CID in a separate registry.** An off-chain
   index maps `keccak256 → CID`. The contract changes nothing. The resolver queries
   the index to find which CID to fetch. The index can be rebuilt from event logs.
   Simpler contract changes but requires a discoverable index.

Pattern 2 is the strongest fit for web3-llm's existing design. It does not change
deployed contracts; the CID is surfaced via an event or via the `BountyCreated`
event's indexed fields; any party can retrieve text by CID and verify both sha2-256
(IPFS) and keccak256 (on-chain commitment).

Sources:
- [Efficient, Usable, And Cheap Storage of IPFS Hashes In Solidity Smart Contracts](https://medium.com/temporal-cloud/efficient-usable-and-cheap-storage-of-ipfs-hashes-in-solidity-smart-contracts-eb3bef129eba)
- [ERC-1577: contenthash field for ENS](https://eips.ethereum.org/EIPS/eip-1577)
- [IPFS Hashing Concepts](https://filebase.com/blog/ipfs-content-addressing-explained/)

### 2c. Arweave — permanent storage

Arweave ([arweave.org](https://arweave.org)) stores data permanently through a
one-time payment into an endowment model. Miners are paid from the endowment fund
indefinitely. The claim is 200+ year persistence for a single upfront fee.

**Cost model (2026):**

- ~$0.002–$0.005 per MB (in AR tokens). A typical spec+PR text pair is well under
  10 KB, costing fractions of a cent per bounty.
- One-time payment, no recurring subscription.
- Break-even vs. IPFS pinning services: a few years. For decade-scale storage,
  Arweave is cheaper; for short-term (<2 years), IPFS pinning services win.

Source: [Decentralized Storage Wars: IPFS vs Arweave](https://future.forem.com/ribhavmodi/where-blockchain-data-actually-lives-ipfs-arweave-the-2026-storage-war-2bka)

**TypeScript SDKs:**

- **arweave-js** ([github.com/ArweaveTeam/arweave-js](https://github.com/ArweaveTeam/arweave-js))
  — official TS/JS SDK. `npm i arweave`. Upload text:
  ```typescript
  const tx = await arweave.createTransaction({ data: text }, wallet);
  tx.addTag('Content-Type', 'text/plain');
  await arweave.transactions.sign(tx, wallet);
  await arweave.transactions.post(tx);
  // retrieve: fetch(`https://arweave.net/${tx.id}`)
  ```
- **Irys** (formerly Bundlr) ([irys.xyz](https://irys.xyz)) — bundling layer on
  Arweave; simpler upload API, instant availability via receipt + gateway URL:
  ```typescript
  import Irys from "@irys/sdk";
  const irys = new Irys({ url: "https://node1.irys.xyz", token: "arweave", key: wallet });
  const receipt = await irys.upload(text);
  // retrieve: fetch(`https://gateway.irys.xyz/${receipt.id}`)
  ```
  Irys provides a millisecond-accurate timestamp and a signed receipt for each
  upload, useful for audit trails.

**Retrieval:** HTTP GET to `https://arweave.net/<txId>` — no client library needed.
Standard fetch works. Any of the public Arweave gateways (arweave.net, ar.io, etc.)
can serve the content.

**Key difference from IPFS:** Arweave uses SHA-256 internally but retrieval is by
**transaction ID** (not a content hash). The transaction ID is the SHA-256 hash of
the transaction header, not the raw content hash. To use Arweave with web3-llm's
keccak256 commitment, the architecture is: store arweave txId as a pointer; fetch
text by txId; re-verify with keccak256 via `withHashVerification`.

**Caution:** Arweave's permanence claim rests on the endowment economic model
holding. While the model is well-designed, it is not a cryptographic guarantee —
it depends on the AR token having future value and miners remaining active.

Sources:
- [Decentralized Storage: Filecoin vs. Arweave vs. Storj (2026)](https://www.securities.io/decentralized-storage-filecoin-arweave-storj-comparison/)
- [The economics of storing large datasets on Arweave](https://permaweb-journal.arweave.net/article/economics-storing-large-data-on-arweave.html)
- [NFT Storage Choices: On-Chain, IPFS, and Arweave](https://midlandsinbusiness.com/nft-storage-choices-on-chain-ipfs-and-arweave-for-long-term-asset-survival)
- [Arweave-js README](https://github.com/ArweaveTeam/arweave-js)
- [Irys SDK Docs](https://arweave-tools.irys.xyz/irys-sdk)

### 2d. Filecoin / Storacha positioning

**Filecoin** ([filecoin.io](https://filecoin.io)) in 2026 is evolving toward an
"Onchain Cloud" model: verifiable storage proofs + compute. In January 2026 it
launched its Onchain Cloud roadmap on mainnet. Raw storage capacity: 7.6 EiB.
Storacha uses Filecoin as the underlying persistence layer for its "decentralized
hot storage" service.

Filecoin is the right fit for large data archival (project repositories, large
evidence sets) but overkill for the small text payloads web3-llm handles. The
Storacha abstraction (`@web3-storage/w3up-client`) gives IPFS CIDs + Filecoin
persistence without directly managing Filecoin deal mechanics.

Sources:
- [Top Decentralized Storage Crypto Projects 2026](https://bingx.com/en/learn/article/top-decentralized-storage-crypto-projects-to-know)
- [Web3 Storage War 2026](https://adipek.com/articles/the-web3-storage-war-is-here-why-decentralized-file-systems-are-suddenly-everywhere-in-2026)

---

## 3. Recommended Approach for This Stack

### 3a. Architectural decision: dual commitment

Keep the existing contract design unchanged. The on-chain `specHash`/`prHash` remain
the authoritative keccak256 commitments. Add IPFS CIDs as **retrieval pointers**,
emitted in event logs.

**Flow:**

```
Funder creates bounty:
  1. Hash spec text:  specHash = keccak256(specText)
  2. Hash PR text:    prHash   = keccak256(prText)
  3. Upload spec text to IPFS → specCid
  4. Upload PR text to IPFS   → prCid
  5. Call contract.createBounty(specHash, prHash, specCid, prCid, ...)

Resolver handles BountyCreated event:
  1. Extract specCid, prCid from event (or from off-chain registry keyed by hash)
  2. IpfsContentProvider.fetch(specHash, prHash):
       a. fetch(`https://ipfs.io/ipfs/${specCid}`) → specText
       b. fetch(`https://ipfs.io/ipfs/${prCid}`)   → prText
       c. withHashVerification re-checks keccak256 of both
  3. Judge. Submit verdict.

Challenger / arbiter:
  1. Read specCid / prCid from event logs (no trusted intermediary needed)
  2. Independently fetch and verify via any IPFS gateway
```

The IPFS content-hash (sha2-256 via CID) provides a second independent integrity
check on top of the keccak256 contract commitment. Any mismatch at either layer
means the content was tampered.

### 3b. What to build in this repo

**New file: `resolver/src/providers/ipfs.ts`**

Implement `ContentProvider` using Helia or a simple gateway fetch (the latter
requires no daemon and no keys):

```typescript
// resolver/src/providers/ipfs.ts
import { withHashVerification } from "../content.js";
import type { ContentProvider, BountyContent } from "../content.js";
import type { Hex } from "viem";

export interface IpfsCidPair { specCid: string; prCid: string; }

/** Resolve CIDs from an in-memory or on-chain event map, then fetch via public gateway. */
export class IpfsGatewayContentProvider implements ContentProvider {
  constructor(
    private readonly cidMap: Map<string, IpfsCidPair>,  // keyed by specHash (hex)
    private readonly gateway = "https://ipfs.io",
  ) {}

  async fetch(specHash: Hex, prHash: Hex): Promise<BountyContent> {
    const pair = this.cidMap.get(specHash.toLowerCase());
    if (!pair) throw new Error(`no CID mapping for specHash ${specHash}`);
    const [specText, prText] = await Promise.all([
      this.fetchCid(pair.specCid),
      this.fetchCid(pair.prCid),
    ]);
    return { specText, prText };
  }

  private async fetchCid(cid: string): Promise<string> {
    const res = await fetch(`${this.gateway}/ipfs/${cid}`);
    if (!res.ok) throw new Error(`IPFS gateway error ${res.status} for CID ${cid}`);
    return res.text();
  }
}

/** Always wrap with this — turns "gateway returned text" into "text matches on-chain commitment". */
export const withVerification = withHashVerification;
```

Usage in `resolver/src/index.ts`:

```typescript
import { IpfsGatewayContentProvider, withVerification } from "./providers/ipfs.js";
// ... populate cidMap from BountyCreated event log field `specCid`/`prCid` ...
const content = withVerification(new IpfsGatewayContentProvider(cidMap));
```

**New file: `resolver/src/providers/arweave.ts`** (optional parallel backend)

```typescript
export class ArweaveContentProvider implements ContentProvider {
  constructor(private readonly txMap: Map<string, { specTxId: string; prTxId: string }>) {}
  async fetch(specHash: Hex, prHash: Hex): Promise<BountyContent> {
    const pair = this.txMap.get(specHash.toLowerCase());
    if (!pair) throw new Error(`no Arweave tx for specHash ${specHash}`);
    const [specText, prText] = await Promise.all([
      fetch(`https://arweave.net/${pair.specTxId}`).then(r => r.text()),
      fetch(`https://arweave.net/${pair.prTxId}`).then(r => r.text()),
    ]);
    return { specText, prText };
  }
}
```

**Upload script: `resolver/scripts/upload-content.ts`**

A CLI script the funder runs before calling `createBounty`:

```typescript
// npm run upload -- --spec ./spec.txt --pr ./pr.txt
// Outputs: specHash, prHash, specCid, prCid → feed into createBounty args
```

Uses Pinata SDK or `@web3-storage/w3up-client` to upload, returns CIDs and
keccak256 hashes. The hashes go into the contract; the CIDs go into the event.

**Contract change (minor, additive):**

Add two `string`-typed parameters or a `bytes`-typed CID field to `BountyCreated`
event in `BountyEscrow.sol` / `StakedBountyEscrow.sol`:

```solidity
event BountyCreated(
    uint256 indexed id,
    address indexed claimant,
    bytes32 specHash,
    bytes32 prHash,
    string  specCid,   // ← new: IPFS CID (retrieval pointer, not commitment)
    string  prCid      // ← new: IPFS CID
);
```

The CID fields are **not** commitments — they are retrieval hints. The keccak256
hashes remain the sole authoritative commitments. If a bad actor emits a false CID,
`withHashVerification` catches it.

### 3c. Pinning strategy

**Primary:** Pinata (`npm i pinata`) — free tier sufficient for testnet/MVP. Their
TypeScript SDK is the simplest upload path. API key stored in `.env` as
`PINATA_JWT`.

**Backup (optional at P2, recommended at P3):** Storacha (`@web3-storage/w3up-client`
via `npm i @web3-storage/w3up-client`) backed by Filecoin. Run both for dual-pin
redundancy. Storacha uses UCAN delegation so keys are not API secrets in the
traditional sense — lower operational risk.

**Do not operate your own IPFS node** for v0/P2 — unnecessary operational burden.
Public gateways (ipfs.io, cloudflare-ipfs.com, dweb.link) are sufficient for
resolver reads.

### 3d. Arweave as complement

For dispute-critical content (e.g., once a bounty is challenged), consider
uploading to Arweave via Irys (`npm i @irys/sdk`) as a permanent archive. This
adds permanence insurance for the ~$0.001 cost per bounty. It is not the primary
fetch path — it is a fallback and audit trail.

**Decision tree:**
- Normal operation: IPFS (Pinata) for upload + read
- Disputed bounty or high-value bounty: IPFS + Arweave (Irys) dual archive
- P4 / full decentralization: self-hosted IPFS + Filecoin deal + Arweave

### 3e. Versus the current local JSON map

| Property | Current (`content.example.json`) | IPFS (Pinata + gateway) | Arweave (Irys) |
|---|---|---|---|
| **Availability** | Only on resolver host | Any IPFS gateway (redundant) | arweave.net + mirror gateways |
| **Permanence** | Deleted if resolver lost | Until pinning lapses | 200+ year endowment claim |
| **Integrity** | keccak256 via `withHashVerification` | CID sha2-256 + keccak256 | keccak256 via `withHashVerification` |
| **Trust model** | Trust our server | Trustless (dual hash verify) | Trustless (keccak256 verify) |
| **Cost** | Free | Free tier → fractions of cent/KB | ~$0.002–$0.005/MB |
| **Ops burden** | Manual JSON edit | Upload script + JWT in .env | Upload script + AR wallet |
| **P2 fit** | Blocks live GitHub integration | Fits directly | Fits, slightly more setup |

---

## 4. Effort, Dependencies, Risks

### Effort: M (Medium)

- `resolver/src/providers/ipfs.ts`: ~60 lines, straightforward
- `resolver/src/providers/arweave.ts`: ~40 lines (optional)
- `resolver/scripts/upload-content.ts`: ~80 lines (CLI upload + hash/CID output)
- Contract event change (`specCid`/`prCid` fields): ~10 lines Solidity; requires
  `forge test` pass + security-auditor sign-off + new Sepolia deploy
- Tests: new vitest unit tests for both providers using `msw` or `nock` to mock
  gateway HTTP; integration test with real Pinata account

Total estimate: 2–3 days of focused engineering (resolver-engineer owns; smart-
contract-engineer does the event field change).

### Dependencies

- `npm i pinata` — Pinata TypeScript SDK
- Optionally `npm i @web3-storage/w3up-client` — Storacha backup pin
- Optionally `npm i @irys/sdk` — Arweave permanent archive
- No Helia node required (gateway fetch is enough for the resolver)
- Pinata JWT (free account) added to `.env` and `.env.example`
- Contract redeploy to Sepolia (triggered by event field addition) — needs
  devops-deployer + security-auditor sign-off

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Pinata service outage | Low-medium | Dual-pin with Storacha; resolver retries on 5xx |
| Pinata shuts down or drops free IPFS | Happened to web3.storage pre-Storacha | Storacha as fallback; keccak256 commitment on-chain is still valid; re-pin elsewhere |
| IPFS gateway unavailable for resolver | Low (multiple public gateways) | Configurable gateway URL; try list of gateways on failure |
| CID spoofing in event (attacker emits wrong CID) | Low | `withHashVerification` catches this; keccak256 is the real commitment |
| Arweave economic model failure | Very low / long-term | IPFS is primary; Arweave is backup |
| Contract redeploy breaks testnet state | Medium | Plan Sepolia redeploy as part of P1→P2 transition; not a surprise |
| AR token wallet management complexity | Low | Irys handles this; can also fund via Irys credit |

**The `withHashVerification` layer is the critical safety net.** Even if the content
store is fully compromised (bad actor controls the pinning service and the gateway),
the resolver rejects tampered content because keccak256 does not match the on-chain
commitment. This security property already exists; decentralized storage only
improves availability, not integrity.

---

## 5. Verdict

### Roadmap phase: P2

Correctly placed. P0 (judge accuracy) and P1 (live testnet, auto-settle) must
complete first. Decentralized content storage is a dependency of a fully live,
trustless product — but it is not a dependency of proving the judge works or
demonstrating the settlement loop on Sepolia. The current local JSON map is
adequate for P0 and P1.

Explicitly in scope at P2 because: without it, the "judge a live GitHub PR by URL"
kill-gate cannot be fully satisfied in a trustless way. GitHub is the *live fetch*
source (#02 research); IPFS/Arweave is the *durable commitment archive* that makes
the verdict verifiable to third parties and challengers.

### Go / No-go: GO (at P2)

The pattern is well-established, the TypeScript libraries are mature, the
`ContentProvider` interface already makes this a pure swap of the backend, and the
`withHashVerification` safety net already in place means decentralized storage adds
availability/trustlessness without introducing new integrity attack surfaces.

### Priority: 3 out of 5

- **Priority 1:** P0 kill-gate (judge accuracy). Nothing ships without this.
- **Priority 2:** P1 testnet + auto-settle bot.
- **Priority 3 (this):** Decentralized content storage at P2. Important for
  trustlessness; not blocking P0/P1.
- **Priority 4:** Frontend dApp (#06).
- **Priority 5:** Multi-resolver / token (#05, #08, #09).

### Implementation recommendation

1. At P2, implement `IpfsGatewayContentProvider` in `resolver/src/providers/ipfs.ts`
   using simple `fetch()` to a public IPFS gateway. No Helia daemon needed.
2. Add a Pinata upload script at `resolver/scripts/upload-content.ts`. Pin on
   upload; optionally dual-pin with Storacha for redundancy.
3. Add `specCid`/`prCid` as string fields to the `BountyCreated` event (additive,
   backward-compatible after redeploy). Have smart-contract-engineer make the change
   and security-auditor review before Sepolia redeploy.
4. Keep `MapContentProvider` (local JSON map) as the test and CI backend — no change
   needed there. The production swap is purely in how `index.ts` instantiates the
   `ContentProvider`.
5. Arweave (Irys) as optional fallback for disputed/high-value bounties — defer to
   P3 unless a challenger scenario materializes earlier.

---

*Research by feature-researcher agent, June 2026.*
*Sources: [IPFS Docs](https://docs.ipfs.tech/concepts/content-addressing/), [Pinata](https://pinata.cloud/ipfs), [Storacha/web3.storage](https://storacha.network/), [arweave-js](https://github.com/ArweaveTeam/arweave-js), [Irys SDK](https://arweave-tools.irys.xyz/irys-sdk), [IPFS vs Arweave 2026](https://future.forem.com/ribhavmodi/where-blockchain-data-actually-lives-ipfs-arweave-the-2026-storage-war-2bka), [Decentralized Storage Comparison 2026](https://bingx.com/en/learn/article/top-decentralized-storage-crypto-projects-to-know), [IPFS Persistence docs](https://docs.ipfs.tech/concepts/persistence/)*
