# Round 1 — contract-engineer proposal

Scope (P1, all on `src/StakedBountyEscrow.sol`): (1) inert protocol-fee switch in
`_payout`; (2) `require(..., "string")` → custom errors with identical revert
conditions; (3) Base Sepolia deploy. Planning only — no `.sol` edited this round.

Grounding read: `docs/research/09-fee-treasury.md`, `10-l2-gasless.md`,
`src/StakedBountyEscrow.sol`, `test/StakedBountyEscrow.invariant.t.sol`,
`script/DeployStaked.s.sol`, `foundry.toml`.

---

## What to build

### A. Inert protocol-fee switch (deployed at `feeBps = 0`)

**Storage (add after the economic-params block, ~line 62):**
```solidity
uint16 public constant MAX_FEE_BPS = 500; // 5% hard ceiling — immutable, source-readable trust bound
uint16 public feeBps;                     // current rate; 0 = fee OFF (default)
address public feeRecipient;              // protocol treasury (devops-supplied Safe)
```
`uint16` holds 0–500 comfortably and packs into a slot with `feeRecipient`
(2 + 20 = 22 of 32 bytes), so the switch costs **one new storage slot** plus the
immutable constant (no slot). `MAX_FEE_BPS` is `constant` (compile-time inlined),
which is what makes "the fee can never exceed 5%" verifiable by reading the source —
the property research #09 §3b wants.

**Event:**
```solidity
event FeeUpdated(uint16 feeBps, address indexed feeRecipient);
```

**Admin setter (alongside `setParams`, `onlyOwner`):**
```solidity
function setFee(uint16 _feeBps, address _feeRecipient) external onlyOwner {
    if (_feeBps > MAX_FEE_BPS) revert FeeExceedsCap();
    if (_feeBps != 0 && _feeRecipient == address(0)) revert FeeRecipientRequired();
    feeBps = _feeBps;
    feeRecipient = _feeRecipient;
    emit FeeUpdated(_feeBps, _feeRecipient);
}
```
Guards mirror Allo/Uniswap: cap-enforced rate, and a non-zero recipient is required
whenever the fee is live (prevents burning fees to `address(0)`).

**`_payout` — fee exits atomically (this is the solvency-critical change):**
```solidity
function _payout(uint256 id, Bounty storage b, bool outcome) internal {
    address recipient = outcome ? b.claimant : b.funder;
    uint256 principal = b.amount;

    uint256 fee = (feeBps == 0) ? 0 : (principal * feeBps) / 10_000;
    uint256 net = principal - fee; // fee <= principal always (feeBps <= 500), no underflow

    if (fee != 0) _send(feeRecipient, fee); // INTERACTION
    _send(recipient, net);                  // INTERACTION
    emit Settled(id, outcome, recipient, net, fee);
}
```
Key invariant property: the **entire `principal` leaves the contract in this single
call** (`fee + net == principal`), split into two transfers. The escrow never retains
the fee — so the solvency-expected-sum formula does not change (see "How to build").

`Settled` gains a `uint256 fee` field (sixth arg). This is an ABI change that
`resolver/src/abi.ts` and any indexer must track — flagged to resolver-engineer.
Keeping `net` (not `amount`) as the `amount` field means existing consumers read the
*actually-paid* number, which is the truthful value at any `feeBps`.

When `feeBps = 0` (the deployed default and the entire P1 reality): `fee = 0`, `net =
principal`, only one `_send`, `Settled.fee = 0` — **byte-for-byte the current
behaviour**. The switch is genuinely inert until `setFee` is called.

**CEI / reentrancy:** `_payout` is only reachable from `settle` and `resolveDispute`,
both `nonReentrant` and both already finalize all EFFECTS (`status = Settled`,
`lockedStake`/`resolverStake` adjustments) before calling `_payout`. The new
`_send(feeRecipient, …)` is just one more INTERACTION after state is final — no new
reentrancy surface. Note the recipient ordering: fee is sent **before** the principal
payout; both are external calls under the same guard, so order is cosmetic, but
fee-first keeps the "protocol is paid" intuition.

