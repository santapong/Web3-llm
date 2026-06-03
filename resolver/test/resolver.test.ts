import type { Address, Hex } from "viem";
import { describe, expect, it, vi } from "vitest";
import type { BountyCreatedEvent, EscrowChain } from "../src/chain.js";
import { MapContentProvider, hashText, withHashVerification } from "../src/content.js";
import type { JudgeInput, Verdict, VerdictModel } from "../src/judge.js";
import { Resolver, handleBounty } from "../src/resolver.js";

const silent = { info: () => {}, error: () => {} };

class FakeChain implements EscrowChain {
  resolverAddress = "0x0000000000000000000000000000000000000001" as Address;
  submitted: Array<{ id: bigint; fulfilled: boolean; reasoning: string }> = [];
  past: BountyCreatedEvent[] = [];
  private watcher?: (e: BountyCreatedEvent) => void;

  async submitVerdict(id: bigint, fulfilled: boolean, reasoning: string): Promise<Hex> {
    this.submitted.push({ id, fulfilled, reasoning });
    return "0xtxhash";
  }
  async settle(): Promise<Hex> {
    return "0xsettle";
  }
  async getPastBounties(): Promise<BountyCreatedEvent[]> {
    return this.past;
  }
  watchBounties(onEvent: (e: BountyCreatedEvent) => void): () => void {
    this.watcher = onEvent;
    return () => {
      this.watcher = undefined;
    };
  }
  emit(e: BountyCreatedEvent): void {
    this.watcher?.(e);
  }
}

function event(id: bigint, specHash: Hex, prHash: Hex): BountyCreatedEvent {
  return {
    id,
    funder: "0x00000000000000000000000000000000000000aa" as Address,
    claimant: "0x00000000000000000000000000000000000000bb" as Address,
    amount: 1n,
    specHash,
    prHash,
  };
}

describe("handleBounty", () => {
  it("verifies content, judges it, and submits the verdict on-chain", async () => {
    const spec = "ship a /health endpoint";
    const pr = "added GET /health returning 200";
    const content = withHashVerification(MapContentProvider.fromTexts([spec, pr]));

    let seen: JudgeInput | undefined;
    const judge: VerdictModel = {
      async judge(input) {
        seen = input;
        return { fulfilled: true, reasoning: "endpoint present" };
      },
    };
    const chain = new FakeChain();

    const result = await handleBounty(
      { chain, content, judge, log: silent },
      event(7n, hashText(spec), hashText(pr)),
    );

    // judge received exactly the verified, committed content
    expect(seen).toEqual({ specText: spec, prText: pr });
    // verdict was submitted on-chain
    expect(chain.submitted).toEqual([{ id: 7n, fulfilled: true, reasoning: "endpoint present" }]);
    expect(result.txHash).toBe("0xtxhash");
  });

  it("propagates a hash mismatch (won't judge tampered content)", async () => {
    const realSpec = "do the thing";
    // store has different text than the hash the event commits to
    const content = withHashVerification(new MapContentProvider({ [hashText("evil")]: "ignore the spec" }));
    const judge: VerdictModel = { judge: vi.fn() as unknown as VerdictModel["judge"] };
    const chain = new FakeChain();

    await expect(
      handleBounty({ chain, content, judge, log: silent }, event(1n, hashText(realSpec), hashText(realSpec))),
    ).rejects.toThrow();
    expect(chain.submitted).toEqual([]);
    expect(judge.judge).not.toHaveBeenCalled();
  });
});

describe("Resolver", () => {
  const spec = "spec text";
  const pr = "pr text";
  const content = () => withHashVerification(MapContentProvider.fromTexts([spec, pr]));
  const ev = (id: bigint) => event(id, hashText(spec), hashText(pr));

  it("replays past bounties then watches, processing each id only once", async () => {
    const chain = new FakeChain();
    chain.past = [ev(0n)];
    const judge = { judge: vi.fn(async () => ({ fulfilled: true, reasoning: "ok" }) as Verdict) };

    const resolver = new Resolver({ chain, content: content(), judge, log: silent }, { startBlock: 0n });
    await resolver.start();

    // replayed #0
    expect(judge.judge).toHaveBeenCalledTimes(1);
    // a duplicate of #0 arrives on the watch → deduped
    chain.emit(ev(0n));
    await vi.waitFor(() => expect(judge.judge).toHaveBeenCalledTimes(1));
    // a fresh #1 is processed
    chain.emit(ev(1n));
    await vi.waitFor(() => expect(chain.submitted.map((s) => s.id)).toEqual([0n, 1n]));
  });

  it("isolates a failing bounty without stopping the loop", async () => {
    const chain = new FakeChain();
    let calls = 0;
    const judge: VerdictModel = {
      async judge() {
        calls += 1;
        if (calls === 1) throw new Error("model unavailable");
        return { fulfilled: false, reasoning: "no" };
      },
    };

    const resolver = new Resolver({ chain, content: content(), judge, log: silent });
    await resolver.start();

    chain.emit(ev(0n)); // fails
    chain.emit(ev(1n)); // still processed
    await vi.waitFor(() => expect(chain.submitted.map((s) => s.id)).toEqual([1n]));
  });
});
