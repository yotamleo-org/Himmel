#!/usr/bin/env bash
# check-graph-freshness.sh — freshness + corpus-orphan CHECK for one graphify-out
# snapshot. The check companion to
# refresh-graph-map.sh: the refresher REBUILDS the graph; this tells
# a caller (scheduler / operator / query path) whether an existing graphify-out/
# is still trustworthy to query, or has gone stale / orphaned.
#
# WHY: graphify graphs are point-in-time snapshots under <repo>/graphify-out/.
# They drift silently as the corpus changes, and a graphify-out can be left
# pointing at a corpus that no longer exists (orphaned) — queries against a
# stale/orphaned graph return confidently-wrong structure. This guard fails loud
# before that happens.
#
# WHAT IT CHECKS (exit code):
#   rc=2 FAIL — out dir missing; manifest.json missing/unparseable/empty;
#               --corpus-root given but the dir does not exist;
#               corpus orphaned (no --corpus-root AND no .graphify_root marker,
#               OR >50% of manifest.json's checkable paths do not resolve
#               under the corpus root);
#   rc=3 STUCK — the graph is verified and fresh, but the semantic refresh is
#               stuck (one file failed, was shrink-refused or stayed backed off
#               in each of the last 3 merge rows of semantic-runs.jsonl). A
#               backed-off file is not retried until its content changes; to
#               clear it without a content change run
#               `semantic-merge.py unstick --out <out>`. Rows written before
#               backed_off_files existed name no backed-off files, so one backed
#               off at upgrade time counts as stuck only once 3 newer rows
#               carry it. A stale graph still reports rc=1; the stuck message
#               is printed either way. rc=3 is not rc=2: the graph can be
#               queried, only its semantic layer is behind.
#   rc=3 SEMANTIC-STALE — the semantic layer is past a bound even
#               though the AST layer may be fresh: the last merge row is older
#               than 48h (daily cadence + one missed fire), or the last row has
#               more than 10 content failures or 10 content refusals, or more
#               than 50 content files are unstamped, or the oldest unstamped
#               content file is older than 7d, or the unstamped counts cannot
#               be read. Templates, fixtures, testdata, eval
#               graders and vendored dirs (an ancestor holds VENDORED.md) are
#               counted apart as non_content_* and never trip the bound. A
#               stale graph still reports rc=1; the message prints either way.
#   rc=1 WARN — age is older than --max-age-days. Age is measured from
#               graph.json's embedded built_at_commit (via that commit's
#               committer date in the resolved corpus, when available),
#               else falls back to graph.json's (or
#               manifest.json's) filesystem mtime.
#   rc=0 OK   — fresh AND corpus verified AND (with a semantic-runs.jsonl) the
#               semantic layer within the bounds above; prints exactly one OK line (after the
#               semantic line below, when there is one):
#               "graph-freshness: OK (<age-days>d old, corpus verified)"
#   With a semantic-runs.jsonl, every verdict past the orphan check is preceded
#   by "graph-freshness: semantic last=<ts> failed=<n> refused=<n> [backed_off=<n>
#   unstamped=<n> oldest_unstamped=<d>d non_content_unstamped=<n>]
#   non_content_failed=<n>" on stdout.
#
# CORPUS RESOLUTION (orphan detection):
#   --corpus-root given → that dir is the corpus root (must exist); the orphan
#     check is skipped (the operator asserted the corpus).
#   no --corpus-root → the .graphify_root marker file in the out dir is read; its
#     first non-blank line is the corpus-root path (absolute, or relative to the
#     out dir's parent). Marker absent OR empty → orphan (rc=2). With the root
#     resolved, count how many manifest.json-named paths exist under it, out
#     of how many are checkable (untrusted absolute/traversal keys are
#     skipped from both counts); >50% missing (or zero checkable) → orphan
#     (rc=2). The measured ratio is always printed (stderr) for this step.
#
# Usage:
#   check-graph-freshness.sh --out <graphify-out dir> [--max-age-days N] [--corpus-root <path>]
#   check-graph-freshness.sh --out <graphify-out dir> --print-built-at
#     prints graph.json's built_at_commit when it is a literal commit SHA and
#     exits 0; prints nothing and exits 2 otherwise. No other check runs
#     (himmel-update.sh's graph-data fetch reads it).
#
# Exit: 0 ok; 1 stale (warn) / usage; 2 fail (missing/orphaned/unparseable); 3 semantic refresh stuck.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-graph-map.sh"

