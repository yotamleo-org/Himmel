import { test, expect, afterEach } from "bun:test";
import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { readReviewers, runReport, REPORT_TIMEOUT_MS } from "../reviewers";
import { renderHealth } from "../public/health.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const PAGE = `# How good are our reviewers?

Each number comes from the newest run.

## The judges

Verdicts written from 1 Oct 2026 to 24 Oct 2026. Ranges are 95 % ranges.

- A bug got past a GO on 2 of 100 merged PRs: 2 % (likely between 1 % and 7 %).

## What we changed, and whether it helped

No change yet.
`;

function boot(page?: string) {
  const dir = mkdtempSync(join(tmpdir(), "reviewers-route-"));
  const home = join(dir, "home"), root = join(dir, "root");
  mkdirSync(home); mkdirSync(root);
  const file = join(dir, "review-page.md");
  if (page !== undefined) writeFileSync(file, page);
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root, REVIEW_PAGE_FILE: file } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return s;
}
const get = (port: number, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }, method = "GET") =>
  fetch(`http://127.0.0.1:${port}/api/reviewers`, { headers, method });

test("reviewers: the stored page is served as text with the day it was written", async () => {
  const s = boot(PAGE);
  const r = await (await get(s.port)).json();
  expect(r.state).toBe("ok");
  expect(r.text).toBe(PAGE);
  expect(typeof r.writtenAt).toBe("string");
});

test("reviewers: an absent file is state absent; the route is token-gated and read-only", async () => {
  const s = boot();
  expect(await (await get(s.port)).json()).toMatchObject({ state: "absent" });
  expect((await get(s.port, {})).status).toBe(401);
  expect((await get(s.port, { "X-Himmel-Token": TOKEN }, "POST")).status).toBe(405);
});

test("reviewers-move-to-tool-health-as-source-text", async () => {
  const { renderToolHealth } = await import("../public/tool-health.js");
  const tab = (reviewers: any) => renderToolHealth({ data: { state: "absent", selected: { days: 7 } }, reviewers }, "t", { tab: "reviewers" }) as string;
  const R = { state: "ok", text: "# Review sample\n\nCaught 8 of 10 planted cases.\n", writtenAt: "2026-10-26T03:00:00Z" };
  const html = tab(R);
  expect(html).toContain("Caught 8 of 10 planted cases.");
  expect(html).toContain("File updated 2026-10-26 03:00 UTC");
  expect(html).not.toContain("80");
  expect(html).not.toContain('class="tile');
  expect(tab({ state: "absent" })).toContain("No review page yet");
  expect(tab({ state: "ok", text: "  \n", writtenAt: R.writtenAt })).toContain("Review page is empty");
  expect(tab({ state: "error", reason: "unreadable" })).toContain("Review page could not load");
  expect(tab(undefined)).toContain("Loading the review page");
  const evil = `<img src=x onerror=alert(1)>`;
  expect(tab({ ...R, text: `## ${evil}\n\n- ${evil}\n` })).not.toContain("<img");
  const s = boot(PAGE);
  const served = tab(await (await get(s.port)).json());
  expect(served).toContain("<h4>The judges</h4>");
  expect(served).toContain("<li>A bug got past a GO on 2 of 100 merged PRs: 2 % (likely between 1 % and 7 %).</li>");
  expect(renderHealth(null, { bank: { state: "absent" }, workers: { state: "absent" }, monitoring: { state: "absent" }, mode: { state: "absent" }, reviewers: R })).not.toContain("How good are our reviewers?");
});

