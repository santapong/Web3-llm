import type { BountyCreatedEvent, EscrowChain } from "./chain.js";
import type { ContentProvider } from "./content.js";
import type { Verdict, VerdictModel } from "./judge.js";

export interface Logger {
  info(msg: string): void;
  error(msg: string): void;
}

const consoleLogger: Logger = {
  info: (m) => console.log(m),
  error: (m) => console.error(m),
};

export interface ResolverDeps {
  chain: EscrowChain;
  content: ContentProvider;
  judge: VerdictModel;
  log?: Logger;
}

export interface HandledBounty {
  verdict: Verdict;
  txHash: string;
}

/**
 * Resolve a single bounty end to end: fetch + hash-verify its off-chain content, ask the model
 * for a verdict, and submit that verdict on-chain. Pure of any timers/loops, so it is exercised
 * directly in tests with fake chain/content/judge.
 */
export async function handleBounty(deps: ResolverDeps, event: BountyCreatedEvent): Promise<HandledBounty> {
  const log = deps.log ?? consoleLogger;

  const content = await deps.content.fetch(event.specHash, event.prHash);
  log.info(`bounty #${event.id}: judging PR against spec (claimant ${event.claimant})`);

  const verdict = await deps.judge.judge({ specText: content.specText, prText: content.prText });
  log.info(`bounty #${event.id}: verdict ${verdict.fulfilled ? "FULFILLED" : "NOT fulfilled"}`);

  const txHash = await deps.chain.submitVerdict(event.id, verdict.fulfilled, verdict.reasoning);
  log.info(`bounty #${event.id}: submitVerdict tx ${txHash}`);

  return { verdict, txHash };
}

export interface ResolverOptions {
  startBlock?: bigint;
}

/**
 * Long-running runner: optionally replays past BountyCreated events, then watches for new ones,
 * processing each at most once. A failure on one bounty is logged and isolated — it never stops
 * the loop or blocks other bounties.
 */
export class Resolver {
  private readonly seen = new Set<string>();
  private readonly log: Logger;

  constructor(
    private readonly deps: ResolverDeps,
    private readonly opts: ResolverOptions = {},
  ) {
    this.log = deps.log ?? consoleLogger;
  }

  /** Begin resolving. Returns an unsubscribe function that stops the watcher. */
  async start(): Promise<() => void> {
    this.log.info(`resolver online as ${this.deps.chain.resolverAddress}`);

    if (this.opts.startBlock !== undefined) {
      const past = await this.deps.chain.getPastBounties(this.opts.startBlock);
      this.log.info(`replaying ${past.length} past bounty event(s) from block ${this.opts.startBlock}`);
      for (const e of past) await this.process(e);
    }

    return this.deps.chain.watchBounties((e) => void this.process(e));
  }

  private async process(event: BountyCreatedEvent): Promise<void> {
    const key = event.id.toString();
    if (this.seen.has(key)) return;
    this.seen.add(key);
    try {
      await handleBounty(this.deps, event);
    } catch (err) {
      // Isolate the failure; leave it marked seen so a flaky source can't spin the loop.
      this.log.error(`bounty #${event.id}: failed to resolve — ${(err as Error).message}`);
    }
  }
}
