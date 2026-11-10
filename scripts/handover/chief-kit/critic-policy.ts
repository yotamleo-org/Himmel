import { spawnSync } from "node:child_process";
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { createHash } from "node:crypto";
import { isAbsolute, resolve } from "node:path";
import { readCriticBudget } from "../../telegram/chief-route";
import { gitCleanEnv } from "../../lanes/git-clean.mjs";

//   bun critic-policy.ts check REQUEST.json                  exit 0 eligible, 3 operator-required, 4 refused, 2 malformed
//   bun critic-policy.ts routing-diff --base <40 hex>        exit 0 clear, 1 violations, 2 invalid

type Kind = "spec" | "plan";
type Artifact = { path: string; sha256: string };
type NumberedFile = { round: number; path: string };
type Round = {
  observed_count: number | null; requested: number | null; next: number | null; cap: number | null;
  operator_record: boolean | null; numberedFiles: NumberedFile[] | null; renamed: string[] | null;
};
export type Preflight = {
  schema: 1; kind: "critic-preflight"; operation_id: string | null;
  action: "eligible" | "operator-required" | "refused" | "malformed";
  source_head: string | null; artifacts: Artifact[]; round: Round; reasons: string[];
};
type Request = { operation_id: string; kind: Kind; spec_path: string; source_repo: string; source_head: string; artifacts: Artifact[]; requested_round: number };

const EXIT = { eligible: 0, "operator-required": 3, refused: 4, malformed: 2 } as const;
const REQUEST_KEYS = ["artifacts", "kind", "operation_id", "requested_round", "schema", "source_head", "source_repo", "spec_path"];
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const canonicalAbsolute = (p: unknown): p is string => typeof p === "string" && isAbsolute(p) && resolve(p) === p;
const nullRound = (requested: number | null = null): Round => ({ observed_count: null, requested, next: null, cap: null, operator_record: null, numberedFiles: null, renamed: null });
const malformed = (): { exit: number; output: Preflight } => ({
  exit: EXIT.malformed,
  output: { schema: 1, kind: "critic-preflight", operation_id: null, action: "malformed", source_head: null, artifacts: [], round: nullRound(), reasons: ["invalid"] },
});

function parseRequest(input: unknown): Request | null {
  if (!input || typeof input !== "object" || Array.isArray(input)) return null;
  const o = input as Record<string, unknown>;
  if (Object.keys(o).sort().join() !== REQUEST_KEYS.join()) return null;
  if (o.schema !== 1 || typeof o.operation_id !== "string" || o.operation_id === "") return null;
  if (o.kind !== "spec" && o.kind !== "plan") return null;
  if (!canonicalAbsolute(o.spec_path) || !canonicalAbsolute(o.source_repo)) return null;
  if (typeof o.source_head !== "string" || !HEX40.test(o.source_head)) return null;
  if (typeof o.requested_round !== "number" || !Number.isInteger(o.requested_round) || o.requested_round < 1) return null;
  if (!Array.isArray(o.artifacts)) return null;
  for (const a of o.artifacts) {
    if (!a || typeof a !== "object" || Object.keys(a).sort().join() !== "path,sha256") return null;
    if (!canonicalAbsolute((a as Artifact).path) || !HEX64.test((a as Artifact).sha256)) return null;
  }
  return o as unknown as Request;
}

function git(cwd: string, args: string[]) {
  const r = spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8", env: { ...gitCleanEnv(), GIT_OPTIONAL_LOCKS: "0" }, maxBuffer: 64 * 1024 * 1024 }); // git-env-ok: env built by gitCleanEnv()
  return { status: r.status, out: r.stdout ?? "" };
}

const sha256File = (p: string) => createHash("sha256").update(readFileSync(p)).digest("hex");
function artifactState(a: Artifact): "ok" | "artifact-unavailable" | "stale-artifact" {
  try {
    if (!lstatSync(a.path).isFile() || realpathSync(a.path) !== a.path) return "artifact-unavailable";
    return sha256File(a.path) === a.sha256 ? "ok" : "stale-artifact";
  } catch { return "artifact-unavailable"; }
}