const NOW = Date.parse("2026-11-10T00:00:00Z");
const EVIL = "<img src=x onerror=alert(1)>";
const GEN = `
import json, os, sys
sys.path.insert(0, sys.argv[1])
import eval_runs
d, quiet = sys.argv[2], sys.argv[3] == "quiet"
EVIL = ${JSON.stringify(EVIL)}
def rp(run_id, ts, critics, recall, status="ok"):
    m = {"codex.key_match_recall": recall, "codex.class.logic.recall": recall, "codex.class.logic.n": 5,
         "codex.key_match_precision": None, "codex.findings": 0, "panel.key_match_recall": recall,
         EVIL + ".findings": 2, EVIL + ".key_match_precision": 0.5}
    r = eval_runs.make_row("review-panel", "scripts/eval/review-panel/score.py", {"critics": critics}, m, n=4,
                           run_id=run_id, status=status, gitsha="0" * 40, meta={"scorer_sha256": "a" * 64})
    r["ts"] = ts
    return r
j = eval_runs.make_row("judge-accuracy", "x", {"days": 28}, {"escape_rate": 0.02}, n=5, run_id="ja-1", gitsha="0" * 40)
rows = [rp("rp-a", "2026-10-20T00:00:00Z", ["codex", "claude"], 0.4), rp("rp-b", "2026-11-02T00:00:00Z", ["codex", EVIL], 0.6), j,
        rp("rp-c", "2026-11-09T00:00:00Z", ["codex"], None, "inconclusive")]
open(os.path.join(d, "runs.jsonl"), "w").write("".join(json.dumps(r) + "\\n" for r in rows))
open(os.path.join(d, "changes.jsonl"), "w").write("")
ts = "2026-10-01T00:00:00Z" if quiet else "2026-11-05T00:00:00Z"
def fin(model, fid):
    return {"kind": "finding", "ts": ts, "branch": "b-" + fid, "head": "h1", "model": model, "finding_id": fid,
            "severity": "imp", "file": "a.sh", "line": 1, "verdict": "", "artifact": "diff", "perspective": "off",
            "text": "RAW-REVIEW-BODY"}
def amend(fid, v):
    return {"kind": "amend", "ts": ts, "branch": "b-" + fid, "target_head": "h1", "finding_id": fid, "artifact": "diff",
            "perspective": "off", "set": {"verdict": v}, "reason": "r"}
cr = [fin("coderabbit", "c1"), amend("c1", "agreed"), fin("coderabbit", "c2"), amend("c2", "disproved")]
if not quiet:
    cr.append(fin("judge", "x1"))
open(os.path.join(d, "cr.jsonl"), "w").write("".join(json.dumps(r) + "\\n" for r in cr))
`;
function ledgers(kind: "main" | "quiet" = "main") {
  const dir = mkdtempSync(join(tmpdir(), "reviewers-report-"));
  execFileSync("python3", ["-I", "-c", GEN, join(import.meta.dir, "../../eval/lib"), dir, kind]);
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  return { dir, runs: join(dir, "runs.jsonl"), changes: join(dir, "changes.jsonl"), cr: join(dir, "cr.jsonl") };
}
function bootReport(extra: Record<string, string>) {
  const dir = mkdtempSync(join(tmpdir(), "reviewers-route-"));
  const home = join(dir, "home"), root = join(dir, "root");
  mkdirSync(home); mkdirSync(root);
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, now: () => NOW, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root, ...extra } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return s;
}
const reportEnv = (l: ReturnType<typeof ledgers>, over: Record<string, string> = {}) => ({ HIMMEL_EVAL_RUNS_LEDGER: l.runs, HIMMEL_EVAL_CHANGES_LEDGER: l.changes, CR_LEDGER: l.cr, ...over });
const tabOf = async (reviewers: any) => {
  const { renderToolHealth } = await import("../public/tool-health.js");
  return renderToolHealth({ data: { state: "absent", selected: { days: 7 } }, reviewers }, "t", { tab: "reviewers" }) as string;
};

test("ledger_present_page_missing: with no page file the route serves the typed report from the ledgers", async () => {
  const s = bootReport(reportEnv(ledgers()));
  const raw = await (await get(s.port)).text();
  const r = JSON.parse(raw);
  expect(r.state).toBe("ok");
  expect(r.mode).toBe("report");
  expect(r.codeReviewers.v).toBe(1);
  expect(r.codeReviewers.generated_at).toBe("2026-11-10T00:00:00Z");
  expect(r.codeReviewers.metrics.length).toBeGreaterThan(0);
  expect(raw).not.toContain("RAW-REVIEW-BODY");
  expect((await get(s.port, {})).status).toBe(401);
  expect((await get(s.port, { "X-Himmel-Token": TOKEN }, "POST")).status).toBe(405);
});

test("no_judge_fields_in_new_report: the typed report carries no judge row, metric or change", async () => {
  const raw = await (await get(bootReport(reportEnv(ledgers())).port)).text();
  expect(raw).not.toContain("judge");
  expect(raw).not.toContain("escape_rate");
});

