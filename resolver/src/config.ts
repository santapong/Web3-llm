import "dotenv/config";
import { type Address, type Hex, getAddress, isHex } from "viem";
import { DEFAULT_MODEL } from "./judge.js";

/** Resolver configuration, loaded and validated from the environment (see .env.example). */
export interface ResolverConfig {
  rpcUrl: string;
  privateKey: Hex; // resolver signing key (the address must equal the contract's `resolver`)
  contract: Address;
  anthropicApiKey?: string; // optional: the SDK also reads ANTHROPIC_API_KEY directly
  model: string;
  contentFile: string; // path to a { "<hash>": "<text>" } JSON store
  startBlock?: bigint; // optional: replay BountyCreated from this block on startup
}

function required(name: string): string {
  const v = process.env[name];
  if (!v || v.trim() === "") throw new Error(`missing required env var ${name}`);
  return v.trim();
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ResolverConfig {
  const privateKey = required("RESOLVER_PRIVATE_KEY");
  if (!isHex(privateKey) || privateKey.length !== 66) {
    throw new Error("RESOLVER_PRIVATE_KEY must be a 0x-prefixed 32-byte hex string");
  }

  const startBlockRaw = env.RESOLVER_START_BLOCK?.trim();

  return {
    rpcUrl: required("RESOLVER_RPC_URL"),
    privateKey: privateKey as Hex,
    contract: getAddress(required("RESOLVER_CONTRACT")),
    anthropicApiKey: env.ANTHROPIC_API_KEY?.trim() || undefined,
    model: env.RESOLVER_MODEL?.trim() || DEFAULT_MODEL,
    contentFile: required("RESOLVER_CONTENT_FILE"),
    startBlock: startBlockRaw ? BigInt(startBlockRaw) : undefined,
  };
}