OUT="" MAX_AGE_DAYS=7 CORPUS_ROOT="" PRINT_BUILT_AT=0
usage() { echo "usage: check-graph-freshness.sh --out <graphify-out dir> [--max-age-days N] [--corpus-root <path>] | --print-built-at" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --max-age-days) MAX_AGE_DAYS="${2:-}"; shift 2 ;;
    --corpus-root) CORPUS_ROOT="${2:-}"; shift 2 ;;
    --print-built-at) PRINT_BUILT_AT=1; shift ;;
    -h|--help) usage ;;
    *) echo "check-graph-freshness: unknown flag: $1" >&2; usage ;;
  esac
done
[ -n "$OUT" ] || usage

# built_at_commit is UNTRUSTED graph.json content (codex CR): must look
# like a literal commit SHA (hex, 7-40 chars) before it ever reaches git,
# or a value like "HEAD" (a ref, not the actual built commit) or "--all"
# (a git OPTION, not a revision — `git log --all` silently swallows it)
# would resolve to an unrelated, often-fresher timestamp and falsely mark
# a stale graph as fresh. Prints nothing for anything else.
built_at_commit() {
  python3 -c 'import json,re,sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError, UnicodeError):
    sys.exit(0)
c = d.get("built_at_commit") if isinstance(d, dict) else None
if isinstance(c, str) and re.fullmatch(r"[0-9a-fA-F]{7,40}", c):
    print(c)' "$1" 2>/dev/null || true
}
if [ "$PRINT_BUILT_AT" -eq 1 ]; then
  _bac="$(built_at_commit "$OUT/graph.json")"
  [ -n "$_bac" ] || exit 2
  printf '%s\n' "$_bac"
  exit 0
fi
case "$MAX_AGE_DAYS" in
  ''|*[!0-9]*) echo "check-graph-freshness: --max-age-days must be a non-negative integer, got: $MAX_AGE_DAYS" >&2; exit 1 ;;
esac

# Remediation embedded in every non-OK message: the refresh invocation shape
# (mirrors refresh-graph-map.sh's own usage). No --backend: the runner's own
# default (claude-cli) is the one we want a copy-paste of this
# hint to use — naming a backend here is how it went stale in the first place.
REMEDIATION="Rebuild with: bash $REFRESH --name <N> --corpus-root <path> --maps-dir <vault>/60-Maps --title \"<Title>\" --slug <slug>"
_cgf_choices="$HERE/../himmelctl/lib/graph-choices.js"
_cgf_own="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || _cgf_own=""
_cgf_of_out="$(git -C "$(dirname "${OUT:-.}")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || _cgf_of_out=""
if [ -n "$_cgf_own" ] && [ "$_cgf_of_out" = "$_cgf_own" ] && [ "$(node "$_cgf_choices" role 2>/dev/null)" != publisher ]; then
  _cgf_remedy="$(node "$_cgf_choices" remedy 2>/dev/null)" || _cgf_remedy=""
  REMEDIATION="Refresh: ${_cgf_remedy:-the himmel graph comes from us with each update (bash scripts/himmel-update.sh)}"
fi

# python3 is required (manifest.json parse + cross-platform mtime). `stat -c %Y`
# is GNU-only and `stat -f %m` is BSD-only, so mtime goes through python3.
command -v python3 >/dev/null 2>&1 || {
  echo "graph-freshness: FAIL python3 not found (needed to parse manifest.json + read mtime)." >&2
  echo "  $REMEDIATION" >&2; exit 2
}

