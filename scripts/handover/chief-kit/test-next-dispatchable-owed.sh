#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-next-dispatchable.sh
# test-next-dispatchable-owed.sh — slice S4a of the in-progress drift fixes: what next-dispatchable.sh does with a merged contract=no PR whose
# remainder the reader answers `owed` (a coverage line `owed -> chief|operator by YYYY-MM-DD`). Fixture only: a Jira mirror,
# a status log of contract=no merge rows, a stub reader (NEXT_DISPATCH_READER: it prints the PR body as its answer, so a
# body file IS the answer line) and a gh stub that logs each call. No real mirror, Jira, gh or worktree is touched.
# NEXT_DISPATCH overrides the script under test. bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-next-dispatchable-owed.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${NEXT_DISPATCH:-$HERE/next-dispatchable.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/next-dispatch-owed.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" HANDOVER_DIR="$WORK/h"
mkdir -p "$HOME" "$HANDOVER_DIR"
export TICKET_STATUS_STATE_DIR="$WORK/ts-none" HIMMEL_ADMISSIONS_LEDGER="$WORK/ledger-none.jsonl"
GN="$WORK/git-none"; mkdir -p "$GN"
git -C "$GN" init -q -b main && git -C "$GN" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "init" \
    || { echo "FAIL: could not build the fixture main"; exit 1; }
export NEXT_DISPATCH_GIT_DIR="$GN" NEXT_DISPATCH_MAIN_REF=main
M="$WORK/jira-mirror/HIMMEL"; mkdir -p "$M"
mkdir -p "$WORK/notcore-stub"
cat > "$WORK/notcore-stub/index.js" <<'NCEOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
NCEOF
export NEXT_DISPATCH_JIRA_CLI="$WORK/notcore-stub/index.js"
printf 'v1.0.1\tfalse\t\n' > "$WORK/jira-mirror/HIMMEL.versions.tsv"

mk() { # <key> <status> <title> <body>
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "x"\npriority: "Medium"\nlabels: []\nfixVersions: []\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: %s\n\n## Description\n\n%s\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n' \
        "$1" "$2" "$1" "$3" "$4" > "$M/$1.md"
}

# the gh stub logs every call; `pr view <n>` prints that PR's body file, every list is empty
export GH_ARGS="$WORK/gh.args" PR_BODY_DIR="$WORK/prbody"
mkdir -p "$PR_BODY_DIR"; : > "$GH_ARGS"
cat > "$WORK/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"
case "$1 $2" in
    "pr view")
        [ "$4" = --repo ] && [ -n "${5:-}" ] && [ "${6:-}" = --json ] && [ "${7:-}" = body ] || { echo "gh stub: unexpected pr view: $*" >&2; exit 64; }
        cat "$PR_BODY_DIR/$3" 2>/dev/null || exit 1; exit 0 ;;
    "pr list") exit 0 ;;
esac
echo "gh stub: unsupported request: $*" >&2; exit 64
EOF
# the stub reader: the PR body is the reader's answer line
printf 'import sys\nsys.stdout.write(sys.stdin.read())\n' > "$WORK/reader.py"
cat > "$WORK/classify" <<'EOF'
#!/usr/bin/env bash
for k in "$@"; do printf '%s\tLOCAL-NATIVE\tstub\n' "$k"; done
EOF
chmod +x "$WORK/gh" "$WORK/classify"
LEG="$WORK/HIMMEL-399-N1-live.md"; printf '> **Writes:** none named\n# live\n' > "$LEG"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"}]}\n' "$LEG" > "$WORK/fleet.json"
STATE="$WORK/state"; mkdir -p "$STATE/workers"
CACHE="$WORK/cache.json"
DUE="2026-11-20"
K_C="HIMMEL-$((300 + 3))"  # the key whose older PR is owed and whose newer PR is a remainder (built so no literal key sits in a citation)

