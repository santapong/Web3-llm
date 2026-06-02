import {
  http,
  type Address,
  type Hex,
  createPublicClient,
  createWalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { escrowAbi } from "./abi.js";
import type { ResolverConfig } from "./config.js";

export interface BountyCreatedEvent {
  id: bigint;
  funder: Address;
  claimant: Address;
  amount: bigint;
  specHash: Hex;
  prHash: Hex;
}

/** The chain operations the resolver loop depends on. Faked in tests. */
export interface EscrowChain {
  /** The resolver's own address (derived from the signing key). */
  readonly resolverAddress: Address;
  submitVerdict(id: bigint, fulfilled: boolean, reasoning: string): Promise<Hex>;
  settle(id: bigint): Promise<Hex>;
  /** Past BountyCreated events from `fromBlock` to latest (inclusive). */
  getPastBounties(fromBlock: bigint): Promise<BountyCreatedEvent[]>;
  /** Subscribe to new BountyCreated events. Returns an unsubscribe function. */
  watchBounties(onEvent: (e: BountyCreatedEvent) => void): () => void;
}

/** viem-backed EscrowChain. */
export class ViemEscrowChain implements EscrowChain {
  private readonly publicClient;
  private readonly walletClient;
  private readonly account;
  private readonly address: Address;

  constructor(config: ResolverConfig) {
    this.account = privateKeyToAccount(config.privateKey);
    this.address = config.contract;
    this.publicClient = createPublicClient({ transport: http(config.rpcUrl) });
    this.walletClient = createWalletClient({ account: this.account, transport: http(config.rpcUrl) });
  }

  get resolverAddress(): Address {
    return this.account.address;
  }

  async submitVerdict(id: bigint, fulfilled: boolean, reasoning: string): Promise<Hex> {
    return this.walletClient.writeContract({
      chain: null,
      address: this.address,
      abi: escrowAbi,
      functionName: "submitVerdict",
      args: [id, fulfilled, reasoning],
    });
  }

  async settle(id: bigint): Promise<Hex> {
    return this.walletClient.writeContract({
      chain: null,
      address: this.address,
      abi: escrowAbi,
      functionName: "settle",
      args: [id],
    });
  }

  async getPastBounties(fromBlock: bigint): Promise<BountyCreatedEvent[]> {
    const logs = await this.publicClient.getContractEvents({
      address: this.address,
      abi: escrowAbi,
      eventName: "BountyCreated",
      fromBlock,
      toBlock: "latest",
    });
    return logs.map((l) => toEvent(l.args));
  }

  watchBounties(onEvent: (e: BountyCreatedEvent) => void): () => void {
    return this.publicClient.watchContractEvent({
      address: this.address,
      abi: escrowAbi,
      eventName: "BountyCreated",
      onLogs: (logs) => {
        for (const l of logs) onEvent(toEvent(l.args));
      },
    });
  }
}

/** Narrow viem's optionally-undefined decoded args into a complete event (or throw). */
function toEvent(args: {
  id?: bigint;
  funder?: Address;
  claimant?: Address;
  amount?: bigint;
  specHash?: Hex;
  prHash?: Hex;
}): BountyCreatedEvent {
  const { id, funder, claimant, amount, specHash, prHash } = args;
  if (
    id === undefined ||
    funder === undefined ||
    claimant === undefined ||
    amount === undefined ||
    specHash === undefined ||
    prHash === undefined
  ) {
    throw new Error("BountyCreated log is missing decoded fields");
  }
  return { id, funder, claimant, amount, specHash, prHash };
}
