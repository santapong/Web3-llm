# Research #09 — On-chain Protocol Fee & Treasury (Monetization)

> Feature-researcher report for **web3-llm**.
> Roadmap area: monetization (complements P1–P3).
> Contract under analysis: `src/StakedBountyEscrow.sol`.

---

## 1. What & Why for web3-llm

### The gap

`StakedBountyEscrow` currently routes 100 % of the escrowed principal to either the
claimant (fulfilled) or the funder (refund). There is no on-chain mechanism to
retain any portion as platform revenue. STRATEGY.md names **per-settlement platform
fee + hosted judge SaaS** as the primary monetization model. The fee belongs on-chain
because:

- It is self-enforcing: the resolver or keeper cannot skip it.
- It is auditable: funders and claimants can verify the deduction before escrowing.
- It decouples off-chain SaaS billing from individual bounty flows — even self-hosted
  users contribute to sustainability.

### What "small fee" means here

STRATEGY.md targets 1–3 % of the payout. In basis-point (bps) language that is
100–300 bps. A 1 % fee on a $1,000 bounty is $10 — frictionless for a DAO treasurer
but meaningful at volume. The fee must not break the solvency invariant:

> `address(escrow).balance == resolverStake + Σ bounty.amount[live] + Σ challengeBondPaid[disputed]`

Because the fee is taken **at settle** (when `bounty.amount` leaves escrow), reducing
the payout by the fee amount keeps the invariant trivially intact — the escrow never
holds more than it owes.

### Design decisions to resolve

| Question | Options | Recommendation (see §3) |
|---|---|---|
| Fee unit | bps of payout vs flat ETH | **bps of payout** |
| Taken at | `createBounty` vs `settle`/`resolveDispute` | **settle** |
| Who pays | funder (pre-deducted) vs claimant (deducted at payout) | **claimant** (on fulfilled), funder implicit on refund |
| Rate control | immutable / owner-settable / governance-gated | **owner-settable with hard cap** |
| Treasury | raw EOA / Safe multisig / OZ `Ownable` payable address | **Safe multisig address stored as `feeRecipient`** |

---

## 2. How the Leaders Do It

### 2a. Uniswap v2/v3 — the "fee switch"

Uniswap's protocol fee is architecturally a fraction of the LP trading fee, set via
governance. In v2, the fee switch could divert 1/6 of the 0.3 % swap fee (~0.05 %)
to a `feeTo` address controlled by governance. In v3, pools carry a
`protocolFees{Token0,Token1}` accumulator; a governance call sets the fraction (0 or
some bps) and a separate `collectProtocol` function pulls accrued fees to the
governance treasury.

In December 2025, Uniswap governance passed the "UNIfication" proposal with 99 %
approval: LP fees became 0.25 % and protocol fees 0.05 % (a 1/5 split), routing to a
burn mechanism rather than a DAO treasury wallet. The fee switch itself — the boolean
or fraction controlling fee collection — is governed by an on-chain
`TimelockController` before execution.

**Lessons for web3-llm:**
- The fee parameter (here: bps rate) lives in contract storage, settable by owner.
- Governance delay (timelock) on rate changes builds trust — no rug-the-fee surprises.
- Accumulate fees in a dedicated recipient, not commingled with the main escrow
  balance.

