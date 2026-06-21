# Research #10 — L2 Deployment, Gas Optimization & Gasless UX (P1/P3)

**Area:** L2 deployment target, contract-level gas savings, and sponsored/gasless transaction UX for funders and claimants.
**Roadmap fit:** P1 (testnet L2 deploy) / P3 (productized gasless UX)
**Date:** June 2026
**Stack:** Solidity 0.8.26 + OZ v5.6.1 + Foundry; resolver/clients use viem (`^2.52.0`)

---

## 1. What & Why for Web3-llm

The Verdict oracle has five on-chain flows: `createBounty`, `depositStake`, `submitVerdict`, `challenge`, `settle`/`resolveDispute`. Even at sub-cent L2 fees, gas friction matters in three ways:

1. **Low-value bounties die at L1.** A $20 bug-fix bounty paying $1–5 in Ethereum L1 gas is unusable. On an L2 the same bounty transacts for fractions of a cent, making micro-bounties viable and opening the DAO/hackathon target market.
2. **Funder UX.** Requiring a funder to own ETH before they can escrow a bounty is a hard onboarding wall. A paymaster-sponsored `createBounty` (or even a credit-card-funded approach) can let them escrow in one click.
3. **Resolver gas.** The resolver submits `submitVerdict` and `settle` automatically. These are internal, but cheap L2 calls mean the resolver's operating cost approaches zero and requires minimal ETH float.

The deployment decision also determines which testnet is used for the P1 gate (P1 requires an end-to-end testnet run). The current stack's config (`RESOLVER_RPC_URL` in `.env`) is chain-agnostic — any EVM RPC works — so switching chains is a one-line env change, not a code rewrite.

---

## 2. How the Leaders Do It

### 2.1 L2 Selection Landscape

**EIP-4844 (Dencun, March 2024) is the baseline.** Blob data lowered L2 data costs by ~90% across all OP-stack and Arbitrum chains. As of mid-2026, average transaction fees across the big three are all sub-cent for simple calls; complex contract interactions are $0.01–$0.10. The meaningful differentiators are now ecosystem depth, bridging UX, and developer tooling.

