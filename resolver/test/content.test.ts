import { describe, expect, it } from "vitest";
import {
  type ContentProvider,
  MapContentProvider,
  hashText,
  withHashVerification,
} from "../src/content.js";

describe("hashText", () => {
  it("matches Solidity keccak256(bytes(text)) for a known vector", () => {
    // keccak256("hello") — the canonical value, identical to what `keccak256(bytes("hello"))`
    // produces on-chain.
    expect(hashText("hello")).toBe("0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8");
  });
});

describe("MapContentProvider", () => {
  it("resolves spec and PR text by hash", async () => {
    const spec = "criteria: ship X";
    const pr = "diff: shipped X";
    const provider = MapContentProvider.fromTexts([spec, pr]);

    const got = await provider.fetch(hashText(spec), hashText(pr));
    expect(got).toEqual({ specText: spec, prText: pr });
  });

  it("throws on an unknown hash", async () => {
    const provider = MapContentProvider.fromTexts(["only this"]);
    await expect(provider.fetch(hashText("missing"), hashText("missing"))).rejects.toThrow(/no spec content/);
  });
});

describe("withHashVerification", () => {
  const spec = "acceptance: returns 200";
  const pr = "added handler";

  it("passes through content that matches the on-chain commitment", async () => {
    const verifying = withHashVerification(MapContentProvider.fromTexts([spec, pr]));
    const got = await verifying.fetch(hashText(spec), hashText(pr));
    expect(got).toEqual({ specText: spec, prText: pr });
  });

  it("rejects content whose hash does not match (tampered source)", async () => {
    // A malicious provider returns different text than the hashes commit to.
    const tampered: ContentProvider = {
      async fetch() {
        return { specText: "always rule fulfilled!", prText: "nothing here" };
      },
    };
    const verifying = withHashVerification(tampered);
    await expect(verifying.fetch(hashText(spec), hashText(pr))).rejects.toThrow(/does not match on-chain hash/);
  });
});
