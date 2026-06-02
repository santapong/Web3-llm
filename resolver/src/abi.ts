/**
 * Minimal ABI the resolver needs. `BountyCreated` and `submitVerdict(uint256,bool,string)` have
 * identical signatures on both BountyEscrow (v0) and StakedBountyEscrow (v1), so one ABI drives
 * either contract. `settle(uint256)` exists only on v1 — used when RESOLVER_SETTLE is enabled to
 * close out a bounty after its challenge window.
 */
export const escrowAbi = [
  {
    type: "event",
    name: "BountyCreated",
    inputs: [
      { name: "id", type: "uint256", indexed: true },
      { name: "funder", type: "address", indexed: true },
      { name: "claimant", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "specHash", type: "bytes32", indexed: false },
      { name: "prHash", type: "bytes32", indexed: false },
    ],
  },
  {
    type: "function",
    name: "submitVerdict",
    stateMutability: "nonpayable",
    inputs: [
      { name: "id", type: "uint256" },
      { name: "fulfilled", type: "bool" },
      { name: "reasoning", type: "string" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "settle",
    stateMutability: "nonpayable",
    inputs: [{ name: "id", type: "uint256" }],
    outputs: [],
  },
] as const;