export async function checkCriticSnapshot(input: unknown): Promise<{ exit: number; output: Preflight }> {
  const req = parseRequest(input);
  if (!req) return malformed();
  const reasons = new Set<string>();
  const [first, second] = req.artifacts;
  if (req.artifacts.length !== (req.kind === "spec" ? 1 : 2) || first?.path !== req.spec_path || (req.kind === "plan" && second?.path === req.spec_path)) reasons.add("binding-mismatch");

  const head = git(req.source_repo, ["rev-parse", "--verify", "HEAD"]);
  const actual = head.out.trim();
  if (head.status !== 0 || !HEX40.test(actual)) reasons.add("source-unavailable");
  else if (actual !== req.source_head) reasons.add("stale-source");

  for (const a of req.artifacts) { const s = artifactState(a); if (s !== "ok") reasons.add(s); }

  let round = nullRound(req.requested_round);
  let operatorRequired = false;
  if (reasons.size === 0) {
    try {
      const b = await readCriticBudget(req.spec_path, req.kind, req.requested_round);
      round = { observed_count: b.count, requested: req.requested_round, next: b.count + 1, cap: b.cap, operator_record: b.operatorAllowed, numberedFiles: b.numberedFiles, renamed: b.renamed };
      if (req.requested_round !== b.count + 1) reasons.add("round-mismatch");
      else operatorRequired = req.requested_round > b.cap && !b.operatorAllowed;
    } catch { reasons.add("round-unavailable"); }
  }
  const action = reasons.size > 0 ? "refused" : operatorRequired ? "operator-required" : "eligible";
  return {
    exit: EXIT[action],
    output: {
      schema: 1, kind: "critic-preflight", operation_id: req.operation_id, action, source_head: req.source_head,
      artifacts: req.artifacts.map(a => ({ path: a.path, sha256: a.sha256 })), round,
      reasons: action === "operator-required" ? ["operator-required"] : [...reasons],
    },
  };
}


const SKILL = "marketplace/plugins/himmel-ops/skills/minerva/SKILL.md";
const WHOLE_FILES = new Set([
  "marketplace/plugins/himmel-ops/skills/minerva/panel-charter.md", "marketplace/plugins/himmel-ops/skills/minerva/plan-charter.md",
  "scripts/hooks/guard-agent-model.sh", "scripts/guardrails/agent-model-policy.json", "scripts/handover/chief-kit/gen-judge-brief.py",
]);
const AGENTS_DIR = ".claude/agents/";
const PATHSPECS = [SKILL, ...WHOLE_FILES, AGENTS_DIR];
const isWholeFile = (p: string) => WHOLE_FILES.has(p) || p.startsWith(AGENTS_DIR);
const LEXICAL: Array<[string, RegExp]> = [
  ["model", /\bmodel\s*:/i], ["model-name", /\b(opus|sonnet|haiku|fable)\b/i], ["effort", /\beffort\b(?!-assess)/], ["Tier", /\bTier\b/],
  ["agent_type", /\bagent_type\b/], ["DEFAULT_MODEL", /\bDEFAULT_MODEL\b/], ["DELTA_MODEL", /\bDELTA_MODEL\b/], ["model_of", /\bmodel_of\b/],
];

export type RoutingViolation = { path: string; layer: "committed" | "index" | "worktree" | "untracked"; rule: string; line: number | null };
export class RoutingDiffError extends Error {
  constructor(public reason: "invalid-base" | "invalid-repo" | "git-failure", message: string) { super(message); }
}

export function resolveRepo(cwd: string): { top: string; head: string } {
  const top = git(cwd, ["rev-parse", "--show-toplevel"]);
  const head = git(cwd, ["rev-parse", "--verify", "HEAD"]);
  if (top.status !== 0 || head.status !== 0 || !HEX40.test(head.out.trim())) throw new RoutingDiffError("invalid-repo", `${cwd} is not a git worktree with a HEAD`);
  return { top: top.out.trim(), head: head.out.trim() };
}

type Raw = { srcMode: string; dstMode: string; status: string; path: string };
const DIFF_FLAGS = ["--no-ext-diff", "--no-textconv", "--no-color", "--no-renames"];

function rawEntries(top: string, range: string[]): Raw[] {
  const r = git(top, ["diff", ...DIFF_FLAGS, "--raw", "-z", ...range, "--", ...PATHSPECS]);
  if (r.status !== 0) throw new RoutingDiffError("git-failure", "git diff failed");
  const tokens = r.out.split("\0").filter(t => t !== "");
  const out: Raw[] = [];
  for (let i = 0; i + 1 < tokens.length; i += 2) {
    const m = /^:(\d+) (\d+) [0-9a-f]+ [0-9a-f]+ ([A-Z])\d*$/.exec(tokens[i]);
    if (!m) throw new RoutingDiffError("git-failure", "unreadable git diff output");
    out.push({ srcMode: m[1], dstMode: m[2], status: m[3], path: tokens[i + 1] });
  }
  return out;
}

function skillLexical(top: string, range: string[], layer: RoutingViolation["layer"]): RoutingViolation[] {
  const r = git(top, ["diff", ...DIFF_FLAGS, "-U0", ...range, "--", SKILL]);
  if (r.status !== 0) throw new RoutingDiffError("git-failure", "git diff failed");
  const out: RoutingViolation[] = [];
  let oldLine = 0, newLine = 0, inHunk = false;
  for (const text of r.out.split("\n")) {
    if (!inHunk && (text.startsWith("Binary files ") || text === "GIT binary patch")) return [{ path: SKILL, layer, rule: "unsupported-diff", line: null }];
    const h = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(text);
    if (h) { inHunk = true; oldLine = Number(h[1]); newLine = Number(h[2]); continue; }
    if (!inHunk || (text[0] !== "+" && text[0] !== "-")) continue;
    const line = text[0] === "+" ? newLine++ : oldLine++;
    for (const [rule, re] of LEXICAL) if (re.test(text.slice(1))) out.push({ path: SKILL, layer, rule, line });
  }
  return out;
}

