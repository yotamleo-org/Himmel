import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import * as R from "../public/render.js";
import { renderConfigure, renderSetup } from "../public/setup.js";

const secrets = ["JIRA_EMAIL", "JIRA_BASE_URL", "JIRA_PROJECT_KEY", "JIRA_API_TOKEN", "TELEGRAM_BOT_TOKEN"].map((name) => ({ name, collect: "file", status: "not-set", feature: "core" }));
const setup = {
  secrets, account: { status: "not-set", create: "ui" }, commit: { tracker: "jira", ticketIdRequired: true },
  choices: { paths: [], forge: { value: "github" } },
  coderabbit: { installed: "installed", armed: true, requirement: "optional", what: "Reviews PRs", steps: ["Arm the gates for this clone: git config --local himmel.coderabbit true"], manual: "" },
};
const state = { plans: {}, reviewGate: { data: { reviewers: [], env: [], overlay: "critics.local.json" } } };
const cfg = (tile: string, data = setup) => renderConfigure({ rows: [] }, { tile, setup: data, state, msgs: {} });
const visible = (html: string) => html.replace(/<button\b[^>]*data-act="copy"[^>]*>[\s\S]*?<\/button>/g, "").replace(/<[^>]*>/g, "");

test("Tracker tile: Team mode is one switch under the Board heading, off when unset, and each side previews a dry run", () => {
  const html = cfg("tracker", { ...setup, commit: { ...setup.commit, teamMode: "off" } });
  expect(visible(html)).toContain("Board · who edits this Jira project");
  expect(visible(html)).toContain("Team mode");
  for (const v of ["on", "off"]) expect(html).toContain(`data-action="config.tracker" data-target="team-mode" data-value="${v}"`);
  expect(html).toMatch(/data-value="off" data-k="[^"]*" aria-pressed="true"/);
  const on = cfg("tracker", { ...setup, commit: { ...setup.commit, teamMode: "on" } });
  expect(on).toMatch(/data-action="config.tracker" data-target="team-mode" data-value="on" data-k="[^"]*" aria-pressed="true"/);
  expect(R.settingsCommand({ action: "config.tracker", target: "team-mode" }, "~/himmel", "on")).toBe("node ~/himmel/scripts/himmelctl/bin.js config set tracker.teamMode on");
});

// Removing the shared buttons would expose shell text again, or lose the exact command to copy.
test("Configure commands are compact copy buttons, not raw command blocks", () => {
  const html = cfg("scope");
  expect(html).toContain('data-act="copy"');
  expect(html).not.toContain("<pre><code>");
  expect(visible(html)).not.toContain("node ~/himmel/scripts/himmelctl/bin.js");
  const commands = [...html.matchAll(/data-cmd="([^"]*)"/g)].map((m) => m[1]);
  expect(commands).toContain("node ~/himmel/scripts/himmelctl/bin.js profile lean");
  expect(new Set(commands).size).toBe(commands.length);
});

test("previews and setup instructions keep known commands inside the copy control", () => {
  for (const stage of ["plan", "running", "done"]) {
    const html = R.planHtml("fixture", { stage, command: "himmelctl profile lean", output: "would change profile", consent: { kind: "plain" }, rc: 0 });
    expect(html).toContain('data-cmd="himmelctl profile lean"');
    expect(visible(html)).not.toContain("himmelctl profile lean");
    if (stage === "plan") expect(html).toContain("would change profile");
  }
  const html = cfg("secrets");
  expect(html).toContain('data-cmd="himmelctl install"');
  expect(visible(html)).not.toContain("himmelctl install");
  expect(visible(cfg("scope"))).not.toContain("git config himmel.forge");
  expect(visible(cfg("scope"))).not.toContain("himmelctl config set");
});

test("copy buttons escape command attributes and never turn command text into markup", () => {
  expect(typeof R.copyCommand).toBe("function");
  const html = R.copyCommand('echo "<fixture>" & exit');
  expect(html).toContain('type="button"');
  expect(html).toContain('data-cmd="echo &quot;&lt;fixture&gt;&quot; &amp; exit"');
  expect(html).not.toContain("<fixture>");
});

test("Jira email, site and project are text; tokens stay password fields with local reveal controls (in the Secrets tile)", () => {
  const html = cfg("secrets");
  for (const name of ["JIRA_EMAIL", "JIRA_BASE_URL", "JIRA_PROJECT_KEY"]) {
    expect(html).toContain(`type="text" data-secret="${name}"`);
    expect(html).not.toContain(`data-reveal="${name}"`);
  }
  expect(html).toContain('type="password" data-secret="JIRA_API_TOKEN"');
  expect(html).toContain('data-reveal="JIRA_API_TOKEN"');
  expect(html).not.toMatch(/<input[^>]*data-secret[^>]*\svalue=/);
});

