import assert from "node:assert/strict";
import { chmod, utimes, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, it } from "node:test";
import { createEgress, PURPOSE } from "../src/egress.js";
import { buildRepo, literalRule, REPO_ROOT, scratch } from "./helpers.js";

const GROK = "xai-grokbot";
const CHAT = "openai-chatgpt";

const LOAD = 'import { readFileSync } from "node:fs";\nexport const loadMatrix = (p) => JSON.parse(readFileSync(p, "utf8"));\n';
const stubEval = (verdict: string): string => `${LOAD}export const evaluate = () => (${verdict});\n`;

describe("egress gate against the real matrix", () => {
  it("allows every non-salus collection for both PA providers and reports each corpus", async () => {
    const egress = createEgress(REPO_ROOT);
    const expected: Record<string, string[]> = {
      luna: ["luna-personal", "luna-clippings"],
      "luna-pa": ["luna-personal", "luna-clippings"],
      himmel: ["himmel-code"],
      "jira-himmel": ["jira-mirror"],
      "station-ops": ["operator-repos"],
      "ggs-local": ["operator-repos"],
      "ggs-bridge": ["operator-repos"],
      "agent-command-chain": ["operator-repos"],
      "nvidia-steam-shader-cache": ["operator-repos"],
      "roadmap-plan": ["roadmap-plan"],
      skills: ["skill-index"],
    };
    for (const [collection, corpora] of Object.entries(expected)) {
      for (const provider of [GROK, CHAT]) {
        const d = await egress.check(collection, provider);
        assert.equal(d.allow, true, `${collection}/${provider}: ${d.reason}`);
        assert.deepEqual(d.corpora, corpora);
        assert.equal(d.reason, null);
      }
    }
    assert.equal(PURPOSE, "luna-mcp-read");
  });

  it("denies salus, an unmapped collection and an unknown provider", async () => {
    const egress = createEgress(REPO_ROOT);
    const salus = await egress.check("salus", GROK);
    assert.equal(salus.allow, false);
    const unmapped = await egress.check("mystery", GROK);
    assert.equal(unmapped.allow, false);
    assert.match(unmapped.reason ?? "", /unmapped/);
    assert.equal((await egress.check("luna", "local-ollama")).allow, false);
    assert.equal((await egress.check("luna", "openai-codex")).allow, false);
  });
});

