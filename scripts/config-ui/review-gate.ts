// the config UI's read and write of the review gate. The effective reviewer set comes from the ONE resolver
// (scripts/lib/critics-config.sh), so this page cannot disagree with the gate. The only file ever written is a
// critics.local.json overlay: a candidate overlay is resolved first, and nothing lands unless the resolver and the
// "one hard reviewer" rule accept it. The base scripts/cr/critics.json is a trust path and is never opened for write.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { homedir } from "node:os";

type Env = Record<string, string | undefined>;
type Row = { slug: string; provider?: string; model?: string; tier?: string; mode: string; required: boolean };
type Resolved = { review: string | null; panel: Row[]; files: { base: string; local: string | null } };
export type GateResult = { status: number; body: Record<string, unknown> };

const RESOLVER = resolve(import.meta.dir, "../lib/critics-config.sh");
const MODES: readonly string[] = ["hard", "best-effort"];
const RECOMMENDED: Readonly<Record<string, { mode: string; required: boolean; enabled: boolean }>> = {
  codex: { mode: "hard", required: true, enabled: true },
  claude: { mode: "best-effort", required: false, enabled: false }, // the Claude API critic is off (decision 108)
  coderabbit: { mode: "best-effort", required: false, enabled: true },
};
export const RATE_LIMIT = "CodeRabbit rate limited or absent is a note and continue: the gate never waits for it. Heavy CI releases on a clean CodeRabbit or a clean critic at the head.";
const ENV_KNOBS: readonly { name: string; default: string; means: string }[] = [
  { name: "CR_PROFILE", default: "unset (paid codex anchor where configured)", means: "which critic tier /pr-check runs; none = Claude alone, no outside reviewer" },
  { name: "CR_REQUIRE_CROSS_MODEL", default: "off", means: "when on, at least one non-Claude critic must pass before the review marker clears" },
  { name: "CR_FLOOR_FALLBACK", default: "unset", means: "what stands in when every other critic is out of quota; claude-only is never counted as cross-model" },
  { name: "CRITIC_PANEL_TIERS", default: "free", means: "which tiers of reviewers run, comma separated" },
  { name: "CRITIC_TIMEOUT_SECS", default: "240", means: "how long one reviewer may run, in seconds" },
  { name: "CRITIC_PARALLEL", default: "0 (one after another)", means: "1 runs the reviewers at the same time" },
];

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

function resolveGate(env: Env, overlay?: string): { ok: true; r: Resolved } | { ok: false; error: string } {
  const e: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined) e[k] = v;
  if (overlay !== undefined) e.CRITICS_LOCAL_JSON = overlay;
  try {
    const out = execFileSync("bash", ["-c", '. "$1" && critics_config_resolve', "_", RESOLVER], { env: e, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 15_000 });
    return { ok: true, r: JSON.parse(out.trim().split("\n").pop() as string) };
  } catch (err) {
    const msg = String((err as { stderr?: unknown }).stderr || (err as Error).message).trim();
    return { ok: false, error: msg.split("\n").pop() || "the reviewer config could not be read" };
  }
}

// where a write goes: the overlay the resolver already reads, else the per-machine cache the resolver looks in first.
function overlayPath(env: Env, r: Resolved): string {
  if (env.CRITICS_LOCAL_JSON) return env.CRITICS_LOCAL_JSON;
  return r.files.local ?? join(env.HIMMELCTL_CACHE_DIR || join(env.HOME || homedir(), ".claude", "himmel"), "critics.local.json");
}

function readOverlay(path: string): { panel: Record<string, unknown>[]; rest: Record<string, unknown> } {
  if (!existsSync(path)) return { panel: [], rest: {} };
  const j = JSON.parse(readFileSync(path, "utf8"));
  if (!isObject(j)) throw new Error(`${path} is not a JSON object`);
  const { panel, ...rest } = j;
  if (panel !== undefined && !Array.isArray(panel)) throw new Error(`${path}: panel is not an array`);
  return { panel: (panel ?? []).filter(isObject), rest };
}

