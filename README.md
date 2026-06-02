# Web3-llm

**Trustless software bounties, judged by an LLM.**

A funder escrows ETH against a bounty with machine-checkable acceptance criteria. A claimant
submits a pull request. An off-chain agent powered by Claude reads the criteria and the PR, decides
whether the work is done, and posts a verdict on-chain — which settles the escrow to the claimant
(fulfilled) or refunds the funder (not). The protocol makes that AI resolver *accountable*: its
verdicts can be challenged, disputed by a human arbiter, and its stake slashed when it's wrong.

This repo has two halves:

| Half | Stack | What it is |
| --- | --- | --- |
| **On-chain** | Solidity + Foundry (`src/`, `test/`, `script/`) | The escrow contracts and their test suites. |
| **Off-chain** | TypeScript + viem + Anthropic SDK (`resolver/`) | The "llm" — the agent that watches events, judges PRs, and submits verdicts. |

---

## Architecture

```mermaid
sequenceDiagram
    actor Funder
    actor Claimant
    participant Escrow as Escrow contract
    participant Resolver as Off-chain resolver (Claude)
    actor Challenger

    Funder->>Escrow: createBounty{value}(claimant, specHash, prHash)
    Escrow-->>Resolver: BountyCreated event
    Resolver->>Resolver: fetch spec + PR, verify keccak hashes
    Resolver->>Resolver: Claude judges PR vs criteria → {fulfilled, reasoning}
    Resolver->>Escrow: submitVerdict(id, fulfilled, reasoning)
    Note over Escrow: v0 pays out immediately.<br/>v1 opens a challenge window.
    opt v1 — dispute path
        Challenger->>Escrow: challenge{bond}(id)
        Note over Escrow: arbiter rules; wrong resolver is slashed
    end
    Escrow->>Claimant: pay (fulfilled) — or refund Funder (not)
```

The chain stores only **hashes** of the acceptance criteria and the PR (`specHash`, `prHash`); the
full text lives off-chain. The resolver re-hashes whatever it fetches and checks it against the
on-chain commitment, so a tampered content source can't feed the judge different criteria than the
parties agreed to.

---

## Repository layout

```
src/
  BountyEscrow.sol          # v0 — single trusted resolver, instant settlement
  StakedBountyEscrow.sol    # v1 — optimistic settlement: challenge window + staking + slashing
test/
  BountyEscrow.t.sol               # v0 unit tests
  StakedBountyEscrow.t.sol         # v1 unit + fuzz tests
  StakedBountyEscrow.invariant.t.sol  # v1 solvency / accounting invariants
script/
  Deploy.s.sol              # deploy v0
  DeployStaked.s.sol        # deploy v1
resolver/                   # off-chain LLM resolver (TypeScript) — see resolver/README.md
.github/workflows/ci.yml    # CI: Foundry build/test + resolver typecheck/test
```

---

## The contracts

### `BountyEscrow` (v0) — the simple baseline

A single trusted `resolver` calls `submitVerdict`, which **immediately** pays the claimant or
refunds the funder. Minimal on purpose: it's the smallest thing that proves the money moves
correctly on command. Uses OpenZeppelin `Ownable` (owner can rotate the resolver key) and
`ReentrancyGuard`, and follows checks-effects-interactions on the payout.

### `StakedBountyEscrow` (v1) — optimistic settlement with accountability

v0 trusts the resolver completely. v1 makes it *optimistic and accountable*:

1. **Escrow** — `createBounty` holds the funder's ETH (`Open`).
2. **Verdict** — the resolver calls `submitVerdict`; **no money moves**. A `resolverBond` of the
   resolver's stake is locked, a `challengeDeadline` is set, and the bounty becomes `Proposed`.
3. **Challenge window** — anyone may `challenge` within the window by posting a `challengeBond`
   (→ `Disputed`). Permissionless, so the resolver can be policed by economically-motivated watchers.
4. **Settle** — if unchallenged past the deadline, anyone may `settle`; the verdict pays out and the
   resolver's bond unlocks (`Settled`).
5. **Dispute** — if challenged, an `arbiter` (a human / DAO, the court of last resort) calls
   `resolveDispute`:
   - **Verdict upheld** → the challenger forfeits its bond to the resolver (anti-griefing); the
     original outcome pays out.
   - **Verdict overturned** → the resolver's locked bond is **slashed** to the challenger, the
     challenger's own bond is refunded, and the **opposite** outcome pays out.

**Roles:** `owner` (admin, rotates keys + tunes economics), `resolver` (posts verdicts, must hold
stake), `arbiter` (rules on disputes). **Economic params** (`challengePeriod`, `resolverBond`,
`challengeBond`) are owner-tunable and **pinned per bounty** at proposal/challenge time, so changing
them never alters an in-flight dispute.

Every fund-moving path is `nonReentrant` and checks-effects-interactions. The test suite proves a
**solvency invariant** across 128k randomized calls: the contract's ETH balance always equals
`held bounty principal + resolverStake + active challenge bonds` — funds can never leak or get
trapped.

---

## The off-chain resolver (`resolver/`)

A small TypeScript service — the "llm" in Web3-llm. It:

