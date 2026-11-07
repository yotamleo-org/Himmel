// T5b: the Multi accounts section of Configure -> Secrets, rendered through renderConfigure with six fixtures
// (absent, valid, partial, invalid, no-configured-account, account config unreadable). Pure render: no server, no files.
import { test, expect } from "bun:test";
// @ts-ignore plain browser ES module, no types
import { apiRolesDraft, renderConfigure, rolesPreview } from "../public/setup.js";

const secrets = ["JIRA_API_TOKEN", "TELEGRAM_BOT_TOKEN"].map((name) => ({ name, collect: "file", status: "set", feature: "core" }));
const setup = { secrets, account: { status: "not-set", create: "ui" }, commit: { tracker: "jira", ticketIdRequired: true }, choices: { paths: [], forge: { value: "github" } } };
const ROLES = ["graphify", "judge"];
// the rows carry extra fields on purpose: nothing but account, configured, cap, tag and reason may reach the page
const row = (account: string, configured: boolean, tag: string, extra: Record<string, unknown> = {}) => ({ account, configured, cap_usd: configured ? "40.000000" : null, tag, organization_id: "org-LEAK", key_id: "key-LEAK", ...extra });
const ROWS = [row("A", true, "room"), row("B", true, "stale reading"), row("C", false, "not configured")];
const data = (state: string, roles: Record<string, string[]>, errors: string[] = [], over: Record<string, unknown> = {}) =>
  ({ roleMap: { state, roles, errors }, warnings: [], ROLES, accounts: "ok", letters: ["A", "B", "C"], rows: ROWS, ...over });
const fixture = (d: any, over: Record<string, unknown> = {}) => ({ data: d, error: null, draft: apiRolesDraft(d), preview: false, msg: null, ...over });
const tile = (apiRoles: unknown, id = "secrets") => renderConfigure({ rows: [] }, { tile: id, setup, state: { plans: {}, apiRoles }, msgs: {} }) as string;
const text = (html: string) => html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");

test("absent: the empty-state card says the defaults apply and the accounts and editor still show", () => {
  const html = tile(fixture(data("absent", {})));
  expect(text(html)).toContain("No roles set: the defaults apply");
  expect(html).toContain('data-account-row="A"');
  expect(html).toContain('data-act="role-toggle"');
  expect(text(html)).toContain("graph pass (default)");
});

test("valid: roles sit on their account rows, an unconfigured mapped account says it is skipped at pick time", () => {
  const html = tile(fixture(data("valid", { judge: ["B"], graphify: ["A", "C"] })));
  const rowOf = (l: string) => text((html.match(new RegExp(`<tr[^>]*data-account-row="${l}"[\\s\\S]*?</tr>`)) || [""])[0]);
  expect(rowOf("A")).toContain("graphify");
  expect(rowOf("B")).toContain("judge");
  expect(rowOf("C")).toContain("skipped at pick time");
  expect(rowOf("A")).toContain("$40 cap");
  expect(rowOf("B")).toContain("stale reading");
  expect(html).not.toContain("role-card");
});

test("partial: each error line shows and the other entries still apply", () => {
  const html = tile(fixture(data("partial", { graphify: ["A"], judge: ["B"] }, ["unknown-account:judge:D", "unknown-role:jduge"])));
  expect(html).toContain("unknown-account:judge:D");
  expect(html).toContain("unknown-role:jduge");
  expect(text(html)).toContain("the other entries still apply");
  expect(html).toContain('class="card crit role-card"');
});

test("invalid: the whole file is ignored and the editor starts empty", () => {
  const d = data("invalid", {}, ["invalid-role-map:not-json"]);
  const html = tile(fixture(d));
  expect(html).toContain("invalid-role-map:not-json");
  expect(text(html)).toContain("the whole file is ignored, the defaults apply");
  expect(apiRolesDraft(d)).toEqual({});
});

