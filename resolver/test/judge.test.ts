import type Anthropic from "@anthropic-ai/sdk";
import { describe, expect, it, vi } from "vitest";
import {
  AnthropicJudge,
  DEFAULT_MODEL,
  type MessagesClient,
  SUBMIT_VERDICT_TOOL,
  buildVerdictRequest,
  parseVerdict,
} from "../src/judge.js";

const input = { specText: "SPEC: add a /health endpoint returning 200", prText: "PR: added GET /health -> 200" };

/** Build a minimal Messages API response carrying a forced submit_verdict tool call. */
function verdictMessage(fulfilled: boolean, reasoning: string): Anthropic.Message {
  return {
    content: [{ type: "tool_use", id: "toolu_1", name: SUBMIT_VERDICT_TOOL.name, input: { fulfilled, reasoning } }],
  } as unknown as Anthropic.Message;
}

describe("buildVerdictRequest", () => {
  it("targets the configured model (default opus 4.8) and forces the verdict tool", () => {
    const req = buildVerdictRequest(input);
    expect(req.model).toBe(DEFAULT_MODEL);
    expect(req.tools).toEqual([SUBMIT_VERDICT_TOOL]);
    expect(req.tool_choice).toEqual({ type: "tool", name: "submit_verdict" });
  });

  it("caches the static rubric and puts only the volatile spec+PR in the user turn", () => {
    const req = buildVerdictRequest(input);
    const system = req.system as Anthropic.TextBlockParam[];
    expect(system[0]?.cache_control).toEqual({ type: "ephemeral" });

    const userContent = req.messages[0]?.content as string;
    expect(userContent).toContain(input.specText);
    expect(userContent).toContain(input.prText);
    // The rubric must NOT contain per-bounty content, or it would invalidate the cache.
    expect(system[0]?.text).not.toContain(input.prText);
  });

  it("honors model + maxTokens overrides", () => {
    const req = buildVerdictRequest(input, { model: "claude-haiku-4-5", maxTokens: 512 });
    expect(req.model).toBe("claude-haiku-4-5");
    expect(req.max_tokens).toBe(512);
  });
});

describe("parseVerdict", () => {
  it("extracts a well-formed verdict from the tool call", () => {
    expect(parseVerdict(verdictMessage(true, "all criteria met"))).toEqual({
      fulfilled: true,
      reasoning: "all criteria met",
    });
  });

  it("throws when no submit_verdict tool call is present", () => {
    const msg = { content: [{ type: "text", text: "I think so" }] } as unknown as Anthropic.Message;
    expect(() => parseVerdict(msg)).toThrow(/did not return a submit_verdict/);
  });

  it("throws on a non-boolean fulfilled", () => {
    const msg = {
      content: [{ type: "tool_use", id: "t", name: "submit_verdict", input: { fulfilled: "yes", reasoning: "x" } }],
    } as unknown as Anthropic.Message;
    expect(() => parseVerdict(msg)).toThrow(/not a boolean/);
  });

  it("throws on empty reasoning", () => {
    expect(() => parseVerdict(verdictMessage(false, "   "))).toThrow(/reasoning is missing or empty/);
  });
});

describe("AnthropicJudge", () => {
  it("sends the built request and returns the parsed verdict", async () => {
    const create = vi.fn().mockResolvedValue(verdictMessage(false, "endpoint missing tests"));
    const fakeClient: MessagesClient = { messages: { create } };

    const judge = new AnthropicJudge(fakeClient, { model: "claude-opus-4-8" });
    const verdict = await judge.judge(input);

    expect(verdict).toEqual({ fulfilled: false, reasoning: "endpoint missing tests" });
    // It called the API with our forced-tool, cached request shape.
    const sent = create.mock.calls[0]?.[0] as Anthropic.MessageCreateParamsNonStreaming;
    expect(sent.tool_choice).toEqual({ type: "tool", name: "submit_verdict" });
    expect(sent.model).toBe("claude-opus-4-8");
  });
});
