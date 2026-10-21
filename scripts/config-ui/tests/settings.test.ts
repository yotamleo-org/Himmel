import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import * as R from "../public/render.js";
import { DOCS_PATHS, DOCS_URL, navLinks } from "../public/nav.js";
import { buildTable, resolveAction } from "../actions";
// @ts-ignore plain ES module, no types
import { slugOf } from "../../../site/src/plugins/remark-docs.mjs";

// Journey J3, the pure half: the Settings page draws the frame-10 groups in order, and every row shows its
// himmelctl command, when it takes effect and a Learn more link. The browser half is tests/e2e/settings.e2e.ts.
const GROUPS = ["Plugins", "Review by a second model", "Auto-ship steps", "Scheduled jobs", "Commit rules", "Session switches", "Your install answers"];
const toggle = (id: string, action: string, target: string, health = "ok", state = "present") => ({
  id, source: "item", group: "core", title: id, health,
  declared: { where: "w", desired: "required", profile: "all" }, installed: { state, detail: `detail-${id}` },
  fires: { state: "unverified", evidence: null, at: null }, fix: { remedy: "", owner: "user" },
  probedAt: "2026-10-04T14:02:00Z", control: { class: "toggle", action, target, consent: "plain" }, sensitive: false,
});
const feed = {
  schema: "himmel-config-feed/1", generatedAt: "2026-10-04T14:02:00Z", target: { scope: "user", path: "/x" },
  rows: [
    toggle("plugin:himmel-guard@himmel", "plugin.enable", "himmel-guard@himmel", "off", "absent"),
    toggle("lane:codex", "config.lanes", "codex"),
    toggle("initiative:prcheck", "config.initiative", "prcheck", "ok", "present"),
    toggle("initiative:pr", "config.initiative", "pr", "off", "absent"),
    toggle("qmd-cadence", "cadence.disarm", "qmd"),
    toggle("pipeline-cadence", "cadence.arm", "pipeline", "off", "absent"),
  ],
  summary: { total: 6, ok: 4, warn: 0, fail: 0, off: 2, info: 0 },
};
const html: string = R.render(feed, { open: new Set(), bundles: {}, filt: { health: null, kind: null, q: "" } });
const settings = html.slice(html.indexOf('<section id="settings"'), html.indexOf("</section>", html.indexOf('<section id="settings"')));
const rows = settings.split('<div class="setrow">').slice(1);

test("the page is titled Settings and its groups come in the frame-10 order", () => {
  expect(settings).toContain('<h2 id="h-settings">Settings</h2>');
  expect([...settings.matchAll(/<h3 id="sg-[a-z-]+">([^<]+)<\/h3>/g)].map((m) => m[1])).toEqual(GROUPS);
});

test("every group is drawn even when the feed offers it no switch, so the order never moves", () => {
  const bare: string = R.render({ ...feed, rows: [] }, { open: new Set(), bundles: {}, filt: { health: null, kind: null, q: "" } });
  expect([...bare.matchAll(/<h3 id="sg-[a-z-]+">([^<]+)<\/h3>/g)].map((m) => m[1])).toEqual(GROUPS);
});

test("every row shows its command, when it takes effect, and a Learn more link into the docs site", () => {
  expect(rows.length).toBeGreaterThanOrEqual(12);
  for (const r of rows) {
    expect(r, r.slice(0, 120)).toMatch(/<pre><code>[^<]+<\/code><\/pre>/);
    expect(r, r.slice(0, 120)).toContain("takes effect: ");
    expect(r, r.slice(0, 120)).toMatch(new RegExp(`<a class="learn" href="${DOCS_URL}[a-z/-]*" target="_blank" rel="noopener">Learn more</a>`));
  }
});

test("each Learn more path is a docs-site route: listed in DOCS_PATHS and built from an allowlisted page", () => {
  const routes = new Set(readFileSync(join(import.meta.dir, "../../../site/allowlist.txt"), "utf8").split("\n")
    .filter((l) => l.trim() && !l.startsWith("#")).map((l) => "/" + slugOf(l.trim()) + "/"));
  const paths = [...new Set([...settings.matchAll(new RegExp(`href="${DOCS_URL}([a-z/-]*)"`, "g"))].map((m) => "/" + m[1]))];
  expect(paths.length).toBeGreaterThanOrEqual(6);
  for (const p of paths) {
    expect(DOCS_PATHS, p).toContain(p);
    expect(routes.has(p), p).toBe(true);
  }
});

