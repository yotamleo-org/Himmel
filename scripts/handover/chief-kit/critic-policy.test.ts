import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, realpathSync, chmodSync, symlinkSync, rmSync, readdirSync, lstatSync, readlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, basename } from "node:path";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import * as route from "../../telegram/chief-route";
import { gitCleanEnv } from "../../lanes/git-clean.mjs";

const policy = () => import("./critic-policy");
const CLI = join(import.meta.dir, "critic-policy.ts");
const BUN = process.execPath;
const T = 60_000;

const git = (cwd: string, ...args: string[]) => {
  const r = spawnSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", ...args], { cwd, encoding: "utf8", env: gitCleanEnv() });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
};
const made: string[] = [];
const tmp = (prefix: string) => { const d = realpathSync(mkdtempSync(join(tmpdir(), prefix))); made.push(d); return d; };
afterAll(() => { for (const d of made) rmSync(d, { recursive: true, force: true }); });
const treeHash = (dir: string): string => {
  const h = createHash("sha256");
  const walk = (d: string) => {
    for (const n of readdirSync(d).sort()) {
      if (n === ".git" || n === "request.json") continue;
      const p = join(d, n); const s = lstatSync(p);
      if (s.isDirectory()) walk(p);
      else h.update(`${p}\0${s.isSymbolicLink() ? readlinkSync(p) : readFileSync(p).toString("base64")}\0`);
    }
  };
  walk(dir);
  return h.digest("hex");
};
const sha = (p: string) => createHash("sha256").update(readFileSync(p)).digest("hex");
const put = (p: string, text: string | Uint8Array) => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, text); };

type Fx = { root: string; spec: string; plan: string; head: string };
const ROUTE = join(import.meta.dir, "../../telegram/chief-route.ts");
const KEY = "HIMMEL-1";
function fixture(opts: { spec?: number; plan?: number; blocking?: boolean } = {}): Fx {
  const root = tmp("critic-policy-");
  const spec = join(root, `specs/design/${KEY}-subject.md`);
  const plan = join(root, `specs/plans/${KEY}-subject.md`);
  put(spec, "# Subject\n"); put(plan, "# Plan\n"); mkdirSync(join(root, "specs/decisions"), { recursive: true });
  git(root, "init", "-q"); git(root, "add", "-A"); git(root, "commit", "-q", "-m", "base");
  const fx = { root, spec, plan, head: git(root, "rev-parse", "HEAD") };
  const verdict = (kind: string) => (opts.blocking ? `${kind} FINDINGS 1` : `${kind} CLEAN`);
  for (let n = 1; n <= (opts.spec ?? 0); n++) put(`${spec}.critic-spec-r${n}.md`, `Read it, round ${n}.\n${opts.blocking ? `CONTENT-SHA256 ${sha(spec)} ${basename(spec)}\n` : ""}${verdict("SPEC")}\n`);
  for (let n = 1; n <= (opts.plan ?? 0); n++) put(`${spec}.critic-plan-r${n}.md`, `Read it, round ${n}.\n${verdict("PLAN")}\n`);
  const seeded = spawnSync(BUN, [ROUTE, "round-seed", "--all", join(root, "specs")], { encoding: "utf8" });
  if (seeded.status !== 0) throw new Error(`round-seed: ${seeded.stderr}`);
  return fx;
}
const ledgerOf = (fx: Fx) => join(fx.root, `specs/ledgers/spec-rounds/${KEY}.jsonl`);
const operatorRecord = (fx: Fx, round: number) => {
  put(`${fx.spec}.operator-round-r${round}.md`, "decision 7\n");
  put(join(fx.root, "specs/decisions/verbatim-decision-7-words.txt"), "operator words\n");
};
const request = (fx: Fx, over: Record<string, unknown> = {}) => ({
  schema: 1, operation_id: "op-1", kind: "spec", spec_path: fx.spec, source_repo: fx.root, source_head: fx.head,
  artifacts: [{ path: fx.spec, sha256: sha(fx.spec) }], requested_round: 1, ...over,
});
const planRequest = (fx: Fx, over: Record<string, unknown> = {}) => request(fx, {
  kind: "plan", artifacts: [{ path: fx.spec, sha256: sha(fx.spec) }, { path: fx.plan, sha256: sha(fx.plan) }], ...over,
});
type Run = { code: number | null; out: string; json: any };
function run(dir: string, args: string[], env: NodeJS.ProcessEnv = process.env): Run {
  const r = spawnSync(BUN, [CLI, ...args], { cwd: dir, encoding: "utf8", env });
  let json: any = null;
  try { json = JSON.parse(r.stdout); } catch {}
  return { code: r.status, out: r.stdout, json };
}
function check(fx: Fx, body: unknown, extra: string[] = [], env?: NodeJS.ProcessEnv): Run {
  const file = join(fx.root, "request.json");
  writeFileSync(file, typeof body === "string" ? body : JSON.stringify(body));
  return run(fx.root, ["check", file, ...extra], env);
}