mk HIMMEL-301 "In Progress" "one owed PR" "Edit scripts/lib/o1.sh."
mk HIMMEL-302 "In Progress" "older remaining, newer owed" "Edit scripts/lib/o2.sh."
mk HIMMEL-303 "In Progress" "older owed, newer remaining" "Edit scripts/lib/o3.sh."
mk HIMMEL-304 "In Progress" "older handed-off, newer owed" "Edit scripts/lib/o4.sh."
mk HIMMEL-305 "In Progress" "owed, then a newer PR that records none" "Edit scripts/lib/o5.sh."
printf 'owed\toperator\t%s\tlive proof\n' "$DUE" > "$PR_BODY_DIR/6001"
printf 'remaining\tEdit scripts/lib/older.sh\n' > "$PR_BODY_DIR/6002"
printf 'owed\tchief\t%s\tthe chief reruns the check\n' "$DUE" > "$PR_BODY_DIR/6003"
printf 'owed\toperator\t%s\tlive proof\n' "$DUE" > "$PR_BODY_DIR/6004"
printf 'remaining\tEdit scripts/lib/newer-scope.sh\n' > "$PR_BODY_DIR/6005"
printf 'handed-off\tHIMMEL-9\trest: deferred to HIMMEL-9\n' > "$PR_BODY_DIR/6006"
printf 'owed\toperator\t%s\tlive proof\n' "$DUE" > "$PR_BODY_DIR/6007"
printf 'owed\toperator\t%s\tlive proof\n' "$DUE" > "$PR_BODY_DIR/6008"
printf 'none\n' > "$PR_BODY_DIR/6009"
printf 'owed\tchief\t%s\tthe chief reruns the check\n' "$DUE" > "$PR_BODY_DIR/6010"
printf 'handed-off\tHIMMEL-9\trest: deferred to HIMMEL-9\n' > "$PR_BODY_DIR/6011"
mk HIMMEL-306 "In Progress" "older owed, newer handed-off" "Edit scripts/lib/o6.sh."
mk HIMMEL-307 "In Progress" "two owed PRs, the newer is due first" "Edit scripts/lib/o7.sh."
mk HIMMEL-308 "In Progress" "two owed PRs, the older is due first" "Edit scripts/lib/o8.sh."
printf 'owed\tchief\t2026-11-25\tlater check\n' > "$PR_BODY_DIR/6012"
printf 'owed\toperator\t2026-11-19\tearlier check\n' > "$PR_BODY_DIR/6013"
printf 'owed\tchief\t2026-11-18\tearlier check\n' > "$PR_BODY_DIR/6014"
printf 'owed\toperator\t2026-11-22\tlater check\n' > "$PR_BODY_DIR/6015"
{
    for pair in 301:6001 302:6002 302:6003 303:6004 303:6005 304:6006 304:6007 305:6008 305:6009 306:6010 306:6011 307:6012 307:6013 308:6014 308:6015; do
        printf '{"ts":"t","event":"merge","key":"HIMMEL-%s","pr":"%s","contract":"no","result":"noop"}\n' "${pair%%:*}" "${pair##*:}"
    done
} > "$STATE/status-events.jsonl"

