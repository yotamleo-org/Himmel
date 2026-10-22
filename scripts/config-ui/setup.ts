// the Setup page's server side: which secrets exist and whether each is set, the commit rules in effect, and the one
// write path for a secret value. The value is held in a local for the write only: it is never logged, audited,
// returned, or put in an error.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import * as store from "../himmelctl/lib/secret-store.js";
import manifest from "../himmelctl/lib/secrets-manifest.json";

type Env = Record<string, string | undefined>;
export type SetupOpts = { env: Env; home: string; himmelRoot: string; projectRoot: string };
export type SecretResult = { status: number; body: Record<string, unknown>; audit: { action: string; target: string; ok: boolean } | null };

type Entry = { name: string; collect: string; feature?: string; required?: string };
const entries = manifest.secrets as Entry[];

// shown under each secret form: shaped like the real value, never a working one.
const EXAMPLES: Record<string, string> = {
  BITBUCKET_API_TOKEN: "<app password from Bitbucket settings>",
  BITBUCKET_EMAIL: "you@example.com",
  TELEGRAM_BOT_TOKEN: "<token from @BotFather, digits:letters>",
  JIRA_API_TOKEN: "<API token from id.atlassian.com>",
  JIRA_BASE_URL: "https://your-team.atlassian.net", // env-literal-ok: a placeholder shown as an example, never used as a host
  JIRA_EMAIL: "you@example.com",
  JIRA_PROJECT_KEY: "ABC",
};

const gitCheckIgnore = (file: string): boolean => {
  try { execFileSync("git", ["check-ignore", "-q", file], { cwd: dirname(file), stdio: "ignore", timeout: 10_000 }); return true; }
  catch { return false; }
};
const ctxOf = (o: SetupOpts) => ({ home: o.home, himmelRoot: o.himmelRoot, projectRoot: o.projectRoot, env: o.env, gitCheckIgnore });

// ~/.himmel/himmel.conf, where the wizard writes the commit rules; null for a key it does not carry.
function commitRules(home: string) {
  const kv: Record<string, string> = {};
  try {
    for (const l of readFileSync(join(home, ".himmel", "himmel.conf"), "utf8").split("\n")) {
      const m = /^(TRACKER|TICKET_ID_REQUIRED)=(.*)$/.exec(l);
      if (m && !(m[1] in kv)) kv[m[1]] = m[2];
    }
  } catch { /* no conf yet */ }
  return { tracker: kv.TRACKER ?? null, ticketIdRequired: kv.TICKET_ID_REQUIRED === "1" ? true : kv.TICKET_ID_REQUIRED === "0" ? false : null };
}

const CR_APP_URL = "https://github.com/apps/coderabbitai";
const CR_JQ = '[.[].statusCheckRollup[]? | select(.context == "CodeRabbit" or .name == "CodeRabbit")] | length';

// CodeRabbit is an add-on: the App reviews a PR after it opens. "installed" means a CodeRabbit check shows on one of the
// last 10 PRs of this repo; no gh, no sign-in or no remote is "unknown" and the page asks for a manual confirm.
function coderabbit(o: SetupOpts) {
  const run = (cmd: string, args: string[]) => execFileSync(cmd, args, { cwd: o.projectRoot, env: o.env as NodeJS.ProcessEnv, timeout: 10_000, stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
  let installed: "installed" | "not-installed" | "unknown" = "unknown";
  try {
    const n = run("gh", ["pr", "list", "--state", "all", "--limit", "10", "--json", "statusCheckRollup", "--jq", CR_JQ]);
    if (/^\d+$/.test(n)) installed = Number(n) > 0 ? "installed" : "not-installed";
  } catch { /* unknown */ }
  let armed = false;
  try { armed = run("git", ["config", "--local", "--bool", "--get", "himmel.coderabbit"]) === "true"; } catch { /* unset */ }
  return {
    requirement: "optional",
    what: "CodeRabbit is a GitHub App that reviews each pull request after it opens. himmel works without it; with it, its review is one more reviewer in the review gate.",
    steps: [
      `Install the GitHub App on this repo: ${CR_APP_URL}`,
      "Open a pull request and wait for the CodeRabbit check to appear.",
      "Arm the gates for this clone: git config --local himmel.coderabbit true",
    ],
    installed,
    armed,
    manual: installed === "unknown" ? `Could not check from here. Confirm the App is listed under the repo's Settings, Integrations, GitHub Apps (${CR_APP_URL}).` : "",
  };
}

// GET /api/setup: presence only, never a value.
export function setupState(o: SetupOpts) {
  const ctx = ctxOf(o);
  return {
    secrets: entries.map((e) => ({ name: e.name, feature: e.feature ?? "", required: e.required ?? "", collect: e.collect, example: EXAMPLES[e.name] ?? "", status: store.detect(e.name, ctx).status })),
    commit: commitRules(o.home),
    coderabbit: coderabbit(o),
  };
}

const fail = (status: number, error: string): SecretResult => ({ status, body: { error }, audit: null });

// POST /api/setup/secret {name, op: "set"|"remove", value?}.
// ponytail: a service-mode server refuses set (the launch token alone is too weak for a write that takes a secret), upgrade path is a UI login, HIMMEL-4862.
export function secretWrite(b: Record<string, unknown>, o: SetupOpts & { serviceMode: boolean }): SecretResult {
  const e = entries.find((x) => x.name === b.name);
  if (!e || e.collect !== "file") return fail(400, "not a secret this page can set");
  if (b.op !== "set" && b.op !== "remove") return fail(400, "op must be set or remove");
  const set = b.op === "set";
  if (set && typeof b.value !== "string") return fail(400, "value required");
  if (!set && b.value !== undefined) return fail(400, "remove takes no value");
  if (set && o.serviceMode) return fail(403, "service mode: set the secret in the terminal (himmelctl install) until the UI login ships");
  const action = set ? "secret.set" : "secret.remove";
  if (set) {
    const v = store.validate(e.name, b.value);
    if (!v.ok) return fail(400, `value failed rule "${v.rule}"`);
  }
  const ctx = ctxOf(o);
  try {
    if (set) store.write(e.name, b.value, ctx); else store.remove(e.name, ctx);
  } catch (err) {
    if (err instanceof store.SecretStoreError) return { status: 409, body: { error: err.message }, audit: { action, target: e.name, ok: false } };
    return { status: 500, body: { error: "internal error" }, audit: { action, target: e.name, ok: false } };
  }
  return { status: 200, body: { name: e.name, status: store.detect(e.name, ctx).status }, audit: { action, target: e.name, ok: true } };
}