test("round_owner_parity", async () => {
  const a = fixture({ spec: 3 });
  put(`${a.spec}.critic-spec-renamed.md`, "Read it.\nSPEC FINDINGS 1\n");
  const budget = await route.readCriticBudget(a.spec, "spec");
  expect(budget).toMatchObject({ count: 3, requestedRound: 4, allowed: false, cap: route.CRITIC_ROUND_CAP });
  expect(budget.why).toBe(`${KEY} spec round 4 needs a blocking finding in round 3 of either kind; sign it under 848, its minors go to the build`);
  put(`${a.spec}.critic-spec-r4.md`, "Round four.\nSPEC CLEAN\n");
  await expect(route.refuseRoundPastCap(`${a.spec}.critic-spec-r4.md`, a.spec)).rejects.toThrow(budget.why!);

  const c = fixture({ spec: 3, blocking: true });
  expect(await route.readCriticBudget(c.spec, "spec", 4)).toMatchObject({ count: 3, requestedRound: 4, allowed: true, why: null });
  put(`${c.spec}.critic-spec-r4.md`, `CLOSURE-CHECK ${KEY} spec r3 ${route.returnSha(readFileSync(`${c.spec}.critic-spec-r3.md`, "utf8")).slice(0, 12)}\nRound four.\nSPEC CLEAN\n`);
  await route.refuseRoundPastCap(`${c.spec}.critic-spec-r4.md`, c.spec);
}, T);

test("requested_round_exact_next", async () => {
  const none = fixture();
  expect((await route.readCriticBudget(none.spec, "spec")).requestedRound).toBe(1);
  expect(check(none, request(none, { requested_round: 1 })).code).toBe(0);
  for (const r of [2, 3]) expect(check(none, request(none, { requested_round: r })).json).toMatchObject({ action: "refused", reasons: ["round-mismatch"] });

  const two = fixture({ spec: 2 });
  expect(check(two, request(two, { requested_round: 3 })).code).toBe(0);
  for (const r of [2, 4]) expect(check(two, request(two, { requested_round: r })).code).toBe(4);

  const three = fixture({ spec: 3 });
  expect(check(three, request(three, { requested_round: 4 })).json).toMatchObject({ action: "operator-required", reasons: ["operator-required"] });
  expect(check(three, request(three, { requested_round: 4 })).code).toBe(3);
  for (const r of [3, 5]) expect(check(three, request(three, { requested_round: r })).code).toBe(4);
  for (const bad of [0, -1, 1.5, "4", true, null]) expect(check(three, request(three, { requested_round: bad })).code).toBe(2);
}, T);

test("blocking_round_three_opens_exactly_round_four", async () => {
  const fx = fixture({ spec: 3, blocking: true });
  const ok = check(fx, request(fx, { requested_round: 4 }));
  expect(ok.code).toBe(0);
  expect(ok.json).toMatchObject({ action: "eligible", reasons: [], round: { observed_count: 3, requested: 4, next: 4, cap: 3, allowed: true } });

  const five = check(fx, request(fx, { requested_round: 5 }));
  expect(five.code).toBe(4);
  expect(five.json).toMatchObject({ action: "refused", reasons: ["round-mismatch"], round: { observed_count: 3, requested: 5, next: 4, allowed: null } });
  const six = check(fx, request(fx, { requested_round: 2 }));
  expect(six.json.round.allowed).toBeNull();

  const bare = fixture({ spec: 3 });
  operatorRecord(bare, 4);
  expect(check(bare, request(bare, { requested_round: 4 })).code).toBe(3);
}, T);