### B. `require(..., "string")` → custom errors (identical revert conditions)

There are **18** string-`require` sites. Proposed error set (one-to-one, no behaviour
change — same condition, same revert, only the data format changes from string to
4-byte selector):

| Current `require` | Custom error |
|---|---|
| `"not resolver"` (modifier) | `NotResolver()` |
| `"not arbiter"` (modifier) | `NotArbiter()` |
| `"bad resolver"` (ctor + setResolver) | `ZeroResolver()` |
| `"bad arbiter"` (ctor + setArbiter) | `ZeroArbiter()` |
| `"no value"` (depositStake, withdrawStake) | `ZeroValue()` |
| `"exceeds free stake"` | `ExceedsFreeStake()` |
| `"no funds escrowed"` | `NoFundsEscrowed()` |
| `"bad claimant"` | `ZeroClaimant()` |
| `"not open"` | `NotOpen()` |
| `"insufficient stake"` | `InsufficientStake()` |
| `"not challengeable"` | `NotChallengeable()` |
| `"window closed"` | `WindowClosed()` |
| `"wrong bond"` | `WrongBond()` |
| `"not settleable"` | `NotSettleable()` |
| `"window open"` | `WindowOpen()` |
| `"not disputed"` | `NotDisputed()` |
| `"transfer failed"` | `TransferFailed()` |
| new (fee) | `FeeExceedsCap()`, `FeeRecipientRequired()` |

Pattern: `if (!condition) revert ErrorName();` (negate the require predicate).
**Do not** use the `require(cond, CustomError())` overload — it is via-ir-only
(Solidity 0.8.26) and this repo's `foundry.toml` does not set `via_ir = true`, so that
overload would not compile under the default pipeline.

Errors declared at the top of the contract body. Tests that currently assert on revert
strings (`vm.expectRevert("not open")`) must switch to
`vm.expectRevert(StakedBountyEscrow.NotOpen.selector)` — flagged to whoever owns
`test/StakedBountyEscrow.t.sol` (the unit suite).

### C. Base Sepolia deploy

