# Research #01 — Judge-Accuracy Eval Harness (The P0 Moat)

**Area:** LLM-as-judge accuracy evaluation, labelled dataset design, CI kill-gate  
**Roadmap fit:** P0 (prerequisite to everything else)  
**Assigned:** feature-researcher  
**Date:** 2026-06-20

---

## 1. What & Why for web3-llm

### The core bet

The product's commercial thesis is: *a funder can trust that ETH released to a claimant was released correctly.* That trust rests entirely on one empirical claim — **the Claude judge agrees with human reviewers on clear-cut (criteria, PR) → fulfilled? cases at ≥ 90% accuracy.** Without a number attached to that claim, the oracle is marketing copy, not a product.

`blockllm` (the standby lab) designed the right discipline: a labelled eval set, a kill-gate threshold (10/10 clear-cut), and the rule "below ~9/10, stop and rethink — do not just tweak the prompt." `web3-llm` inherited none of that. This is the single biggest trust gap in the main project.

### Why it is the moat

Anyone can fork `StakedBountyEscrow.sol`. Nobody can clone a curated, growing, domain-calibrated labelled dataset of real `(criteria, PR diff)` pairs that has been used to tune a production judge. As the dataset grows and the accuracy compounds, the eval harness *becomes the defensible asset* — it is the thing a competitor has to rebuild from scratch.

### What the harness must do

1. Load a labelled set of cases: `{ specText, prText, label: "fulfilled" | "not_fulfilled" | "ambiguous" }`.
2. Call the live judge (`AnthropicJudge` in `resolver/src/judge.ts`) over each case.
3. Score **clear-cut** cases (fulfilled/not_fulfilled) for agreement with the human label.
4. Print per-case results, a confusion matrix summary, and an overall accuracy figure.
5. Exit non-zero when clear-cut accuracy falls below the gate threshold (≥ 90%).
6. Run in CI as a required check — blocks merge on regression.

### What it must NOT do at P0

- Make live GitHub API calls (inline diffs in the JSON keep the eval reproducible with no token)
- Touch the chain (no RPC, no key)
- Measure latency, cost, or other production concerns (those come later)

---

## 2. How the Leaders Do It

### 2.1 promptfoo (open-source, MIT) — the CI-native standard

