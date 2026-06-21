# 06 — Frontend dApp (P3)

> Feature-researcher report. Current date: June 2026.
> Stack: Solidity 0.8.26 + OZ v5.6.1 + Foundry (`StakedBountyEscrow` v1); resolver in TypeScript + viem + Anthropic SDK.

---

## 1. What & Why for Web3-llm

### The problem a UI solves

Today the product is entirely CLI: a funder must craft a raw `createBounty` call with
pre-computed `keccak256` hashes, a claimant has no way to see their verdict without an
RPC explorer, and a challenger must call `challenge(uint256)` by hand within the window.
None of this is accessible to a non-technical DAO treasurer, open-source maintainer, or
hackathon participant — the exact audiences listed in `docs/STRATEGY.md §"Target users"`.

The STRATEGY.md roadmap explicitly positions the UI at **P3 — Productize**, gated behind
P0 (eval kill-gate ≥90%), P1 (live Sepolia loop), and P2 (real GitHub evidence). Its
win condition: *"a third party (not us) creates and settles a bounty through the UI."*

That scoping is correct. The UI is the *display window* for a loop that must first
prove it works without one.

### The five screens that unlock P3

A minimal-viable "thin UI" needs exactly five user flows:

| Flow | Actor | Contract calls / reads |
|------|-------|------------------------|
| Connect wallet | Anyone | — |
| Create bounty | Funder | `createBounty(claimant, specHash, prHash){value}` |
| View bounty list / detail | Anyone | `getBounty(id)`, watch `BountyCreated`, `VerdictProposed`, `Settled` events |
| Read verdict + reasoning | Claimant / observer | Parse `VerdictProposed` event (`reasoning` string lives in the event log, not storage — see `StakedBountyEscrow.sol:77`) |
| Challenge | Any challenger | `challenge(id){value: challengeBond}` during window |

Everything else (arbiter UI, stake management, dispute resolution) is operational work
that can remain CLI for P3. It can be wrapped in UI at P4.

---

## 2. How the Leaders Do It

### Wallet connection kit