test("every Setup and Configure password has an accessible show/hide button", () => {
  for (const html of [cfg("secrets"), renderSetup(setup, {}, {})]) {
    const passwords = [...html.matchAll(/<input type="password"[^>]*>/g)];
    expect(passwords.length).toBeGreaterThan(0);
    for (const [input] of passwords) {
      const name = /data-(?:secret|account)="([^"]+)"/.exec(input)![1];
      expect(html).toMatch(new RegExp(`<button[^>]*type="button"[^>]*data-act="reveal"[^>]*data-reveal="${name}"[^>]*aria-pressed="false"[^>]*>show</button>`));
    }
  }
});

test("the real delegated show/hide handler only changes DOM visibility, never reads or stores the value", () => {
  const source = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8");
  const body = /document.addEventListener\("click", \(e\) => \{([\s\S]*?)\n\}\);/.exec(source)![1];
  const click = new Function("e", "feed", "currentPage", body);
  let stopped = 0;
  const input = { type: "password", get value(): string { throw new Error("reveal must not read the value"); } };
  const attrs: Record<string, string> = {};
  const button = {
    dataset: { act: "reveal", reveal: "JIRA_API_TOKEN" }, textContent: "show",
    closest: () => ({ querySelector: () => input }),
    setAttribute: (key: string, value: string) => { attrs[key] = value; },
  };
  const event = { target: { closest: () => button }, stopPropagation: () => { stopped++; } };
  click(event, null, { needsFeed: false });
  expect(input.type).toBe("text");
  expect(button.textContent).toBe("hide");
  expect(attrs["aria-pressed"]).toBe("true");
  click(event, null, { needsFeed: false });
  expect(input.type).toBe("password");
  expect(button.textContent).toBe("show");
  expect(attrs["aria-pressed"]).toBe("false");
  expect(stopped).toBe(2);
});

test("healthy CodeRabbit setup is collapsed, unknown or absent installation is expanded", () => {
  for (const installed of ["installed", "not-installed", "unknown"]) {
    const data = { ...setup, coderabbit: { ...setup.coderabbit, installed } };
    for (const html of [cfg("review", data), renderSetup(data, {}, {})]) {
      expect(html).toMatch(new RegExp(`<details class="more"${installed === "installed" ? "" : " open"}><summary>CodeRabbit`));
      expect(visible(html)).not.toContain("git config --local himmel.coderabbit true");
      expect(html).toContain('data-cmd="git config --local himmel.coderabbit true"');
    }
  }
});

test("review provider copy distinguishes API credit from the session subscription limits", () => {
  const html = R.renderReviewGate({ data: { reviewers: ["claude-api", "claude-subscription"].map((provider) => ({ slug: provider, provider, mode: "hard", required: true })), env: [], overlay: "local" } });
  expect(html).toContain('<div class="ro">runs on your Anthropic API key and bills API credit, separate from your plan</div>');
  expect(html).toContain('<div class="ro">runs through the Claude CLI on your Claude plan and uses the same 5-hour and weekly limits as your own sessions</div>');
});

test("timeout and tier rows name real config, operator-policy and launching-shell homes", () => {
  const names = ["CR_PROFILE", "CR_REQUIRE_CROSS_MODEL", "CR_FLOOR_FALLBACK", "CRITIC_PANEL_TIERS", "CRITIC_TIMEOUT_SECS", "CRITIC_PARALLEL"];
  const html = R.renderReviewGate({ data: { reviewers: [], env: names.map((name) => ({ name, means: "fixture", value: null, default: "fixture" })), overlay: "local" } });
  const rows = html.split('<div class="setrow">').slice(1);
  expect(rows[0]).toContain("~/.himmel/himmel.conf");
  expect(rows[0]).toContain(".himmel/himmel.conf");
  for (const row of rows.slice(1, 3)) {
    expect(row).toContain("~/.himmel/config.json");
    expect(row).toContain("policy");
    expect(row).toContain("operator");
  }
  for (const row of rows.slice(3)) {
    expect(row).toContain("shell that starts Claude Code");
    expect(row).toContain("critic-panel.sh");
  }
  expect(html).not.toContain("set in .env or the launching shell, read-only here");
  expect(html).toContain("not critics.json");
});

