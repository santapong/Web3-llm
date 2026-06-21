# Research Report #04 — Automated Settlement Keepers (P1)

**Area:** Auto-calling `settle()` once the challenge window expires, with no human in the loop.  
**Roadmap phase:** P1 — Live on testnet, end-to-end, hands-off  
**Priority:** 1 (blocks P1 gate; straightforward to ship)  
**Effort:** S  
**Go/No-go:** GO

---

## 1. What & Why for web3-llm

### The gap

`StakedBountyEscrow.settle(uint256 id)` is **permissionless** — anyone may call it once `block.timestamp > challengeDeadline`. The contract is already correct; the gap is purely operational: after the resolver posts a verdict with `submitVerdict`, the challenge window opens (e.g. 24 h) and then nothing automatically finalizes the bounty. A human must currently call `settle` by hand. That makes P1's "fully unattended" gate impossible to clear.

### Why it matters

- The P1 kill-gate is: *"a real bounty created → judged → challenge window → settled, fully unattended, with reasoning readable on-chain."* Without auto-settle this gate literally cannot pass.
- The commercial story (DAO/grant-program settlement) breaks if a DAO treasurer must babysit a `settle` call. Automation here is not polish — it is the product.
- The contract already has a `VerdictProposed` event that carries `challengeDeadline`. Any keeper strategy can latch directly onto that event, making the wiring clean.

### What the contract requires

```solidity
function settle(uint256 id) external nonReentrant {
    Bounty storage b = bounties[id];
    require(b.status == Status.Proposed, "not settleable");
    require(block.timestamp > b.challengeDeadline, "window open");
    // ... pays out
}
```

`settle` has no access control — `msg.sender` can be any address, including a keeper's relayer or the resolver itself. There is no gas griefing risk because the function does real work (it pays out ETH) and there is nothing a caller can gain by front-running or back-running. The only live risk is **liveness failure** (nobody calls settle), not a security risk from permissionlessness.

---

## 2. How the Leaders Do It

### 2a. Chainlink Automation (formerly Keepers)

**How it works:** Smart contracts register as *upkeeps* on Chainlink's registry. A decentralized network of keeper nodes calls `checkUpkeep` (a view) off-chain every block; when it returns `true`, the network executes `performUpkeep` on-chain via an OCR3-secured committee.

Two modes are relevant:
- **Time-based:** Register a cron expression; Chainlink calls a named function on schedule. Best for "sweep all expired bounties every hour."
- **Custom logic:** The target contract implements `IAutomationCompatible` (`checkUpkeep` / `performUpkeep`); condition can be anything a view function can compute, e.g. iterate open bounties and return the first expired one.