**RainbowKit** (by Rainbow wallet team) is the de-facto standard — Uniswap, OpenSea,
and hundreds of consumer dApps use it. It ships a polished, branded connect modal
out-of-the-box with minimal configuration, and integrates natively with wagmi v2.
([RainbowKit docs](https://rainbowkit.com/docs/installation))

**ConnectKit** (by Family) is a modular alternative. It gives developers more control
over every pixel of the wallet modal and follows wagmi v2's peer-dep model identically.
Well-suited for enterprise or custom-branded builds, but has lower community momentum.
([ConnectKit / Family docs](https://docs.family.co/connectkit/migration-guide))

**Reown AppKit** (formerly Web3Modal) has undergone a major 2024–2025 rebranding and
supports wagmi, Ethers v6, Solana, Bitcoin, and TON — making it the widest-net option.
It adds ~200–250 KB to the bundle and is more configuration-heavy.
([Reown AppKit npm](https://www.npmjs.com/package/@reown/appkit),
[Reown AppKit docs](https://docs.reown.com/appkit/react/core/installation))

Comparison:

| | RainbowKit | ConnectKit | Reown AppKit |
|---|---|---|---|
| wagmi v2 native | ✅ | ✅ | ✅ (adapter) |
| Bundle overhead | ~120 KB | ~80 KB | ~200–250 KB |
| Customization | Opinionated / theming | Fully modular | Config-heavy |
| Chain coverage | EVM | EVM | EVM + Solana/BTC/TON |
| Community momentum | Highest | Medium | High (WalletConnect backing) |
| Best for | Speed-to-market, UX | Deep branding control | Multi-chain / enterprise |

For Web3-llm (EVM-only, thin UI, speed-to-market), **RainbowKit** is the pick.

Sources: [dappness.com wallet SDK guide](https://dappness.com/posts/which-web3-wallet-sdk-should-i-use),
[chainscorelabs RainbowKit vs ConnectKit](https://chainscorelabs.com/comparisons/wallets-eoa-vs-smart-contract-wallets/client-side-integration/rainbowkit-vs-connectkit-developer-focused-wallet-ui)

### wagmi + viem for contract interaction

wagmi v2 (React hooks layer on top of viem) is the dominant production choice for
Next.js dApps in 2025–2026. Key hooks for this product:

- `useWriteContract` → `createBounty`, `challenge`
- `useReadContract` → `getBounty(id)`, `challengeBond`, `challengePeriod`
- `useWatchContractEvent` → real-time `VerdictProposed`, `Settled`, `Challenged` events
- `useWaitForTransactionReceipt` → UX feedback after a write

The hook layer infers return types directly from the ABI (powered by
[ABIType](https://abitype.dev/)), so there is zero manual type-casting.

Sources: [wagmi + viem modern stack](https://www.iamuvin.com/blog/web3-wagmi-viem-modern-frontend-stack),
[production-ready wagmi + Next.js guide](https://medium.com/@vahdatfardin/building-production-ready-web3-dapps-with-wagmi-viem-and-next-js-cfc5d12f766b),
[wagmi v3 event listening guide](https://ignaciopastorsanchez.com/blog/how-to-listen-for-and-parse-smart-contract-events-using-wagmi-v3)

### Data / indexing strategy

Three options for reading historical bounty state:

**Option A — Direct viem `getLogs` (no indexer)**  
`publicClient.getContractEvents` with `fromBlock` and `toBlock: 'latest'` fetches
all `BountyCreated`, `VerdictProposed`, `Settled`, and `Challenged` logs directly
from the RPC. No extra infrastructure. Works well for low-volume testnet/early
production deployments where log history fits in a single RPC query.
([viem getLogs docs](https://viem.sh/docs/actions/public/getLogs.html))

**Option B — Ponder (TypeScript-native indexer, self-hosted)**  
Ponder is an open-source TypeScript EVM indexer that auto-generates a GraphQL API
from a `ponder.schema.ts` file. It runs locally or on Railway/Render. Ideal when
the log history grows large or you want pre-aggregated data (e.g., "all bounties for
this funder"). TypeScript config aligns perfectly with the existing resolver stack.
([Ponder GitHub](https://github.com/ponder-sh/ponder),
[Introducing Ponder](https://ponder.sh/blog/introducing-ponder))

**Option C — The Graph (decentralized, hosted subgraph)**  
Mature, battle-tested, with the largest ecosystem. Requires writing AssemblyScript
handlers and deploying a subgraph — more operational overhead. Best for production
scale or when a public API is needed for third parties.
([Best blockchain indexers 2026](https://docs.envio.dev/blog/blog/best-blockchain-indexers-2026))

For P3 (thin UI, testnet, low volume): start with **Option A** (direct viem reads, no
indexer). Add **Option B** (Ponder) when log history grows or the team wants a cleaner
GraphQL data layer. Defer The Graph to P4 or mainnet scale.

### Hosting

**Vercel** is the natural choice for Next.js App Router deployments — zero-config,
git-push deploys, CDN, preview URLs per PR.
([nextjs wagmi rainbowkit Vercel template](https://medium.com/@daqingchong0809_90988/nextjs-wagmi-rainbowkit-dapp-template-and-example-d27c4673a0ec))

All Web3 RPC calls go from the browser directly to the configured RPC endpoint
(e.g., Alchemy/Infura via `NEXT_PUBLIC_RPC_URL`). No server-side secrets are needed
for the read-only UI — private keys stay in the resolver service, not the frontend.

---

## 3. Recommended Approach in This Stack

### Monorepo layout

Add the UI as a top-level `app/` package alongside `resolver/`:

```
Web3-llm/
├── app/                        # NEW — Next.js App Router dApp
│   ├── src/
│   │   ├── app/
│   │   │   ├── layout.tsx      # WagmiProvider + RainbowKitProvider + QueryClientProvider
│   │   │   ├── page.tsx        # Bounty list / home
│   │   │   └── bounty/[id]/
│   │   │       └── page.tsx    # Bounty detail: verdict + reasoning + challenge button
│   │   ├── components/
│   │   │   ├── CreateBountyForm.tsx
│   │   │   ├── BountyCard.tsx
│   │   │   ├── VerdictPanel.tsx   # parses VerdictProposed event; shows reasoning string
│   │   │   └── ChallengeButton.tsx
│   │   ├── hooks/
│   │   │   ├── useBounties.ts     # getLogs(BountyCreated) + useWatchContractEvent
│   │   │   └── useBounty.ts       # useReadContract(getBounty) + watch VerdictProposed/Settled
│   │   └── lib/
│   │       └── contract.ts        # re-exports escrowAbi + CONTRACT_ADDRESS constant
│   ├── package.json
│   └── next.config.mjs
├── resolver/                   # existing TypeScript resolver
└── src/                        # Solidity contracts
```

### ABI / type sharing (zero duplication)

The resolver already defines `escrowAbi` as a `const` TypeScript object in
`resolver/src/abi.ts`. The frontend can import it directly:

```typescript
// app/src/lib/contract.ts
export { escrowAbi } from "../../resolver/src/abi.js";
export const CONTRACT_ADDRESS = process.env.NEXT_PUBLIC_CONTRACT_ADDRESS as `0x${string}`;
```

Because `escrowAbi` is declared `as const`, wagmi's hooks infer fully-typed args and
return values with no additional tooling. No code generation step (e.g., wagmi CLI)
is needed until the ABI grows substantially.

This is the critical shortcut: **the resolver's existing `abi.ts` is the single source
of truth** for both the off-chain judge and the frontend. Both import from the same
file; a change to the ABI propagates to both automatically.

### Key packages (app/package.json)

```json
{
  "dependencies": {
    "next": "^15",
    "@rainbow-me/rainbowkit": "^2",
    "wagmi": "^2",
    "viem": "^2",
    "@tanstack/react-query": "^5"
  }
}
```

Note: `viem` version must match the resolver's `viem: "^2.52.0"` to share types safely.

### Provider wiring (app/src/app/layout.tsx)

```typescript
"use client";
import { WagmiProvider } from "wagmi";
import { RainbowKitProvider, getDefaultConfig } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { sepolia } from "wagmi/chains";

const config = getDefaultConfig({
  appName: "Web3-llm Bounty",
  projectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID!,
  chains: [sepolia],
});

const queryClient = new QueryClient();

export default function RootLayout({ children }) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider>{children}</RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
```

### Reading verdict reasoning from events

`StakedBountyEscrow`'s `submitVerdict` logs reasoning in the `VerdictProposed` event
(`reasoning` field, `string` type) — not in contract storage. The frontend must read
this from logs, not from `getBounty()`. The `VerdictPanel` component fetches the log:

```typescript
// hooks/useBounty.ts (simplified)
const { data: verdictLogs } = useContractEvents({
  address: CONTRACT_ADDRESS,
  abi: escrowAbi,
  eventName: "VerdictProposed",
  args: { id: bountyId },
  fromBlock: deployBlock,
});
// verdictLogs[0]?.args.reasoning — the full Claude reasoning string
```

This is architecturally important: the on-chain reasoning is retrievable without any
off-chain database; it lives in the Ethereum event log.

### Challenge UI countdown

The challenge deadline is stored per-bounty in `bounties[id].challengeDeadline`
(`uint64 unix timestamp`). `useReadContract` reads it; the component renders a live
countdown:

```typescript
const { data: bounty } = useReadContract({
  address: CONTRACT_ADDRESS,
  abi: escrowAbi,
  functionName: "getBounty",
  args: [bountyId],
  watch: true,
});
// bounty.challengeDeadline is a bigint unix timestamp
```

### Environment variables

| Var | Purpose |
|-----|---------|
| `NEXT_PUBLIC_CONTRACT_ADDRESS` | `StakedBountyEscrow` deployed address |
| `NEXT_PUBLIC_RPC_URL` | Public RPC endpoint (Alchemy/Infura Sepolia) |
| `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` | From [cloud.walletconnect.com](https://cloud.walletconnect.com) |
| `NEXT_PUBLIC_DEPLOY_BLOCK` | Start block for log scanning (reduces RPC cost) |

### Hosting

Deploy `app/` to Vercel as a standard Next.js project. All env vars are `NEXT_PUBLIC_`
(browser-safe). The resolver runs as a separate process (Railway/fly.io/server) — the
UI does not need to talk to it.

---

## 4. Effort, Dependencies, Risks

### Effort: **M (Medium)** — estimated 5–8 dev-days for a solo developer

| Task | Days |
|------|------|
| Scaffold Next.js + wagmi + RainbowKit, Vercel deploy, env wiring | 0.5 |
| Bounty list (read `BountyCreated` logs, display status) | 1.0 |
| Bounty detail page (read contract state + watch events + verdict reasoning) | 1.5 |
| Create bounty form (specHash/prHash input, ETH value, write contract) | 1.5 |
| Challenge button with countdown timer | 1.0 |
| Polish, error handling, responsive layout | 1.0–2.0 |

### Hard dependencies (must be done before UI is useful)

| Dependency | Phase |
|-----------|-------|
| `StakedBountyEscrow` deployed to Sepolia with a stable address | P1 |
| Resolver running live and submitting verdicts on-chain | P1 |
| Real GitHub evidence (actual `specHash`/`prHash` from PR URLs) | P2 |

Without P1 and P2 complete, the UI can be built and demonstrated against a local Anvil
fork, but there is nothing real to show a third party.

### Risks

**R1 — SSR/hydration mismatch (low, well-solved)**  
wagmi v2 + Next.js 15 App Router requires `"use client"` on all hook-using components.
All published guides and starter kits address this. Mitigation: use the `nexth` starter
([GitHub: wslyvh/nexth](https://github.com/wslyvh/nexth)) as a scaffold reference.

**R2 — WalletConnect projectId required (low overhead)**  
Every dApp using WalletConnect (RainbowKit's default transport) needs a free
`projectId` from [cloud.walletconnect.com](https://cloud.walletconnect.com). One
signup, one env var.

**R3 — RPC log range limits (medium for large log history)**  
Public RPC endpoints cap `getLogs` call range at 2,000–10,000 blocks. On testnet this
is not an issue early on, but grows as block count climbs. Mitigation: always set
`NEXT_PUBLIC_DEPLOY_BLOCK` so queries start from the contract's deploy block, not
genesis. Upgrade to Ponder if the list view becomes sluggish.

**R4 — Reasoning string display (low, architectural awareness needed)**  
`VerdictProposed.reasoning` is only in the event log — `getBounty()` does not return
it. The UI must fetch it from logs, not from state. This is known and handled in the
design above (Section 3).

**R5 — specHash / prHash UX (medium — UX design problem)**  
Users need to commit `keccak256` hashes of spec text and PR content when creating a
bounty. Exposing raw hash input is a poor UX. The form should accept a GitHub PR URL
and spec text and hash them client-side using viem's `keccak256` and
`stringToHex` / `toBytes` utilities — matching the resolver's `scripts/hash.ts`
hashing logic. This is a non-trivial UX detail but is self-contained.

**R6 — Scope creep: arbiter / stake management screens (medium risk)**  
The arbiter `resolveDispute` call, the resolver `depositStake`/`withdrawStake` flows,
and the `setParams` owner call are operationally useful but are **not** needed for the
P3 user-facing demo. These should remain CLI at P3. Flag any PR that adds them.

---

## 5. Verdict

### Roadmap phase fit

This feature is explicitly **P3** per `docs/STRATEGY.md`. It has hard upstream
dependencies on P1 (live Sepolia loop with auto-settle) and P2 (real GitHub evidence).
Building it before those gates pass would mean a UI wrapping a broken loop — exactly
the mistake the strategy memo warns against.

### Go / No-Go

**No-Go now. Go immediately when P2 passes.**

P0 (eval kill-gate) must pass first — it is the product's trust foundation.
P1 (live testnet loop) must run unattended. P2 (real GitHub PR evidence) must work.
Only then does a UI make the loop demonstrable to a non-technical user.

Starting the scaffold work (Next.js + wagmi + RainbowKit boilerplate, Vercel project
setup, ABI shared module) in parallel with late P2 work is reasonable — it is cheap,
low-risk, and does not block or distort P2.

### Priority: **2 / 5**

- Priority 1 (highest): P0 eval kill-gate — the trust moat, nothing ships without it
- **Priority 2: P1 + P2 (live loop + real evidence) — the loop the UI wraps**
- Priority 3: This UI — demonstrates the loop to the target audience (DAOs, maintainers)
- Priority 4: Ponder indexer (upgrade when log history requires it)
- Priority 5: P4 features (multi-resolver, token, arbiter UI)

Assigning priority 2 reflects that the UI is the first commercial-facing deliverable
(enables the P3 gate: "a third party settles a bounty through the UI"), not that it
should be built before the loop it depends on.

---

## Summary Card

| Dimension | Recommendation |
|---|---|
| Framework | Next.js 15 App Router |
| Wallet kit | RainbowKit v2 (wagmi v2 native, fastest to ship) |
| Contract layer | wagmi v2 + viem v2 (already in resolver deps) |
| ABI sharing | Import `escrowAbi` from `resolver/src/abi.ts` directly — single source of truth |
| Historical events | Direct viem `getLogs` / `getContractEvents` (no indexer needed for P3) |
| Indexer (later) | Ponder (TypeScript-native, GraphQL API, self-hosted on Railway) |
| Hosting | Vercel (zero-config Next.js) |
| Effort | M — 5–8 dev-days |
| Phase | P3 (after P0 eval gate + P1 live loop + P2 real evidence) |
| Go/No-Go | No-Go now; Go immediately when P2 passes |
| Priority | 2 / 5 (behind P0 gate and the live loop; ahead of indexer and P4 features) |
