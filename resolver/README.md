# Web3-llm resolver

The off-chain half of [Web3-llm](../README.md) — the "llm". It watches `BountyCreated` events,
judges each PR against the bounty's acceptance criteria with Claude, and submits the verdict
on-chain.

## Flow

```
BountyCreated(id, specHash, prHash)
        │
        ▼
fetch spec + PR text  →  verify keccak256(text) == on-chain hash   (content.ts)
        │
        ▼
Claude judges criteria vs PR  →  { fulfilled, reasoning }           (judge.ts)
        │
        ▼
submitVerdict(id, fulfilled, reasoning)                             (chain.ts)
```

## How the LLM judging works (`judge.ts`)

- **Model:** `claude-opus-4-8`.
- **Forced structured output:** a single `submit_verdict` tool with `tool_choice` pinned to it, so
  every response is a parseable `{ fulfilled: boolean, reasoning: string }` — never prose.
- **Prompt caching:** the static judging rubric is the `cache_control` system prefix; only the
  per-bounty spec + PR (the volatile suffix) changes per request.
- **Injection-resistant rubric:** the model is told to treat spec/PR text as data to evaluate, not
  instructions to follow, and to lean toward "not fulfilled" when genuinely uncertain.

`buildVerdictRequest` and `parseVerdict` are pure functions, so the LLM contract is unit-tested
without any network call.

## Run

```bash
npm ci
npm run typecheck
npm test          # offline: no chain, no API key

cp .env.example .env   # then fill in RESOLVER_CONTRACT etc.
npm start
```

Set `RESOLVER_MOCK_VERDICT=fulfilled|rejected` to run the full loop without an Anthropic key
(used by the local anvil demo in the [root README](../README.md#local-end-to-end-demo-anvil-no-api-key-needed)).

## Configuration

See [`.env.example`](.env.example). Required: `RESOLVER_RPC_URL`, `RESOLVER_PRIVATE_KEY` (must equal
the contract's `resolver`), `RESOLVER_CONTRACT`, `RESOLVER_CONTENT_FILE`. The content file is a
`{ "<keccak256 hash>": "<text>" }` map; compute hashes with `cat spec.txt | npx tsx scripts/hash.ts`.