**Cost model:** Upkeeps are funded in LINK (ERC-677). The fee is `gasUsed × gasPrice × (1 + premium%) / LINK_native_rate` plus a small flat per-execution fee. The premium varies by chain (e.g. 20–70%); on Sepolia testnet there is a nominal 0.01 LINK flat fee per execution. LINK must be swapped from ERC-20 via PegSwap on mainnet. On testnet LINK is freely available from the [Chainlink faucet](https://faucets.chain.link/).

**Decentralization:** OCR3 committee of independent nodes; no single point of failure. Strong uptime guarantees; used by Aave, Synthetix, Compound, and hundreds of DeFi protocols.

**Multi-chain:** Ethereum, Arbitrum, Optimism, Polygon, Avalanche, BNB Chain, Base, and more. Sepolia is supported. ([docs.chain.link](https://docs.chain.link/chainlink-automation))

**Security risk for web3-llm:** Zero. `settle` is permissionless so there is no privilege to steal. The worst a failed keeper run can do is delay settlement until the next execution.

**Friction/downside:** Requires LINK tokens even on Sepolia (free from faucet, but still a dependency). If the target contract needs `IAutomationCompatible`, that requires a Solidity change. The time-based variant avoids the interface requirement. New sign-ups and usage on Sepolia are available today.

Sources: [Chainlink Automation](https://chain.link/automation) · [Automation docs](https://docs.chain.link/chainlink-automation) · [Supported networks](https://docs.chain.link/chainlink-automation/overview/supported-networks) · [Economics](https://docs.chain.link/chainlink-automation/overview/automation-economics)

---

### 2b. Gelato Network / Web3 Functions

**How it works:** Gelato runs a network of executor bots ("Gelato nodes") that pick up *tasks* registered by developers. Two automation products are relevant:
- **Automate (on-chain trigger):** Register a Solidity resolver function that returns `(bool canExec, bytes calldata execPayload)`; Gelato calls it off-chain and executes `execPayload` when `canExec == true`. Analogous to Chainlink's custom logic.
- **Web3 Functions:** Off-chain TypeScript/JavaScript functions deployed to Gelato's decentralized cloud. They can call APIs, read chain state, and emit a transaction. Think serverless function that fires an on-chain tx. Supports both time-interval (every N seconds/minutes) and cron expressions.

Gelato supports gasless/sponsored execution via its **Relay** API — the developer pre-funds a 1Balance account in USDC and Gelato pays gas. There is no native token requirement.

**Decentralization:** Gelato's executor network is semi-decentralized — a curated set of whitelisted executor nodes, not fully open. This is a tradeoff: higher reliability and lower latency than a fully open keeper network, but somewhat centralized trust. Gelato is used by 500+ projects across 100+ chains.

**Multi-chain:** Ethereum, Arbitrum, Polygon, BNB Chain, Optimism, Base, zkSync, and many L2s. Sepolia is explicitly supported as the recommended Ethereum testnet. ([gelato.network/web3-functions](https://www.gelato.network/web3-functions))

**Cost model:** 1Balance (USDC-denominated pre-paid gas abstraction). Web3 Functions have compute limits (CPU/memory); simple `settle` calls are well within them.

**Security risk for web3-llm:** Same as above — `settle` is permissionless so Gelato can't do harm. A compromised Gelato executor cannot call anything else on the contract.

**Friction/downside:** Slightly more centralized than Chainlink. Web3 Functions require deploying a TS function to Gelato's CDN (IPFS-pinned). The TypeScript stack matches the resolver's existing stack.

Sources: [Gelato Web3 Functions](https://www.gelato.network/web3-functions) · [Automate blog](https://gelato.cloud/blog/automate-smart-contract-executions) · [Rootstock guide](https://rootstock.io/blog/guide-to-getting-started-with-gelato-web3-functions/)

---

### 2c. OpenZeppelin Defender (Autotasks / Actions)

**How it works:** Defender Actions are serverless Node.js snippets that run in OZ's cloud infrastructure, triggered by schedule (cron), Sentinel events, or webhook. An Action can use a Defender Relayer to submit transactions without exposing a private key in the function code.

**Status: DEAD END — shutting down July 1, 2026.** OZ announced ([announcement](https://www.openzeppelin.com/news/doubling-down-on-open-source-and-phasing-out-defender)) they are phasing out Defender and releasing open-source versions of Relayer and Monitor. New sign-ups were disabled June 30, 2025. **Do not build on Defender.** OZ's own recommendation is to self-host the open-source Relayer + Monitor, or migrate to Chainlink/Gelato.

If needed in future, the OZ open-source Relayer (self-hosted) is a viable key-management component to pair with a self-hosted cron bot (see §2e).

Sources: [OZ Defender sunset](https://www.openzeppelin.com/news/doubling-down-on-open-source-and-phasing-out-defender) · [Defender sunset FAQ](https://www.openzeppelin.com/news/defender-sunset-faq)

---

### 2d. Powerpool / PowerAgent V2

**How it works:** PowerAgent V2 is a decentralized keeper network where nodes stake CVP tokens to earn execution fees. Jobs are registered on-chain; keepers execute them and are rewarded in native gas token + job fees. Mainnet launched December 2023; deployed on Ethereum, Gnosis, Arbitrum, Polygon, Base.

**Suitability for web3-llm:** Low. PowerAgent is a DePIN (Decentralized Physical Infrastructure Network) product aimed at protocols that want keeper decentralization as a core feature (e.g. vault rebalancers, liquidators). It introduces a native token dependency (CVP) and a more complex job registration flow. It is less battle-tested at the application layer than Chainlink or Gelato. Its competitive advantage (trustless staking/slashing of keepers) does not materially matter here — `settle` is permissionless so there is no trust lift from keeper decentralization.

**Verdict for web3-llm:** Skip unless you need the DePIN decentralization story for marketing. Adds complexity with no corresponding value.

Sources: [PowerPool PowerAgent](https://powerpool.finance/power-agent/) · [PowerPool docs](https://docs.powerpool.finance/)

---

### 2e. Self-Hosted Viem Cron Bot

**How it works:** A TypeScript service — runnable alongside the existing resolver process, or as a separate worker — that:
1. Maintains a `Map<bigint, bigint>` of `bountyId → challengeDeadline` populated by listening to `VerdictProposed` events via `publicClient.watchContractEvent`.
2. Runs a `setInterval` (or `node-cron`) loop, e.g. every 5 minutes.
3. On each tick, checks which deadlines have passed and calls `chain.settle(id)` for each.

The resolver's `ViemEscrowChain` already has a `settle(id)` method (`resolver/src/chain.ts` line 61–68). The `EscrowChain` interface already declares `settle`. This is literally wiring a timer to an existing method with a deadline check.

**Reliability:** Depends entirely on the hosting environment. If the resolver process dies, `settle` never fires until it restarts (and replays `VerdictProposed` events from `startBlock`). For testnet/P1, this is acceptable. For production, a self-hosted process with a systemd/pm2 supervisor and a dead-man alert is sufficient. It is the most fragile option at scale but the simplest to implement.

**Cost:** Just gas (ETH) from the resolver's existing wallet. No third-party token or subscription.

**Decentralization:** Fully centralized — single operator. Acceptable for P1; a risk to disclose in the security model for P3+.

**Security:** The only threat is **liveness** (keeper goes down). `settle` cannot be griefed (it has real economic effect; no exploit). Front-running by a third party is harmless — if someone else calls `settle`, it succeeds and the bounty closes correctly.

**Implementation fit:** Directly in `resolver/src/` with zero new dependencies (viem is already present; `setInterval` is Node built-in). The existing `EscrowChain` interface needs one additional method or the watcher can read `VerdictProposed` events directly via `publicClient.getLogs`.

---

## 3. Recommended Approach in This Stack

### Recommendation: Self-Hosted Viem Cron Bot (for P1), with Gelato as the P3 upgrade path

**For P1 (testnet, hands-off demo):** Implement the cron bot directly inside the resolver service. This is the right call because:

1. **Zero new dependencies.** viem `^2.52.0` is already in `package.json`. Node's `setInterval` needs nothing.
2. **Already have the scaffolding.** `ViemEscrowChain.settle(id)` exists at `resolver/src/chain.ts:61`. `VerdictProposed` is in the ABI at `resolver/src/abi.ts`.
3. **Matches the P1 scope.** P1 is testnet + internal demo. A self-hosted keeper with a pm2/Docker restart policy is entirely adequate.
4. **Keeps it auditable.** The settle logic lives in the same codebase, same language, same test suite.

**For P3 (productize, third-party funders):** Add a Gelato Web3 Function as a backup/redundant keeper. By P3, the TypeScript Web3 Functions model maps naturally onto the resolver codebase, supports Sepolia → mainnet migration, and removes single-operator liveness risk. Gelato's 1Balance gas model avoids LINK token management.

**Do not use Chainlink Automation for P1** unless the team already has LINK tokens on Sepolia and wants to evaluate Chainlink integration for marketing purposes. The setup overhead (LINK token, upkeep registration UI, optional contract interface change) is not justified vs. the cron bot for P1.

**Do not use OpenZeppelin Defender** — it shuts down July 1, 2026, which is today.

### Concrete Implementation Plan

#### New file: `resolver/src/settler.ts`

```typescript
import type { EscrowChain } from "./chain.js";
import type { Logger } from "./resolver.js";

/** Watches VerdictProposed events and calls settle() after the challenge window. */
export class Settler {
  // bountyId → unix deadline (seconds)
  private readonly pending = new Map<bigint, bigint>();
  private timer?: ReturnType<typeof setInterval>;
  private readonly log: Logger;

  constructor(
    private readonly chain: EscrowChain,
    opts: { log?: Logger } = {},
  ) {
    this.log = opts.log ?? { info: console.log, error: console.error };
  }

  /** Track a newly proposed verdict. */
  track(id: bigint, challengeDeadline: bigint): void {
    this.pending.set(id, challengeDeadline);
    this.log.info(`settler: tracking bounty #${id}, deadline ${new Date(Number(challengeDeadline) * 1000).toISOString()}`);
  }

  /** Remove a settled or disputed bounty from the queue. */
  untrack(id: bigint): void {
    this.pending.delete(id);
  }

  /** Start the settlement loop. Checks every `intervalMs` (default 5 min). */
  start(intervalMs = 5 * 60 * 1000): void {
    this.timer = setInterval(() => void this.sweep(), intervalMs);
    this.log.info(`settler: loop started (interval ${intervalMs / 1000}s)`);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  private async sweep(): Promise<void> {
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    for (const [id, deadline] of this.pending) {
      if (nowSec <= deadline) continue;
      this.pending.delete(id); // remove before the async call so a slow RPC can't double-settle
      try {
        const tx = await this.chain.settle(id);
        this.log.info(`settler: settled bounty #${id} tx ${tx}`);
      } catch (err) {
        this.log.error(`settler: failed to settle bounty #${id} — ${(err as Error).message}`);
      }
    }
  }
}
```

#### Changes to `resolver/src/chain.ts`

The `EscrowChain` interface already declares `settle(id: bigint): Promise<Hex>`. To replay past `VerdictProposed` events on startup (so bounties that proposed before the settler started are not lost), add one method:

```typescript
// In EscrowChain interface:
getPastProposedVerdicts(fromBlock: bigint): Promise<Array<{ id: bigint; challengeDeadline: bigint }>>;

// In ViemEscrowChain:
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

#### Changes to `resolver/src/index.ts`

Wire the `Settler` into `main()` alongside the existing `Resolver`:

```typescript
import { Settler } from "./settler.js";
// ...

const settler = new Settler(chain);

// Replay past VerdictProposed events so any in-window bounties are tracked.
if (config.startBlock !== undefined) {
  const proposed = await chain.getPastProposedVerdicts(config.startBlock);
  for (const { id, challengeDeadline } of proposed) settler.track(id, challengeDeadline);
}

// Watch for new VerdictProposed events.
chain.watchVerdictProposed(({ id, challengeDeadline }) => settler.track(id, challengeDeadline));

settler.start(); // defaults to 5-minute sweep interval

const shutdown = () => {
  settler.stop();
  unwatch();
  process.exit(0);
};
```

#### ABI note

`resolver/src/abi.ts` must include the `VerdictProposed` event. Verify it contains:
```
{ type: "event", name: "VerdictProposed", inputs: [
  { name: "id", type: "uint256", indexed: true },
  { name: "fulfilled", type: "bool", indexed: false },
  { name: "challengeDeadline", type: "uint64", indexed: false },
  { name: "reasoning", type: "string", indexed: false }
]}
```

#### Gelato upgrade path (P3)

When the team is ready to remove single-operator liveness risk:

1. Create a Gelato Web3 Function in `resolver/src/keeper/gelato-settle.ts` — a TypeScript function that reads open bounties from the RPC, finds expired ones, and returns `{ canExec: true, callData: encodeSettle(id) }`.
2. Deploy it via `npx @gelatonetwork/web3-functions-sdk`. No contract changes needed.
3. Fund a [1Balance](https://app.gelato.network/funds) account in USDC for gas.
4. Keep the self-hosted cron bot as a fallback; the two are safely idempotent (a second `settle` call reverts with "not settleable" once the first succeeds).

---

## 4. Effort, Dependencies, Risks

| Dimension | Detail |
|---|---|
| **Effort** | S — est. 4–6 hours: ~100 lines of TypeScript, one new file (`settler.ts`), small changes to `chain.ts` and `index.ts`, unit tests with a fake `EscrowChain`. |
| **Dependencies** | None new. viem already in `package.json`. No tokens, no third-party accounts, no Solidity changes. |
| **Hosting risk (P1)** | Process crash = liveness gap. Mitigate: `pm2`/Docker restart policy; `RESOLVER_START_BLOCK` replay recovers in-flight bounties on restart. |
| **Double-settle safety** | Idempotent by contract: second `settle` call reverts with "not settleable" (status is already `Settled`). No ETH risk. |
| **Front-run / griefing** | None. `settle` is permissionless and does real work; no MEV surface. If a third party settles first, outcome is correct and our call cleanly reverts. |
| **Clock drift** | The checker uses `Date.now()` (wall clock). A small drift vs. `block.timestamp` is fine: a few seconds of slack before calling settle is safe, and the deadline check is conservative (we only call when `nowSec > deadline`, not `>=`). |
| **Key management** | Settler reuses the resolver's existing private key (`RESOLVER_PRIVATE_KEY`). No new key needed. |
| **Gelato migration (P3)** | M — est. 1–2 days. Requires Gelato account, 1Balance USDC funding, Web3 Functions SDK, no Solidity changes. |

### What this does NOT require

- No Solidity contract changes.
- No LINK tokens.
- No new npm packages for P1.
- No Chainlink registration UI.
- No OpenZeppelin Defender (defunct).

---

## 5. Verdict — Roadmap Phase, Go/No-Go, Priority

| Attribute | Value |
|---|---|
| **Roadmap phase** | P1 (blocks the "fully unattended" kill-gate) |
| **Go/No-go** | **GO** — straightforward, zero blockers |
| **Priority** | **1** (highest) — without this, P1 cannot pass; everything downstream depends on a working end-to-end loop |
| **Effort** | **S** (~100 lines of TS, no new deps, no contract changes) |

### Summary reasoning

The self-hosted viem cron bot is the right call for P1 because the constraint is time, not decentralization. The resolver service already has `settle()` on the `EscrowChain` interface, the wallet, and the event subscription primitives. The only missing piece is a timed sweeper — a `Map` and a `setInterval`. This is a P1 blocker that should ship in hours, not days.

Gelato Web3 Functions is the right P3 upgrade: TypeScript-native, Sepolia-ready, no LINK dependency, and it adds liveness redundancy without a contract change. Add it when the product moves toward third-party funders who cannot tolerate single-operator downtime.

Chainlink Automation is the right answer if the team wants maximum decentralization guarantees or plans to use Chainlink for other oracle services (price feeds, VRF). Worth benchmarking at P3 alongside Gelato.

Powerpool is not worth the additional token dependency for this use case. OpenZeppelin Defender is dead (EOL July 1, 2026).

---

*Research conducted June 2026. Sources: [Chainlink Automation](https://chain.link/automation) · [Chainlink docs](https://docs.chain.link/chainlink-automation) · [Chainlink Economics](https://docs.chain.link/chainlink-automation/overview/automation-economics) · [Gelato Network](https://www.gelato.network/web3-functions) · [Gelato automation blog](https://gelato.cloud/blog/automate-smart-contract-executions) · [OZ Defender sunset](https://www.openzeppelin.com/news/doubling-down-on-open-source-and-phasing-out-defender) · [OZ Defender sunset FAQ](https://www.openzeppelin.com/news/defender-sunset-faq) · [PowerAgent](https://powerpool.finance/power-agent/) · [PowerPool docs](https://docs.powerpool.finance/) · [viem](https://viem.sh/) · [Gelato Rootstock guide](https://rootstock.io/blog/guide-to-getting-started-with-gelato-web3-functions/)*
