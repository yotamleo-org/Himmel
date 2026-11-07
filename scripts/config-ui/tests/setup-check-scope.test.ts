// Configure's "Check this install" strip covers the setup checks only; Health lists every check. A setup finding keeps
// its link to its Health row instead of repeating the whole list, and what the strip leaves out is counted, not hidden.
import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
// @ts-ignore plain browser ES module, no types
import { renderConfigure, SETUP_CHECKS, isSetupCheck } from "../public/setup.js";
// @ts-ignore plain browser ES module, no types
import { renderHealth } from "../public/health.js";

const setupFixture = { account: null, secrets: [], commit: { tracker: null, ticketIdRequired: null }, choices: null, coderabbit: null };
const finding = (sev: string, id: string, msg: string) => ({ sev, id, msg, remedy: `fix ${id}` });
// Rows the doctor really emits as WARN or FAIL: three setup checks (C65 git hooks FAIL, C55 tracker and forge WARN, C85
// self-heartbeat hook FAIL) and three that are not (C7 worktrees WARN, C40 search index WARN, C44 skill index FAIL).
const findings = [
  finding("FAIL", "C65-git-hooks", "git gate hooks are not installed"),
  finding("WARN", "C55-project-mode", "tracker/forge unresolved"),
  finding("FAIL", "C85-self-heartbeat", "the queue lock self-heartbeat hook is not wired"),
  finding("WARN", "C7-shipped", "a worktree is behind main"),
  finding("WARN", "C40-qmd-vec", "the search index has a backlog"),
  finding("FAIL", "C44-skill-index", "the skills collection is missing or empty"),
];
const setupFindings = findings.slice(0, 3);
const otherFindings = findings.slice(3);
const verify = { state: "done", ok: 30, info: 2, warn: 3, fail: 3, findings };
const configure = (v: unknown) => renderConfigure(null, { tile: null, setup: setupFixture, state: {}, msgs: {}, verify: v });
const ids = () => SETUP_CHECKS.map((c: { id: string }) => c.id);

test("Configure lists only the setup findings", () => {
  const html = configure(verify);
  for (const f of setupFindings) expect(html).toContain(`data-id="doctor:${f.id}"`);
  expect(html).toContain("git gate hooks are not installed");
  expect(html).toContain("self-heartbeat hook is not wired");
});

test("a worktree, search index or skill index check (C7, C40, C44) is absent from Configure", () => {
  const html = configure(verify);
  for (const f of otherFindings) {
    expect(html).not.toContain(f.id);
    expect(html).not.toContain(f.msg);
  }
});

test("the count names its scope and counts the setup subset, not the whole run", () => {
  const html = configure(verify);
  expect(html).toMatch(/2 fail/);
  expect(html).toMatch(/1 warn/);
  expect(html).not.toMatch(/\d+ ok/); // the server's ok total covers every check, so the setup subset has no ok count
  expect(html).toMatch(/setup checks/i);
});

test("the findings outside the setup list are counted and sent to Health, so 0 fail never hides a real one", () => {
  const html = configure({ ...verify, findings: otherFindings });
  expect(html).toMatch(/0 fail/);
  expect(html).toContain("Not setup, so only on");
  expect(html).toContain("1 fail, 2 warn"); // C44 fail, C7 and C40 warn
  expect(html).toContain('href="#/health"');
  expect(configure({ ...verify, findings: setupFindings })).not.toContain("Not setup");
});

test("a setup finding carries its link to its Health row", () => {
  const html = configure(verify);
  for (const f of setupFindings) expect(html.split(`data-act="open-config" data-id="doctor:${f.id}"`).length - 1).toBe(1);
  expect(html).toContain("Open in Health");
  expect(html).toContain('href="#/health"');
});

test("a run with only non-setup findings says the setup is fine", () => {
  const html = configure({ ...verify, findings: otherFindings, fail: 1 });
  expect(html).not.toContain('data-act="open-config"');
  expect(html).toMatch(/Nothing to fix in the setup checks/);
});