export function readGate(env: Env): GateResult {
  const g = resolveGate(env);
  if (!g.ok) return { status: 422, body: { error: g.error } };
  const path = overlayPath(env, g.r);
  let dropped: string[] = [];
  try { dropped = readOverlay(path).panel.filter((x) => x.drop === true && typeof x.slug === "string").map((x) => x.slug as string); } catch { /* an unreadable overlay shows as no drops; the resolver already named it */ }
  // a dropped row is off the resolved panel, so its shared settings come from the base file: turning it back on restores them.
  const droppedBase: Record<string, { mode: string; required: boolean }> = {};
  try {
    for (const x of readOverlay(g.r.files.base).panel) {
      if (typeof x.slug !== "string" || !dropped.includes(x.slug)) continue;
      droppedBase[x.slug] = { mode: typeof x.mode === "string" ? x.mode : x.provider === "github-app" ? "best-effort" : "hard", required: x.required === true };
    }
  } catch { /* an unreadable base shows the plain defaults; the resolver already named it */ }
  return {
    status: 200,
    body: {
      review: g.r.review,
      overlay: path,
      dropped,
      droppedBase,
      rateLimit: RATE_LIMIT,
      reviewers: g.r.panel.map((row, i) => ({
        slug: row.slug, order: i + 1, provider: row.provider ?? "", mode: row.mode, required: row.required, enabled: true,
        recommended: RECOMMENDED[row.slug] ?? { mode: row.mode, required: row.required, enabled: true },
      })),
      env: ENV_KNOBS.map((k) => ({ ...k, value: env[k.name] ?? null })),
    },
  };
}

const fail = (error: string): GateResult => ({ status: 400, body: { error } });

// body: { reviewers: [{ slug, mode, required, enabled }] }. Only those three fields of a row are ever written.
export function writeGate(env: Env, b: Record<string, unknown>): GateResult {
  if (env.CRITICS_JSON) return fail("CRITICS_JSON is set, so no overlay is read; unset it to edit the review gate here");
  const g = resolveGate(env);
  if (!g.ok) return { status: 422, body: { error: g.error } };
  const path = overlayPath(env, g.r);
  if (basename(path) !== "critics.local.json") return fail("refusing to write anything but a critics.local.json overlay");
  if (!Array.isArray(b.reviewers)) return fail("reviewers must be a list");
  let cur: ReturnType<typeof readOverlay>;
  try { cur = readOverlay(path); } catch (e) { return { status: 422, body: { error: (e as Error).message } }; }
  const known = new Set([...g.r.panel.map((x) => x.slug), ...cur.panel.map((x) => x.slug as string)]);
  const panel = cur.panel.map((x) => ({ ...x }));
  for (const x of b.reviewers) {
    if (!isObject(x) || typeof x.slug !== "string" || !known.has(x.slug)) return fail("unknown reviewer");
    if (typeof x.mode !== "string" || !MODES.includes(x.mode)) return fail(`mode must be ${MODES.join(" or ")}`);
    if (typeof x.required !== "boolean" || typeof x.enabled !== "boolean") return fail("required and enabled must be true or false");
    const row: Record<string, unknown> = x.enabled ? { slug: x.slug, mode: x.mode, required: x.required } : { slug: x.slug, drop: true };
    const at = panel.findIndex((p) => p.slug === x.slug);
    if (at < 0) panel.push(row);
    else {
      const merged = { ...panel[at], ...row };
      if (x.enabled) delete merged.drop; else { delete merged.mode; delete merged.required; }
      panel[at] = merged;
    }
  }
  const text = JSON.stringify({ ...cur.rest, panel }, null, 2) + "\n";
  const tmp = `${path}.tmp-${process.pid}`;
  try {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(tmp, text);
    const c = resolveGate(env, tmp);
    if (!c.ok) return fail(c.error.replace(tmp, path));
    if (!c.r.review && !c.r.panel.some((r) => r.mode === "hard")) return fail("no hard reviewer would be left; keep at least one reviewer on hard");
    renameSync(tmp, path);
  } catch (e) {
    return { status: 422, body: { error: (e as Error).message } };
  } finally {
    try { unlinkSync(tmp); } catch { /* renamed into place, or never written */ }
  }
  return readGate(env);
}