test("source_and_artifact_hash_bound", async () => {
  const fx = fixture({ spec: 1 });
  const good = check(fx, request(fx, { requested_round: 2 }));
  expect(good.json).toMatchObject({ action: "eligible", source_head: fx.head, artifacts: [{ path: fx.spec, sha256: sha(fx.spec) }] });

  expect(check(fx, request(fx, { requested_round: 2, source_head: "0".repeat(40) })).json).toMatchObject({ action: "refused", reasons: ["stale-source"] });
  expect(check(fx, request(fx, { requested_round: 2, source_repo: tmp("not-a-repo-") })).json).toMatchObject({ action: "refused", reasons: ["source-unavailable"] });
  expect(check(fx, request(fx, { requested_round: 2, artifacts: [{ path: fx.spec, sha256: "f".repeat(64) }] })).json).toMatchObject({ action: "refused", reasons: ["stale-artifact"] });
  expect(check(fx, request(fx, { requested_round: 2, spec_path: join(fx.root, "specs/design/missing.md"), artifacts: [{ path: join(fx.root, "specs/design/missing.md"), sha256: "a".repeat(64) }] })).json.reasons).toContain("artifact-unavailable");

  const p = fixture({ plan: 1 });
  expect(check(p, planRequest(p, { requested_round: 2 })).code).toBe(0);
  expect(check(p, planRequest(p, { requested_round: 2, artifacts: [{ path: p.plan, sha256: sha(p.plan) }, { path: p.spec, sha256: sha(p.spec) }] })).json.reasons).toContain("binding-mismatch");
  expect(check(p, planRequest(p, { requested_round: 2, artifacts: [{ path: p.spec, sha256: sha(p.spec) }, { path: p.spec, sha256: sha(p.spec) }] })).json.reasons).toContain("binding-mismatch");
  expect(check(p, planRequest(p, { requested_round: 2, artifacts: [{ path: p.spec, sha256: sha(p.spec) }, { path: p.plan, sha256: "0".repeat(64) }] })).json.reasons).toContain("stale-artifact");
  expect(check(fx, request(fx, { requested_round: 2, artifacts: [{ path: fx.spec, sha256: sha(fx.spec) }, { path: fx.plan, sha256: sha(fx.plan) }] })).json.reasons).toContain("binding-mismatch");

  const link = join(fx.root, "specs/design/alias.md");
  symlinkSync(fx.spec, link);
  expect(check(fx, request(fx, { requested_round: 2, spec_path: link, artifacts: [{ path: link, sha256: sha(fx.spec) }] })).code).toBe(4);
  expect(check(fx, request(fx, { requested_round: 2, spec_path: "specs/design/subject.md", artifacts: [{ path: "specs/design/subject.md", sha256: sha(fx.spec) }] })).code).toBe(2);
}, T);

test("unknown_source_not_eligible", async () => {
  const fx = fixture();
  const empty = tmp("empty-repo-");
  git(empty, "init", "-q");
  const cases: Array<[string, Run]> = [
    ["no commits at source", check(fx, request(fx, { source_repo: empty }))],
    ["source is not a directory", check(fx, request(fx, { source_repo: join(fx.root, "nothing-here") }))],
    ["request file missing", run(fx.root, ["check", join(fx.root, "no-such-request.json")])],
    ["request is not JSON", check(fx, "{not json")],
    ["request is an array", check(fx, [])],
    ["request is empty", check(fx, "")],
  ];
  for (const [name, r] of cases) {
    expect(r.code, name).not.toBe(0);
    expect(r.json?.action, name).not.toBe("eligible");
    expect(r.json, name).not.toBeNull();
  }
  expect(cases[0][1].json).toMatchObject({ action: "refused", reasons: ["source-unavailable"] });
  expect(cases[2][1].code).toBe(2);
}, T);

test("unreadable_round_not_zero", async () => {
  const fx = fixture({ spec: 1 });
  writeFileSync(ledgerOf(fx), `${readFileSync(ledgerOf(fx), "utf8")}not json\n`);
  await expect(route.readCriticBudget(fx.spec, "spec")).rejects.toThrow(`${KEY} ledger line 2 does not parse`);
  const r = check(fx, request(fx, { requested_round: 2 }));
  expect(r.code).toBe(4);
  expect(r.json).toMatchObject({
    action: "refused", reasons: ["round-unavailable"],
    round: { observed_count: null, requested: 2, next: null, cap: null, allowed: null, rounds: null },
  });

  const gone = fixture({ spec: 1 });
  rmSync(ledgerOf(gone));
  await expect(route.readCriticBudget(gone.spec, "spec")).rejects.toThrow(`${KEY} is in the round manifest but has no ledger`);
  const d = check(gone, request(gone, { requested_round: 2 }));
  expect(d.code).toBe(4);
  expect(d.json).toMatchObject({ action: "refused", reasons: ["round-unavailable"], round: { observed_count: null, rounds: null } });
}, T);