**Base** ([docs.base.org](https://docs.base.org/)) is the standout for this use case:
- TVL ~$12B as of late 2025, surpassing Arbitrum (~$7.4B) at ~46% of total L2 DeFi TVL. ([CoinLedger](https://coinledger.io/research/base-tvl-and-network-growth))
- 25,000+ active developers and 14M+ daily transactions. Coinbase's distribution gives access to fiat onramps and a massive existing wallet base. ([MEXC News](https://www.mexc.co/news/109750))
- OP Stack — fully EVM equivalent, Foundry works unchanged. Remappings and `foundry.toml` need zero changes.
- **Coinbase Paymaster** ([docs.cdp.coinbase.com](https://docs.cdp.coinbase.com/paymaster/introduction/welcome)) — Coinbase runs a production-grade, ERC-4337-compliant paymaster on Base with a free developer tier (100 sponsored ops/day in early tiers), making it the only major L2 where a first-party, custodied paymaster with no infrastructure overhead is available.
- **Base Sepolia testnet** (chain ID 84532) — the OP-stack L2 testnet, active through at least 2026, with 2-second block times, near-zero fees, and a Coinbase Developer Platform faucet (0.1 ETH per 24 hours). ([docs.base.org/network-faucets](https://docs.base.org/base-chain/network-information/network-faucets))

**Arbitrum One** ([arbitrum.io](https://arbitrum.io/)) — the other serious option:
- Fees similarly sub-cent post-Dencun; gas price at time of writing ~0.02 Gwei ([arbiscan.io](https://arbiscan.io/gastracker)).
- Stronger DeFi/derivative ecosystem, but smaller consumer wallet installed base than Base.
- Good testnet (Arbitrum Sepolia), full Foundry support. ZeroDev and Pimlico have strong Arbitrum coverage.
- No first-party paymaster equivalent to Coinbase's; must integrate a third-party AA provider.

**Optimism Mainnet** — functionally near-identical to Base (same OP Stack), but smaller ecosystem and no first-party paymaster advantage.

**Polygon PoS** — ~$0.015 per tx but sidechain security model (not a true L2, lacks Ethereum-level finality guarantees). Not the right trust model for an escrow that handles real funds. Polygon zkEVM (~$0.11) has better security but no distribution advantage here.

**Recommendation: Base (mainnet) / Base Sepolia (testnet).** The combination of Coinbase's distribution, first-party ERC-4337 paymaster, active developer ecosystem, and OP-stack EVM parity is the strongest fit for this product.

---

### 2.2 ERC-4337 Account Abstraction

ERC-4337 ([EIP-4337 spec](https://eips.ethereum.org/EIPS/eip-4337)) reached final status in March 2023 and is now the dominant production AA standard. It adds a parallel mempool of `UserOperation` objects processed by **bundlers**, routed through a singleton `EntryPoint` contract, and optionally subsidized by a **paymaster**. No consensus-layer changes required.

**Key providers (all support Base):**

| Provider | Bundler | Paymaster | SDK | Chain coverage |
|---|---|---|---|---|
| **Pimlico** | Yes (leading volume) | Verifying + ERC-20 | `permissionless` (viem-native) | ETH, Base, Arbitrum, Optimism, Polygon + more |
| **Coinbase** | Yes (via CDP) | Yes (first-party on Base) | `@coinbase/cdp-sdk`, wagmi integration | Base-primary |
| **Alchemy** | Yes | Gas Manager (sponsorship) | Account Kit SDK | ETH, Base, Arbitrum, Optimism, Polygon |
| **Biconomy** | Yes | Nexus (V2/Modular) | `@biconomy/sdk` | Polygon, BNB, Base, Arbitrum |
| **ZeroDev** | Yes | Kernel paymaster | `@zerodev/sdk` | All major EVMs |

**Pimlico's `permissionless`** ([github.com/pimlicolabs/permissionless.js](https://github.com/pimlicolabs/permissionless.js)) is the strongest viem-native choice: it is a thin wrapper around viem with no additional dependencies, uses `createSmartAccountClient()` / `createPaymasterClient()` / `toSimpleSmartAccount()` APIs, and integrates with Pimlico's bundler RPC and `pm_sponsorUserOperation` paymaster endpoint. Install: `npm install permissionless`. ([npm](https://www.npmjs.com/package/permissionless)) The resolver stack already depends on `viem ^2.52.0` — adding `permissionless` requires zero ecosystem changes.

**Supported smart account types in permissionless:** Safe, Kernel (ZeroDev), Biconomy, SimpleAccount, LightAccount, TrustWallet.

---

### 2.3 ERC-2771 Meta-Transactions

ERC-2771 ([OpenZeppelin Docs](https://docs.openzeppelin.com/defender/guide/meta-tx)) is an older approach: the contract inherits `ERC2771Context`, reads `_msgSender()` instead of `msg.sender`, and accepts calls from a trusted forwarder relayer. Pros: simpler than full AA; no EntryPoint dependency. Cons: requires contract changes (inherit `ERC2771Context`, all `msg.sender` references become `_msgSender()`), introduces a trusted relayer assumption, and is being superseded by ERC-4337 and EIP-7702 for new deployments.

**For web3-llm:** `StakedBountyEscrow` uses raw `msg.sender` throughout and is already deployed (or will be deployed as-is). Retrofitting ERC-2771 requires modifying the contract and re-auditing. Not recommended unless the simpler `permissionless`/ERC-4337 route is blocked.

---

### 2.4 EIP-7702 (Pectra, May 2025)

EIP-7702 ([Openfort blog](https://www.openfort.io/blog/eip-7702)) went live in the Pectra hard fork on May 7, 2025. It lets an EOA point its account slot to a smart contract implementation for a transaction, enabling batching, sponsorship, and session keys from existing EOA addresses without migrating to a contract wallet. This is delegation, not deployment: the EOA keeps its address and private key.

**For web3-llm:** EIP-7702 is a near-term upgrade path for funder/claimant UX once P3 ships a frontend. ZeroDev's Kernel supports EIP-7702 via `@zerodev/sdk` with `quickstart-7702`. It enables session keys — a time-bounded, scope-limited sub-key that lets a funder `createBounty` in a single click without MetaMask confirmations for each call. This is a P3 concern, not P1.

---

### 2.5 Session Keys

Session keys (implemented by ZeroDev Kernel, Biconomy's "session" paymaster, and now natively via EIP-7702) allow a user to pre-authorize a constrained signing key that can call specific contract functions within a time/value limit. For the funder flow: fund a session for `createBounty` only, on `StakedBountyEscrow`, up to N ETH, expiring in 24 hours. One signature up front, zero gas prompts during the session.

**For web3-llm:** Useful at P3 when a dApp UI exists. Not needed for P1's resolver-only testnet loop.

---

## 3. Recommended Approach in This Stack

### 3.1 Deployment Target

**Testnet (P1): Base Sepolia** (chain ID 84532)
- Drop-in replacement for the current Sepolia config: change `RESOLVER_RPC_URL` to a Base Sepolia RPC (e.g., `https://sepolia.base.org` or a Quicknode/Alchemy endpoint).
- Faucet: Coinbase Developer Platform Faucet at `coinbase.com/developer-platform/products/faucet` — 0.1 ETH/24h, no account required beyond verification.
- `foundry.toml` already has `optimizer = true; optimizer_runs = 200` — no changes needed for deployment.

**Mainnet (P3+): Base Mainnet** (chain ID 8453)
- Same OP Stack, same toolchain, same `StakedBountyEscrow` bytecode.
- Bridging: ETH via Coinbase's native Base bridge, or third-party bridges (Across Protocol, Stargate).

### 3.2 Contract-Level Gas Optimizations

**Already done / good in `StakedBountyEscrow`:**
- Reasoning logged via `string calldata reasoning` in events (`VerdictProposed`, `VerdictSubmitted`) — not stored in contract storage. This is the single biggest gas save: a long LLM reasoning string as a storage write would cost hundreds of thousands of gas; as an event, it is ~8 gas per byte.
- CEI pattern throughout — no re-entrancy wasted gas.
- `nonReentrant` guard only on fund-moving paths (not on reads/admin).
- `uint64 challengeDeadline` already packed into the `Bounty` struct alongside other smaller-than-256-bit values. Check if `Status` (uint8) and `bool fulfilled`/`challenger` are adjacent in the struct for tight packing (Solidity packs adjacent storage slots when types fit in 32 bytes).

**Not yet done — recommended improvements:**

1. **Custom errors over `require(condition, "string")`.** Available since Solidity 0.8.4 and already supported by 0.8.26. Custom errors reduce bytecode size and runtime revert cost.
   - File to edit: `/home/user/Web3-llm/src/StakedBountyEscrow.sol`
   - Current: `require(b.status == Status.Open, "not open");` (16 instances of string-argument `require`)
   - Target: `error NotOpen(); ... if (b.status != Status.Open) revert NotOpen();`
   - Savings: ~50–100 gas per revert path hit; ~1–3% bytecode reduction.

2. **Struct storage slot audit.** In `StakedBountyEscrow.Bounty`, the layout is:
   ```
   address funder;         // 20 bytes → slot 0 (20/32)
   address claimant;       // 20 bytes → slot 1 (new slot, 20/32)
   uint256 amount;         // 32 bytes → slot 2
   bytes32 specHash;       // 32 bytes → slot 3
   bytes32 prHash;         // 32 bytes → slot 4
   Status status;          // 1 byte (enum) → slot 5 start
   bool fulfilled;         // 1 byte → slot 5 (packed with status)
   uint64 challengeDeadline; // 8 bytes → slot 5 (packed)
   address challenger;     // 20 bytes → slot 5 (packed, fits: 1+1+8+20 = 30 bytes)
   uint256 bondLocked;     // 32 bytes → slot 6
   uint256 challengeBondPaid; // 32 bytes → slot 7
   ```
   `funder` and `claimant` are each 20-byte addresses occupying separate 32-byte slots. These can't be combined without a refactor, but `status`, `fulfilled`, `challengeDeadline`, and `challenger` appear to already pack into one slot — confirm with `forge inspect StakedBountyEscrow storageLayout`.

3. **`calldata` over `memory` for read-only string/bytes parameters.** Already done for `reasoning` (`string calldata`). No change needed there.

4. **Optimizer runs.** `optimizer_runs = 200` in `foundry.toml` optimizes for deployment cost. If the primary use case is many small bounties (many calls, fewer deploys), bumping to `optimizer_runs = 1000` shifts optimization toward runtime call gas at marginal deploy cost increase. Worth testing with `forge snapshot --diff`.

5. **`nextId` increment pattern.** Current: `id = nextId++` (post-increment, reads then writes). Pre-incrementing (`id = ++nextId; id--`) is marginal; the current pattern is idiomatic and fine.

### 3.3 Gasless UX Implementation

**Phase: P3 (funder/claimant flows in a dApp UI). The resolver's own gas is trivial on L2 — not worth AA for that path.**

**Recommended stack: Pimlico `permissionless` + Coinbase Paymaster on Base.**

The resolver already uses `viem ^2.52.0`. For a P3 frontend:

```bash
npm install permissionless
# peer dep: viem already present
```

**Minimal gasless `createBounty` flow (funder, no ETH needed):**

```typescript
// resolver/src or frontend/src (new file, e.g. smartWallet.ts)
import { createSmartAccountClient, toSimpleSmartAccount } from "permissionless";
import { createPaymasterClient } from "permissionless/clients";
import { http, createPublicClient } from "viem";
import { base } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

// 1. Public client for Base
const publicClient = createPublicClient({ chain: base, transport: http() });

// 2. Funder's EOA (or passkey via Coinbase Smart Wallet)
const funderAccount = privateKeyToAccount(FUNDER_PRIVATE_KEY);

// 3. Smart account (SimpleAccount is the lightest — no extra dependencies)
const smartAccount = await toSimpleSmartAccount({
  client: publicClient,
  owner: funderAccount,
  entryPoint: { address: ENTRY_POINT_V07, version: "0.7" },
});

// 4. Coinbase Paymaster (free tier on Base)
const paymasterClient = createPaymasterClient({
  transport: http("https://api.developer.coinbase.com/rpc/v1/base/YOUR_API_KEY"),
});

// 5. Smart account client with bundler + paymaster
const smartAccountClient = createSmartAccountClient({
  account: smartAccount,
  chain: base,
  bundlerTransport: http("https://api.developer.coinbase.com/rpc/v1/base/YOUR_API_KEY"),
  paymaster: paymasterClient,
});

// 6. Gasless createBounty (funder pays nothing)
const txHash = await smartAccountClient.writeContract({
  address: BOUNTY_ESCROW_ADDRESS,
  abi: escrowAbi,
  functionName: "createBounty",
  args: [claimantAddress, specHash, prHash],
  value: parseEther("0.01"), // the bounty amount itself — the GAS is sponsored
});
```

The `StakedBountyEscrow` contract itself requires zero modification for this pattern. The funder's smart account sends a `UserOperation`; the Coinbase Paymaster covers the L2 gas; the ETH bounty value is still transferred from the funder's balance.

**For claimant flows (no changes needed):** The claimant does not pay gas in the current contract design — settlement is triggered by `settle()` (permissionless) or `resolveDispute()` (arbiter). Either the resolver's settle-bot calls `settle()` on their behalf (already built in `chain.ts`), or a keeper calls it. The claimant receives ETH without needing to submit any tx.

**Alternative: Coinbase Smart Wallet (for P3 consumer UX)**

For a full consumer product, [Coinbase Smart Wallet](https://www.coinbase.com/wallet/smart-wallet) provides passkey-based ERC-4337 wallets with Coinbase-sponsored gas on Base and zero MetaMask dependency. Users sign up with Face ID / Touch ID. The wagmi connector (`@coinbase/wallet-sdk`) integrates with the frontend stack. This is the highest-leverage approach for the "funder signs up without buying ETH" cold-start problem.

**Provider comparison for this stack:**

| Provider | viem-native | Base support | Paymaster cost | Setup effort |
|---|---|---|---|---|
| Pimlico `permissionless` | Yes (built on viem) | Yes | Pay-per-use, generous free tier | Low — npm install |
| Coinbase CDP Paymaster | Via wagmi/CDP SDK | First-party | Free dev tier (100 ops/day) | Low — API key only |
| Alchemy Account Kit | Partial (own SDK) | Yes | Gas Manager (free/paid tiers) | Medium — Alchemy SDK |
| ZeroDev Kernel | Via permissionless | Yes | Kernel paymaster | Medium — session key setup |
| Biconomy Nexus | Own SDK | Yes | Biconomy paymaster | Medium |

**Recommendation: Start with Coinbase CDP Paymaster (zero infra, first-party on Base) + permissionless.js for the TypeScript client. If session key UX is needed at P3, layer in ZeroDev Kernel on top of permissionless.**

---

## 4. Effort, Dependencies, Risks

### P1 Component: Deploy to Base Sepolia

**Effort: S (Small)**

Changes needed:
- `.env.example`: add `RESOLVER_RPC_URL=https://sepolia.base.org` as the Base Sepolia default.
- `docs/` or `scripts/`: update deploy script (`script/DeployStaked.s.sol`) — zero code changes, just document the `--rpc-url` flag for Base Sepolia.
- Faucet: Coinbase Developer Platform Faucet covers testnet ETH.
- CI: If GitHub Actions runs `forge test` with a live RPC, add `BASE_SEPOLIA_RPC_URL` secret; fork-mode tests work identically.

Dependencies: Coinbase Developer Platform account (free), Base Sepolia RPC (Alchemy/Quicknode/public endpoint).

Risks:
- **RPC reliability.** The public `https://sepolia.base.org` endpoint rate-limits. Use Alchemy or Quicknode for CI.
- **Block finalization.** Base Sepolia uses optimistic confirmation; for the watcher in `chain.ts`, ensure `fromBlock` replay starts at a safe block depth.

### P1 Component: Contract Gas Optimizations

**Effort: S**

Changes needed:
- `src/StakedBountyEscrow.sol`: replace 16× `require(condition, "string")` with custom errors.
- Run `forge snapshot` before and after to quantify gas deltas.
- Security review of any storage layout changes before mainnet deploy (already mandated by CLAUDE.md).

Dependencies: None (purely local Solidity changes).

Risks: Minimal. Custom errors are a pure gas-saving change with no semantic difference. Any struct repacking changes the ABI in ways that downstream clients (resolver `abi.ts`) must track — keep struct changes minimal and coordinate with `abi.ts`.

### P3 Component: Gasless Funder UX

**Effort: M (Medium)**

Changes needed:
- Frontend (P3 dApp, not yet built): integrate `permissionless` + Coinbase CDP Paymaster.
- Coinbase Developer Platform: create project, obtain paymaster API key.
- New file (e.g., `frontend/src/smartWallet.ts` or inline in wagmi config): wrap `writeContract` calls with `createSmartAccountClient`.
- No contract changes required.

Dependencies:
- P3 frontend must exist (this is a P3 item itself).
- Coinbase Developer Platform account and paymaster API key.
- Decision: which functions to sponsor (gas cost for sponsoring `createBounty`+`depositStake` is negligible on Base; the bounty value in ETH is separate).

Risks:
- **Paymaster budget.** Free tier covers development; production volume needs a paid plan. Need to cap per-user sponsorship to avoid griefing (sponsor only `createBounty` per funder, not unlimited).
- **UserOperation vs native tx compatibility.** The current `escrowAbi` and `ViemEscrowChain` class use native viem `walletClient.writeContract`. AA adds a parallel path; the resolver should continue using native EOA transactions (it already has ETH for gas on L2 — trivial cost).
- **ERC-4337 EntryPoint version.** Use EntryPoint v0.7 (latest); Coinbase CDP and Pimlico both support it on Base.
- **Session keys (P3+).** Adding ZeroDev Kernel for session-key UX requires upgrading the smart account from SimpleAccount to Kernel — a moderate refactor at P3 time. Worth revisiting when the dApp is underway, not now.

---

## 5. Verdict

### Roadmap Phase Fit

| Component | Phase | Go/No-Go | Priority |
|---|---|---|---|
| Deploy to Base Sepolia (testnet) | **P1** | **GO** | **1** |
| Custom errors gas optimization | **P1** | **GO** | **2** |
| Base Mainnet deploy | **P3** | GO (when P3 starts) | 2 |
| Gasless funder UX (AA paymaster) | **P3** | GO (when frontend exists) | 3 |
| Session keys | **P3+** | Defer — revisit at P3 | 4 |
| EIP-7702 delegation | **P3+** | Defer — Pectra is live but tooling is maturing | 5 |

### Headline

**Deploy to Base Sepolia for P1. The L2 choice is Base (mainnet/testnet) with no hesitation: first-party Coinbase paymaster, largest L2 ecosystem, OP-stack EVM parity, and near-zero fees make it the right home for this product. Gas savings (custom errors) are a 1-day S-effort improvement before any deploy. Gasless UX via permissionless.js + Coinbase CDP Paymaster is the right P3 approach, requires zero contract changes, and slots cleanly into the existing viem stack. No action needed until P3 has a frontend.**

- **Effort:** S (Base Sepolia deploy + custom errors) / M (gasless UX at P3)
- **Phase:** P1 (deploy + gas) / P3 (gasless UX)
- **Go/No-Go:** GO on Base Sepolia now; GO on gasless at P3
- **Priority:** 1 (testnet), 2 (gas opts), 3 (gasless UX)

---

## Sources

- [Top Ethereum Gas Fee Solutions in 2026 — Bitcoin Foundation](https://bitcoinfoundation.org/news/ethereum/top-ethereum-gas-fee-solutions-in-2026-how-cheap-is-eth-now/)
- [Gas Fee Markets on Layer 2 Statistics 2026 — CoinLaw](https://coinlaw.io/gas-fee-markets-on-layer-2-statistics/)
- [Which Blockchain Has the Lowest Fees in 2026 — Bleap Finance](https://www.bleap.finance/en-us/blog/which-blockchain-has-the-lowest-fees)
- [Arbitrum vs Optimism 2026 — Pixelplex](https://pixelplex.io/blog/arbitrum-vs-optimism/)
- [Layer 2 Battles: Base vs. Arbitrum vs. Optimism — 0xProcessing](https://0xprocessing.com/blog/layer-2-battles-base-vs-arbitrum-vs-optimism-which-is-best-for-merchant-payments/)
- [Base vs Arbitrum 2026 — Eco](https://eco.com/support/en/articles/15183718-base-vs-arbitrum-2026-which-l2-fits-your-use-case)
- [Base TVL and Network Growth — CoinLedger](https://coinledger.io/research/base-tvl-and-network-growth)
- [Base's $20B TVL Goal — MEXC News](https://www.mexc.co/news/109750)
- [Network Faucets — Base Documentation](https://docs.base.org/base-chain/network-information/network-faucets)
- [Coinbase Paymaster Documentation](https://docs.cdp.coinbase.com/paymaster/introduction/welcome)
- [ERC-4337 Account Abstraction Explained — Eco](https://eco.com/support/en/articles/15254036-what-is-erc-4337-account-abstraction-explained-2026)
- [Account Abstraction Stack 2026 — Eco](https://eco.com/support/en/articles/15254046-account-abstraction-stack-2026-bundlers-paymasters-factories)
- [ERC-4337 — Pimlico Docs](https://docs.pimlico.io/guides/conceptual/account-abstraction)
- [permissionless.js — GitHub](https://github.com/pimlicolabs/permissionless.js/)
- [permissionless — npm](https://www.npmjs.com/package/permissionless)
- [Tutorial 1: Send your first gasless transaction — Pimlico Docs](https://docs.pimlico.io/guides/tutorials/tutorial-1)
- [Permissionless.js Quickstart — Safe Docs](https://docs.safe.global/advanced/erc-4337/guides/permissionless-quickstart)
- [What are Meta Transactions (ERC-2771)? — Alchemy](https://www.alchemy.com/overviews/meta-transactions)
- [Relaying gasless meta-transactions — OpenZeppelin Docs](https://docs.openzeppelin.com/defender/guide/meta-tx)
- [EIP-7702 Explained: Smart EOAs in 2026 — Openfort](https://www.openfort.io/blog/eip-7702)
- [Secure Temporary Permissions with EIP-7702 Session Keys](https://smartagentkeys.com/2026/02/04/secure-temporary-permissions-in-smart-wallets-using-eip-7702-session-keys)
- [ZeroDev Permissions (Session Keys)](https://docs.zerodev.app/smart-wallet/permissions/intro)
- [ZeroDev Integration Guide — Arbitrum Docs](https://docs.arbitrum.io/for-devs/third-party-docs/ZeroDev/zero-dev)
- [Best Smart Wallet SDKs for Developers 2026 — Eco](https://eco.com/support/en/articles/14797815-best-smart-wallet-sdks-for-developers-2026)
- [What Is a Paymaster? Gas Sponsorship Explained 2026 — Eco](https://eco.com/support/en/articles/15254040-what-is-a-paymaster-gas-sponsorship-explained-2026)
- [Arbitrum One Gas Tracker — Arbiscan](https://arbiscan.io/gastracker)
- [Gas Optimization In Solidity — Hacken](https://hacken.io/discover/solidity-gas-optimization/)
- [Day 24: Optimizing Gas with Custom Errors — CoinsBench](https://coinsbench.com/day-24-optimizing-gas-in-solidity-with-custom-errors-and-reverts-0835a0cd1434)
- [Polygon PoS vs Polygon zkEVM Comparison — Moralis](https://moralis.com/whats-the-difference-between-polygon-pos-vs-polygon-zkevm/)
- [Base Sepolia Testnet — Thirdweb](https://thirdweb.com/base-sepolia-testnet)
- [Test Networks — Base Documentation](https://docs.base.org/learn/deployment-to-testnet/test-networks)
- [Ethereum Testnets Guide 2026](https://theethereum.wiki/learn/ethereum-testnets-guide/)
