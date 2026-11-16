#!/usr/bin/env bash
# scripts/handover/chief-kit/test-version-counts-check.sh - suite: version-counts-check.sh,
# the read-only side-by-side of live Jira and Jira-mirror per-version open and residual counts.
# The jira CLI is a stub behind VERSION_COUNTS_JIRA; the mirror is a fixture dir. No network.
#
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

# Stub jira CLI: `list ... --jql <jql>` prints $LIVE_DIR/<version>.tsv for the fixVersion named in the jql.
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
# mirror_issue <key> <status> <labels-json> <fixVersions-json>
mirror_issue() {
    printf -- '---\nkey: "%s"\nstatus: "%s"\nstatusCategory: "To Do"\nlabels: %s\nfixVersions: %s\nupdated: "2026-11-16T09:00:00.000+0100"\n---\n\n# %s\n' \
        "$1" "$2" "$3" "$4" "$1" > "$M/$1.md"
}
# live_row <version> <key> <status> <labels-csv>
live_row() { printf '%s\tTask\t%s\ttitle\t%s\n' "$2" "$3" "$4" >> "$LIVE_DIR/$1.tsv"; }
run_vc() {
    OUT="$(JIRA_PROJECT_KEY=HIMMEL VERSION_COUNTS_MIRROR="$M" VERSION_COUNTS_JIRA="$W/bin/jira-stub" LIVE_DIR="$LIVE_DIR" bash "$VC" "$@" 2>"$CASE/err")"
    RC=$?
}

# 1. SAME: a residual variant label counts, a non-residual label does not.
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

# 2. DIFF open: the mirror still holds a ticket live Jira closed.
new_case stale
mirror_issue HIMMEL-1 "To Do" '[]' '["v1.1.4"]'
mirror_issue HIMMEL-2 "To Do" '[]' '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "To Do" ""
run_vc
check "DIFF open: exit 1" "$RC" "1"
contains "DIFF open: counts printed side by side" "$OUT" "v1.1.4 open live=1 mirror=2 residual-regex live=0 mirror=0 DIFF"
contains "DIFF open: final verdict" "$OUT" "VERDICT DIFF"

# 3. Residual differing with open equal is shown but never moves the verdict (open is the version size).
new_case residual
mirror_issue HIMMEL-1 "To Do" '["residual"]' '["v1.1.4"]'
live_row v1.1.4 HIMMEL-1 "To Do" backlog
run_vc
check "residual-only difference: exit 0" "$RC" "0"
contains "residual-only difference: both residual columns shown, verdict SAME" "$OUT" "v1.1.4 open live=1 mirror=1 residual-regex live=0 mirror=1 SAME"

# 4. Closed statuses are not open on either side, both Wont Do spellings included.
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

# 5. A ticket under two fixVersions counts in each; a released version is skipped.
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

# 6. Version arguments restrict the listing and the jira calls.
rm -f "$LIVE_DIR/calls.log"
run_vc v1.1.5
check "version arg: exit 0" "$RC" "0"
if grep -q 'v1.1.4' <<< "$OUT"; then bad "version arg: only v1.1.5 listed" "$OUT"; else ok "version arg: only v1.1.5 listed"; fi
check "version arg: one jira call" "$(wc -l < "$LIVE_DIR/calls.log" | tr -d ' ')" "1"

# 7. The live read carries the closed-status exclusion and the labels flag.
contains "jira call names --labels" "$(cat "$LIVE_DIR/calls.log")" "--labels"
contains "jira call excludes closed statuses" "$(cat "$LIVE_DIR/calls.log")" "status NOT IN"

# 8. Bad input and unreadable sources exit 2, with no verdict line.
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

new_case nokey
OUT="$(env -u JIRA_PROJECT_KEY VERSION_COUNTS_MIRROR="$M" VERSION_COUNTS_JIRA="$W/bin/jira-stub" LIVE_DIR="$LIVE_DIR" bash "$VC" 2>/dev/null)"
check "no JIRA_PROJECT_KEY: exit 2" "$?" "2"

echo "test-version-counts-check: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
