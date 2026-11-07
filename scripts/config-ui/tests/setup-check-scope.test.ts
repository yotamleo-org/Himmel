// Configure's "Check this install" strip covers the setup checks only; Health lists every check. A setup finding keeps
// its link to its Health row instead of repeating the whole list.
import { test, expect } from "bun:test";
// @ts-ignore plain browser ES module, no types
import { renderConfigure, SETUP_CHECKS, isSetupCheck } from "../public/setup.js";
// @ts-ignore plain browser ES module, no types
import { renderHealth } from "../public/health.js";

const setupFixture = { account: null, secrets: [], commit: { tracker: null, ticketIdRequired: null }, choices: null, coderabbit: null };
const finding = (sev: string, id: string, msg: string) => ({ sev, id, msg, remedy: `fix ${id}` });
// two setup checks (C4 the source code host, C5 the handover folder) and two that are not (C7 worktrees, C40 the search index)
const findings = [
  finding("FAIL", "C5-handover", "handover root is missing"),
  finding("WARN", "C4-forge", "no source code host detected"),
  finding("WARN", "C7-shipped", "a worktree is behind main"),
  finding("WARN", "C40-qmd-vec", "the search index has a backlog"),
];
const verify = { state: "done", ok: 30, info: 2, warn: 3, fail: 1, findings };
const configure = (v: unknown) => renderConfigure(null, { tile: null, setup: setupFixture, state: {}, msgs: {}, verify: v });

test("Configure lists only the setup findings", () => {
  const html = configure(verify);
  for (const id of ["C5-handover", "C4-forge"]) expect(html).toContain(`data-id="doctor:${id}"`);
  expect(html).toContain("handover root is missing");
});

test("a worktree or index check (C7, C40) is absent from Configure", () => {
  const html = configure(verify);
  for (const id of ["C7-shipped", "C40-qmd-vec"]) {
    expect(html).not.toContain(id);
  }
  expect(html).not.toContain("a worktree is behind main");
  expect(html).not.toContain("the search index has a backlog");
});

test("the count names its scope and counts the setup subset, not the whole run", () => {
  const html = configure(verify);
  expect(html).toMatch(/1 fail/);
  expect(html).toMatch(/1 warn/);
  expect(html).not.toMatch(/3 warn/);
  expect(html).not.toMatch(/\d+ ok/); // the server's ok total covers every check, so the setup subset has no ok count
  expect(html).toMatch(/setup checks/i);
});

test("a setup finding carries its link to its Health row", () => {
  const html = configure(verify);
  expect(html.split('data-act="open-config" data-id="doctor:C4-forge"').length - 1).toBe(1);
  expect(html).toContain("Open in Health");
  expect(html).toContain('href="#/health"'); // and the strip says where every check is listed
});

test("a run with only non-setup findings says the setup is fine", () => {
  const html = configure({ ...verify, findings: findings.slice(2), fail: 0 });
  expect(html).not.toContain('data-act="open-config"');
  expect(html).toMatch(/Nothing to fix/);
});

test("the setup list is one exported table with a reason per check, and C7 and C40 are not in it", () => {
  expect(SETUP_CHECKS.length).toBeGreaterThan(0);
  for (const c of SETUP_CHECKS) {
    expect(c.id).toMatch(/^C\d+$/);
    expect(c.reason.length).toBeGreaterThan(10);
  }
  expect(new Set(SETUP_CHECKS.map((c: { id: string }) => c.id)).size).toBe(SETUP_CHECKS.length);
  for (const id of ["C7", "C40"]) expect(SETUP_CHECKS.map((c: { id: string }) => c.id)).not.toContain(id);
  expect([isSetupCheck("C4-forge"), isSetupCheck("C7-shipped"), isSetupCheck("C40-qmd-vec"), isSetupCheck("C74")]).toEqual([true, false, false, true]);
  expect(isSetupCheck("C44-skill-index")).toBe(false); // a number that merely starts with a setup number's digits
  expect(isSetupCheck("C40")).toBe(false);
});

test("Health lists every check, setup or not", () => {
  const row = (id: string, health: string) => ({ id: `doctor:${id}`, source: "doctor", bundle: "workflow", scope: "project", health, installed: { state: "present", detail: `d-${id}` }, fix: { remedy: `fix-${id}`, by: "chief" } });
  const rows = [row("C5-handover", "fail"), row("C4-forge", "warn"), row("C7-shipped", "warn"), row("C40-qmd-vec", "warn")];
  for (const tab of ["broken", "all"]) {
    const html = renderHealth({ rows }, null, { tab, tile: "checks" });
    for (const r of rows) expect([tab, r.id, html.includes(`data-id="${r.id}"`)]).toEqual([tab, r.id, true]);
  }
});