**[promptfoo](https://www.promptfoo.dev/)** has become the de facto OSS standard for LLM regression testing, used by >350 000 developers and >25% of Fortune 500 companies as of 2026. Its key strengths for this use case:

- **Declarative YAML/JSON test configs** with `tests[].vars` (spec, PR) and `assert` blocks (`type: llm-rubric`, `type: javascript`, `type: equals`).
- **Programmatic TypeScript API** via `import { evaluate } from 'promptfoo'` — the `evaluate(testSuite, options)` function accepts a `TestSuiteConfiguration` object and returns an `EvaluateSummary` with per-case pass/fail. This integrates cleanly into a vitest runner.
- **CI/CD gate** built in: the CLI exits non-zero on any failure; a GitHub Actions step simply runs `npx promptfoo eval` and the pipeline blocks on failure. ([CI/CD docs](https://www.promptfoo.dev/docs/integrations/ci-cd/))
- **LLM-as-judge scorer** via `type: llm-rubric` which is itself LLM-graded, but for a binary `fulfilled/not_fulfilled` label we need only a deterministic exact-match assertion against the tool-call output, which is cleaner.

*Risk:* promptfoo is primarily a YAML-config tool; using it programmatically requires wrapping the existing `AnthropicJudge` as a custom provider, adding indirection. It adds a heavy dependency for a relatively simple problem.

**Verdict on promptfoo for web3-llm:** Use as an *optional* local developer tool for manual experimentation; do not make it the core harness implementation. The programmatic API works but is overbuilt for a focused binary classification gate.

Sources: [Promptfoo Review 2026](https://aitestingguide.com/promptfoo-review/), [Promptfoo Complete Guide 2026](https://qaskills.sh/blog/promptfoo-complete-guide-2026), [node-package API](https://www.promptfoo.dev/docs/usage/node-package/)

### 2.2 vitest-evals (Sentry, open-source) — vitest-native, CI-ready

**[vitest-evals](https://github.com/getsentry/vitest-evals)** is a Vitest extension built by Sentry that makes LLM evals look and feel like unit tests. The project was created by David Cramer on the premise that "evals are just tests, so why aren't engineers writing them?" ([Sentry blog](https://blog.sentry.io/evals-are-just-tests-so-why-arent-engineers-writing-them/))

Key API:

```typescript
describeEval("bounty verdict", { harness, judges }, (it) => {
  it("fulfilled health-endpoint case", async ({ run }) => {
    const result = await run("spec + pr text");
    await expect(result).toSatisfyJudge(judge, { threshold: 0.9 });
  });
});
```

CI integration:

```yaml
- run: npx vitest run --reporter=vitest-evals/reporter --reporter=json --outputFile=vitest-results.json
- uses: getsentry/vitest-evals@v0
  with:
    results: vitest-results.json
    publish-check: true
```

The `toSatisfyJudge` matcher enforces a threshold; below it the test fails and the job fails.  
**NPM:** [`vitest-evals`](https://www.npmjs.com/package/vitest-evals) · **Docs:** [vitest-evals.sentry.dev](https://vitest-evals.sentry.dev/)

*Verdict on vitest-evals for web3-llm:* A strong fit. The stack already uses vitest (`package.json` `devDependencies`). The `describeEval` pattern maps naturally onto the existing `AnthropicJudge` interface. For a binary classification task (fulfilled = true/false), we can skip the LLM-as-judge scorer and use a deterministic match function — simpler and faster than the generic judge.

### 2.3 Braintrust — SaaS platform, dataset management

**[Braintrust](https://www.braintrust.dev/)** is a full-platform SaaS (eval + prompt management + tracing + dataset versioning) with a GitHub Action that posts eval results to PRs and blocks merges on score drops. ([Best AI Eval Tools for CI/CD, 2026](https://www.braintrust.dev/articles/best-ai-evals-tools-cicd-2025))

Strengths: structured experiment history, LLM-as-judge scorers, human review queue, dataset versioning.  
*Risk for this project:* SaaS dependency, data sent to a third party (PR diffs that may reference private repos), overkill for a 15–30 case binary gate. Worth revisiting at P3 when the judge is in production and you want longitudinal tracking.

### 2.4 DeepEval — Python-first, TypeScript emerging

**[DeepEval](https://deepeval.com/)** offers 50+ metrics including `GEval` (LLM-as-judge), factuality, and G-Eval for binary verdicts. TypeScript support was added in 2025/2026 but appears to be a thin wrapper over the Python monorepo rather than a first-class SDK. ([DeepEval introduction](https://deepeval.com/docs/introduction))

For a pure TypeScript stack, DeepEval adds Python process-spawning complexity. Skip for now; revisit if the judge starts handling multi-step agentic tasks where its 50+ metrics add value.

### 2.5 Inspect AI (UK AISI) — academic rigor, Python only

**[Inspect AI](https://inspect.aisi.org.uk/)** is the UK AI Security Institute's open-source eval framework ([GitHub](https://github.com/UKGovernmentBEIS/inspect_ai)). Excellent for safety evals and benchmarks, 200+ contributed evaluations. Python-only. Wrong stack for web3-llm; mention only for completeness.

### 2.6 Agreement metrics — what the research says

A June 2026 arXiv paper ("Agreement Metrics for LLM-as-Judge Evaluation: What to Report and Why") found that **accuracy alone is unreliable on imbalanced datasets** and recommends reporting accuracy *together with* a marginal-sensitive agreement measure such as Cohen's κ. ([arXiv:2606.00093](https://arxiv.org/html/2606.00093))

In practice for a binary `fulfilled / not_fulfilled` judgment:

- **Clear-cut accuracy** = `correct / (fulfilled_cases + not_fulfilled_cases)`. Simple, interpretable. This is what blockllm uses and what we should gate on.
- **Cohen's κ** corrects for chance agreement. For a well-designed eval set with roughly equal positive/negative labels, κ ≥ 0.80 is "substantial agreement" (the JudgeBench benchmark found high-performing judges reach κ ≈ 0.95; ([JudgeBench arXiv:2410.12784](https://arxiv.org/pdf/2410.12784))). Report κ alongside accuracy as the dataset grows.
- **Confusion matrix** (TP/TN/FP/FN) lets you distinguish false-positive errors (wrongly paying out) from false-negative errors (wrongly withholding). For this oracle, false positives are catastrophic (funder loses ETH incorrectly); report them separately.
- **Ambiguous-case reasoning quality** is qualitative, reviewed by hand — not scored. This is the right call from blockllm.

---

## 3. Recommended Approach for This Stack

### Decision: port blockllm's harness idea natively into TS/vitest

Do not add a new framework dependency. The right implementation is:

1. **A `eval/` directory under `resolver/`** (so it shares the `package.json`, vitest, TypeScript config, and the `AnthropicJudge` class directly).
2. **A JSON dataset** (`eval/eval_set.json`, git-ignored; `eval/eval_set.example.json` committed as template with synthetic cases mirroring blockllm's schema — already proven to work).
3. **A vitest test file** (`eval/run_eval.test.ts`) that loads the dataset, calls `AnthropicJudge`, and asserts accuracy against the gate threshold.
4. **A dedicated CI job** (`eval-gate`) in `.github/workflows/ci.yml` that requires `ANTHROPIC_API_KEY` as a secret and runs this file — gated as a required check on `main`.

### 3.1 Dataset schema (extend blockllm's)

```typescript
// eval/types.ts
export interface EvalCase {
  id: number;
  label: "fulfilled" | "not_fulfilled" | "ambiguous";
  pr_ref: string;          // e.g. "owner/repo#42" — for traceability
  pr_title: string;
  criteria: string;        // specText sent to the judge
  diff: string;            // unified diff inline — reproducible without GitHub
  notes?: string;          // optional labeller rationale
}

export interface EvalSet {
  _comment: string;
  cases: EvalCase[];
}
```

This maps 1:1 to blockllm's `eval_set.example.json`. The `criteria` field → `specText`; the `diff` field (plus `pr_title`) → `prText`.

### 3.2 Harness file

```typescript
// eval/run_eval.test.ts
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import Anthropic from "@anthropic-ai/sdk";
import { AnthropicJudge } from "../src/judge.js";
import type { EvalCase, EvalSet } from "./types.js";

const GATE_THRESHOLD = 0.9;        // 90% on clear-cut — 9/10 minimum
const EVAL_SET_PATH = new URL("./eval_set.json", import.meta.url).pathname;

function formatPrText(c: EvalCase): string {
  return `## ${c.pr_title}\n\n### Diff\n\`\`\`diff\n${c.diff}\n\`\`\``;
}

describe("Judge-accuracy eval (P0 kill-gate)", () => {
  const raw: EvalSet = JSON.parse(readFileSync(EVAL_SET_PATH, "utf8"));
  const judge = AnthropicJudge.fromApiKey();   // uses ANTHROPIC_API_KEY env var

  const clearCases = raw.cases.filter(c => c.label !== "ambiguous");
  const ambiguousCases = raw.cases.filter(c => c.label === "ambiguous");

  // ---- clear-cut accuracy gate ----
  it(
    `clears ${GATE_THRESHOLD * 100}% accuracy on ${clearCases.length} clear-cut cases`,
    async () => {
      let agree = 0;
      const disagreements: string[] = [];

      for (const c of clearCases) {
        const verdict = await judge.judge({
          specText: c.criteria,
          prText: formatPrText(c),
        });
        const expected = c.label === "fulfilled";
        if (verdict.fulfilled === expected) {
          agree++;
        } else {
          disagreements.push(
            `[${c.id}] expected=${c.label} got=${verdict.fulfilled} | ${verdict.reasoning.slice(0, 120)}`
          );
        }
      }

      const accuracy = agree / clearCases.length;
      if (disagreements.length) {
        console.error("DISAGREEMENTS:\n" + disagreements.join("\n"));
      }
      expect(accuracy, `Clear-cut accuracy ${agree}/${clearCases.length}`).toBeGreaterThanOrEqual(GATE_THRESHOLD);
    },
    { timeout: clearCases.length * 30_000 }   // 30s per case budget
  );

  // ---- ambiguous cases: reasoning quality (logged, not scored) ----
  for (const c of ambiguousCases) {
    it.skip(`[ambiguous ${c.id}] ${c.pr_title} — review reasoning by hand`, async () => {
      const verdict = await judge.judge({
        specText: c.criteria,
        prText: formatPrText(c),
      });
      console.log(`[${c.id}] fulfilled=${verdict.fulfilled} | ${verdict.reasoning}`);
    });
  }
});
```

Key decisions in this design:
- Uses the real `AnthropicJudge` (not a stub) — the gate tests the actual production path.
- `it.skip` for ambiguous cases: they appear in output when `--reporter=verbose` but never fail CI. Run manually with `vitest run --reporter=verbose`.
- The `timeout` multiplier gives adequate budget for API latency.
- `GATE_THRESHOLD = 0.9` matches blockllm's 9/10 minimum. Promote to 1.0 once the dataset is mature.

### 3.3 Dataset assembly — the 15-case minimum

Mirror blockllm's proven design:

| Slice | Label | Count | How to source |
|---|---|---|---|
| Clear fulfilled | `fulfilled` | 5 | Real open-source PRs where the spec was clearly met — ideally from Gitcoin, Dework, or your own demo bounties |
| Clear not-fulfilled | `not_fulfilled` | 5 | PRs with missing tests, wrong versions, partial work — mirror blockllm cases 6–10 |
| Genuinely ambiguous | `ambiguous` | 5 | Cases where a careful engineer could argue either way: missing a stated sub-criterion but code is functionally correct, or wrong file but right behavior |

**Sourcing tip:** Use real GitHub PR diffs (copy the unified diff from `?diff=1` URL). Strip author names if diffs reference private repos. Store inline — never as URLs — so the eval runs without GitHub access.

**Anti-patterns to avoid:**
- Cases where the label is obvious from PR title alone (model uses shallow cues, not reasoning)
- Only positive-label cases (a yes-biased model passes trivially)
- Criteria that are intrinsically subjective (e.g., "write clean code")

### 3.4 Metrics to report

For the P0 gate:

```
Clear-cut accuracy:   N_agree / N_clear         (gate: ≥ 0.90)
Confusion matrix:     TP / TN / FP / FN         (FP = wrongly paid out — track separately)
```

Once the set reaches 30+ cases, add:

```
Cohen's κ:  (P_o - P_e) / (1 - P_e)           (target: κ ≥ 0.80)
Precision / Recall on "fulfilled" label
```

### 3.5 CI wiring

Add to `/home/user/Web3-llm/.github/workflows/ci.yml`:

```yaml
  eval-gate:
    name: Judge-accuracy eval (P0 gate)
    runs-on: ubuntu-latest
    # Only block on main and PR; skip on feature branches unless desired
    if: github.ref == 'refs/heads/main' || github.event_name == 'pull_request'
    defaults:
      run:
        working-directory: resolver
    env:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
          cache-dependency-path: resolver/package-lock.json

      - run: npm ci

      - name: Copy example eval set if real set absent
        run: |
          if [ ! -f eval/eval_set.json ]; then
            echo "WARNING: eval/eval_set.json not found. Copy eval/eval_set.example.json and populate with real labelled cases."
            exit 1
          fi

      - name: Run eval kill-gate
        run: npx vitest run eval/run_eval.test.ts --reporter=verbose
        timeout-minutes: 20
```

**Secret to add:** `ANTHROPIC_API_KEY` in the repo's GitHub Actions secrets. This is already needed by developers locally; CI is the same.

**Cost note:** 15 cases × ~1000 tokens each × `claude-opus-4-8` ≈ $0.15–0.30 per CI run with prompt caching engaged (the static `SYSTEM_RUBRIC` is already cache-controlled in `judge.ts`). Acceptable; skip on feature branches to reduce burn.

### 3.6 Porting from blockllm

The blockllm `eval_set.example.json` schema is a direct subset of what web3-llm needs. Port steps:

1. Copy `blockllm/evals/eval_set.example.json` → `resolver/eval/eval_set.example.json` (rename `criteria` field stays as-is; `diff` field stays as-is).
2. The 15 synthetic cases in blockllm's example can seed the web3-llm `eval_set.example.json` — they test the harness machinery, not the judge on real data.
3. The real `eval_set.json` (git-ignored) must be assembled fresh with cases from real bounties/PRs relevant to the web3-llm use case (Solidity, smart contract work, open-source bounties — not just generic Python API PRs).
4. **Do not** invoke `blockllm/evals/run_eval.py` from CI — it requires Python + the blockllm resolver package. The TS harness is the right owner.

---

## 4. Effort, Dependencies, Risks

### Effort: **S** (Small — 1–2 days engineering)

The harness itself is ~80 lines of TypeScript. The real cost is dataset assembly.

| Work item | Effort |
|---|---|
| Create `resolver/eval/` directory, `types.ts`, `run_eval.test.ts` | 2–4h |
| Copy and adapt `eval_set.example.json` from blockllm | 1h |
| Add `eval-gate` CI job to `ci.yml` | 1h |
| Assemble 15 real labelled cases | 4–8h (human research, the actual moat-building) |
| Add `ANTHROPIC_API_KEY` secret to GitHub | 15 min |
| **Total** | **~1–1.5 days** |

### Dependencies

- `ANTHROPIC_API_KEY` in CI secrets — already needed for other reasons.
- `vitest` — already in `devDependencies`, no new packages needed.
- Real PRs to label — can start with synthetic cases from blockllm for harness smoke-test, then layer in real cases over time.
- No new npm packages required for the minimal implementation. (vitest-evals is optional; adds GitHub check-run reporting but is not required for the gate.)

### Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Gate flakiness from API temperature/non-determinism | Medium | `temperature: 0` on verdict calls (add to `buildVerdictRequest`); retry once on failure |
| CI cost blows up if gate runs on every push | Low | Gate only on PRs and `main`; skip on short-lived feature branches |
| Dataset gets contaminated (cases that are obvious from title alone) | High | Label independently before running the harness; review disagreements with a human, not just the judge |
| False sense of security from synthetic eval set | High | Never gate on `eval_set.example.json`; the `if [ ! -f eval/eval_set.json ]` guard in CI enforces this |
| Model upgrade degrades accuracy silently | Medium | Pin model in `run_eval.test.ts`; promote model upgrade only after eval pass on new model |
| Prompt injection in curated cases | Low | Cases are internally sourced; document that externally-submitted cases must be reviewed before inclusion |

---

## 5. Verdict

### Roadmap phase fit

**P0 — this is the phase-gate itself.** The STRATEGY.md is explicit: "Gate: ≥ 90% agreement with human labels on clear-cut cases. Until this passes, nothing else ships." The eval harness is not optional infrastructure — it *is* Phase 0's exit condition.

### Go / No-Go

**GO. Unambiguously.** This is the single highest-leverage engineering action in the project right now. Without it, the product has no proof of its core claim. With it, the product has a number it can show to DAOs, grant programs, and technical users.

Priority relative to all other research areas: **1 of 10** — nothing else should ship until this is wired and green.

### Priority

**1 (highest)** — block on this before P1, P2, P3, or any deployment work.

### Implementation recommendation (concrete)

1. Create `resolver/eval/eval_set.example.json` (adapt from `blockllm/evals/eval_set.example.json`).
2. Create `resolver/eval/types.ts` and `resolver/eval/run_eval.test.ts` per §3.2.
3. Add the `eval-gate` job to `.github/workflows/ci.yml` per §3.5.
4. Assemble the real 15-case `eval_set.json` (git-ignored) and run locally first.
5. Once the gate passes locally on `claude-opus-4-8`, wire it to CI. This is the P0 exit.

### Summary table

| Dimension | Value |
|---|---|
| Phase fit | P0 (kill-gate) |
| Effort | S (1–2 days) |
| Go/No-go | GO |
| Priority | 1 (highest) |
| Key tool | vitest (already present) + `AnthropicJudge` (already present) |
| New dependencies | None required |
| Dataset minimum | 15 cases (5 fulfilled, 5 not_fulfilled, 5 ambiguous) |
| Gate threshold | ≥ 90% clear-cut accuracy (9/10 minimum) |
| Additional metric | Cohen's κ once set reaches 30+ cases |

---

*Sources consulted:*

- [Promptfoo CI/CD Integration](https://www.promptfoo.dev/docs/integrations/ci-cd/)
- [Promptfoo Review 2026 — Honest Look at LLM Testing](https://aitestingguide.com/promptfoo-review/)
- [Promptfoo Complete Guide 2026](https://qaskills.sh/blog/promptfoo-complete-guide-2026)
- [Best Prompt Evaluation Tools 2026 — Braintrust](https://www.braintrust.dev/articles/best-prompt-evaluation-tools-2025)
- [Best AI Eval Tools for CI/CD 2026 — Braintrust](https://www.braintrust.dev/articles/best-ai-evals-tools-cicd-2025)
- [vitest-evals — npm (getsentry)](https://www.npmjs.com/package/vitest-evals)
- [vitest-evals GitHub](https://github.com/getsentry/vitest-evals)
- [Evals are just tests — Sentry Blog](https://blog.sentry.io/evals-are-just-tests-so-why-arent-engineers-writing-them/)
- [LLM Evals in TypeScript, powered by Vitest](https://duckiedocs.substack.com/p/llm-evals-in-typescript-powered-by)
- [Writing an LLM Eval with Vercel's AI SDK and Vitest](https://xata.io/blog/llm-evals-with-vercel-ai-and-vitest)
- [Agreement Metrics for LLM-as-Judge Evaluation (arXiv:2606.00093)](https://arxiv.org/html/2606.00093)
- [JudgeBench: A Benchmark for Evaluating LLM-based Judges (arXiv:2410.12784)](https://arxiv.org/pdf/2410.12784)
- [LLM-as-a-Judge in 2026 — DeepEval](https://deepeval.com/blog/llm-as-a-judge)
- [DeepEval Introduction](https://deepeval.com/docs/introduction)
- [Inspect AI — UK AISI](https://inspect.aisi.org.uk/)
- [Judge's Verdict: Human Agreement Analysis — OpenReview](https://openreview.net/forum?id=jVyUlri4Rw)
- [LLM Readiness Harness — arXiv:2603.27355](https://arxiv.org/html/2603.27355)
- [CI/CD for LLM Apps — Evidently AI](https://www.evidentlyai.com/blog/llm-unit-testing-ci-cd-github-actions)
- [blockllm/evals/run_eval.py — sibling repo harness](../../../blockllm/evals/run_eval.py)
- [web3-llm resolver/src/judge.ts](../../resolver/src/judge.ts)
- [web3-llm docs/STRATEGY.md](../STRATEGY.md)