test("legacy_snapshot_mode: an explicit REVIEW_PAGE_FILE is served as a stored snapshot", async () => {
  const r = await (await get(boot(PAGE).port)).json();
  expect(r).toMatchObject({ state: "ok", mode: "snapshot", text: PAGE });
  expect(await tabOf(r)).toContain("Stored snapshot");
});

test("ENOENT_absent: a missing snapshot file and missing ledgers are absent, with no instruction to run an eval", async () => {
  expect(await (await get(boot().port)).json()).toMatchObject({ state: "absent" });
  const none = join(tmpdir(), "reviewers-route-none.jsonl");
  const r = await (await get(bootReport({ HIMMEL_EVAL_RUNS_LEDGER: none, HIMMEL_EVAL_CHANGES_LEDGER: none, CR_LEDGER: none }).port)).json();
  expect(r.state).toBe("absent");
  expect(r.codeReviewers.sources.map((x: any) => x.reason)).toEqual(["ENOENT", "ENOENT", "ENOENT"]);
  const html = await tabOf(r);
  expect(html).toContain("No reviewer evidence yet");
  expect(html).not.toMatch(/\b(arm|run the|re-run)\b/i);
});

test("EACCES_or_directory_error: an unreadable snapshot or ledger is an error, never absent", async () => {
  const dir = mkdtempSync(join(tmpdir(), "reviewers-dir-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const legacy = readReviewers({ REVIEW_PAGE_FILE: dir });
  expect(await legacy).toMatchObject({ state: "error", mode: "snapshot", reason: "EISDIR" });
  const r = await (await get(bootReport(reportEnv(ledgers(), { CR_LEDGER: dir })).port)).json();
  expect(r.codeReviewers.sources.find((x: any) => x.id === "cr-ledger")).toMatchObject({ state: "error", reason: "EISDIR" });
});

test("one_source_error_partial: one unreadable source makes the report partial and the tab says which", async () => {
  const dir = mkdtempSync(join(tmpdir(), "reviewers-dir-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const r = await (await get(bootReport(reportEnv(ledgers(), { CR_LEDGER: dir })).port)).json();
  expect(r.state).toBe("partial");
  const html = await tabOf(r);
  expect(html).toContain("Partial");
  expect(html).toContain("cr-ledger could not be read (EISDIR)");
  expect(html).toContain("key-matched labelled target defects");
});

test("typed report in the tab: k of n, labels, dates, sources, freshness, attempts, no trend, escaping", async () => {
  const r = await (await get(bootReport(reportEnv(ledgers())).port)).json();
  const html = await tabOf(r);
  expect(html).toContain("0 findings: —");
  expect(html).not.toContain("0 of 0");
  expect(html).not.toMatch(/>0(\.0)?%</);
  expect(html).toContain("3 of 5 labelled target defects: 60.0%");
  expect(html).toContain("proxy");
  expect(html).toContain('<span class="dim">automated key-match proxy, not verified accuracy</span>');
  expect(html).toContain("Old: observed 8 days before this report");
  expect(html).toContain("Observed 2026-11-02");
  expect(html).toContain("Latest attempt 2026-11-09 (rp-c): inconclusive, not usable");
  expect(html).toContain("No trend:");
  expect(html).not.toMatch(/since the last run|points up|points down/);
  expect(html).toContain("recorded disposition");
  expect(html).toContain("Capture coverage unknown");
  expect(html).toContain("Counted out: 1 findings from 1 slugs that are not code reviewers.");
  expect(html).not.toContain("<img");
  expect(html).toContain("&lt;img src=x onerror=alert(1)&gt;");
});

test("quiet_history_not_failed_capture: a quiet CR ledger says no new records since, never stale or failed", async () => {
  const r = await (await get(bootReport(reportEnv(ledgers("quiet"))).port)).json();
  const html = await tabOf(r);
  expect(html).toContain("No new records since 2026-10-01; capture coverage unknown");
  expect(html).not.toMatch(/stale|failed capture|capture failed/i);
});

const crRow = (o: Record<string, unknown>) => JSON.stringify(o) + "\n";
const finding = (fid: string, branch: string, head: string, ts: string) => crRow({ kind: "finding", ts, branch, head, model: "coderabbit", finding_id: fid, severity: "imp", file: "a.sh", line: 1, verdict: "", artifact: "diff", perspective: "off", text: "RAW-REVIEW-BODY" });
const ruling = (fid: string, branch: string, head: string, ts: string, verdict: string) => crRow({ kind: "amend", ts, branch, target_head: head, finding_id: fid, artifact: "diff", perspective: "off", set: { verdict }, reason: "r" });
const receipt = (pr: number, branch: string, threads: number, result: string) => crRow({ kind: "capture", ts: "2026-11-06T02:00:00Z", pr, branch, head: "h-" + branch, thread_count: threads, outside_count: 0, result, reason: result === "ok" ? null : "RECEIPT-REASON" });
const recorded = (r: any) => r.codeReviewers.metrics.filter((m: any) => m.family === "production" && m.reviewer === "coderabbit" && m.verdict_source === "recorded-disposition").map((m: any) => [m.model, m.k, m.n]);

test("future_PR_appended_updates_report: a CR record appended between two GETs is counted on the next GET, once", async () => {
  const l = ledgers();
  const s = bootReport(reportEnv(l));
  expect(recorded(await (await get(s.port)).json())).toEqual([["unknown", 1, 2]]);
  appendFileSync(l.cr, finding("c5", "b5", "h5", "2026-11-08T00:00:00Z") + ruling("c5", "b5", "h5", "2026-11-08T01:00:00Z", "agreed"));
  const r = await (await get(s.port)).json();
  expect(recorded(r)).toEqual([["unknown", 2, 3]]);
  expect(r.codeReviewers.production.last_record_at).toBe("2026-11-08T01:00:00Z");
  expect(recorded(await (await get(s.port)).json())).toEqual([["unknown", 2, 3]]);
  expect(await tabOf(r)).toContain("2 of 3 decided findings: 66.7%");
});

test("future_model_change_new_cohort: a new responding model is its own row in the report and the tab", async () => {
  const l = ledgers();
  appendFileSync(l.cr, crRow({ kind: "attempt", ts: "2026-11-09T00:00:00Z", branch: "b6", head: "h6", model: "coderabbit", artifact: "diff", responding_model: "cr-model-2" }) + finding("c6", "b6", "h6", "2026-11-09T00:00:00Z") + ruling("c6", "b6", "h6", "2026-11-09T01:00:00Z", "disproved"));
  const r = await (await get(bootReport(reportEnv(l)).port)).json();
  expect(recorded(r)).toEqual([["cr-model-2", 0, 1], ["unknown", 1, 2]]);
  expect(await tabOf(r)).toContain("<td>cr-model-2</td>");
});

test("collection_gap_visible: with no snapshot coverage is unknown; with one, failed and uncaptured PRs are named", async () => {
  const l = ledgers();
  appendFileSync(l.cr, receipt(101, "b1", 2, "ok") + receipt(102, "b2", 1, "error"));
  const none = await (await get(bootReport(reportEnv(l)).port)).json();
  expect(none.codeReviewers.production.capture_coverage).toBe("unknown");
  expect(none.codeReviewers.sources.map((x: any) => x.id)).toEqual(["eval-runs", "eval-changes", "cr-ledger"]);
  const snap = join(l.dir, "expected.jsonl");
  writeFileSync(snap, crRow({ taken_at: "2026-11-10T00:00:00Z" }) + [101, 102, 103].map((pr) => crRow({ pr, branch: "b" + (pr - 100), head: "h", merged_at: "2026-11-06T01:00:00Z" })).join(""));
  const r = await (await get(bootReport(reportEnv(l, { HIMMEL_EXPECTED_PRS: snap })).port)).json();
  expect(r.codeReviewers.production.capture_coverage).toBe("measured");
  expect(r.codeReviewers.production.capture).toMatchObject({ k: 1, n: 3, failed: [102], uncaptured: [103] });
  const html = await tabOf(r);
  expect(html).toContain("Capture: 1 of 3 expected PRs captured (0 with zero threads), snapshot as of 2026-11-10; failed: #102; not captured: #103.");
  expect(html).not.toContain("Capture coverage unknown");
  expect(JSON.stringify(r)).not.toContain("RECEIPT-REASON");
});

test("zero_thread_pr_vs_uncaptured: an ok receipt with no threads is captured-zero, a PR with no receipt is uncaptured", async () => {
  const l = ledgers();
  appendFileSync(l.cr, receipt(107, "b7", 0, "ok"));
  const snap = join(l.dir, "expected.jsonl");
  writeFileSync(snap, crRow({ taken_at: "2026-11-10T00:00:00Z" }) + [107, 108].map((pr) => crRow({ pr, branch: "b" + (pr - 100), head: "h", merged_at: "2026-11-06T01:00:00Z" })).join(""));
  const r = await (await get(bootReport(reportEnv(l, { HIMMEL_EXPECTED_PRS: snap })).port)).json();
  expect(r.codeReviewers.production.capture).toMatchObject({ k: 1, n: 2, captured_zero: [107], uncaptured: [108] });
  expect(recorded(r)).toEqual([["unknown", 1, 2]]);
  expect(await tabOf(r)).toContain("Capture: 1 of 2 expected PRs captured (1 with zero threads), snapshot as of 2026-11-10; not captured: #108.");
  const bare = await (await get(bootReport(reportEnv(l)).port)).json();
  expect(bare.codeReviewers.production).toMatchObject({ capture_coverage: "unknown", capture: { n: null, captured_zero: [107] } });
  expect(await tabOf(bare)).toContain("Capture receipts: 1 PRs, 1 with zero threads; no expected-PR snapshot, so no coverage.");
});

test("stale_snapshot_not_full_coverage: an older snapshot is partial with its date; an undated one leaves coverage unknown", async () => {
  const l = ledgers();
  appendFileSync(l.cr, receipt(101, "b1", 1, "ok") + receipt(115, "b15", 1, "ok"));
  const rows = [101].map((pr) => crRow({ pr, branch: "b1", head: "h", merged_at: "2026-11-05T01:00:00Z" })).join("");
  const stale = join(l.dir, "stale.jsonl"), undated = join(l.dir, "undated.jsonl");
  writeFileSync(stale, crRow({ taken_at: "2026-11-06T00:00:00Z" }) + rows);
  writeFileSync(undated, rows);
  const r = await (await get(bootReport(reportEnv(l, { HIMMEL_EXPECTED_PRS: stale })).port)).json();
  expect(r.codeReviewers.production).toMatchObject({ capture_coverage: "partial", capture: { k: 1, n: 1, snapshot_as_of: "2026-11-06T00:00:00Z" } });
  expect(await tabOf(r)).toContain("Capture: 1 of 1 expected PRs captured (0 with zero threads), snapshot as of 2026-11-06, partial: PRs merged after it are not in it.");
  const u = await (await get(bootReport(reportEnv(l, { HIMMEL_EXPECTED_PRS: undated })).port)).json();
  expect(u.codeReviewers.production).toMatchObject({ capture_coverage: "unknown", capture: { k: null, n: null, snapshot_as_of: null } });
  expect(await tabOf(u)).toContain("the expected-PR snapshot has no as-of time (taken_at), so no coverage");
});

test("the report run is bounded: a timeout, junk output or an oversized answer is state error", async () => {
  const dir = mkdtempSync(join(tmpdir(), "reviewers-stub-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const stub = (name: string, body: string) => { const p = join(dir, name); writeFileSync(p, body); return p; };
  const env = { PATH: process.env.PATH, HOME: dir };
  const run = (name: string, body: string, ms = REPORT_TIMEOUT_MS) => runReport(env, stub(name, body), ms, []);
  expect(await run("slow.py", "import time\ntime.sleep(5)\n", 300)).toMatchObject({ state: "error", mode: "report", reason: "timed out" });
  expect(await run("junk.py", "print('not json')\n")).toMatchObject({ state: "error", reason: "invalid output" });
  expect(await run("v2.py", "print('{\"v\": 2, \"state\": \"ok\"}')\n")).toMatchObject({ state: "error", reason: "invalid output" });
  expect(await run("big.py", "import sys\nsys.stdout.write('x' * (3 * 1024 * 1024))\n")).toMatchObject({ state: "error", reason: "output over 2 MiB" });
  expect(await run("exit.py", "import sys\nsys.exit(3)\n")).toMatchObject({ state: "error", reason: "exit 3" });
});