export async function routingDiffViolations(repo: string, baseSha: string): Promise<RoutingViolation[]> {
  if (typeof baseSha !== "string" || !HEX40.test(baseSha)) throw new RoutingDiffError("invalid-base", "base must be a full 40-hex commit id");
  const { top } = resolveRepo(repo);
  if (git(top, ["cat-file", "-e", `${baseSha}^{commit}`]).status !== 0) throw new RoutingDiffError("invalid-base", "base is not a commit of this repository");
  const anc = git(top, ["merge-base", "--is-ancestor", baseSha, "HEAD"]).status;
  if (anc === 1) throw new RoutingDiffError("invalid-base", "base is not an ancestor of HEAD");
  if (anc !== 0) throw new RoutingDiffError("git-failure", "git merge-base failed");

  const found: RoutingViolation[] = [];
  const layers: Array<[RoutingViolation["layer"], string[]]> = [["committed", [baseSha, "HEAD"]], ["index", ["--cached"]], ["worktree", []]];
  for (const [layer, range] of layers) {
    for (const e of rawEntries(top, range)) {
      if (isWholeFile(e.path)) found.push({ path: e.path, layer, rule: "protected-file-changed", line: null });
      else if (e.path === SKILL) {
        if (e.status === "A") found.push({ path: SKILL, layer, rule: "new-protected-file", line: null });
        else if (e.status !== "M" || e.srcMode !== e.dstMode || !/^100[67]44$/.test(e.dstMode)) found.push({ path: SKILL, layer, rule: "unsupported-diff", line: null });
        else found.push(...skillLexical(top, range, layer));
      }
    }
  }
  const untracked = git(top, ["ls-files", "--others", "--exclude-standard", "-z", "--", ...PATHSPECS]);
  if (untracked.status !== 0) throw new RoutingDiffError("git-failure", "git ls-files failed");
  for (const p of untracked.out.split("\0").filter(Boolean)) {
    if (isWholeFile(p)) found.push({ path: p, layer: "untracked", rule: "protected-file-changed", line: null });
    else if (p === SKILL) found.push({ path: p, layer: "untracked", rule: "new-protected-file", line: null });
  }

  const seen = new Set<string>();
  const unique = found.filter(v => { const k = `${v.path}\0${v.layer}\0${v.line}\0${v.rule}`; return seen.has(k) ? false : (seen.add(k), true); });
  const cmp = (a: string | number, b: string | number) => (a < b ? -1 : a > b ? 1 : 0);
  return unique.sort((a, b) => cmp(a.path, b.path) || cmp(a.layer, b.layer) || cmp(a.line ?? -1, b.line ?? -1) || cmp(a.rule, b.rule));
}

type RoutingDiffOutput = {
  schema: 1; kind: "critic-routing-diff"; state: "clear" | "violations" | "invalid"; repo: string | null; base: string | null;
  head: string | null; violations: RoutingViolation[]; reasons: string[];
};

async function routingDiffCli(args: string[], cwd: string): Promise<{ exit: number; output: RoutingDiffOutput }> {
  const exact = args.length === 3 && args[1] === "--base";
  const base = exact && HEX40.test(args[2]) ? args[2] : null;
  const invalid = (reason: string, repo: string | null = null, head: string | null = null) => ({
    exit: 2, output: { schema: 1, kind: "critic-routing-diff", state: "invalid", repo, base, head, violations: [], reasons: [reason] } as RoutingDiffOutput,
  });
  if (!base) return invalid("invalid-base");
  let top: string, head: string;
  try { ({ top, head } = resolveRepo(cwd)); } catch { return invalid("invalid-repo"); }
  try {
    const violations = await routingDiffViolations(top, base);
    return { exit: violations.length ? 1 : 0, output: { schema: 1, kind: "critic-routing-diff", state: violations.length ? "violations" : "clear", repo: top, base, head, violations, reasons: violations.length ? ["routing-diff"] : [] } };
  } catch (e) {
    if (e instanceof RoutingDiffError) return invalid(e.reason, top, head);
    throw e;
  }
}

export async function main(args: string[], cwd = process.cwd()): Promise<number> {
  let result: { exit: number; output: unknown };
  if (args[0] === "routing-diff") result = await routingDiffCli(args, cwd);
  else if (args[0] === "check" && args.length === 2) {
    let input: unknown = null;
    try { input = JSON.parse(readFileSync(args[1], "utf8")); } catch {}
    result = await checkCriticSnapshot(input);
  } else result = malformed();
  process.stdout.write(`${JSON.stringify(result.output)}\n`);
  return result.exit;
}

if (import.meta.main) process.exitCode = await main(process.argv.slice(2));