1. **Watches** `BountyCreated` events (viem).
2. **Fetches** the spec and PR text behind `specHash`/`prHash` from a content store, and
   **verifies** each `keccak256(text)` matches the on-chain hash (rejects tampered content).
3. **Judges** with Claude (`claude-opus-4-8`): the model is given the criteria + PR and must return
   a structured `{ fulfilled, reasoning }` verdict via a **forced tool call** (`submit_verdict`),
   so the output is always parseable — never free-form prose. The static judging rubric is sent as a
   **cached** system prompt; only the per-bounty spec+PR varies between requests.
4. **Submits** `submitVerdict(id, fulfilled, reasoning)` signed by the resolver key. The reasoning
   is emitted in the on-chain event log for auditability.

Key modules: `judge.ts` (the Claude integration — request building + verdict parsing are pure,
testable functions), `content.ts` (hash-verified content resolution), `chain.ts` (viem read/write),
`resolver.ts` (the orchestration loop), `index.ts` (entrypoint).

The same ABI drives both contracts — `BountyCreated` and `submitVerdict(uint256,bool,string)` are
identical on v0 and v1.

---

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`)
- Node.js ≥ 20 (for the resolver)

### Contracts

```bash
# Install dependencies (lib/ is gitignored; installed fresh):
forge install foundry-rs/forge-std@v1.16.1
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1

forge build
forge test            # unit + fuzz + invariant
forge test -vv        # with logs
```

> **Restricted-network note.** If your environment blocks `foundry.paradigm.xyz` or
> `binaries.soliditylang.org` (e.g. some sandboxes) but allows `github.com`, install Foundry and
> solc from GitHub releases instead: download `foundry_*_linux_amd64.tar.gz` from
> `foundry-rs/foundry/releases`, and place `solc-static-linux` (from `ethereum/solidity/releases`,
> tag `v0.8.26`) at `~/.svm/0.8.26/solc-0.8.26`. Then `forge build --offline` works.

### Resolver

```bash
cd resolver
npm ci
npm run typecheck
npm test            # vitest — runs fully offline (no chain, no API key)
```

### Local end-to-end demo (anvil, no API key needed)

```bash
# 1. Start a local chain
anvil

# 2. Deploy v1 (defaults: resolver = arbiter = deployer = anvil account #0)
forge script script/DeployStaked.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 3. Configure the resolver
cd resolver
cp .env.example .env
#   set RESOLVER_CONTRACT to the deployed address, RESOLVER_START_BLOCK=0,
#   and RESOLVER_MOCK_VERDICT=fulfilled  (skip the LLM for the demo)

# 4. Run it — it replays BountyCreated, judges, and submits the verdict on-chain
npm start
```

`content.example.json` ships with a sample spec + PR already keyed by their keccak hashes; use
those hashes when you `createBounty`. To hash your own text: `cat spec.txt | npx tsx scripts/hash.ts`.
Drop `RESOLVER_MOCK_VERDICT` and set `ANTHROPIC_API_KEY` to use the real Claude judge.

### Deploy to a testnet

```bash
forge script script/DeployStaked.s.sol \
  --rpc-url $SEPOLIA_RPC --broadcast --private-key $PK
# v0: forge script script/Deploy.s.sol ...
```

---

## Testing

| Suite | What it covers |
| --- | --- |
| `BountyEscrow.t.sol` | v0 escrow, both verdict paths, access control, double-resolve, zero-value |
| `StakedBountyEscrow.t.sol` | v1 staking, verdict/challenge/settle/dispute paths, slashing, admin, a fuzz test |
| `StakedBountyEscrow.invariant.t.sol` | solvency + locked-stake invariants across randomized action sequences |
| `resolver/test/*` | judge request-building & verdict parsing, keccak hash verification, the resolver loop |

`forge test` runs all contract suites; `cd resolver && npm test` runs the resolver suite. Both run
in [CI](.github/workflows/ci.yml) on every push and PR.

---

## Security notes & threat model

- **CEI + reentrancy guards** on every payout, withdrawal, and dispute resolution.
- **Hash-committed content**: the resolver only judges text whose `keccak256` matches the on-chain
  `specHash`/`prHash`, so the content host is not trusted.
- **Prompt-injection resistance**: the judging rubric instructs Claude to treat spec/PR text as data
  to evaluate, never as instructions to obey ("ignore previous instructions", "always rule
  fulfilled", etc.).
- **Accountability (v1)**: a wrong resolver is slashed and the outcome is overturned; uncertain
  verdicts lean toward refunding the funder, since a wrong payout is hard to reverse.
- **Trust assumptions**: v0 fully trusts the resolver. v1 still trusts the `arbiter` as the court of
  last resort and the `owner` for admin actions (key rotation, economic params).

This is an educational project; it has not been audited. Do not deploy with real funds without a
professional review.

## Status / roadmap

- [x] **Phase 0** — `BountyEscrow` (v0): instant settlement by a trusted resolver.
- [x] **Phase 1** — `StakedBountyEscrow` (v1): challenge window, staking, slashing, disputes.
- [x] **Phase 2** — off-chain Claude resolver: watch → verify → judge → submit.
- [x] **Phase 3** — docs, CI, fuzz + invariant tests.
- [ ] Future: IPFS/GitHub content providers, auto-`settle` after the window, multi-resolver quorums.