test("request_parser_guards", async () => {
  const fx = fixture(); const p = planRequest(fx);
  const good = request(fx);
  const bad: Array<[string, unknown]> = [
    ["schema 2", { ...good, schema: 2 }], ["schema as string", { ...good, schema: "1" }], ["schema missing", (({ schema, ...r }) => r)(good)],
    ["operation_id empty", { ...good, operation_id: "" }], ["operation_id number", { ...good, operation_id: 7 }], ["operation_id missing", (({ operation_id, ...r }) => r)(good)],
    ["kind unknown", { ...good, kind: "design" }], ["kind capitalised", { ...good, kind: "Spec" }], ["kind number", { ...good, kind: 1 }],
    ["head short", { ...good, source_head: fx.head.slice(0, 39) }], ["head uppercase", { ...good, source_head: fx.head.toUpperCase() }], ["head number", { ...good, source_head: 1 }],
    ["head with newline", { ...good, source_head: `${fx.head}\n` }],
    ["spec_path relative", { ...good, spec_path: "specs/design/subject.md" }], ["spec_path not normalised", { ...good, spec_path: `${fx.root}/specs/../specs/design/subject.md` }],
    ["source_repo relative", { ...good, source_repo: "." }],
    ["artifacts object", { ...good, artifacts: { path: fx.spec, sha256: sha(fx.spec) } }], ["artifacts null", { ...good, artifacts: null }],
    ["artifact is a string", { ...good, artifacts: [fx.spec] }], ["artifact null", { ...good, artifacts: [null] }],
    ["artifact extra key", { ...good, artifacts: [{ path: fx.spec, sha256: sha(fx.spec), mode: "x" }] }],
    ["artifact sha missing", { ...good, artifacts: [{ path: fx.spec }] }], ["artifact sha short", { ...good, artifacts: [{ path: fx.spec, sha256: "a".repeat(63) }] }],
    ["artifact sha uppercase", { ...good, artifacts: [{ path: fx.spec, sha256: sha(fx.spec).toUpperCase() }] }],
    ["artifact path relative", { ...good, artifacts: [{ path: "subject.md", sha256: sha(fx.spec) }] }],
    ["plan artifact path number", { ...p, artifacts: [{ path: fx.spec, sha256: sha(fx.spec) }, { path: 3, sha256: sha(fx.plan) }] }],
  ];
  for (const [name, body] of bad) {
    const r = check(fx, body);
    expect(r.code, name).toBe(2);
    expect(r.json, name).toMatchObject({ action: "malformed", reasons: ["invalid"] });
  }
  expect(check(fx, good).code).toBe(0);
}, T);

test("ledger_rounds_from_same_pass", async () => {
  const fx = fixture({ spec: 2, plan: 1 });
  put(`${fx.spec}.critic-plan-renamed.md`, "Read it.\nPLAN FINDINGS 2\n");
  put(join(fx.root, `specs/plans/${KEY}-subject.md.critic-plan-r2.md`), "Read it.\nPLAN FINDINGS 1\n");
  const plan = await route.readCriticBudget(fx.spec, "plan");
  expect(plan.rounds).toEqual([{ round: 1, path: `${fx.spec}.critic-plan-r1.md` }]);
  expect(plan).toMatchObject({ count: 1 });

  const spec = await route.readCriticBudget(fx.spec, "spec");
  expect(spec.rounds).toEqual([{ round: 2, path: `${fx.spec}.critic-spec-r2.md` }]);
  expect(spec).toMatchObject({ count: 2 });

  const out = check(fx, planRequest(fx, { requested_round: 2 })).json;
  expect(out.round.rounds).toEqual(plan.rounds);
  expect(out.round.observed_count).toBe(plan.count);
}, T);

test("check_exit_json", async () => {
  const fx = fixture({ spec: 3 });
  const eligible = fixture();
  const stale = request(fx, { requested_round: 2 });
  const branches: Array<[number, string, Run]> = [
    [0, "eligible", check(eligible, request(eligible))],
    [3, "operator-required", check(fx, request(fx, { requested_round: 4 }))],
    [4, "refused", check(fx, stale)],
    [2, "malformed", check(fx, "{not json")],
  ];
  const TOP = ["action", "artifacts", "kind", "operation_id", "reasons", "round", "schema", "source_head"];
  const ROUND = ["allowed", "cap", "next", "observed_count", "requested", "rounds"];
  for (const [code, action, r] of branches) {
    expect(r.code, action).toBe(code);
    expect(r.out.trim().split("\n").length, `${action}: one JSON line`).toBe(1);
    expect(Object.keys(r.json).sort(), action).toEqual(TOP);
    expect(Object.keys(r.json.round).sort(), action).toEqual(ROUND);
    expect(r.json).toMatchObject({ schema: 1, kind: "critic-preflight", action });
    expect(Array.isArray(r.json.reasons)).toBe(true);
  }
  expect(branches[0][2].json.operation_id).toBe("op-1");
  expect(branches[3][2].json).toMatchObject({ operation_id: null, source_head: null, artifacts: [], reasons: ["invalid"] });
  expect(Object.values(branches[3][2].json.round).every(v => v === null)).toBe(true);

  const { checkCriticSnapshot } = await policy();
  const inProcess = await checkCriticSnapshot(request(eligible));
  expect(inProcess.exit).toBe(0);
  expect(inProcess.output).toEqual(branches[0][2].json);
}, T);

