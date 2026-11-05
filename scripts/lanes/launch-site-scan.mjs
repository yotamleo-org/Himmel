#!/usr/bin/env node
// Scan scripts/ for every place that execs (or emits a command line
// that execs) `claude`, and report the ones that apply no plugin profile.
// A site is covered when, within WINDOW lines around it, there is a profile-
// derived `--settings` (the literal flag, WORKER_SESSION_PROFILE_SETTINGS, or the
// profile-settings.sh helper) or a `launch-profile-ok: <reason>` marker. A
// file-level `launch-profile-ok-file: <reason>` covers every site in the file.
// Usage: node launch-site-scan.mjs [repo-root]   -> prints "path:line: text" per UNCOVERED site.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const args = process.argv.slice(2);
const GUARD = args.includes("--guard");
const root = args.find((a) => !a.startsWith("--")) || process.cwd();
const SITE = new RegExp(
  String.raw`(?<![\w./-])(claude|"?\$\{?[A-Za-z_]*(CLAUDE|LAUNCHER)[A-Za-z_]*\}?"?)\s+(-p\b|--print|--bg|--settings|--model|--dangerously|--permission|--append|-n\b|--name)` +
    String.raw`|spawn(Sync)?\(\s*["']claude["']` +
    // emitted command lines: a resume prompt / cron entry built around a bare claude
    String.raw`|(?<![\w./-])claude\s+("\$|\$\{?q_)|\}claude\s`,
);
const COVER = /--settings|WORKER_SESSION_PROFILE_SETTINGS|profile-settings\.sh|launch-profile-ok:/;
const FILE_OK = /launch-profile-ok-file:/;
const SKIP_DIR = new Set(["node_modules", "dist", "fixtures", ".git"]);
const EXT = /\.(sh|ts|mjs|js|ps1)$/;
const GUARD_EXT = /\.(sh|ts|mjs|js|ps1|py)$/;
const GUARD_OK = /launch-guard-ok:/;
const GUARD_FILE_OK = /launch-guard-ok-file:/;
const PRINT_FLAG = /(?<![\w-])(-p|--print)(?![\w-])/;

function* walk(dir, ext = EXT) {
  for (const n of readdirSync(dir)) {
    if (SKIP_DIR.has(n)) continue;
    const p = join(dir, n);
    const st = statSync(p);
    if (st.isDirectory()) yield* walk(p, ext);
    else if (ext.test(n) && !/^test-|\.test\./.test(n)) yield p;
  }
}

if (GUARD) {
  let found = 0;
  for (const f of walk(join(root, "scripts"), GUARD_EXT)) {
    const lines = readFileSync(f, "utf8").split("\n");
    if (lines.some((l) => GUARD_FILE_OK.test(l))) continue;
    lines.forEach((l, i) => {
      const t = l.trim();
      if (t.startsWith("#") || t.startsWith("//")) return;
      const m = SITE.exec(l);
      if (!m) return;
      if (/`claude|claude --model (for|pin)|quota_gauge_row claude/.test(l)) return; // prose / usage text / gauge row, not a launch
      // ponytail: the inventory is only as complete as the SITE regex (a launch spelled through an unusual variable or a non-scanned language is missed); upgrade path: a PATH shim that refuses an interactive claude launch whose cwd has not passed launch-guard-check.sh (follow-up h)
      const stmt = l.slice(m.index).split(/;|&&|\|\|?/)[0];
      if (PRINT_FLAG.test(stmt)) return;
      const win = lines.slice(Math.max(0, i - 12), i + 4).join("\n");
      if (GUARD_OK.test(win)) return;
      console.log(`${relative(root, f)}:${i + 1}: ${t.slice(0, 120)}`);
      found++;
    });
  }
  process.exit(found ? 1 : 0);
}

for (const f of walk(join(root, "scripts"))) {
  const lines = readFileSync(f, "utf8").split("\n");
  if (lines.some((l) => FILE_OK.test(l))) continue;
  lines.forEach((l, i) => {
    const t = l.trim();
    if (t.startsWith("#") || t.startsWith("//")) return;
    if (!SITE.test(l)) return;
    if (/`claude|claude --model (for|pin)|quota_gauge_row claude/.test(l)) return; // prose / usage text / gauge row, not a launch
    const win = lines.slice(Math.max(0, i - 12), i + 4).join("\n");
    if (COVER.test(win)) return;
    console.log(`${relative(root, f)}:${i + 1}: ${t.slice(0, 120)}`);
  });
}
