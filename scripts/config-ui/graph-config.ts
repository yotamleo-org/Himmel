import { spawn } from "node:child_process";
import { basename, resolve } from "node:path";
// @ts-ignore CommonJS module without types
import { inspect, save } from "../himmelctl/lib/luna-config.js";
// @ts-ignore CommonJS module without types
import * as choices from "../himmelctl/lib/graph-choices.js";
// @ts-ignore plain ES module, no types
import { ACCOUNTS } from "../lib/api-credit-state.mjs";

type Env = Record<string, string | undefined>;
export type GraphResult = { status: number; body: Record<string, unknown> };

const TIMEOUT_MS = 10_000;
const CHOICES_CLI = resolve(import.meta.dir, "../himmelctl/lib/graph-choices.js");
const CREDIT_CLI = resolve(import.meta.dir, "../lib/api-credit-state.mjs");
const CADENCE = resolve(import.meta.dir, "../graphify/graph-choices-cadence.sh");
const CADENCE_ALERT = resolve(import.meta.dir, "../luna/cadence-alert.sh");
const LETTER = /^[A-Z]$/;
const SENTENCE: Record<string, string> = { default: choices.NO_CHOICE_SENTENCE, none: choices.NONE_SENTENCE, set: choices.SET_SENTENCE, invalid: choices.INVALID_SENTENCE };
const PUBLISHER_REASON = "This station publishes the himmel graph, so graph choices are ignored here. To leave that role: remove graphify.semantic_api_ok from ~/.himmel/config.json, run bash scripts/lib/config-audit.sh accept, then bash scripts/luna/graphmap-cadence.sh arm --rewrite-armed --leave-publisher.";

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

function run(cmd: string, args: string[], env: Env): Promise<{ code: number | null; out: string }> {
  const clean: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined) clean[k] = v;
  return new Promise((done) => {
    let out = "", settled = false;
    const child = spawn(cmd, args, { env: clean, stdio: ["ignore", "pipe", "ignore"] });
    const finish = (code: number | null) => { if (settled) return; settled = true; clearTimeout(timer); done({ code, out: code === 0 ? out : "" }); };
    const timer = setTimeout(() => child.kill("SIGKILL"), TIMEOUT_MS);
    child.stdout.on("data", (d) => { out += d; });
    child.on("error", () => finish(null));
    child.on("close", (code) => finish(code));
  });
}

async function roster(env: Env): Promise<unknown> {
  const r = await run("node", [CREDIT_CLI, "accounts"], env);
  try { return JSON.parse(r.out); } catch { return { accounts: "unreadable", reason: "unreadable-state" }; }
}

const rosterLine = (answer: unknown): string | null =>
  isObject(answer) && answer.accounts === "unreadable" ? choices.rosterCheck({ version: 1, primary: ACCOUNTS[0] }, answer)[0] : null;

function unreadableLine(cause: string): string {
  return `graph config unreadable (cause=${cause}): ${choices.CAUSE_LINES[cause]} Fix: ${choices.FIX_LINES[cause]}`;
}

const letters = (r: { state: string; order: string[] }) => (r.state === "set" ? r.order.filter((v) => LETTER.test(v)) : []);

export async function readGraph(env: Env): Promise<GraphResult> {
  const station = choices.readStation();
  const r = choices.route(station);
  const [worst, first, answer, job] = await Promise.all([
    run("node", [CHOICES_CLI, "worst-case"], env),
    run("node", [CHOICES_CLI, "first-question"], env),
    roster(env),
    run("bash", [CADENCE, "status"], env),
  ]);
  const set = r.state === "set", none = r.state === "none";
  return { status: 200, body: {
    role: station.role,
    state: r.state,
    corpora: r.corpora,
    primary: set ? r.order[0] : none ? "none" : null,
    fallbacks: set ? r.order.slice(1) : [],
    max_usd_per_pass: r.max_usd_per_pass,
    sentence: station.role === "unreadable" ? unreadableLine(station.cause) : SENTENCE[r.state] ?? "",
    worst_case: worst.out.split("\n").filter(Boolean),
    first_question: first.out.trim(),
    accounts: Array.isArray(answer) ? answer.filter(isObject).map((a) => ({ account: a.account, configured: a.configured === true, tag: a.tag })) : [],
    roster: rosterLine(answer),
    job: job.code !== 0 ? "unknown" : /^ARMED\b/.test(job.out) ? "armed" : "not armed",
    reason: station.role === "publisher" ? PUBLISHER_REASON : station.role === "unreadable" ? unreadableLine(station.cause) : null,
  } };
}

function corpusName(root: string, taken: Set<string>): string {
  const base = basename(root).replace(/[^A-Za-z0-9._-]/g, "-").replace(/^[^A-Za-z0-9]+/, "") || "repo";
  let name = base;
  for (let n = 2; taken.has(name); n++) name = `${base}-${n}`;
  taken.add(name);
  return name;
}

function toChoices(b: Record<string, unknown>): Record<string, unknown> {
  const rows = Array.isArray(b.corpora) ? b.corpora : [];
  const taken = new Set(rows.filter(isObject).map((c) => c.name).filter((n): n is string => typeof n === "string" && n !== ""));
  const corpora = rows.map((c) => {
    if (!isObject(c)) return c;
    const root = c.root;
    return { name: typeof c.name === "string" && c.name !== "" ? c.name : typeof root === "string" ? corpusName(root, taken) : "", root };
  });
  const out: Record<string, unknown> = { version: 1, corpora, primary: b.primary, fallbacks: b.fallbacks ?? [] };
  if (b.max_usd_per_pass !== undefined && b.max_usd_per_pass !== null) out.max_usd_per_pass = b.max_usd_per_pass;
  return out;
}

function clearGraphKey(letter: string, env: Env): Promise<unknown> {
  return run("bash", [CADENCE_ALERT, "clear", `graph-key-${letter}`], env);
}

function roleRefusal(station: { role: string; cause: string }): GraphResult | null {
  if (station.role === "publisher") return { status: 409, body: { error: PUBLISHER_REASON } };
  if (station.role === "unreadable") return { status: 409, body: { error: unreadableLine(station.cause) } };
  return null;
}

export async function writeGraph(b: Record<string, unknown>, env: Env): Promise<GraphResult> {
  const early = roleRefusal(choices.readStation());
  if (early) return early;
  const next = toChoices(b);
  const shape: string[] = choices.validateShape(next);
  if (shape.length) return { status: 400, body: { error: shape.join("; ") } };
  const roots: string[] = (next.corpora as { name: string; root: string }[]).flatMap((c) => choices.rootCheck(c.root).map((e: string) => `${c.root}: ${e}`));
  if (roots.length) return { status: 400, body: { error: roots.join("; ") } };
  const refused: string[] = choices.rosterCheck(next, await roster(env));
  if (refused.length) return { status: 400, body: { error: refused.join("; ") } };
  const station = choices.readStation();
  const late = roleRefusal(station);
  if (late) return late;
  const before = letters(choices.route(station));
  try {
    const { doc } = inspect();
    doc.graphify = { ...(isObject(doc.graphify) ? doc.graphify : {}), choices: next };
    save(doc);
  } catch (e) { return { status: 422, body: { error: (e as Error).message } }; }
  const after = letters(choices.route());
  for (const l of before.filter((x) => !after.includes(x))) await clearGraphKey(l, env);
  return readGraph(env);
}