test("no_route_or_dispatch_fields", async () => {
  const fx = fixture({ spec: 3 });
  const eligible = fixture();
  operatorRecord(fx, 4);
  const outputs = [
    check(eligible, request(eligible)), check(fx, request(fx, { requested_round: 4 })), check(fx, request(fx, { requested_round: 9 })),
    check(fx, "{not json"), check(fx, request(fx, { model: "x" })),
  ].map(r => r.json);
  const FORBIDDEN = /model|agent|effort|tier|route|dispatch|prompt|budget|spend|lever|study|admission|launch|approval|grant/i;
  const keys = (v: unknown): string[] => (v && typeof v === "object") ? Object.entries(v).flatMap(([k, x]) => [k, ...keys(x)]) : [];
  for (const o of outputs) expect(keys(o).filter(k => FORBIDDEN.test(k))).toEqual([]);
  const mod = await policy();
  expect(Object.keys(mod).filter(k => /route|dispatch|recommend|select/i.test(k) && k !== "routingDiffViolations")).toEqual([]);
}, T);

const SKILL = "marketplace/plugins/himmel-ops/skills/minerva/SKILL.md";
const PANEL = "marketplace/plugins/himmel-ops/skills/minerva/panel-charter.md";
const PLANCH = "marketplace/plugins/himmel-ops/skills/minerva/plan-charter.md";
const AGENT = ".claude/agents/judge-ro.md";
const GUARD = "scripts/hooks/guard-agent-model.sh";
const POLICY = "scripts/guardrails/agent-model-policy.json";
const GEN = "scripts/handover/chief-kit/gen-judge-brief.py";
const SKILL_BASE = "# Minerva\n\nIntake wording.\nSee effort-assess for sizing; tiers and frontier work are elsewhere.\nLast line.\n";
function routingRepo(skill: string | null = SKILL_BASE): { repo: string; base: string } {
  const repo = tmp("routing-diff-");
  if (skill !== null) put(join(repo, SKILL), skill);
  put(join(repo, PANEL), "panel charter\n"); put(join(repo, PLANCH), "plan charter\n"); put(join(repo, AGENT), "---\nname: judge-ro\n---\n");
  put(join(repo, GUARD), "#!/bin/sh\nTIER=1\n"); put(join(repo, POLICY), '{"blocked_model_patterns":["a"],"warn_model_patterns":["b"]}\n');
  put(join(repo, GEN), "print('x')\n"); put(join(repo, "README.md"), "readme\n");
  git(repo, "init", "-q"); git(repo, "add", "-A"); git(repo, "commit", "-q", "-m", "base");
  return { repo, base: git(repo, "rev-parse", "HEAD") };
}
type Layer = "committed" | "index" | "worktree" | "untracked";
function inLayer(repo: string, layer: Layer, change: () => void, untracked?: () => void) {
  if (layer === "untracked") { (untracked ?? change)(); return; }
  change();
  if (layer === "committed") { git(repo, "add", "-A"); git(repo, "commit", "-q", "-m", "change"); }
  if (layer === "index") git(repo, "add", "-A");
}
const rows = (v: Array<{ path: string; layer: string; rule: string; line: number | null }>, path?: string) =>
  v.filter(x => path === undefined || x.path === path).map(x => `${x.layer}:${x.rule}:${x.line}`);