Sources:
- [Uniswap UNIfication blog post](https://blog.uniswap.org/unification)
- [CoinDesk: UNI burn and fee switch voted in](https://www.coindesk.com/markets/2025/12/22/uniswap-token-burn-moves-closer-to-reality-as-99-of-voters-in-favor-of-fee-switch-proposal)
- [Uniswap Fee Switch Explained](https://web.ourcryptotalk.com/blog/uniswap-fee-switch-change-explained)

---

### 2b. Aave v3 — protocol revenue collector

Aave v3 accumulates borrow interest, flash-loan fees (0.09 % of flash amount),
liquidation bonuses, and Chainlink SVR MEV recapture into an on-chain
`AaveEcosystemReserve` (a treasury contract). Governance can then direct that
treasury (e.g., to fund a $50 M/year UNI buyback approved in April 2025, or to pay
Safety Module yields). The fee rate on flash loans is a constant in the protocol; the
split between LP depositors and treasury is a governance parameter.

**Lessons for web3-llm:**
- Fees accumulate in a dedicated contract (treasury), not sent to an EOA.
- The treasury is governed separately from day-to-day protocol operations.
- Multiple revenue streams (flash loan, interest spread) all funnel to the same
  treasury address — simplifies accounting.

Sources:
- [Aave fee distribution plan (beincrypto)](https://beincrypto.com/aave-fee-switch-proposal/)
- [DeFiLlama Aave V3 revenue](https://defillama.com/protocol/aave-v3)

---

### 2c. 0x Protocol v4 — per-fill fee collectors

0x routes protocol fees into a set of `FeeCollector` contracts (one per Staking Pool).
The taker pays the fee in ETH proportional to gas price at fill time, making it a
variable but bounded gas-scaled amount. The `ZeroExGovernor` (a timelock multisig)
can update the `protocolFeeCollector` address. Fees accumulate in the collector and
are periodically swept into the staking system.

**Lessons for web3-llm:**
- The fee recipient is a separate contract, not an EOA, for security and governance.
- The `protocolFeeCollector` address is updatable (analogous to `feeRecipient` we
  will add to `StakedBountyEscrow`).
- Gas-scaled fees work for DEX fills but not escrow settlement — bps of payout is
  the right model here.

Sources:
- [0x Protocol fee collectors docs](https://docs.0xprotocol.org/en/latest/architecture/fee_collectors.html)
- [0x Protocol fees overview](https://docs.0xprotocol.org/en/development/basics/protocol_fees.html)
- [0x future-proofing fee discussion](https://forum.0xprotocol.org/t/future-proofing-the-protocol-fee/927)

---

### 2d. Gitcoin Allo Protocol — base fee + percentage fee

Allo Protocol (Gitcoin's grants infrastructure, in maintenance mode as of May 2025)
combined two on-chain fee mechanisms:

1. **Base fee**: flat ETH charged at `createPool()` (set to 0 ETH at launch).
2. **Percentage fee (~2.5 %)**: deducted from `fundPool()` calls and sent to the
   treasury before the remainder is credited to the pool.

Both parameters were owner-settable and exposed as public state variables. The fee
was taken from the funding inflow before it was credited to the pool — the pool's
internal accounting never saw the fee amount, keeping invariants clean. This is the
cleanest pattern reference for web3-llm.

Sources:
- [Allo fees documentation](https://docs.allo.gitcoin.co/allo/fees)
- [Allo Protocol Gitcoin overview](https://www.gate.com/learn/articles/allo-protocol-for-gitcoin-protocol-layer-infrastructure-for-community-grants-program/2358)
- [Allo Protocol page](https://gitcoin.co/apps/allo-protocol)

---

### 2e. Gnosis Safe / Safe{Wallet} as protocol treasury

The industry standard for protocol treasury ownership: a Safe m-of-n multisig (e.g.,
3-of-5) owns the treasury EOA or contract. Uniswap DAO uses a 4-of-7 Safe managing
>$2 B. Aave and Synthetix also rely on Safe. In a small team or early-stage protocol
the simplest form is a 2-of-3 Safe whose signers hold the `owner` role of the escrow
contract. The Safe receives fees passively (ETH pushed to it) or actively sweeps them.

Sources:
- [Safe as protocol treasury (4pillars)](https://4pillars.io/en/articles/safe-ownership-infra-layer-for-onchain-applications)
- [Gitcoin multisig treasury mechanism](https://gitcoin.co/mechanisms/multisig-treasury)
- [Safe.global](https://safe.global/)

---

## 3. Recommended Approach in This Stack

### 3a. Fee design

**Basis points of payout, taken at settlement, deducted from the claimant's proceeds
on a `fulfilled` outcome; deducted from the refund on a `!fulfilled` outcome (or
absorbed entirely by the protocol as a fee from escrowed principal).**

The simplest and most trust-preserving form: **fee is always deducted from whatever
leaves the escrow on settlement**, regardless of outcome. This means:

- Claimant receives `amount - fee` on `fulfilled`.
- Funder receives `amount - fee` on `!fulfilled` (refund).
- `fee = (amount * feeBps) / 10_000`, where `feeBps` is stored in contract state.
- Fee is pushed immediately to `feeRecipient` during the settle interaction.

**Why not at `createBounty`?**
A flat fee at create would be simpler but raises the question of refunding it on a
disputed/refunded bounty. Deducting at settle avoids any fee-refund logic and applies
symmetrically to all outcomes.

**Why bps over flat?**
Flat fees favor large bounties (low relative cost) and penalize small ones (high
relative cost). BPS scales proportionally, keeping the platform accessible for small
DAO grants and sensibly remunerative for large ones.

**Solvency invariant preservation:**
The invariant `address(escrow).balance == resolverStake + Σ b.amount[live] + Σ challengeBondPaid[disputed]`
is preserved because:
- The fee is deducted from `b.amount` at the point of payout; the escrow's balance
  decreases by exactly `b.amount` (fee routed out) and the bounty moves to `Settled`.
- The fee is never accumulated in escrow storage — it flows out immediately to
  `feeRecipient`.

**Updated solvency invariant (new test form):**
```
address(escrow).balance == resolverStake
    + Σ b.amount[Open | Proposed | Disputed]
    + Σ b.challengeBondPaid[Disputed]
// fee is transient; it exits the contract in the same call it's computed,
// so it is never part of the escrow balance after any settled step.
```

The invariant test in `test/StakedBountyEscrow.invariant.t.sol` requires **no
changes** to its formula — `b.amount` for live bounties still sums correctly, and
settled bounties are excluded. The handler needs a `feeBps` and `feeRecipient` set in
`setUp()` so the invariant holds under the new code.

### 3b. Fee cap and fee switch

```solidity
uint16 public constant MAX_FEE_BPS = 500;   // 5 % hard ceiling, immutable
uint16 public feeBps;                        // current rate (0 = fee off)
address public feeRecipient;                 // treasury (Safe multisig address)
```

- **`feeBps = 0` is the "fee off" switch.** No conditional branch needed: `0 * amount / 10_000 == 0`.
- **`MAX_FEE_BPS = 500`** (5 %) is an immutable constant that `setFee()` enforces.
  This hard-codes a trust bound funders can read in the source: no matter what
  governance does, the fee can never exceed 5 %.
- `setFee()` and `setFeeRecipient()` are `onlyOwner`. If the owner is a Safe
  multisig this is already multi-party governed.
- A timelock wrapper (OZ `TimelockController`) on the owner address is optional at
  P1/P2 but recommended before mainnet scale (P3): any fee change requires a 48 h
  delay, giving users time to exit.

### 3c. Treasury pattern

For P1–P2 (testnet / early mainnet): owner = deployer EOA, `feeRecipient` = team
2-of-3 Safe multisig. Fee is pushed as ETH with `_send(feeRecipient, fee)` in the
same CEI pass as the bounty payout.

For P3+ (productized): transfer ownership to a `TimelockController` whose proposer
is the Safe. The Safe proposes `setFee()` calls; after 48 h they execute. The
`feeRecipient` can be an OZ `PaymentSplitter` if revenue sharing across team members
is needed, but a simple Safe suffices initially.

**Do NOT use `Ownable`'s `transferOwnership` to set the fee recipient.** Keep
`feeRecipient` as a separate state variable: the fee recipient (treasury) and the
contract operator (owner) serve different security roles and may need to be different
addresses.

### 3d. Exact contract changes to `src/StakedBountyEscrow.sol`

#### New state variables (add after existing params block, line ~64):

```solidity
// --- protocol fee ---
uint16 public constant MAX_FEE_BPS = 500;   // 5 % hard cap, immutable
uint16 public feeBps;                        // 0 = fee off; max MAX_FEE_BPS
address public feeRecipient;                 // protocol treasury (Safe multisig)

event FeeUpdated(uint16 feeBps, address feeRecipient);
```

#### New admin function (add alongside `setParams`):

```solidity
/// @notice Update the protocol fee. feeBps = 0 disables the fee.
/// feeRecipient must be non-zero whenever feeBps > 0.
function setFee(uint16 _feeBps, address _feeRecipient) external onlyOwner {
    require(_feeBps <= MAX_FEE_BPS, "fee exceeds cap");
    require(_feeBps == 0 || _feeRecipient != address(0), "need recipient");
    feeBps   = _feeBps;
    feeRecipient = _feeRecipient;
    emit FeeUpdated(_feeBps, _feeRecipient);
}
```

#### Modified `_payout` internal (lines 286–291 in current file):

```solidity
function _payout(uint256 id, Bounty storage b, bool outcome) internal {
    address recipient = outcome ? b.claimant : b.funder;
    uint256 principal = b.amount;

    uint256 fee;
    if (feeBps > 0 && feeRecipient != address(0)) {
        fee = (principal * feeBps) / 10_000;
    }
    uint256 net = principal - fee;

    // INTERACTIONS: send fee first (external call), then payout (external call).
    // Both guarded by nonReentrant on the callers (settle / resolveDispute).
    if (fee > 0) _send(feeRecipient, fee);
    _send(recipient, net);

    emit Settled(id, outcome, recipient, net);
}
```

**Note on CEI:** `_payout` is always called from `settle` or `resolveDispute`, both
of which are `nonReentrant` and complete all EFFECTS before calling `_payout`. The
two `_send` calls inside `_payout` are both INTERACTIONS happening after state is
already finalized — this is safe under the existing guard.

#### Updated `Settled` event (cosmetic, not required but useful):

```solidity
// Optionally extend to log fee amount:
event Settled(uint256 indexed id, bool fulfilled, address indexed paidTo, uint256 amount, uint256 fee);
```

### 3e. New tests needed

In `test/StakedBountyEscrow.t.sol`:

```
test_fee_deducted_from_claimant_on_fulfilled()
  - setFee(100, treasury)  // 1 %
  - create 1 ETH bounty, settle fulfilled
  - assert claimant received 0.99 ETH
  - assert treasury received 0.01 ETH
  - assert escrow balance == resolverStake (no residue)

test_fee_deducted_from_funder_on_refund()
  - setFee(100, treasury)
  - create 1 ETH bounty, settle !fulfilled
  - assert funder received 0.99 ETH
  - assert treasury received 0.01 ETH

test_fee_zero_no_deduction()
  - feeBps stays 0 (default)
  - create 1 ETH bounty, settle fulfilled
  - assert claimant received exactly 1 ETH

test_setFee_reverts_above_cap()
  - setFee(501, treasury) → expect revert "fee exceeds cap"

test_setFee_reverts_nonzero_fee_zero_recipient()
  - setFee(100, address(0)) → expect revert "need recipient"

test_fee_through_resolveDispute_upheld()
  - fee applies when arbiter upholds resolver (final payout to claimant)

test_fee_through_resolveDispute_overturned()
  - fee applies when arbiter overturns (final payout to funder)
```

In `test/StakedBountyEscrow.invariant.t.sol`:

```
// setUp: set feeBps=100, feeRecipient=address(this) (or a dedicated treasury addr)
// invariant_solvency: unchanged formula — fee exits in same tx as b.amount,
// so settled bounties are still excluded from the expected sum. No change needed.
```

The invariant handler needs `vm.deal(feeRecipient, 0)` and the feeRecipient must
have a `receive()` function (use a simple `address payable` or add `receive()` to
the test contract). The solvency formula itself does not change.

### 3f. Libraries and files involved

| File | Change |
|---|---|
| `src/StakedBountyEscrow.sol` | Add `feeBps`, `MAX_FEE_BPS`, `feeRecipient`, `setFee()`, modify `_payout()` |
| `test/StakedBountyEscrow.t.sol` | 6–7 new unit tests (see above) |
| `test/StakedBountyEscrow.invariant.t.sol` | Handler setUp wires fee; invariant formula unchanged |
| `script/DeployStaked.s.sol` | Pass `feeBps=0, feeRecipient=<Safe>` at deploy (fee off by default) |
| `.env.example` | Add `FEE_RECIPIENT=` and `FEE_BPS=` |

OZ libraries used (already in scope via `@openzeppelin/contracts`):
- `Ownable` (already imported) — `onlyOwner` gates `setFee`.
- No new OZ imports required for MVP.
- Optional P3 addition: `TimelockController` as the `owner` for rate-change governance delay.

---

## 4. Effort, Dependencies, Risks

### Effort: **Small (S)**

The contract change is ~25 lines of Solidity. The test suite is ~60–80 lines.
A single smart-contract-engineer sprint (half-day to one day) covers both.
No new dependencies are introduced. No interface changes for the resolver or watcher.

### Dependencies

- **None blocking.** Can be done on top of the current `StakedBountyEscrow` at any
  point after P1's testnet deployment. The fee can be deployed with `feeBps = 0`
  (effectively inert) to minimize risk during the live-loop phase.
- **Safe multisig address:** needs to be decided before setting a non-zero
  `feeRecipient`. A 2-of-3 Safe can be deployed in minutes on Sepolia.
- **Security review (security-auditor agent):** mandatory before any mainnet deploy
  of a `feeBps > 0` configuration, even though the change is small. The `_payout`
  path is the fund-moving heart of the protocol.

### Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Fee sent to zero address if `feeRecipient` not set | High | `setFee` enforces `feeRecipient != address(0)` when `feeBps > 0`; default is `feeBps = 0` |
| Owner rug: sets `feeBps = 500` silently | Medium | Hard cap `MAX_FEE_BPS` is immutable; add optional `TimelockController` at P3 |
| `_send(feeRecipient, fee)` fails (recipient reverts) | Medium | Use same `_send` pattern with `require(ok)`; if feeRecipient is a Safe it always accepts ETH |
| Solvency invariant broken by fee accounting error | Low | Explicit unit test suite + invariant test covers this; fee is computed and exits atomically in same call |
| Regulatory: fee = payment processor / money transmitter risk | Medium-High | See §5; mitigated by "fee for service" framing and non-custodial flow |

### Regulatory / trust considerations

A per-settlement protocol fee on ETH escrow is structurally analogous to a platform
commission. US regulatory risk depends on framing:

- **Non-custodial framing (low risk):** The contract, not the platform, holds funds.
  The fee deduction is automatic and auditable on-chain. Platform takes no discretion
  over funds. This resembles a smart-contract toll, not money transmission. The 2025
  CLARITY Act and 2026 SEC/CFTC joint guidance increasingly distinguish non-custodial
  protocol operators from regulated intermediaries — platforms where code enforces the
  fee autonomously are less exposed than those where a company manually processes
  payments.
- **Watch: fee as revenue = service provision.** Taking a % fee and providing a
  hosted judge service could attract state-level money-transmitter licensing scrutiny
  depending on jurisdiction (particularly California's DFPI). Consult counsel before
  charging fees on mainnet at scale.
- **Token-based fee deferral reduces risk.** The STRATEGY.md recommendation to defer
  token-based fee capture to P4 is the right call: a token that captures protocol
  fees has the strongest securities-law exposure.
- **Best practice:** display the fee prominently in the frontend (P3), emit `FeeUpdated`
  events with full transparency, and keep `feeBps` low (100 bps / 1 % to start).

Sources:
- [DeFi Regulatory Compliance 2025 overview](https://www.calibraint.com/blog/defi-regulatory-compliance-sec-cftc-2025)
- [Cleary Gottlieb 2026 Digital Assets Regulatory Update](https://www.clearygottlieb.com/news-and-insights/publication-listing/2026-digital-assets-regulatory-update-a-landmark-2025-but-more-developments-on-the-horizon)
- [SEC Economic Analysis of DeFi (April 2026)](https://www.sec.gov/files/ctf-written-craig-m-lewis-economic-analysis-defi-04-07-2026.pdf)

---

## 5. Verdict

### Roadmap phase fit

**P1 / P2** — deploy the contract change with `feeBps = 0` (inert) as part of the
P1 testnet deployment. Flip to a non-zero fee only after P2's real evidence pipeline
is live and the judge accuracy is proven (P0 gate cleared). This avoids charging users
on a judge that hasn't yet proven itself. First real revenue collection starts at P3
(hosted judge SaaS), where the fee switch is turned on alongside the UI.

### Go / No-go

**Go — with deferred activation.**

Build the mechanism now (S effort, no new dependencies, solvency invariant preserved).
Deploy inert (`feeBps = 0`). Flip the switch at P3 after:
- P0 eval gate clears (judge accuracy ≥ 90 %).
- At least one DAO pilot has settled a batch on testnet.
- Security-auditor has signed off on the `_payout` change.
- A Safe multisig `feeRecipient` is deployed and funded for gas.

Do **not** go live with a non-zero fee before P0 passes — charging for a judge of
unproven accuracy would undermine the trust story and poison the first DAO pilot.

### Priority: **2 / 5**

- Priority 1 is the P0 eval kill-gate (judge accuracy).
- This is Priority 2: a small, well-bounded change that closes the monetization loop
  before P3 productization, with no risk to solvency if built correctly.
- Block it on P0's gate; build it in the same sprint as P1 testnet deployment.

---

*Report written June 2026. Sources cited inline above.*