# FAIL: print a one-line reason + the remediation, exit 2.
fail() {
  echo "graph-freshness: FAIL $1" >&2
  echo "  $REMEDIATION" >&2
  exit 2
}

# --- 1. out dir ---
[ -d "$OUT" ] || fail "out dir not found: $OUT"

# --- 2. manifest.json present + parseable (flat object of filename -> {...}) ---
MANIFEST="$OUT/manifest.json"
[ -f "$MANIFEST" ] || fail "manifest.json missing at $MANIFEST."
# Emit one manifest key per line.
#
# UTF-8 IS LOAD-BEARING, BOTH WAYS. The manifest keys are
# corpus-relative FILENAMES, and a real vault has filenames outside the Windows
# default codepage (Hebrew, emoji). Two separate crashes came from that:
#   * `open()` without encoding= decodes the manifest as cp1252 on Windows -> UnicodeDecodeError
#   * `print(k)` encodes to a cp1252 stdout                                -> UnicodeEncodeError
# Either killed python, which the shell then reported as "manifest unparseable"
# — so the guard failed CLOSED on a perfectly good graph and sent the operator
# into a ~45min/$3 rebuild for nothing. Same class the salus vault_health.py
# already handles with PYTHONUTF8=1.
#
# Exit codes are DISTINCT on purpose: a crash and a corrupt manifest are
# different facts and must not share one message (they did, and that is what
# made the bug hard to see).
#   0 = ok   1 = genuinely not a non-empty JSON object   3 = internal/encoding error
KEYS_RC=0
KEYS="$(python3 - "$MANIFEST" <<'PYEOF'
import json, sys

try:
    sys.stdout.reconfigure(encoding="utf-8")  # py3.7+; keys may be non-cp1252
except AttributeError:                        # pragma: no cover - ancient python
    sys.exit(3)

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except (OSError, UnicodeError) as exc:
    print("read/decode failed: %s" % exc, file=sys.stderr)
    sys.exit(3)
except ValueError:
    sys.exit(1)          # real corruption: not JSON

if not isinstance(d, dict) or not d:
    sys.exit(1)          # real: parsed, but not a non-empty object

for k in d:
    print(k)
PYEOF
)" || KEYS_RC=$?
case "$KEYS_RC" in
  0) ;;
  1) fail "manifest.json at $MANIFEST is not a non-empty JSON object (unparseable/empty)." ;;
  *) fail "manifest.json at $MANIFEST could not be READ (rc=$KEYS_RC; see stderr above) — this is an internal/encoding error, NOT proof the manifest is corrupt. The graph may be fine." ;;
esac

# --- 3. corpus resolution + orphan check ---
if [ -n "$CORPUS_ROOT" ]; then
  # operator asserted the corpus root; only require it to exist.
  [ -d "$CORPUS_ROOT" ] || fail "--corpus-root not found: $CORPUS_ROOT."
  CORPUS_RESOLVED="$CORPUS_ROOT"
