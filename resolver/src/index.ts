import { ViemEscrowChain } from "./chain.js";
import { loadConfig } from "./config.js";
import { loadJsonStore, withHashVerification } from "./content.js";
import { AnthropicJudge, type JudgeInput, type Verdict, type VerdictModel } from "./judge.js";
import { Resolver } from "./resolver.js";

/**
 * Deterministic stand-in for the LLM, for local end-to-end runs without an API key.
 * Enable with RESOLVER_MOCK_VERDICT=fulfilled | rejected.
 */
class MockVerdictModel implements VerdictModel {
  constructor(private readonly fulfilled: boolean) {}
  async judge(_input: JudgeInput): Promise<Verdict> {
    return {
      fulfilled: this.fulfilled,
      reasoning: `[mock verdict] ${this.fulfilled ? "criteria met" : "criteria not met"}`,
    };
  }
}

function buildJudge(model: string, apiKey?: string): VerdictModel {
  const mock = process.env.RESOLVER_MOCK_VERDICT?.trim().toLowerCase();
  if (mock === "fulfilled" || mock === "rejected") {
    console.log(`⚠️  using MOCK judge (${mock}) — no Anthropic API call`);
    return new MockVerdictModel(mock === "fulfilled");
  }
  return AnthropicJudge.fromApiKey(apiKey, { model });
}

async function main(): Promise<void> {
  const config = loadConfig();
  const chain = new ViemEscrowChain(config);
  const content = withHashVerification(await loadJsonStore(config.contentFile));
  const judge = buildJudge(config.model, config.anthropicApiKey);

  const resolver = new Resolver({ chain, content, judge }, { startBlock: config.startBlock });
  const unwatch = await resolver.start();

  const shutdown = () => {
    console.log("\nshutting down resolver…");
    unwatch();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