test("a toggle keeps its action and target, and still opens a dry-run plan", () => {
  for (const [action, target] of [["cadence.arm", "pipeline"], ["cadence.disarm", "qmd"], ["config.lanes", "codex"], ["plugin.enable", "himmel-guard@himmel"]]) {
    expect(settings, `${action} ${target}`).toMatch(new RegExp(`<button[^>]*data-act="plan"[^>]*data-action="${action}"[^>]*data-target="${target}"`));
  }
  expect(settings).toMatch(/data-action="config.initiative" data-target="prcheck" data-value="off"/);
  expect(settings).toMatch(/data-action="config.initiative" data-target="pr" data-value="on"/);
});

test("the plugin set row offers lean and full through profile.set, the action the table already has", () => {
  for (const t of ["lean", "full"]) expect(settings).toMatch(new RegExp(`data-act="plan"[^>]*data-action="profile.set" data-target="${t}"`));
});

test("the plugin set row shows every open preview, so clicking full while lean is open never leaves lean's confirm on screen alone", () => {
  const plan = (target: string) => ({ stage: "plan", command: `himmelctl profile ${target}`, output: `would set ${target}`, effect: "next Claude launch", typed: "", consent: { kind: "typed", expect: target } });
  const html = R.renderSettings(feed, { plans: { "settings|profile-set-lean": plan("lean"), "settings|profile-set-full": plan("full") } });
  expect(html).toContain("would set lean");
  expect(html).toContain("would set full");
  expect(html).toContain('data-k="settings|profile-set-full"');
});

test("Commit rules and Session switches are display-only; their home is ~/.himmel/himmel.conf, not the shell profile", () => {
  const g = (id: string) => settings.split('<div class="setgroup">').find((s) => s.includes(`id="sg-${id}"`))!;
  const commit = g("commit-rules"), session = g("session-switches");
  expect(commit).toContain("~/.himmel/himmel.conf");
  expect(commit).toContain("TICKET_ID_REQUIRED=0");
  expect(commit).not.toMatch(/shell profile/i);
  for (const part of [commit, session]) expect(part).not.toContain('data-act="plan"');
  expect(session).toContain("EDIT_ON_MAIN_OK=1 claude");
});

// The command and effect text are written once for the page; this holds them to the action table the server runs.
const ctx = { root: "/r", cadenceRoot: "/h", himmelctl: "/h/scripts/himmelctl/bin.js", platform: "linux", plugins: ["p@himmel"], lanes: ["codex"] };
const table = buildTable(ctx);

test("settingsCommand spells exactly the argv the server runs, for every action in the table", () => {
  const cases: [string, string, string | undefined][] = [
    ["plugin.enable", "p@himmel", undefined], ["plugin.disable", "p@himmel", undefined],
    ["profile.set", "lean", undefined], ["profile.set", "full", undefined],
    ["config.lanes", "codex", "on"], ["config.lanes", "codex", "off"],
    ["config.initiative", "prcheck", "on"], ["config.initiative", "prcheck", "off"],
    ["config.commitRules", "tracker", "jira"], ["config.commitRules", "ticket-id-required", "off"],
    ...["pipeline", "graphmap", "qmd", "doctor"].flatMap((t) => [["cadence.arm", t, undefined], ["cadence.disarm", t, undefined]] as [string, string, undefined][]),
  ];
  expect(new Set(cases.map((c) => c[0]))).toEqual(new Set(table.keys()));
  for (const [action, target, value] of cases) {
    const want = resolveAction(table, action, target, value).argv.join(" ");
    expect(R.settingsCommand({ action, target }, "/h", value), `${action} ${target} ${value}`).toBe(want);
  }
});

test("a lane row prints one command for on and one for off, never an on|off a shell would read as a pipe", () => {
  const html = R.renderSettings(feed, { plans: {} });
  expect(html).not.toContain("on|off");
  expect(html).toContain("config set lanes.codex on\nnode ~/himmel/scripts/himmelctl/bin.js config set lanes.codex off");
});

test("settingsEffect has plain words for every action in the table", () => {
  for (const action of table.keys()) expect(R.settingsEffect(action), action).toMatch(/\S/);
});

test("the rail names the page Settings and keeps its #/config route", () => {
  const l = navLinks({ here: "console", token: "a".repeat(64), current: "config" }).find((x) => x.id === "config")!;
  expect(l).toMatchObject({ label: "Settings", href: "#/config", current: true });
});