test("a valid map whose role has no configured account shows the warning card", () => {
  const html = tile(fixture(data("valid", { graphify: ["C"] }, [], { warnings: ["no-configured-account:graphify"] })));
  expect(html).toContain('class="card warn role-card"');
  expect(text(html)).toContain("graphify is mapped only to C, which is not configured");
  expect(html).toContain("no-configured-account:graphify");
});

test("account config unreadable: one crit row with the CLI's reason, no bank tags, the map and editor still show", () => {
  const html = tile(fixture(data("valid", { judge: ["B"] }, [], { accounts: "unreadable", rows: null, accountsReason: "invalid-account-config" })));
  expect(text(html)).toContain("account config unreadable: invalid-account-config; fix config.json");
  expect(html).not.toContain("data-account-row");
  expect(html).toContain('data-act="role-toggle"');
});

test("no organization or key id string reaches the page", () => {
  for (const d of [data("valid", { judge: ["B"] }), data("absent", {})]) {
    const html = tile(fixture(d));
    expect(html).not.toContain("org-LEAK");
    expect(html).not.toContain("key-LEAK");
  }
});

test("a role row with B and C pressed renders both aria-pressed true, and no toggle is a plan action", () => {
  const d = data("valid", { graphify: ["B", "C"] });
  const html = tile(fixture(d));
  const toggle = (role: string, account: string) => (html.match(new RegExp(`<button[^>]*data-role="${role}" data-account="${account}"[^>]*>`)) || [""])[0];
  expect(toggle("graphify", "B")).toContain('aria-pressed="true"');
  expect(toggle("graphify", "C")).toContain('aria-pressed="true"');
  expect(toggle("graphify", "A")).toContain('aria-pressed="false"');
  expect(toggle("judge", "A")).toContain('aria-pressed="false"');
  const section = html.slice(html.indexOf("<h3>Multi accounts</h3>"));
  expect(section).not.toContain('data-act="plan"');
});

test("rolesPreview shows the added line, and an empty draft shows file removed", () => {
  const added = rolesPreview({ judge: ["B"] }, { judge: ["B"], graphify: ["A"] });
  expect(added.diff).toContainEqual({ sign: "+", text: '"graphify": ["A"]' });
  expect(added.diff.filter((l: any) => l.sign === "-")).toEqual([]);
  expect(added.changes).toBe(1);
  const removed = rolesPreview({ judge: ["B"] }, {});
  expect(removed.after).toBe("file removed");
  expect(removed.diff).toContainEqual({ sign: "-", text: '"judge": ["B"]' });
  expect(rolesPreview({}, {}).after).toBe("no file");
  expect(rolesPreview({ judge: ["B"] }, { judge: ["B"] }).changes).toBe(0);
});

test("the Preview block shows only when asked and makes no server call; Save, Preview and Cancel are the actions", () => {
  const d = data("valid", { judge: ["B"] });
  const quiet = tile(fixture(d));
  expect(quiet).not.toContain('class="dryrun"');
  const draft = { judge: ["B", "C"] };
  const shown = tile(fixture(d, { draft, preview: true }));
  expect(shown).toContain('class="dryrun"');
  expect(text(shown)).toContain("1 change · not saved");
  for (const act of ["roles-preview", "roles-save", "roles-cancel"]) expect(shown).toContain(`data-act="${act}"`);
});

test("the Secrets tile value carries the role text: up to two roles, default roles, or role map error", () => {
  expect(text(tile(fixture(data("valid", { judge: ["B"], graphify: ["A", "C"] }))))).toContain("judge→B · graphify→A,C");
  expect(text(tile(fixture(data("absent", {}))))).toContain("default roles");
  expect(text(tile(fixture(data("partial", { judge: ["B"] }, ["unknown-role:x"]))))).toContain("role map error");
  expect(text(tile(fixture(data("invalid", {}, ["invalid-role-map:not-json"]))))).toContain("role map error");
});
