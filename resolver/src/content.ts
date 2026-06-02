import { readFile } from "node:fs/promises";
import { keccak256, toBytes, type Hex } from "viem";

/**
 * The chain stores only commitments: `specHash` and `prHash` are bytes32 hashes, while the
 * actual acceptance criteria and PR text live off-chain. A ContentProvider resolves a hash back
 * to its text.
 *
 * Hash convention (must match how bounties are created): `hash = keccak256(utf8Bytes(text))`,
 * i.e. Solidity's `keccak256(bytes(text))`.
 *
 * Security: whatever source the text comes from (a local file, IPFS, a web server) is untrusted.
 * `withHashVerification` re-hashes the returned text and rejects anything that does not match the
 * on-chain commitment — so a tampered host cannot feed the judge different criteria than the
 * funder and claimant agreed to.
 */

export interface BountyContent {
  specText: string;
  prText: string;
}

export interface ContentProvider {
  fetch(specHash: Hex, prHash: Hex): Promise<BountyContent>;
}

/** keccak256 of a string's UTF-8 bytes — matches Solidity `keccak256(bytes(text))`. */
export function hashText(text: string): Hex {
  return keccak256(toBytes(text));
}

/** A flat `{ "<hash>": "<text>" }` map, e.g. loaded from a JSON file. */
export type ContentStore = Record<string, string>;

/** Resolve hashes to text from an in-memory store (used in tests and as the JSON-file backend). */
export class MapContentProvider implements ContentProvider {
  constructor(private readonly store: ContentStore) {}

  /** Build a store from raw texts, keyed by their own hash. Handy for fixtures and local demos. */
  static fromTexts(texts: string[]): MapContentProvider {
    const store: ContentStore = {};
    for (const t of texts) store[hashText(t)] = t;
    return new MapContentProvider(store);
  }

  async fetch(specHash: Hex, prHash: Hex): Promise<BountyContent> {
    return { specText: this.lookup(specHash, "spec"), prText: this.lookup(prHash, "pr") };
  }

  private lookup(hash: Hex, label: string): string {
    const text = this.store[hash] ?? this.store[hash.toLowerCase()];
    if (text === undefined) throw new Error(`no ${label} content found for hash ${hash}`);
    return text;
  }
}

/** Load a `{ "<hash>": "<text>" }` JSON file into a MapContentProvider. */
export async function loadJsonStore(path: string): Promise<MapContentProvider> {
  const raw = await readFile(path, "utf8");
  const parsed = JSON.parse(raw) as unknown;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`content store at ${path} must be a JSON object of { hash: text }`);
  }
  return new MapContentProvider(parsed as ContentStore);
}

/**
 * Wrap a provider so every returned text is verified against the on-chain hash it was requested
 * by. This is the trust boundary: it turns "some host gave me text" into "the text the funder and
 * claimant committed to on-chain". Always wrap untrusted providers with this.
 */
export function withHashVerification(inner: ContentProvider): ContentProvider {
  return {
    async fetch(specHash: Hex, prHash: Hex): Promise<BountyContent> {
      const content = await inner.fetch(specHash, prHash);
      assertHash(content.specText, specHash, "spec");
      assertHash(content.prText, prHash, "pr");
      return content;
    },
  };
}

function assertHash(text: string, expected: Hex, label: string): void {
  const actual = hashText(text);
  if (actual.toLowerCase() !== expected.toLowerCase()) {
    throw new Error(
      `${label} content does not match on-chain hash: expected ${expected}, got ${actual} ` +
        `(the content source may be tampered or out of date)`,
    );
  }
}