// ---- the scope tile folds into categories, explains each setting, and hides internal names ----
const feedRow = (id: string, action: string, target: string, detail: string) => ({
  id, source: "item", health: "ok", installed: { state: "present", detail }, fires: { state: "unverified" }, fix: { remedy: "" },
  control: { class: "toggle", action, target, consent: "plain" },
});
const scopeFeed = {
  rows: [
    feedRow("plugin:himmel-guard@himmel", "plugin.enable", "himmel-guard@himmel", "enabled in the user-scope file"),
    feedRow("initiative:prcheck", "config.initiative", "prcheck", "HIMMEL_INITIATIVE has prcheck in .env"),
    feedRow("initiative:merge", "config.initiative", "merge", "HIMMEL_INITIATIVE has merge in .env"),
    ...["pipeline", "graphmap", "qmd", "doctor"].map((t) => feedRow(`${t}-cadence`, "cadence.arm", t, `crontab line for ${t}`)),
  ],
};
const scopeSetup = { ...setup, choices: { paths: [
  { target: "handover-root", key: "HANDOVER_DIR", value: "/srv/h", fallback: "~/.himmel/handovers" },
  { target: "luna-vault", key: "LUNA_VAULT_PATH", value: null, fallback: "~/.himmel/vault" },
], forge: { value: "github" } } };
const scopeState = {
  ...state,
  fleetCap: { data: { cap: 3, min: 1, max: 50, default: 3, source: "config.json", configFile: "/h/.himmel/config.json", envFile: "/h/.env", edit: "~/.himmel/config.json .policy.HIMMEL_FLEET_CAP" } },
  vm: { data: { mode: "remote" }, draft: { mode: "remote", ssh: "", port: "", identity: "" } },
  reports: { data: { report_day: "local", shift_idle_min: 60, shift_cuts: ["08:00", "20:00"], shift_min_run_h: 4 } },
};
const tileHtml = (tile: string, data = scopeSetup) => renderConfigure(scopeFeed, { tile, setup: data, state: scopeState, msgs: {} });
const scope = () => tileHtml("scope");
// What a reader can see: the text outside the copy buttons plus every attribute a tooltip or screen reader shows.
const seen = (html: string) => [visible(html), ...[...html.matchAll(/\s(?:title|aria-label|placeholder)="([^"]*)"/g)].map((m) => m[1])].join("\n");
const cats = (html: string) => html.split('<details class="cat"').slice(1);

test("no scope setting shows an internal key name or a settings file in its text or tooltips", () => {
  const text = seen(scope());
  const hidden = ["HIMMEL_INITIATIVE", "HIMMEL_FLEET_CAP", "HANDOVER_DIR", "LUNA_VAULT_PATH", "FORGE", "himmel.forge", "vm.mode", "report_day", "shift_idle_min", "shift_cuts", "shift_min_run_h",
    "config.json", "himmel.conf", "project.conf", ".env", "crontab", "initiative:", "plugin:", "-cadence", "@himmel", "~/", "config set", "policy."];
  for (const key of hidden) expect(text, key).not.toContain(key);
});

test("every scope setting row carries a plain explanation line", () => {
  const rows = scope().split(/<div class="(?:setrow|srow)"/).slice(1);
  expect(rows.length).toBeGreaterThanOrEqual(12);
  for (const row of rows) expect(row, row.slice(0, 80)).toMatch(/<p class="why">[^<\s][\s\S]*?<\/p>/);
});

test("the scope tile folds into collapsible categories: the first open, the rest closed", () => {
  const c = cats(scope());
  expect(c.length).toBeGreaterThanOrEqual(4);
  expect(c[0].startsWith(" open")).toBe(true);
  for (const rest of c.slice(1)) expect(rest.startsWith(" open")).toBe(false);
  for (const one of c) expect(one).toMatch(/<summary>[^<]+<\/summary>/);
});

test("the Forge row is labelled and explained as the source code host", () => {
  const text = visible(scope());
  expect(text).toContain("Source code host");
  expect(text).toMatch(/where your repository lives/i);
  expect(text).toContain("detected: github");
});

test("GitHub and Bitbucket sit together in one category", () => {
  const holding = cats(scope()).filter((c) => /GitHub|Bitbucket/.test(visible(c)));
  expect(holding).toHaveLength(1);
  expect(visible(holding[0])).toMatch(/GitHub/);
  expect(visible(holding[0])).toMatch(/Bitbucket/);
});

test("no secret field renders outside the Secrets tile, and the Secrets tile holds every one", () => {
  const field = /type="password"|data-secret=|data-setup-form|data-account|data-act="reveal"|data-act="setup-remove"/;
  const stored = { ...scopeSetup, secrets: scopeSetup.secrets.map((s) => ({ ...s, status: "set" })) };
  for (const tile of ["review", "tracker", "scope"]) {
    expect(tileHtml(tile, stored), tile).not.toMatch(field);
    expect(tileHtml(tile), tile).not.toMatch(field);
  }
  const mine = tileHtml("secrets");
  for (const name of ["TELEGRAM_BOT_TOKEN", "JIRA_BASE_URL", "JIRA_EMAIL", "JIRA_API_TOKEN", "JIRA_PROJECT_KEY"]) expect(mine, name).toContain(`data-secret="${name}"`);
});
