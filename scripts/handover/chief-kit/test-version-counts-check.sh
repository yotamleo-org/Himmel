#!/usr/bin/env bash
# Platform guard: Linux/macOS bash 3.2+, python3.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VC="$HERE/version-counts-check.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/version-counts-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT

pass=0; fails=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; [ $# -lt 2 ] || printf '    %s\n' "$2"; fails=$((fails+1)); }
check()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "[$2] != [$3]"; fi; }
contains() { if grep -q -F -e "$3" <<< "$2"; then ok "$1"; else bad "$1" "output does not contain [$3]: $2"; fi; }

if [ ! -f "$VC" ]; then
    bad "version-counts-check.sh exists" "$VC is missing"
    echo "test-version-counts-check: $pass passed, $fails failed"
    exit 1
fi

mkdir -p "$W/bin"
cat > "$W/bin/jira-stub" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_FAIL:-}" ] || { echo "stub: boom" >&2; exit 1; }
printf '%s\n' "$*" >> "$LIVE_DIR/calls.log"
jql=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--jql" ]; then jql="$2"; fi
    shift
done
ver="$(printf '%s' "$jql" | sed -n 's/.*fixVersion = "\([^"]*\)".*/\1/p')"
[ -f "$LIVE_DIR/$ver.tsv" ] && cat "$LIVE_DIR/$ver.tsv"
exit 0
STUB
chmod +x "$W/bin/jira-stub"

new_case() {
    CASE="$W/$1"; M="$CASE/HIMMEL"; LIVE_DIR="$CASE/live"
    mkdir -p "$M" "$LIVE_DIR"
    printf 'v1.0.0\ttrue\t2026-09-01\tfalse\nv1.1.4\tfalse\n' > "$CASE/HIMMEL.versions.tsv"
}
mirror_issue() {
    printf -- '---\nkey: "%s"\nstatus: "%s"\nstatusCategory: "To Do"\nlabels: %s\nfixVersions: %s\nupdated: "2026-11-16T09:00:00.000+0100"\n---\n\n# %s\n' \
        "$1" "$2" "$3" "$4" "$1" > "$M/$1.md"
}
live_row() { printf '%s\tTask\t%s\ttitle\t%s\n' "$2" "$3" "$4" >> "$LIVE_DIR/$1.tsv"; }
run_vc() {
    OUT="$(JIRA_PROJECT_KEY=HIMMEL VERSION_COUNTS_MIRROR="$M" VERSION_COUNTS_JIRA="$W/bin/jira-stub" LIVE_DIR="$LIVE_DIR" bash "$VC" "$@" 2>"$CASE/err")"
    RC=$?
}

new_case same
mirror_issue HIMMEL-1 "To Do" '["residual"]' '["v1.1.4"]'
mirror_issue HIMMEL-2 "In Progress" '["residual-depth-1"]' '["v1.1.4"]'
mirror_issue HIMMEL-3 "To Do" '["backlog","notresidualx"]' '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "To Do" residual
live_row v1.1.4 HIMMEL-2 "In Progress" residual-depth-1
live_row v1.1.4 HIMMEL-3 "To Do" backlog,notresidualx
run_vc
check "SAME: exit 0" "$RC" "0"
contains "SAME: v1.1.4 line shows live and mirror open and residual" "$OUT" "v1.1.4 open live=3 mirror=3 residual-regex live=2 mirror=2 SAME"
contains "SAME: final verdict" "$OUT" "VERDICT SAME"

new_case stale
mirror_issue HIMMEL-1 "To Do" '[]' '["v1.1.4"]'
mirror_issue HIMMEL-2 "To Do" '[]' '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "To Do" ""
run_vc
check "DIFF open: exit 1" "$RC" "1"
contains "DIFF open: counts printed side by side" "$OUT" "v1.1.4 open live=1 mirror=2 residual-regex live=0 mirror=0 DIFF"
contains "DIFF open: final verdict" "$OUT" "VERDICT DIFF"

new_case residual
mirror_issue HIMMEL-1 "To Do" '["residual"]' '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "To Do" backlog
run_vc
check "residual-only difference: exit 0" "$RC" "0"
contains "residual-only difference: both residual columns shown, verdict SAME" "$OUT" "v1.1.4 open live=1 mirror=1 residual-regex live=0 mirror=1 SAME"

new_case closed
mirror_issue HIMMEL-1 "To Do" '[]' '["v1.1.4"]'
mirror_issue HIMMEL-2 "Wont Do" '["residual"]' '["v1.1.4"]'
mirror_issue HIMMEL-3 "Done" '[]' '["v1.1.4"]'
mirror_issue HIMMEL-4 "Closed" '[]' '["v1.1.4"]'
mirror_issue HIMMEL-5 "Resolved" '[]' '["v1.1.4"]'
mirror_issue HIMMEL-6 "Won't Do" '[]' '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "To Do" ""
live_row v1.1.4 HIMMEL-2 "Wont Do" residual
live_row v1.1.4 HIMMEL-6 "Won't Do" ""
run_vc
check "closed statuses: exit 0" "$RC" "0"
contains "closed statuses: one open ticket per side" "$OUT" "v1.1.4 open live=1 mirror=1 residual-regex live=0 mirror=0 SAME"

new_case parity5505
python3 - "$HERE/fixtures/t1-views.json" "$M" "$LIVE_DIR" <<'PYTEST'
import json, pathlib, sys
f, mirror, live = sys.argv[1:]
rows = json.loads(pathlib.Path(f).read_text())['statuses']
for i, r in enumerate(rows, 1):
    fields = {'key': 'HIMMEL-%d' % i, 'status': r['status'], 'statusCategory': r['category'], 'labels': ['residual'], 'fixVersions': ['v1.1.4']}
    pathlib.Path(mirror, fields['key'] + '.md').write_text('---\n' + ''.join(k + ': ' + json.dumps(v) + '\n' for k, v in fields.items()) + '---\n')
# Jira applies the category predicate; retain name-terminal rows to test the local filter too.
pathlib.Path(live, 'v1.1.4.tsv').write_text(''.join('HIMMEL-%d\tTask\t%s\ttitle\tresidual\n' % (i, r['status']) for i, r in enumerate(rows, 1) if r['category'] == 'To Do' or r['open']))
PYTEST
run_vc
check "5505 shared status fixture: exit 0" "$RC" "0"
contains "5505 shared status fixture: unknown stays open, all terminal variants excluded" "$OUT" "open live=4 mirror=4 residual-regex live=4 mirror=4 SAME"
contains "5505 live query applies the category rule" "$(cat "$LIVE_DIR/calls.log")" "statusCategory"
contains "5505 live query excludes Fix statuses" "$(cat "$LIVE_DIR/calls.log")" '"Wont Fix"'
contains "5505 live query excludes curly-apostrophe Fix" "$(cat "$LIVE_DIR/calls.log")" "\"Won’t Fix\""
contains "live query excludes In Public" "$(cat "$LIVE_DIR/calls.log")" '"In Public"'

new_case four_residuals
mirror_issue HIMMEL-1 "To Do" '["residual"]' '["v1.1.4"]'
mirror_issue HIMMEL-2 "Wont Fix" '["residual"]' '["v1.1.4"]'
mirror_issue HIMMEL-3 "Won't Fix" '["residual"]' '["v1.1.4"]'
mirror_issue HIMMEL-4 "Resolved" '["residual"]' '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "To Do" residual
run_vc
check "four reported residuals: exit 0" "$RC" "0"
contains "four reported residuals: only To Do is open" "$OUT" "open live=1 mirror=1 residual-regex live=1 mirror=1 SAME"

new_case multi
printf 'v1.0.0\ttrue\t2026-09-01\tfalse\nv1.1.4\tfalse\nv1.1.5\tfalse\n' > "$CASE/HIMMEL.versions.tsv"
mirror_issue HIMMEL-1 "To Do" '[]' '["v1.1.4","v1.1.5","v1.0.0"]'
live_row v1.1.4 HIMMEL-1 "To Do" ""
live_row v1.1.5 HIMMEL-1 "To Do" ""
run_vc
check "two fixVersions: exit 0" "$RC" "0"
contains "two fixVersions: v1.1.4" "$OUT" "v1.1.4 open live=1"
contains "two fixVersions: v1.1.5" "$OUT" "v1.1.5 open live=1"
if grep -q 'v1.0.0' <<< "$OUT"; then bad "released version is not listed" "$OUT"; else ok "released version is not listed"; fi

rm -f "$LIVE_DIR/calls.log"
run_vc v1.1.5
check "version arg: exit 0" "$RC" "0"
if grep -q 'v1.1.4' <<< "$OUT"; then bad "version arg: only v1.1.5 listed" "$OUT"; else ok "version arg: only v1.1.5 listed"; fi
check "version arg: one jira call" "$(wc -l < "$LIVE_DIR/calls.log" | tr -d ' ')" "1"

contains "jira call names --labels" "$(cat "$LIVE_DIR/calls.log")" "--labels"
contains "jira call excludes closed statuses" "$(cat "$LIVE_DIR/calls.log")" "status NOT IN"

new_case jirafail
mirror_issue HIMMEL-1 "To Do" '[]' '["v1.1.4"]'
STUB_FAIL=1 run_vc
check "jira failure: exit 2" "$RC" "2"
if grep -q 'VERDICT' <<< "$OUT"; then bad "jira failure: no verdict" "$OUT"; else ok "jira failure: no verdict"; fi

new_case jiragarbage
mirror_issue HIMMEL-1 "To Do" '[]' '["v1.1.4"]'
printf 'jira: unexpected response\n' > "$LIVE_DIR/v1.1.4.tsv"
run_vc
check "unparseable jira output: exit 2" "$RC" "2"
if grep -q 'VERDICT' <<< "$OUT"; then bad "unparseable jira output: no verdict" "$OUT"; else ok "unparseable jira output: no verdict"; fi

new_case nostatus
printf -- '---\nkey: "HIMMEL-1"\nfixVersions: ["v1.1.4"]\n---\n' > "$M/HIMMEL-1.md"
run_vc
check "mirror file without status: exit 2" "$RC" "2"

new_case nofixversions
printf -- '---\nkey: "HIMMEL-1"\nstatus: "To Do"\n---\n' > "$M/HIMMEL-1.md"
run_vc
check "mirror file without fixVersions: exit 2" "$RC" "2"

new_case emptystatus
mirror_issue HIMMEL-1 "" '[]' '["v1.1.4"]'
run_vc
check "empty mirror status stays unread, not zero: exit 2" "$RC" "2"

new_case emptylivestatus
mirror_issue HIMMEL-1 "To Do" '[]' '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "" residual
run_vc
check "empty live status stays unread, not zero: exit 2" "$RC" "2"
if grep -q 'VERDICT' <<< "$OUT"; then bad "empty live status: no verdict" "$OUT"; else ok "empty live status: no verdict"; fi

new_case longfront
labels_json="[$(seq 1 400 | sed 's/.*/"label-number-&"/' | paste -sd, -)]"
mirror_issue HIMMEL-1 "To Do" "$labels_json" '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "To Do" ""
run_vc
check "fixVersions past 3000 chars of frontmatter: exit 0" "$RC" "0"
contains "fixVersions past 3000 chars of frontmatter: counted" "$OUT" "v1.1.4 open live=1 mirror=1"

new_case badjson
mirror_issue HIMMEL-1 "To Do" '[]' '["v1.1.4"'
run_vc
check "malformed fixVersions value: exit 2" "$RC" "2"

new_case badlabels
mirror_issue HIMMEL-1 "To Do" '"residual"' '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "To Do" ""
run_vc
check "labels that are not a list: exit 2" "$RC" "2"

new_case limit
mirror_issue HIMMEL-1 "To Do" '[]' '["v1.1.4"]'
for n in $(seq 1 5000); do live_row v1.1.4 "HIMMEL-$n" "To Do" ""; done
run_vc
check "live list at the row limit: exit 2" "$RC" "2"
if grep -q 'VERDICT' <<< "$OUT"; then bad "live list at the row limit: no verdict" "$OUT"; else ok "live list at the row limit: no verdict"; fi

new_case nomirror
rm -rf "$M"
run_vc
check "missing mirror dir: exit 2" "$RC" "2"

new_case noversions
rm -f "$CASE/HIMMEL.versions.tsv"
run_vc
check "missing versions file: exit 2" "$RC" "2"

new_case badarg
run_vc --nope
check "unknown option: exit 2" "$RC" "2"

new_case surf
mirror_issue HIMMEL-1 "To Do" '["residual"]' '["v1.1.4"]'
mirror_issue HIMMEL-2 "In Progress" '["residual-depth-1"]' '["v1.1.4"]'
mirror_issue HIMMEL-3 "To Do" '["backlog"]' '["v1.1.4"]'
mirror_issue HIMMEL-4 "Done" '["residual"]' '["v1.1.4"]'
printf '{"milestones":[{"version":"v1.1.4","done":1,"total":4,"open":3,"residual":2,"open_blockers":[]}]}\n' > "$CASE/board-same.json"
printf '{"milestones":[{"version":"v1.1.4","done":1,"total":4,"open":4,"residual":2,"open_blockers":[]}]}\n' > "$CASE/board-diff.json"
printf '{"milestones":[{"version":"v1.1.4","unavailable":true}]}\n' > "$CASE/board-unavail.json"
printf '<details class="krel" data-v="v1.1.4" data-open="3" data-residual="2"><summary>x</summary></details>\n' > "$CASE/tracker-same.html"
printf '<details class="krel" data-v="v1.1.4" data-open="3" data-residual="1"><summary>x</summary></details>\n' > "$CASE/tracker-diff.html"
run_vc --board-json "$CASE/board-same.json" --tracker-html "$CASE/tracker-same.html"
check "surfaces match the tick: exit 0" "$RC" "0"
contains "surfaces match the tick: one line with all three" "$OUT" "v1.1.4 surfaces tick open=3 residual=2 board open=3 residual=2 tracker open=3 residual=2 SAME"
contains "surfaces match the tick: verdict" "$OUT" "VERDICT SAME"
run_vc --board-json "$CASE/board-diff.json" --tracker-html "$CASE/tracker-same.html"
check "board open differs from the tick: exit 1" "$RC" "1"
contains "board open differs from the tick: line DIFF" "$OUT" "board open=4 residual=2 tracker open=3 residual=2 DIFF"
contains "board open differs from the tick: verdict DIFF" "$OUT" "VERDICT DIFF"
run_vc --board-json "$CASE/board-same.json" --tracker-html "$CASE/tracker-diff.html"
check "tracker residual differs from the tick: exit 1" "$RC" "1"
run_vc --tracker-html "$CASE/tracker-same.html"
check "tracker alone matching the tick: exit 0" "$RC" "0"
contains "a surface not given prints a dash" "$OUT" "board - tracker open=3 residual=2 SAME"
run_vc --board-json "$CASE/board-unavail.json"
check "an unavailable board milestone: exit 2" "$RC" "2"
run_vc --board-json "$CASE/missing.json"
check "an unreadable board json: exit 2" "$RC" "2"
printf '{"milestones":[null]}\n' > "$CASE/board-null.json"
printf '{"milestones":[{"version":"v1.1.4","open":3.5,"residual":2}]}\n' > "$CASE/board-frac.json"
run_vc --board-json "$CASE/board-null.json"
check "a null board milestone: exit 2" "$RC" "2"
run_vc --board-json "$CASE/board-frac.json"
check "a fractional board count: exit 2" "$RC" "2"
run_vc --tracker-html "$CASE/tracker-same.html" v1.1.9
check "a tracker that shows none of the versions: exit 2" "$RC" "2"

new_case nokey
OUT="$(env -u JIRA_PROJECT_KEY VERSION_COUNTS_MIRROR="$M" VERSION_COUNTS_JIRA="$W/bin/jira-stub" LIVE_DIR="$LIVE_DIR" bash "$VC" 2>/dev/null)"
check "no JIRA_PROJECT_KEY: exit 2" "$?" "2"

echo "test-version-counts-check: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
