#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes in node -e intentional (shell vars arrive via env)
# scripts/cr/standards-cadence.sh — weekly standards feedback cadence
# Reads `known-findings.sh --ladder` (read-only), keeps the classes that recurred in the window, gives each
# EXACTLY ONE structural target and writes <handover-root>/cr-tune/proposals-YYYY-MM-DD.md. Lean-invoke
# (/cr-tune, /cr-learnings-refresh); nothing here changes a rung, config, hook or setting.
#
# Usage: standards-cadence.sh [--since <N>d]     window for "keeps recurring" (default 7d)
# Target per class, most to least preferred: lint or check · shared helper plus a check · standard line ·
#   critic rule · CodeRabbit rule · rebuttal.
#   retire -> rebuttal · advisory->gate -> lint or check · kind fix -> lint or check ·
#   kind checklist -> standard line · kind rebuttal -> CodeRabbit rule when its source is a CodeRabbit
#   learning, else critic rule.
# Approval: CodeRabbit rule and critic rule (.coderabbit.yaml, critics.json) = operator; every other target
#   = console GO with an opus judge.
# Expiry: a proposal lasts 14 days. A class listed in an older file (>= 14 days) that is proposed again is
#   REFIRED; one that is not is EXPIRED; one promoted (rung_since) or removed since is BUILT.
# Promoted classes (`rung_since` set) show real findings per week before and after promotion; a class whose
#   rate does not fall is demoted to restructure (S5).
# Env: KNOWN_FINDINGS_FILE, CR_LEDGER (both passed through), HANDOVER_DIR (via scripts/lib/handover-path.sh),
#      STANDARDS_CADENCE_TODAY (YYYY-MM-DD, test injection).
# Exit: 0, 2 usage / missing input.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KF="${KNOWN_FINDINGS_FILE:-$SCRIPT_DIR/known-findings.json}"
SINCE=7
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || { echo "standards-cadence.sh: --since requires <N>d" >&2; exit 2; }
             case "$2" in [1-9]*d) SINCE="${2%d}";; *) echo "standards-cadence.sh: --since must look like 7d (got '$2')" >&2; exit 2;; esac
             case "$SINCE" in *[!0-9]*) echo "standards-cadence.sh: --since must look like 7d (got '$2')" >&2; exit 2;; esac
             shift 2;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) echo "standards-cadence.sh: unknown option $1" >&2; exit 2;;
  esac
done
[ -f "$KF" ] || { echo "standards-cadence.sh: not found: $KF" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "standards-cadence.sh: node is required" >&2; exit 2; }
# shellcheck disable=SC1091  # resolved relative to this script
. "$SCRIPT_DIR/../lib/handover-path.sh" || exit 2
# shellcheck disable=SC1091  # resolved relative to this script
. "$SCRIPT_DIR/../lib/git-clean.sh" || exit 2
git_env_scrub
ROOT="$(handover_root_ensure)" || exit 2
OUT_DIR="$ROOT/cr-tune"
mkdir -p "$OUT_DIR" || exit 2
LEDGER="${CR_LEDGER:-}"
if [ -z "$LEDGER" ]; then
  _gc="$(git rev-parse --git-common-dir)" || { echo "standards-cadence.sh: cannot resolve the git common dir; set CR_LEDGER" >&2; exit 2; }
  LEDGER="$_gc/cr-critic-scores.jsonl"
fi
TODAY="${STANDARDS_CADENCE_TODAY:-$(date -u +%Y-%m-%d)}"
LADDER="$(mktemp "${TMPDIR:-/tmp}/standards-cadence.XXXXXX")" || exit 2
trap 'rm -f "$LADDER"' EXIT
KNOWN_FINDINGS_FILE="$KF" CR_LEDGER="$LEDGER" bash "$SCRIPT_DIR/known-findings.sh" --ladder > "$LADDER" || { echo "standards-cadence.sh: known-findings.sh --ladder failed" >&2; exit 2; }

OUT="$OUT_DIR/proposals-$TODAY.md"
# /cr-tune step 4 writes the same name: never clobber a file this script did not write
if [ -f "$OUT" ] && ! grep -q '^# CR standards proposals ' "$OUT"; then OUT="$OUT_DIR/proposals-$TODAY-standards.md"; fi
if [ -f "$OUT" ] && ! grep -q '^# CR standards proposals ' "$OUT"; then echo "standards-cadence.sh: $OUT exists and is not a cadence file; move it aside" >&2; exit 2; fi
KF="$KF" LEDGER="$LEDGER" LADDER="$LADDER" OUT="$OUT" OUT_DIR="$OUT_DIR" TODAY="$TODAY" SINCE="$SINCE" node -e '
const fs = require("fs");
const E = process.env, DAY = 864e5, WEEK = 7 * DAY;
const today = Date.parse(E.TODAY + "T00:00:00Z"), since = +E.SINCE;
const iso = (ms) => new Date(ms).toISOString().slice(0, 10);
const classes = JSON.parse(fs.readFileSync(E.KF, "utf8")).classes || [];
const byId = Object.fromEntries(classes.map(c => [c.id, c]));