run() { NEXT_DISPATCH_BODY_CACHE="${CACHE_PATH:-off}" NEXT_DISPATCH_READER="${READER_OVERRIDE:-$WORK/reader.py}" NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify" \
    bash "$SUT" --workers-dir "$STATE/workers" --workers-from "$WORK/fleet.json" 2>/dev/null; }
row() { printf '%s\n' "$1" | grep -E "(^|	)$2(	|:|$)" || true; }

out="$(run)"
# (a) one owed PR
has "(a) an owed PR prints OWED with the PR, who and the date" "$out" "OWED HIMMEL-301: merged PR #6001 owes operator by $DUE"
lacks "(a) an owed ticket is no RESUME row" "$out" "RESUME	HIMMEL-301"
lacks "(a) an owed ticket needs no chief note" "$out" "NEEDS-CHIEF-NOTE HIMMEL-301"
# a second run on one cache path reads each owed PR once
out_first="$(CACHE_PATH="$CACHE" run)" || fail "(a) the cache-populating run exited non-zero"
has "(a) the cache-populating run printed the OWED row" "$out_first" "OWED HIMMEL-301: merged PR #6001 owes operator by $DUE"
: > "$GH_ARGS"
out_second="$(CACHE_PATH="$CACHE" run)" || fail "(a) the cache-hit run exited non-zero"
has "(a) the cache-hit run printed the same OWED row" "$out_second" "OWED HIMMEL-301: merged PR #6001 owes operator by $DUE"
has "(a) the cache-hit run reached gh (it listed the open PRs), so it ran to the end" "$(cat "$GH_ARGS")" "pr list"
if grep -q 'pr view 6001' "$GH_ARGS"; then fail "(a) a second run on the same cache path makes no gh pr view call for the owed PR (gh log: $(cat "$GH_ARGS"))"; else pass "(a) a second run on the same cache path makes no gh pr view call for the owed PR"; fi
# (b) older remaining, newer owed
has "(b) an older remaining PR and a newer owed one: OWED" "$out" "OWED HIMMEL-302: merged PR #6003 owes chief by $DUE"
lacks "(b) the newer owed PR drops the older remainder: no RESUME row" "$out" "RESUME	HIMMEL-302"
# (c) older owed, newer remaining
r303="$(printf '%s\n' "$out" | grep -E '^RESUME	' || true)"
has "(c) an older owed PR and a newer remaining one: a RESUME row" "$out" "RESUME	"
[ "$(printf '%s\n' "$r303" | grep -c .)" = 1 ] && pass "(c) exactly one RESUME row in the run" || fail "(c) exactly one RESUME row in the run (out: $out)"
has "(c) its scope is the newer PR's remainder" "$r303" "scripts/lib/newer-scope.sh"
has "(c) it is the ticket whose older PR is owed" "$r303" "older owed, newer remaining"
lacks "(c) no OWED row beside it" "$out" "OWED $K_C"
# (d) older handed-off, newer owed
has "(d) an older handed-off PR and a newer owed one: OWED" "$out" "OWED HIMMEL-304: merged PR #6007 owes operator by $DUE"
lacks "(d) no HANDED-OFF row" "$out" "HANDED-OFF HIMMEL-304"
# (e) a newer PR that records none still asks
has "(e) a newer PR recording none after an owed one: NEEDS-CHIEF-NOTE" "$out" "NEEDS-CHIEF-NOTE HIMMEL-305: merged PR #6009"
lacks "(e) and no OWED row for it" "$out" "OWED HIMMEL-305"

# (f) older owed, newer handed-off: the owed step is still pending, so OWED, and neither a RESUME row nor a HANDED-OFF row
has "(f) an older owed PR and a newer handed-off one: OWED" "$out" "OWED HIMMEL-306: merged PR #6010 owes chief by $DUE"
lacks "(f) no HANDED-OFF row while a step is owed" "$out" "HANDED-OFF HIMMEL-306"
lacks "(f) no RESUME row for it" "$out" "RESUME	HIMMEL-306"

# (g) several owed PRs: the row names the earliest due date, whichever PR carries it
has "(g) two owed PRs, the newer due first: the row names the newer PR and its date" "$out" "OWED HIMMEL-307: merged PR #6013 owes operator by 2026-11-19"
has "(g) two owed PRs, the older due first: the row names the older PR and its date" "$out" "OWED HIMMEL-308: merged PR #6014 owes chief by 2026-11-18"

# (h) the real reader: a lone CR joins two items for the merge and for ready-check, so the dispatcher must not read them as two
mk HIMMEL-309 "In Progress" "a lone CR joins the owed line to the next" "Edit scripts/lib/o9.sh."
mk HIMMEL-310 "In Progress" "the same body with a newline, the control" "Edit scripts/lib/o10.sh."
printf '## Ticket coverage\n- a: owed -> operator by %s\r- c: done\n' "$DUE" > "$PR_BODY_DIR/6016"
printf '## Ticket coverage\n- a: owed -> operator by %s\n- c: done\n' "$DUE" > "$PR_BODY_DIR/6017"
printf '{"ts":"t","event":"merge","key":"HIMMEL-309","pr":"6016","contract":"no","result":"noop"}\n{"ts":"t","event":"merge","key":"HIMMEL-310","pr":"6017","contract":"no","result":"noop"}\n' >> "$STATE/status-events.jsonl"
out_h="$(READER_OVERRIDE="$(cd "$(dirname "$SUT")/../../lib" && pwd)/pr_remainder.py" run)"
has "(h) the control body with a newline reads as owed through the real reader" "$out_h" "OWED HIMMEL-310: merged PR #6017 owes operator by $DUE"
lacks "(h) a lone CR is stripped, so the joined line is not owed" "$out_h" "OWED HIMMEL-309"

if [ "$fails" -eq 0 ]; then echo "next-dispatchable-owed: all rows passed"; else echo "next-dispatchable-owed: $fails row(s) failed"; exit 1; fi