describe("egress gate against synthetic matrices", () => {
  const corpus = { luna: ["luna-personal", "luna-clippings"], himmel: ["himmel-code"] };

  it("requires a literal allow+log row, so a wildcard allow+log row fails closed", async (t) => {
    const repo = await buildRepo(t, { corpus, matrix: { default: "deny", rules: [{ corpus: "himmel-code", provider: "*", purpose: "*", verdict: "allow+log" }] } });
    assert.equal((await createEgress(repo).check("himmel", GROK)).allow, false);
  });

  it("requires a literal allow+log row, so a wildcard allow fails closed", async (t) => {
    const repo = await buildRepo(t, { corpus, matrix: { default: "deny", rules: [{ corpus: "*", provider: "*", purpose: "*", verdict: "allow" }] } });
    assert.equal((await createEgress(repo).check("himmel", GROK)).allow, false);
  });

  it("fails closed when the literal row is plain allow rather than allow+log", async (t) => {
    const repo = await buildRepo(t, { corpus, matrix: { default: "deny", rules: [literalRule("himmel-code", GROK, "allow")] } });
    assert.equal((await createEgress(repo).check("himmel", GROK)).allow, false);
  });

  it("fails closed when the literal row is deny", async (t) => {
    const repo = await buildRepo(t, { corpus, matrix: { default: "deny", rules: [literalRule("himmel-code", GROK, "deny")] } });
    assert.equal((await createEgress(repo).check("himmel", GROK)).allow, false);
  });

  it("fails closed when an earlier wildcard deny shadows the literal allow+log row", async (t) => {
    const repo = await buildRepo(t, {
      corpus,
      matrix: { default: "deny", rules: [{ corpus: "himmel-code", provider: GROK, purpose: "*", verdict: "deny" }, literalRule("himmel-code", GROK)] },
    });
    const d = await createEgress(repo).check("himmel", GROK);
    assert.equal(d.allow, false);
    assert.match(d.reason ?? "", /himmel-code/);
  });

  it("allows when the literal row exists and nothing shadows it", async (t) => {
    const repo = await buildRepo(t, { corpus, matrix: { default: "deny", rules: [literalRule("himmel-code", GROK)] } });
    const d = await createEgress(repo).check("himmel", GROK);
    assert.equal(d.allow, true);
    assert.equal((await createEgress(repo).check("himmel", CHAT)).allow, false);
  });

  it("requires every corpus of a multi-corpus collection, naming the missing one", async (t) => {
    const repo = await buildRepo(t, { corpus, matrix: { default: "deny", rules: [literalRule("luna-personal", GROK)] } });
    const d = await createEgress(repo).check("luna", GROK);
    assert.equal(d.allow, false);
    assert.match(d.reason ?? "", /luna-clippings/);
    const both = await buildRepo(t, { corpus, matrix: { default: "deny", rules: [literalRule("luna-personal", GROK), literalRule("luna-clippings", GROK)] } });
    assert.equal((await createEgress(both).check("luna", GROK)).allow, true);
  });

  it("compares the evaluator's verdict field, not the returned object", async (t) => {
    const rules = [literalRule("himmel-code", GROK)];
    const denying = await buildRepo(t, { corpus, matrix: { default: "deny", rules }, evalSource: stubEval('{ verdict: "deny", note: "" }') });
    assert.equal((await createEgress(denying).check("himmel", GROK)).allow, false);
    const bare = await buildRepo(t, { corpus, matrix: { default: "deny", rules }, evalSource: stubEval('"allow+log"') });
    assert.equal((await createEgress(bare).check("himmel", GROK)).allow, false);
    const allowing = await buildRepo(t, { corpus, matrix: { default: "deny", rules }, evalSource: stubEval('{ verdict: "allow+log", note: "" }') });
    assert.equal((await createEgress(allowing).check("himmel", GROK)).allow, true);
  });

  it("treats a throwing evaluator as a denial", async (t) => {
    const repo = await buildRepo(t, { corpus, matrix: { default: "deny", rules: [literalRule("himmel-code", GROK)] }, evalSource: `${LOAD}export const evaluate = () => { throw new Error("boom"); };\n` });
    assert.equal((await createEgress(repo).check("himmel", GROK)).allow, false);
  });

  it("fails closed on a corpus map entry that is not a list of corpus names", async (t) => {
    const repo = await buildRepo(t, { corpus: { himmel: "himmel-code", luna: [], bad: [1] }, matrix: { default: "deny", rules: [literalRule("himmel-code", GROK)] } });
    const egress = createEgress(repo);
    assert.equal((await egress.check("himmel", GROK)).allow, false);
    assert.equal((await egress.check("luna", GROK)).allow, false);
    assert.equal((await egress.check("bad", GROK)).allow, false);
  });

  it("reloads a changed matrix without a restart", async (t) => {
    const repo = await buildRepo(t, { corpus, matrix: { default: "deny", rules: [literalRule("himmel-code", GROK)] } });
    const egress = createEgress(repo);
    assert.equal((await egress.check("himmel", GROK)).allow, true);
    const file = join(repo, "scripts/guardrails/egress-matrix.json");
    await writeFile(file, JSON.stringify({ default: "deny", rules: [] }));
    await utimes(file, 1, 2);
    assert.equal((await egress.check("himmel", GROK)).allow, false);
  });
});

describe("egress gate fails closed when the repo is unusable", () => {
  it("denies everything for an unset or missing HIMMEL_REPO", async (t) => {
    const missing = join(await scratch(t), "does-not-exist");
    for (const repo of [undefined, "", missing]) {
      const d = await createEgress(repo).check("himmel", GROK);
      assert.equal(d.allow, false);
      assert.deepEqual(d.corpora, []);
      assert.match(d.reason ?? "", /egress-unavailable/);
    }
  });

  it("denies when the matrix, the corpus map or the evaluator is missing or malformed", async (t) => {
    const corpus = { himmel: ["himmel-code"] };
    const rules = { default: "deny", rules: [literalRule("himmel-code", GROK)] };
    for (const skip of ["eval", "matrix", "corpus"] as const) {
      const repo = await buildRepo(t, { corpus, matrix: rules, skip: [skip] });
      assert.equal((await createEgress(repo).check("himmel", GROK)).allow, false, `missing ${skip}`);
    }
    const bad = await buildRepo(t, { corpus, matrix: "{not json" });
    assert.equal((await createEgress(bad).check("himmel", GROK)).allow, false);
    const noRules = await buildRepo(t, { corpus, matrix: { default: "deny" } });
    assert.equal((await createEgress(noRules).check("himmel", GROK)).allow, false);
  });

  it("denies when the repo files are unreadable", async (t) => {
    if (process.getuid?.() === 0) return t.skip("root reads every file");
    const repo = await buildRepo(t, { corpus: { himmel: ["himmel-code"] }, matrix: { default: "deny", rules: [literalRule("himmel-code", GROK)] } });
    await chmod(join(repo, "scripts/guardrails/egress-matrix.json"), 0o000);
    assert.equal((await createEgress(repo).check("himmel", GROK)).allow, false);
  });
});