test("routing_diff_fixtures", async () => {
  const { routingDiffViolations } = await policy();

  const clean = routingRepo();
  expect(await routingDiffViolations(clean.repo, clean.base)).toEqual([]);

  const lexical: Array<[string, string[]]> = [
    ["Dispatch the opted-in critic with `model: haiku`.", ["model", "model-name"]],
    ["MoDeL: HAIKU", ["model", "model-name"]],
    ["Set the effort to high.", ["effort"]], ["Tier 1 applies.", ["Tier"]], ["Pass agent_type judge.", ["agent_type"]],
    ["Uses DEFAULT_MODEL here.", ["DEFAULT_MODEL"]], ["Uses DELTA_MODEL here.", ["DELTA_MODEL"]], ["Uses model_of here.", ["model_of"]],
    ["Unrelated intake wording.", []], ["Run effort-assess for sizing.", []], ["Lower tiers and frontier work.", []], ["Read the models page.", []],
  ];
  for (const [text, rules] of lexical) {
    const { repo, base } = routingRepo();
    put(join(repo, SKILL), SKILL_BASE.replace("Intake wording.", text));
    git(repo, "add", "-A"); git(repo, "commit", "-q", "-m", "c");
    const v = await routingDiffViolations(repo, base);
    expect(v.filter(x => x.path === SKILL).map(x => x.rule).sort(), text).toEqual([...rules].sort());
    for (const x of v) { expect(x.layer).toBe("committed"); expect(x.line).toBe(3); expect(Object.keys(x).sort()).toEqual(["layer", "line", "path", "rule"]); }
  }

  const fam = routingRepo(SKILL_BASE.replace("Last line.", "Use Opus for the plan critic."));
  put(join(fam.repo, SKILL), SKILL_BASE.replace("Last line.", "Use Haiku for the plan critic."));
  git(fam.repo, "add", "-A"); git(fam.repo, "commit", "-q", "-m", "c");
  expect([...new Set((await routingDiffViolations(fam.repo, fam.base)).map(x => x.rule))]).toEqual(["model-name"]);

  const del = routingRepo(SKILL_BASE.replace("Last line.", "Tier 3 here."));
  put(join(del.repo, SKILL), SKILL_BASE.replace("Last line.\n", ""));
  git(del.repo, "add", "-A"); git(del.repo, "commit", "-q", "-m", "c");
  const removed = (await routingDiffViolations(del.repo, del.base)).filter(x => x.rule === "Tier");
  expect(removed.map(x => x.line)).toEqual([4]);

  const top = routingRepo(SKILL_BASE.replace("# Minerva\n", "Tier 0 intro\n"));
  put(join(top.repo, SKILL), SKILL_BASE.replace("# Minerva\n", ""));
  git(top.repo, "add", "-A"); git(top.repo, "commit", "-q", "-m", "c");
  expect((await routingDiffViolations(top.repo, top.base)).filter(x => x.rule === "Tier").map(x => x.line)).toEqual([1]);

  for (const layer of ["committed", "index", "worktree"] as const) {
    const { repo, base } = routingRepo();
    inLayer(repo, layer, () => put(join(repo, SKILL), SKILL_BASE.replace("Intake wording.", "Tier 2 applies.")));
    expect(rows(await routingDiffViolations(repo, base), SKILL), layer).toEqual([`${layer}:Tier:3`]);
  }

  const whole: Array<[string, (repo: string) => void]> = [
    [GUARD, repo => put(join(repo, GUARD), "#!/bin/sh\nTIER=2\nESCALATION=3\n")],
    [POLICY, repo => put(join(repo, POLICY), '{"blocked_model_patterns":["a","c"],"warn_model_patterns":["b"]}\n')],
    [GEN, repo => put(join(repo, GEN), "print('y')\n")],
    [AGENT, repo => put(join(repo, AGENT), "---\nname: judge-ro\nmodel: x\n---\n")],
    [PANEL, repo => put(join(repo, PANEL), "panel charter, edited\n")],
    [PLANCH, repo => put(join(repo, PLANCH), "plan charter\n\n")],
  ];
  for (const [path, change] of whole) {
    for (const layer of ["committed", "index", "worktree"] as const) {
      const { repo, base } = routingRepo();
      inLayer(repo, layer, () => change(repo));
      const v = await routingDiffViolations(repo, base);
      expect(v, `${path} ${layer}`).toEqual([{ path, layer, rule: "protected-file-changed", line: null }]);
    }
  }
  const shapes: Array<[string, string, (repo: string) => void]> = [
    ["delete", AGENT, repo => rmSync(join(repo, AGENT))],
    ["mode", GUARD, repo => chmodSync(join(repo, GUARD), 0o755)],
    ["type", PANEL, repo => { rmSync(join(repo, PANEL)); symlinkSync("plan-charter.md", join(repo, PANEL)); }],
    ["add", ".claude/agents/new-agent.md", repo => put(join(repo, ".claude/agents/new-agent.md"), "new\n")],
  ];
  for (const [name, path, change] of shapes) {
    for (const layer of ["committed", "index", "worktree", "untracked"] as const) {
      if (layer === "untracked" ? name !== "add" : layer === "worktree" && name === "add") continue;
      const { repo, base } = routingRepo();
      inLayer(repo, layer, () => change(repo));
      expect(rows(await routingDiffViolations(repo, base), path), `${name} ${layer}`).toEqual([`${layer}:protected-file-changed:null`]);
    }
  }

  const skillShapes: Array<[string, (repo: string) => void, string]> = [
    ["binary", repo => put(join(repo, SKILL), Buffer.concat([Buffer.from(SKILL_BASE), Buffer.from([0, 1, 2, 0])])), "unsupported-diff"],
    ["mode", repo => chmodSync(join(repo, SKILL), 0o755), "unsupported-diff"],
    ["type", repo => { rmSync(join(repo, SKILL)); symlinkSync("../../../../../README.md", join(repo, SKILL)); }, "unsupported-diff"],
  ];
  for (const [name, change, rule] of skillShapes) {
    const { repo, base } = routingRepo();
    inLayer(repo, "committed", () => change(repo));
    expect(rows(await routingDiffViolations(repo, base), SKILL), name).toEqual([`committed:${rule}:null`]);
  }
  for (const layer of ["committed", "index", "untracked"] as const) {
    const { repo, base } = routingRepo(null);
    inLayer(repo, layer, () => put(join(repo, SKILL), "# Minerva\nUnrelated.\n"));
    expect(rows(await routingDiffViolations(repo, base), SKILL), `new ${layer}`).toEqual([`${layer}:new-protected-file:null`]);
  }

  const other = routingRepo();
  put(join(other.repo, "README.md"), "readme, edited\n"); put(join(other.repo, "docs/new.md"), "model: x\n");
  expect(await routingDiffViolations(other.repo, other.base)).toEqual([]);
  const sorted = routingRepo();
  inLayer(sorted.repo, "committed", () => { put(join(sorted.repo, SKILL), SKILL_BASE.replace("Last line.", "Tier 9.\nMoDeL: HAIKU")); put(join(sorted.repo, GUARD), "#!/bin/sh\n"); });
  const got = await routingDiffViolations(sorted.repo, sorted.base);
  const key = (x: { path: string; layer: string; line: number | null; rule: string }) => [x.path, x.layer, String(x.line ?? -1).padStart(6, "0"), x.rule].join("|");
  expect(got.map(key)).toEqual(got.map(key).sort());
  expect(got.length).toBeGreaterThan(2);

  const inv = routingRepo();
  put(join(inv.repo, "README.md"), "second\n"); git(inv.repo, "add", "-A"); git(inv.repo, "commit", "-q", "-m", "second");
  const second = git(inv.repo, "rev-parse", "HEAD");
  git(inv.repo, "checkout", "-q", "--detach", inv.base);
  for (const bad of [undefined, "", "HEAD", "main", inv.base.slice(0, 12), inv.base.toUpperCase(), "0".repeat(40), second]) {
    await expect(routingDiffViolations(inv.repo, bad as string), String(bad)).rejects.toMatchObject({ reason: "invalid-base" });
  }
  await expect(routingDiffViolations(tmp("not-a-repo-"), inv.base)).rejects.toMatchObject({ reason: "invalid-repo" });
  const unborn = tmp("unborn-"); git(unborn, "init", "-q");
  await expect(routingDiffViolations(unborn, inv.base)).rejects.toMatchObject({ reason: "invalid-repo" });
}, T);