else
  MARKER="$OUT/.graphify_root"
  [ -f "$MARKER" ] || fail "corpus orphaned: no --corpus-root given and no .graphify_root marker in $OUT (cannot locate the corpus this graph was built from)."
  # first non-blank line of the marker = corpus-root path
  MARKER_ROOT="$(grep -m1 -v '^[[:space:]]*$' "$MARKER" 2>/dev/null || true)"
  [ -n "$MARKER_ROOT" ] || fail "corpus orphaned: .graphify_root marker in $OUT is empty (cannot locate the corpus)."
  # absolute (POSIX /c/... or drive C:\...) as-is; else relative to the out dir's parent
  case "$MARKER_ROOT" in
    /*|[A-Za-z]:*) CORPUS_RESOLVED="$MARKER_ROOT" ;;
    *)             CORPUS_RESOLVED="$OUT/../$MARKER_ROOT" ;;
  esac
  # Count how many manifest-named files exist under the resolved corpus root,
  # out of how many are checkable, and orphan only on a MAJORITY miss
  # rather than requiring just one hit. Keys are UNTRUSTED (a
  # corrupt/crafted manifest could carry absolute or ..-traversal paths that
  # "verify" via files OUTSIDE the root — codex CR): only plain relative keys
  # may join the path; others are skipped (not counted either way).
  #
  # Strip a trailing CR from each key: python3 on
  # Windows writes text-mode stdout, translating each print()'s "\n" to
  # "\r\n"; bash's `$(...)` command substitution here strips only the very
  # LAST trailing newline, so every key but the last keeps a literal
  # trailing \r glued onto its filename. `$CORPUS_RESOLVED/$key` then never
  # matches a real file for ~all keys, and the checker reported "0 exist"
  # while the overwhelming majority genuinely did.
  total=0
  exist=0
  while IFS= read -r key; do
    key="${key%$'\r'}"
    [ -n "$key" ] || continue
    case "$key" in
      /*|[A-Za-z]:*|../*|*/../*|*/..|..) continue ;;
    esac
    total=$((total + 1))
    [ -e "$CORPUS_RESOLVED/$key" ] && exist=$((exist + 1))
  done <<< "$KEYS"
  # Orphan threshold: >50% of checkable manifest paths missing. total=0 (no
  # checkable keys at all) has nothing to verify against -> orphaned too.
  RATIO_PCT=0
  [ "$total" -gt 0 ] && RATIO_PCT=$(( exist * 100 / total ))
  echo "graph-freshness: corpus check: $exist/$total manifest paths exist under $CORPUS_RESOLVED (${RATIO_PCT}%)." >&2
  if [ "$total" -eq 0 ] || [ $(( exist * 2 )) -lt "$total" ]; then
    fail "corpus orphaned: only $exist/$total manifest.json paths exist under $CORPUS_RESOLVED (${RATIO_PCT}%, at least 50% required) — graph references a gone/moved corpus."
  fi
fi

# --- 3b. semantic refresh: the last merge row, and files stuck across runs ---
# The semantic layer is judged on its own, apart from the AST age in step 4: the
# hourly AST rebuild keeps graph.json fresh while the semantic layer can lag for
# weeks. SEMANTIC-STALE when the last merge row is older than SEM_MAX_AGE_H (the
# daily semantic cadence, 24h, plus 24h grace for one missed fire), has no ts, or
# carries more than SEM_MAX_FAILED content failures, SEM_MAX_REFUSED refusals,
# SEM_MAX_UNSTAMPED unstamped content files, or a content file unstamped for more
# than SEM_MAX_OLDEST_D days. A failed or refused path is non-content, and
# counted apart, when a directory above it holds VENDORED.md or one of its
# directories is a template or fixture directory: semantic-merge.py's
# noncontent(), which also keeps such files out of the corpus, so a new one is
# never unstamped and only older run rows still name them.
SEM_MAX_AGE_H=48 SEM_MAX_FAILED=10 SEM_MAX_REFUSED=10 SEM_MAX_UNSTAMPED=50 SEM_MAX_OLDEST_D=7
STUCK_MSG="" SEM_STALE_MSG=""
SEMANTIC_RUNS="$OUT/semantic-runs.jsonl"
if [ -f "$SEMANTIC_RUNS" ]; then
  SEM_OUT="$(python3 - "$SEMANTIC_RUNS" "$CORPUS_RESOLVED" "$OUT" "$HERE/semantic-merge.py" \
    "$SEM_MAX_AGE_H" "$SEM_MAX_FAILED" "$SEM_MAX_REFUSED" "$SEM_MAX_UNSTAMPED" "$SEM_MAX_OLDEST_D" <<'PYEOF'
import calendar, importlib.util, json, os, sys, time

root, out = sys.argv[2], sys.argv[3]
max_age_h, max_failed, max_refused, max_unstamped, max_oldest_d = (int(v) for v in sys.argv[5:10])
spec = importlib.util.spec_from_file_location("semantic_merge", sys.argv[4])
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)


