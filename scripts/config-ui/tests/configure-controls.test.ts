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

test("Jira email, site and project are text; tokens stay password fields with local reveal controls", () => {
  const html = cfg("tracker");
  for (const name of ["JIRA_EMAIL", "JIRA_BASE_URL", "JIRA_PROJECT_KEY"]) {
    expect(html).toContain(`type="text" data-secret="${name}"`);
    expect(html).not.toContain(`data-reveal="${name}"`);
  }
  expect(html).toContain('type="password" data-secret="JIRA_API_TOKEN"');
  expect(html).toContain('data-reveal="JIRA_API_TOKEN"');
  expect(html).not.toMatch(/<input[^>]*data-secret[^>]*\svalue=/);
});

test("every Setup and Configure password has an accessible show/hide button", () => {
  for (const html of [cfg("secrets"), cfg("tracker"), renderSetup(setup, {}, {})]) {
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
  expect(html).toContain("runs on your Anthropic API key and bills API credit, separate from your plan");
  expect(html).toContain("runs claude -p on your Claude plan and uses the same 5-hour and weekly limits as your own sessions");
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