test("routing_diff_cli_parity", async () => {
  const { routingDiffViolations } = await policy();
  const KEYS = ["base", "head", "kind", "reasons", "repo", "schema", "state", "violations"];

  const ok = routingRepo();
  mkdirSync(join(ok.repo, "scripts/handover"), { recursive: true });
  const clear = run(join(ok.repo, "scripts/handover"), ["routing-diff", "--base", ok.base]);
  expect(clear.code).toBe(0);
  expect(Object.keys(clear.json).sort()).toEqual(KEYS);
  expect(clear.json).toEqual({ schema: 1, kind: "critic-routing-diff", state: "clear", repo: ok.repo, base: ok.base, head: ok.base, violations: [], reasons: [] });

  const bad = routingRepo();
  inLayer(bad.repo, "worktree", () => put(join(bad.repo, SKILL), SKILL_BASE.replace("Intake wording.", "Use `model: haiku`.")));
  const viol = run(bad.repo, ["routing-diff", "--base", bad.base]);
  expect(viol.code).toBe(1);
  expect(viol.json).toMatchObject({ state: "violations", reasons: ["routing-diff"], repo: bad.repo, base: bad.base });
  expect(viol.json.violations).toEqual(await routingDiffViolations(bad.repo, bad.base));
  expect(viol.json.violations.length).toBeGreaterThan(0);

  const invalid: Array<[string, Run, string]> = [
    ["no base", run(ok.repo, ["routing-diff"]), "invalid-base"],
    ["abbreviated", run(ok.repo, ["routing-diff", "--base", ok.base.slice(0, 10)]), "invalid-base"],
    ["symbolic", run(ok.repo, ["routing-diff", "--base", "HEAD"]), "invalid-base"],
    ["missing commit", run(ok.repo, ["routing-diff", "--base", "1".repeat(40)]), "invalid-base"],
    ["unknown flag", run(ok.repo, ["routing-diff", "--base", ok.base, "--model", "x"]), "invalid-base"],
    ["not a repo", run(tmp("not-a-repo-"), ["routing-diff", "--base", ok.base]), "invalid-repo"],
  ];
  const broken = routingRepo();
  writeFileSync(join(broken.repo, ".git/index"), "not an index");
  invalid.push(["git failure", run(broken.repo, ["routing-diff", "--base", broken.base]), "git-failure"]);
  for (const [name, r, reason] of invalid) {
    expect(r.code, name).toBe(2);
    expect(r.json, name).toMatchObject({ schema: 1, kind: "critic-routing-diff", state: "invalid", violations: [], reasons: [reason] });
    expect(Object.keys(r.json).sort(), name).toEqual(KEYS);
  }
  expect(invalid[5][1].json).toMatchObject({ repo: null, head: null });
}, T);