// ledger rows -> first row per finding + last non-empty verdict (same rule as known-findings.sh)
const first = {}, verdict = {};
for (const l of fs.readFileSync(E.LEDGER, "utf8").split("\n")) {
  let r; try { r = JSON.parse(l); } catch { continue; }
  const k = `${(r.head || r.target_head || "").slice(0, 7)}|${r.finding_id}`;
  if (r.kind === "finding") { if (!first[k]) first[k] = r; if (r.verdict) verdict[k] = r.verdict; else if (!(k in verdict)) verdict[k] = ""; }
  else if (r.kind === "amend" && r.set && r.set.verdict && k in verdict) verdict[k] = r.set.verdict;
}
const globRe = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&")
  .replace(/\*\*\//g, "\u0001").replace(/\*\*/g, "\u0002").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]")
  .replace(/\u0001/g, "(?:.*/)?").replace(/\u0002/g, ".*") + "$");
const real = (c) => Object.keys(first).filter(k => {
  const r = first[k];
  return ["agreed", "confirmed", "fixed"].includes(verdict[k]) && r.file && (c.globs || []).some(g => globRe(g).test(r.file))
    && c.match && typeof r.text === "string" && new RegExp(c.match, "i").test(r.text);
}).map(k => Date.parse(first[k].ts)).filter(t => !isNaN(t));

// PROPOSE lines from the ladder
const proposed = {};
for (const l of fs.readFileSync(E.LADDER, "utf8").split("\n")) {
  const m = /^\s*PROPOSE \[([^\]]+)\] (retire|(\S+) -> (\S+))(?: recurrences=(\d+) branches=(\d+))?(?: host=(.*))?/.exec(l);
  if (m) proposed[m[1]] = { retire: m[2] === "retire", from: m[3], to: m[4], rec: m[5], br: m[6], host: m[7] };
}

const targetOf = (c, p) => {
  if (p.retire) return "rebuttal";
  if (p.to === "gate" || c.kind === "fix") return "lint or check";
  if (c.kind === "checklist") return "standard line";
  return /coderabbit/.test(c.source || "") ? "CodeRabbit rule" : "critic rule";
};
const approvalOf = (t) => (t === "CodeRabbit rule" || t === "critic rule") ? "operator" : "console GO + opus judge";

const lines = [];
for (const id of Object.keys(proposed)) {
  const c = byId[id]; if (!c) continue;
  const inWin = real(c).filter(t => t >= today - since * DAY).length;
  if (!inWin) continue;                       // not recurring in the window
  const p = proposed[id], t = targetOf(c, p);
  lines.push(`- [${id}] target: ${t} · move: ${p.retire ? "retire" : p.from + " -> " + p.to} · window_recurrences=${inWin}` +
    (p.rec ? ` · recurrences=${p.rec} · branches=${p.br}` : "") + (p.host ? ` · host=${p.host}` : "") + ` · approval: ${approvalOf(t)}`);
  p.listed = true;
}

// before/after promotion
const promoted = [];
for (const c of classes.filter(c => c.rung_since)) {
  const s = Date.parse(c.rung_since); if (isNaN(s)) continue;
  const ts = real(c), before = ts.filter(t => t < s), after = ts.filter(t => t >= s);
  const bSpan = Math.max(WEEK, s - Math.min(...before, s)), aSpan = Math.max(WEEK, today - s);
  const rb = before.length / (bSpan / WEEK), ra = after.length / (aSpan / WEEK);
  const falling = !before.length || ra < rb;
  promoted.push(`- [${c.id}] promoted ${c.rung_since} before=${before.length} after=${after.length} per-week-before=${rb.toFixed(2)} per-week-after=${ra.toFixed(2)} ` +
    (falling ? "falling" : "not falling: demote to restructure (S5)"));
}

// expiry: older files (>= 14 days) whose classes are still unbuilt
const exp = [];
for (const f of fs.readdirSync(E.OUT_DIR).filter(f => /^proposals-\d{4}-\d{2}-\d{2}(-standards)?\.md$/.test(f)).sort()) {
  const d = f.slice(10, 20), dm = Date.parse(d + "T00:00:00Z");
  if (!fs.readFileSync(E.OUT_DIR + "/" + f, "utf8").startsWith("# CR standards proposals ") || d >= E.TODAY || isNaN(dm) || today - dm < 14 * DAY) continue;
  for (const m of fs.readFileSync(E.OUT_DIR + "/" + f, "utf8").matchAll(/^- \[([^\]]+)\] target:/gm)) {
    const id = m[1], cl = byId[id];
    if (!cl || (cl.rung_since && cl.rung_since >= d)) { exp.push(`- BUILT [${id}] first proposed ${d}, class retired or promoted since`); continue; }
    exp.push(proposed[id] && proposed[id].listed ? `- REFIRED [${id}] first proposed ${d}, unbuilt after 14 days and still recurring` : `- EXPIRED [${id}] first proposed ${d}, not built and no longer recurring`);
  }
}

const out = [`# CR standards proposals ${E.TODAY}`, `window: ${since}d · expires: ${iso(today + 14 * DAY)} · proposed: ${E.TODAY}`, "",
  "Generated by scripts/cr/standards-cadence.sh. Each proposal names exactly one target; nothing is applied by this run.", "",
  "## Proposals", ...(lines.length ? lines : ["- none"]), "",
  "## Promoted classes: recurrence before and after", ...(promoted.length ? promoted : ["- none"]), "",
  "## Expiry", ...(exp.length ? exp : ["- none"]), ""];
fs.writeFileSync(E.OUT, out.join("\n"));
console.log(E.OUT);
' || exit 2
[ -f "$OUT" ] || { echo "standards-cadence.sh: proposals file was not written: $OUT" >&2; exit 2; }