def noncontent(rel):  # the one rule the semantic corpus walk uses, so the two never drift
    return sm.noncontent(root, rel)


rows = []
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and "batch" in row:
            rows.append(row)
if not rows:
    sys.exit(0)


def stuck(row):
    return set(row.get("failed_files") or []) | set(row.get("refused_files") or []) | set(row.get("backed_off_files") or [])


last = rows[-1]
failed_files = last.get("failed_files")
failed = len(failed_files) if failed_files is not None else last.get("failed", 0)
nc_failed = sum(1 for f in failed_files or [] if noncontent(f))
refused = len(last["refused_files"]) if "refused_files" in last else last.get("shrink_refused", 0)
nc_refused = sum(1 for f in last.get("refused_files") or [] if noncontent(f))
status = ""
unstamped_content, oldest_content_d = 0, 0.0
changed, unstamped_err = None, ""
if os.path.isfile(os.path.join(out, "semantic-manifest.json")):
    # the same counts `semantic-merge.py status` prints, plus the content-only ones the bounds judge
    try:
        _, changed, skipped = sm.unstamped(type("A", (), {"root": root, "out": out}))
    except Exception as exc:  # unreadable manifest or corpus: the unstamped bounds cannot be judged, so never OK
        changed = skipped = None
        unstamped_err = type(exc).__name__
if changed is not None:
    now = time.time()
    age_d = {rel: (now - os.path.getmtime(os.path.join(root, rel))) / 86400 for rel in changed}
    content = [rel for rel in changed if not noncontent(rel)]
    unstamped_content = len(content)
    oldest_content_d = max((age_d[rel] for rel in content), default=0.0)
    status = " backed_off=%d unstamped=%d oldest_unstamped=%dd non_content_unstamped=%d" % (
        len(skipped), len(changed), max(age_d.values(), default=0), len(changed) - len(content))
print("LINE last=%s failed=%s refused=%s%s non_content_failed=%d" % (last.get("ts", "?"), failed, refused, status, nc_failed))
if len(rows) >= 3:
    every = stuck(rows[-1]) & stuck(rows[-2]) & stuck(rows[-3])
    if every:
        print("STUCK " + ", ".join(sorted(every)))

why = []
try:
    age_h = (time.time() - calendar.timegm(time.strptime(last["ts"], "%Y-%m-%dT%H:%M:%SZ"))) / 3600
except (KeyError, TypeError, ValueError):
    age_h = None
if age_h is None:
    why.append("last semantic merge age unknown (no parseable ts)")