test("the setup list is one exported table with a reason per check, and C7 and C40 are not in it", () => {
  expect(SETUP_CHECKS.length).toBeGreaterThan(0);
  for (const c of SETUP_CHECKS) {
    expect(c.id).toMatch(/^C\d+$/);
    expect(c.reason.length).toBeGreaterThan(10);
  }
  expect(new Set(ids()).size).toBe(SETUP_CHECKS.length);
  for (const id of ["C7", "C40"]) expect(ids()).not.toContain(id);
  expect([isSetupCheck("C65-git-hooks"), isSetupCheck("C85-self-heartbeat"), isSetupCheck("C7-shipped"), isSetupCheck("C40-qmd-vec"), isSetupCheck("C74")]).toEqual([true, true, false, false, true]);
  expect(isSetupCheck("C44-skill-index")).toBe(false); // a number that merely starts with a setup number's digits
  expect(isSetupCheck("C40")).toBe(false);
});

// ---- the list against the doctor itself ----
const doctor = readFileSync(new URL("../../himmel-doctor.sh", import.meta.url), "utf8");
// every check number the doctor runs: the C1 call and each run_check / run_heavy line
const registry = new Set([...doctor.matchAll(/^(?:run_check|run_heavy|if ! doctor_wants) (C\d+)\b/gm)].map((m) => m[1]));
// the numbers that are health checks, not setup: classified on purpose, so a new check cannot stay off Configure unseen
const NOT_SETUP = new Set(
  `C2 C3 C4 C5 C7 C8 C12 C14 C19 C21 C22 C23 C24 C25 C26 C27 C29 C30 C31 C33 C34 C35 C36 C37 C40 C41 C42 C44 C45 C47 C48 C49 C50 C51 C52 C54
  C56 C57 C58 C59 C60 C61 C64 C66 C67 C68 C69 C70 C71 C72 C76 C77 C79 C80 C82 C83 C84 C86 C87 C88 C89 C90 C91`.split(/\s+/),
);

test("the test reads the doctor's check numbers", () => {
  expect(registry.size).toBeGreaterThan(60);
  expect(registry.has("C1") && registry.has("C74") && registry.has("C90")).toBe(true);
});

test("every check the doctor runs is classified as setup or not, and nothing is both", () => {
  const unclassified = [...registry].filter((n) => !ids().includes(n) && !NOT_SETUP.has(n));
  expect(unclassified).toEqual([]); // a new check: add it to SETUP_CHECKS (with a reason) or to NOT_SETUP here
  expect(ids().filter((n: string) => NOT_SETUP.has(n))).toEqual([]);
});

test("no setup or not-setup number is stale: each is still a check the doctor runs", () => {
  expect(ids().filter((n: string) => !registry.has(n))).toEqual([]);
  expect([...NOT_SETUP].filter((n) => !registry.has(n))).toEqual([]);
});

test("every setup number can still reach the strip: the doctor emits a WARN or FAIL row for it", () => {
  // The strip gets WARN and FAIL rows only (verifyDoctor drops OK and INFO), so a check that emits only INFO is dead there.
  const dead = ids().filter((n: string) => !new RegExp(`emit (?:WARN|FAIL|"\\$\\w+") ${n}-`).test(doctor));
  expect(dead).toEqual([]);
});

test("Health lists every check, setup or not", () => {
  const row = (id: string, health: string) => ({ id: `doctor:${id}`, source: "doctor", bundle: "workflow", scope: "project", health, installed: { state: "present", detail: `d-${id}` }, fix: { remedy: `fix-${id}`, by: "chief" } });
  const rows = findings.map((f) => row(f.id, f.sev === "FAIL" ? "fail" : "warn"));
  for (const tab of ["broken", "all"]) {
    const html = renderHealth({ rows }, null, { tab, tile: "checks" });
    for (const r of rows) expect([tab, r.id, html.includes(`data-id="${r.id}"`)]).toEqual([tab, r.id, true]);
  }
});