test("no_model_or_approval_calls", async () => {
  const shims = tmp("shims-"); const log = join(shims, "calls.log");
  for (const name of ["claude", "gh", "jira"]) {
    put(join(shims, name), `#!/bin/sh\necho "${name} $*" >> "${log}"\nexit 99\n`); chmodSync(join(shims, name), 0o755);
  }
  const realNode = Bun.which("node");
  if (realNode) {
    put(join(shims, "node"), `#!/bin/sh\ncase "$1" in */scripts/jira/dist/index.js) echo "node $*" >> "${log}"; exit 99;; esac\nexec "${realNode}" "$@"\n`);
    chmodSync(join(shims, "node"), 0o755);
  }
  const env = { ...process.env, PATH: `${shims}:${process.env.PATH}` };
  const calls = () => (existsSync(log) ? readFileSync(log, "utf8") : "");

  expect(spawnSync("claude", ["--print", "x"], { env }).status).toBe(99);
  expect(calls()).toContain("claude --print x");
  rmSync(log);

  const three = fixture({ spec: 3 }); const none = fixture();
  const fixtureHashes = [treeHash(three.root), treeHash(none.root)];
  const exits = [
    [0, check(none, request(none), [], env)], [3, check(three, request(three, { requested_round: 4 }), [], env)],
    [4, check(three, request(three, { requested_round: 9 }), [], env)], [2, check(three, "{not json", [], env)],
  ] as const;
  for (const [code, r] of exits) expect(r.code).toBe(code);
  const r = routingRepo(); const dirty = routingRepo();
  put(join(dirty.repo, GUARD), "#!/bin/sh\n");
  expect(run(r.repo, ["routing-diff", "--base", r.base], env).code).toBe(0);
  expect(run(dirty.repo, ["routing-diff", "--base", dirty.base], env).code).toBe(1);
  expect(run(dirty.repo, ["routing-diff"], env).code).toBe(2);
  expect(calls()).toBe("");
  expect([treeHash(three.root), treeHash(none.root)], "snapshot fixture files unchanged by every exit branch").toEqual(fixtureHashes);
}, T);

test("routing_diff_runs_no_external_program", async () => {
  const { routingDiffViolations } = await policy();
  const { repo, base } = routingRepo();
  const aux = tmp("hide-");
  const marks = join(aux, "ran");
  const hide = join(aux, "hide.sh");
  put(hide, `#!/bin/sh\necho x >> "${marks}"\necho constant\n`); chmodSync(hide, 0o755);
  put(join(repo, ".gitattributes"), `${SKILL} diff=hide\n`);
  git(repo, "config", "diff.hide.textconv", hide);
  git(repo, "config", "diff.external", hide);
  git(repo, "add", "-A"); git(repo, "commit", "-q", "-m", "attrs");
  const attrBase = git(repo, "rev-parse", "HEAD");
  put(join(repo, SKILL), SKILL_BASE.replace("Intake wording.", "Tier 2 applies."));
  expect(rows(await routingDiffViolations(repo, attrBase), SKILL)).toEqual(["worktree:Tier:3"]);
  git(repo, "add", "-A"); git(repo, "commit", "-q", "-m", "c");
  expect(rows(await routingDiffViolations(repo, attrBase), SKILL)).toEqual(["committed:Tier:3"]);
  const cli = run(repo, ["routing-diff", "--base", attrBase]);
  expect(cli.code).toBe(1);
  expect(existsSync(marks), "no textconv or external diff program ran").toBe(false);
  void base;
}, T);

test("routing_diff_unexpected_error_is_invalid_exit_2", async () => {
  const { routingDiffCli } = await policy();
  const { repo, base } = routingRepo();
  const r = await routingDiffCli(["routing-diff", "--base", base], repo, async () => { throw new TypeError("not a RoutingDiffError"); });
  expect(r.exit).toBe(2);
  expect(r.output).toEqual({ schema: 1, kind: "critic-routing-diff", state: "invalid", repo, base, head: base, violations: [], reasons: ["git-failure"] });
}, T);

test("retired_options_rejected", async () => {
  const fx = fixture();
  for (const key of ["model", "agent", "effort", "lever", "study", "admission", "agent_type", "tier"]) {
    const r = check(fx, request(fx, { [key]: "x" }));
    expect(r.code, key).toBe(2);
    expect(r.json, key).toMatchObject({ action: "malformed", reasons: ["invalid"] });
  }
  const file = join(fx.root, "request.json");
  writeFileSync(file, JSON.stringify(request(fx)));
  const bad: string[][] = [
    ["check", file, "--model", "haiku"], ["check", file, "--effort", "high"], ["check", file, "--study"], ["check", file, "--readiness", "m.json"],
    ["check", "--admission", file], ["check"], ["check", file, "extra.json"], ["bogus", file], [], ["--model", "x"],
    ["routing-diff", "--base", fx.head, "--model", "x"],
  ];
  for (const args of bad) {
    const r = run(fx.root, args);
    expect(r.code, args.join(" ")).toBe(2);
    expect(r.json, args.join(" ")).not.toBeNull();
    expect(r.json.action ?? r.json.state, args.join(" ")).toMatch(/^(malformed|invalid)$/);
  }
  expect(check(fx, request(fx)).code).toBe(0);
}, T);