elif age_h > max_age_h:
    why.append("last semantic merge %dd ago (%dh, bound %dh)" % (age_h // 24, age_h, max_age_h))
if failed - nc_failed > max_failed:
    why.append("content failed=%d (bound %d; %d non-content failures not counted)" % (failed - nc_failed, max_failed, nc_failed))
if refused - nc_refused > max_refused:
    why.append("content refused=%d (bound %d; %d non-content refusals not counted)" % (refused - nc_refused, max_refused, nc_refused))
if unstamped_err:
    why.append("unstamped counts unavailable (%s reading the semantic manifest or corpus)" % unstamped_err)
if unstamped_content > max_unstamped:
    why.append("content unstamped=%d (bound %d)" % (unstamped_content, max_unstamped))
if oldest_content_d > max_oldest_d:
    why.append("oldest content unstamped %.1fd (bound %dd)" % (oldest_content_d, max_oldest_d))
if why:
    print("SEMSTALE " + "; ".join(why))
PYEOF
)" || fail "cannot read $SEMANTIC_RUNS."
  SEM_LINE="$(printf '%s\n' "$SEM_OUT" | sed -n 's/^LINE //p')"
  [ -z "$SEM_LINE" ] || echo "graph-freshness: semantic $SEM_LINE"
  SEM_STUCK="$(printf '%s\n' "$SEM_OUT" | sed -n 's/^STUCK //p')"
  if [ -n "$SEM_STUCK" ]; then
    STUCK_MSG="semantic refresh stuck: $SEM_STUCK failed, was refused or stayed backed off in each of the last 3 runs (a backed-off file stays stuck until its content changes; to retry it now run: python3 $(printf '%q' "$HERE")/semantic-merge.py unstick --out $(printf '%q' "$OUT"))."
    echo "graph-freshness: STUCK $STUCK_MSG" >&2
  fi
  SEM_WHY="$(printf '%s\n' "$SEM_OUT" | sed -n 's/^SEMSTALE //p')"
  if [ -n "$SEM_WHY" ]; then
    SEM_STALE_MSG="semantic layer is stale: $SEM_WHY. The AST layer can be fresh while this is true. Remedy: run the semantic pass for this corpus (himmel station: bash ~/.claude/graphmap-cadence/graphmap-himmel.sh, the HIMMEL-GraphMap-Himmel cron runner)."
    echo "graph-freshness: SEMANTIC-STALE $SEM_STALE_MSG" >&2
  fi
fi

# --- 4. age check: build identity (built_at_commit) preferred over mtime ---
# graph.json is git-tracked while manifest.json/.graphify_root
# are not, so a checkout/restore can give an OLD graph a FRESH mtime while
# corpus verification (step 3) still passes on retained metadata — mtime
# alone then stays silent on genuinely stale structure. When graph.json
# embeds a built_at_commit and the resolved corpus is a git repo that knows
# that commit, age is measured from THAT commit's committer date instead —
# a checkout cannot forge a commit date. Falls back to file mtime when the
# identity signal is unavailable (no graph.json, no built_at_commit, corpus
# isn't a git repo, or the commit is unknown to it, e.g. a shallow clone).
AGE_FILE="$OUT/graph.json"
[ -f "$AGE_FILE" ] || AGE_FILE="$MANIFEST"

AGE_EPOCH=""
if [ -f "$OUT/graph.json" ]; then
  # built_at_commit() rejects anything but a literal SHA before it is used.
  BUILT_COMMIT="$(built_at_commit "$OUT/graph.json")"
  if [ -n "$BUILT_COMMIT" ]; then
    AGE_EPOCH="$(git -C "$CORPUS_RESOLVED" log -1 --format=%ct "$BUILT_COMMIT" -- 2>/dev/null || true)"
  fi
fi

# verdict = STALE when real-valued age (days) > max-age-days; floor days for display.
if [ -n "$AGE_EPOCH" ]; then
  AGE_OUT="$(python3 -c 'import sys,time
age=(time.time()-float(sys.argv[1]))/86400.0
print("STALE" if age > float(sys.argv[2]) else "FRESH", int(age))' "$AGE_EPOCH" "$MAX_AGE_DAYS")"
  AGE_SRC="build commit ${BUILT_COMMIT}"
else
  AGE_OUT="$(python3 -c 'import os,sys,time
age=(time.time()-os.path.getmtime(sys.argv[1]))/86400.0
print("STALE" if age > float(sys.argv[2]) else "FRESH", int(age))' "$AGE_FILE" "$MAX_AGE_DAYS")" \
    || fail "cannot read mtime of $AGE_FILE."
  AGE_SRC="$AGE_FILE mtime"
fi
read -r AGE_VERDICT AGE_DAYS_FLOOR <<< "$AGE_OUT"
if [ "$AGE_VERDICT" = "STALE" ]; then
  echo "graph-freshness: WARN $AGE_SRC is ${AGE_DAYS_FLOOR}d old (older than --max-age-days $MAX_AGE_DAYS)." >&2
  echo "  $REMEDIATION" >&2
  exit 1
fi

[ -z "$STUCK_MSG$SEM_STALE_MSG" ] || exit 3

echo "graph-freshness: OK (${AGE_DAYS_FLOOR}d old, corpus verified)"