**`script/DeployStaked.s.sol`: feed the fee switch through, fee OFF by default.**
```solidity
address feeRecipient = vm.envOr("FEE_RECIPIENT", address(0));
uint16  feeBps       = uint16(vm.envOr("FEE_BPS", uint256(0)));
// after deploy, only if feeBps > 0:
if (feeBps > 0) { vm.broadcast(); escrow.setFee(feeBps, feeRecipient); }
```
For P1 the env defaults (`feeBps = 0`, `feeRecipient = address(0)`) deploy the
contract inert with **no `setFee` call at all** — the simplest, lowest-risk path. The
constructor stays unchanged (fee is configured post-deploy by an owner tx, matching
Uniswap's "deploy immutable, flip via governance call" shape). I am **not** adding fee
params to the constructor: keeping `feeRecipient`/`feeBps` out of the ctor means the
deployed bytecode and the P0/v0 deploy flow are unchanged, and the treasury address
isn't needed at deploy time.

**`foundry.toml`: no changes required.** Base Sepolia is OP-Stack, fully EVM-equivalent
(research #10 §3.1); `solc 0.8.26`, `optimizer_runs = 200`, and the remappings all work
unchanged. Optionally add an `[rpc_endpoints]` + `[etherscan]` block so `--rpc-url
base_sepolia` and `--verify` resolve by alias (see "What to use") — convenience, not
necessity. **devops-engineer owns the actual deploy/verify**; my note only covers the
script + toml deltas.

### New tests / invariant

New unit tests in `test/StakedBountyEscrow.t.sol` (research #09 §3e, adapted):
- `test_fee_zero_is_default_and_inert` — fresh deploy, settle fulfilled, claimant gets
  **exactly** `amount`, `Settled.fee == 0`, balance back to `resolverStake`.
- `test_fee_deducted_on_fulfilled` / `…_on_refund` — `setFee(100, T)`, claimant/funder
  gets `amount*99/100`, treasury gets `amount*1/100`, no residue.
- `test_fee_applies_through_resolveDispute_upheld` / `…_overturned` — fee taken on the
  arbiter path for both final outcomes.
- `test_setFee_reverts_above_cap` → `FeeExceedsCap`; `test_setFee_reverts_live_fee_zero_recipient`
  → `FeeRecipientRequired`; `test_setFee_only_owner`.
- `test_fee_rounds_down` — small principal where `principal*feeBps/10_000` truncates;
  assert `fee + net == principal` exactly (no wei leaks/leftovers).
- Custom-error regression: every migrated `require` keeps a test asserting the new
  `.selector` reverts on the same precondition.

**The invariant update (`test/StakedBountyEscrow.invariant.t.sol`):**
- **The `invariant_solvency` formula does NOT change.** Expected balance stays
  `resolverStake + Σ amount[Open|Proposed|Disputed] + Σ challengeBondPaid[Disputed]`.
  Rationale: the fee is transient — it exits in the same call that moves the bounty to
  `Settled` and removes its `amount` from the live sum. A `Settled` bounty contributes
  0 to both the actual balance and the expected sum, exactly as today. Because
  `fee + net == principal`, the balance decreases by precisely `principal` per
  settlement whether the fee is on or off, so the equality holds identically.
- **What does change in the test:** `setUp()` must (a) call
  `escrow.setFee(100, feeRecipient)` to exercise a **live** fee under fuzzing (default 0
  would never test the fee path), and (b) point `feeRecipient` at an address with a
  `receive()` (the handler already has `receive() external payable {}`, but the
  treasury must be **excluded from the bounty sum** — use a dedicated address, e.g.
  `feeRecipient = address(0xFEE)` with `vm.deal(address(0xFEE), 0)` and a forwarder
  having `receive()`, so its accumulated fees are *not* part of escrow balance).
  Critically `feeRecipient` must be an address **distinct from `address(escrow)`** so
  fees genuinely leave the contract — that is what the invariant proves.
- **Recommended addition:** a second invariant
  `invariant_feeRecipientNeverEscrow` asserting `feeRecipient != address(escrow)`, plus
  the existing `invariant_lockedStakeMatchesOpenVerdicts` (unchanged) — re-run the full
  128k-run suite (`forge test --mt invariant`) and confirm zero counterexamples with
  the fee live. This is the concrete artifact security-reviewer signs off on.

---

## What to use

| Choice | Why | External source (adapted) |
|---|---|---|
| **bps fee taken at settle, deducted from outflow, both outcomes** | symmetric, no fee-refund logic, scales with bounty size; the cleanest reference pattern | Gitcoin **Allo** `_fundPool`: `feeAmount = (amount * percentFee) / denominator`, deducts from inflow before crediting — we deduct from outflow at settle. [Allo fees](https://docs.allo.gitcoin.co/allo/fees) |
| **`feeBps = 0` as the off-switch (no boolean)** | `0 * x / 10_000 == 0`; one fewer branch; inert-by-default | **Uniswap** fee switch: a single governance-set parameter (`feeTo` / fraction) toggles protocol fees globally; contracts otherwise immutable. [Uniswap v2 fees](https://docs.uniswap.org/contracts/v2/concepts/advanced-topics/fees), [UNIfication](https://blog.uniswap.org/unification) |
| **immutable `MAX_FEE_BPS = 500` cap** | source-readable hard ceiling; no owner can rug beyond 5% | Uniswap fee tiers are bounded/governance-bounded; bps = pct × 10_000 convention. [Uniswap fees concept](https://docs.uniswap.org/contracts/v2/concepts/advanced-topics/fees) |
| **`feeRecipient` as its own state var (≠ `owner`)** | treasury and operator are different security roles; recipient is an updatable address | **0x** `protocolFeeCollector` is a separate, governance-updatable address distinct from the operator. [0x protocol fees](https://docs.0xprotocol.org/en/development/basics/protocol_fees.html) |
| **`if (!cond) revert Err()` (not the require-overload)** | the `require(cond, Err())` form is **via-ir-only** and this repo doesn't enable via-ir | Solidity 0.8.26: "Using custom errors with require is currently only supported by the IR pipeline … use `if (!condition) revert CustomError();` for the legacy pipeline." [0.8.26 release](https://www.soliditylang.org/blog/2024/05/21/solidity-0.8.26-release-announcement/) |
| **custom errors at all** | ~100–150 gas/revert + ~smaller bytecode; OZ v5 uses them throughout | [Custom errors save gas](https://medium.com/coinmonks/how-custom-errors-in-solidity-save-gas-3c499aa22745); OZ v5.6.1 already imported uses custom errors (e.g. `OwnableUnauthorizedAccount`). |
| **Base Sepolia (84532), OP-Stack, no toolchain change** | EVM-equivalent → zero contract/foundry changes; first-party Coinbase faucet+paymaster path for P3 | research #10 §2.1/§3.1; verify with an **Etherscan v2** key (legacy Basescan keys deprecated). [Verify with Foundry](https://docs.etherscan.io/etherscan-v2/contract-verification/verify-with-foundry) |

No new imports. `Ownable` (already imported) gates `setFee`. No OZ `SafeERC20`/math
needed — ETH-only, and `feeBps <= 500` guarantees `fee <= principal` so plain checked
arithmetic never underflows on `principal - fee`.

---

## How to build

1. **Custom errors first (mechanical, no behaviour change).** Declare the 18+2 errors;
   convert each `require(cond, "str")` to `if (!cond) revert Err()`; convert the two
   modifiers. `forge build` + `forge test` — the existing suite (minus the revert-string
   assertions, which get updated to selectors) must stay green. This isolates the
   "no-op refactor" from the "new feature" in review/blame.
2. **Add fee storage + `FeeUpdated` event + `setFee` + the two fee errors.** Build.
3. **Modify `_payout`** to compute `fee`/`net`, send both, emit the 6-arg `Settled`.
   Update every `Settled` consumer in tests.
4. **Unit tests** (list above), including the inert-default and round-down cases. Run.
5. **Invariant test:** wire a live `feeBps` + dedicated `feeRecipient` in `setUp()`,
   add `invariant_feeRecipientNeverEscrow`, **re-run the 128k suite** and confirm the
   solvency invariant still holds (formula unchanged — fee is transient). Capture the
   run output for security-reviewer.
6. **`gas snapshot` before/after** the custom-error migration (`forge snapshot --diff`)
   to quantify the win for the decision log.
7. **Deploy script:** thread `FEE_BPS`/`FEE_RECIPIENT` env (default off); no ctor change.
   Hand to devops-engineer for the Base Sepolia broadcast + Etherscan-v2 verify.
8. **security-reviewer sign-off** on the `_payout` diff + invariant run **before** any
   broadcast, and a second sign-off gate before `setFee(>0)` is ever called (P3).

---

## Decisions I own (candidate decision-log entries)

| # | Decision | Rationale | Status |
|---|---|---|---|
| C1 | Fee = bps of principal, taken at settle, deducted from the outflow on **both** outcomes; pushed to `feeRecipient` in `_payout`. | Symmetric, no fee-refund logic; mirrors Allo. Keeps solvency trivially intact (fee exits atomically). | proposed |
| C2 | `feeBps = 0` is the off-switch; deploy inert; `MAX_FEE_BPS = 500` immutable cap. | No boolean branch; source-readable trust bound; matches Uniswap fee-switch shape. | proposed |
| C3 | `feeRecipient` is a separate state var, set via `setFee` post-deploy (not in the constructor). | Decouples treasury from operator (0x pattern); keeps deploy bytecode/flow unchanged; treasury addr not needed at deploy. | proposed |
| C4 | `Settled` event gains a `uint256 fee` field; the `amount` field becomes the **net** paid. | Consumers read the truthful paid amount at any rate; one ABI bump now vs. silent skew later. | proposed (needs resolver-engineer) |
| C5 | Custom-error migration via `if(!cond) revert Err()`, **not** the via-ir-only `require(cond, Err())` overload. | Repo doesn't enable via-ir; the overload wouldn't compile. Identical revert semantics preserved. | proposed |
| C6 | Solvency invariant **formula unchanged**; invariant test updated to run a *live* fee + dedicated `feeRecipient`, plus `invariant_feeRecipientNeverEscrow`. | Fee is transient (exits same call), so the expected-sum is identical; but fuzzing must exercise the live-fee path to be meaningful. | proposed |
| C7 | Base Sepolia (84532) deploy: zero `foundry.toml`/contract change; optional rpc/etherscan alias block; verify via Etherscan-v2 key. | OP-Stack EVM parity; legacy Basescan keys deprecated. | proposed (devops executes) |

---

## Dependencies on other agents

- **devops-engineer:** must supply the **`feeRecipient` Safe multisig** address (Base
  Sepolia 2-of-3 per research #09 §3c) **before** any `setFee(>0)` — not needed for the
  inert P1 deploy. Owns the Base Sepolia broadcast, faucet funding, and Etherscan-v2
  verification. I supply the script/toml deltas; they execute. Confirm whether to add
  the `[rpc_endpoints]`/`[etherscan]` alias block to `foundry.toml`.
- **security-reviewer:** **mandatory sign-off** on the `_payout` diff + the re-run 128k
  invariant output before broadcast (CLAUDE.md: contract safety non-negotiable). Second
  gate before `setFee(>0)` is ever called. Please confirm the fee-first vs payout-first
  send ordering is acceptable and that no new reentrancy surface is introduced.
- **resolver-engineer:** the **`Settled` ABI change** (new `fee` field; `amount` →
  net) must propagate to `resolver/src/abi.ts` and any settlement/indexing logic. Also
  confirm the resolver doesn't assert `Settled.amount == bounty.amount` anywhere.
- **eval-engineer:** none directly; fee is downstream of the P0 gate per research #09
  §5 (don't activate a non-zero fee until judge accuracy is proven).
- **tech-lead:** sequence the custom-error refactor as step 1 (clean, low-risk) and the
  fee switch as step 2 within the same P1 contract sprint; both gate on the invariant
  re-run + security sign-off before the Base Sepolia broadcast.

---

## Open questions / risks

1. **`Settled` ABI change vs. additive event.** Modifying `Settled` (6 args) is cleaner
   than a separate `FeeCharged` event but breaks `abi.ts` decode. Alternative: keep
   `Settled` 4-arg (with `amount = net`) and add `event FeeCharged(uint256 indexed id,
   address indexed feeRecipient, uint256 fee)`. The additive option is *less* breaking
   for indexers. **Want resolver-engineer's call** on which is cheaper to consume.
2. **Fee-recipient griefing.** If `feeRecipient` is a contract that reverts on receive,
   **every settle for that config reverts** → funds locked until owner fixes it. Mitigation:
   `setFee` requires non-zero recipient but cannot prove it accepts ETH; rely on it being
   a Safe (always accepts). At `feeBps = 0` (P1) this risk is zero. Flag to
   security-reviewer; possible future hardening = pull-payment for fees (out of scope v0).
3. **Rounding leakage.** `principal * feeBps / 10_000` truncates; `net = principal - fee`
   absorbs the remainder to the recipient — so `fee + net == principal` exactly and no
   wei is stranded. Covered by `test_fee_rounds_down`. Confirm this rounding direction
   (favor recipient) is acceptable; it is the standard Allo/Uniswap convention.
4. **`uint16` for `feeBps`.** 0–500 fits; chose `uint16` (not `uint96`/`uint256`) for
   slot-packing with `feeRecipient`. If a future fee model wants per-bounty rates pinned
   at create (like `bondLocked`), that's a larger refactor — explicitly **out of P1
   scope**; the global rate is correct for the monetization rail now.
5. **Timelock on `setFee`.** Research #09 §3b recommends an OZ `TimelockController` owner
   before mainnet so rate changes have a 48h delay. **Out of P1 scope** (owner = EOA/Safe
   on testnet); flag as a P3 prerequisite to flipping the fee on.
6. **Optimizer runs.** research #10 §3.2 floats `optimizer_runs = 1000` for runtime-call
   savings (many small bounties). Not part of this task; would change deployed bytecode
   and should be its own benchmarked decision — flagging, not doing.
