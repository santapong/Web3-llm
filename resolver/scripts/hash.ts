/**
 * Print keccak256(utf8Bytes(stdin)) — the specHash/prHash convention used on-chain.
 * Usage:  cat spec.txt | npx tsx scripts/hash.ts
 */
import { hashText } from "../src/content.js";

const chunks: Buffer[] = [];
process.stdin.on("data", (c: Buffer) => chunks.push(c));
process.stdin.on("end", () => {
  const text = Buffer.concat(chunks).toString("utf8");
  process.stdout.write(hashText(text) + "\n");
});
