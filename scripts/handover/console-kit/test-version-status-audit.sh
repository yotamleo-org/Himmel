#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is intentional in the pass/fail lines; the gh stub body is deliberately single-quoted
# test-version-status-audit.sh — Exercises version-status-audit.sh on a fixture
# Jira mirror, a fixture fleet manifest + leg doc and a stubbed gh
# (VSA_GH_CMD): no real mirror, Jira or gh is touched. VSA overrides the script
# under test (the RED control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-version-status-audit.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${VSA:-$HERE/version-status-audit.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { # <name> <haystack> <needle>
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac
}
lacks() { # <name> <haystack> <needle>
    case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vsa-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
M="$WORK/jira-mirror/HIMMEL"; mkdir -p "$M"

mk() { # <key> <type> <status> <statusCategory> <fixVersions json>
    printf -- '---\nkey: "%s"\ntype: "%s"\nstatus: "%s"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: %s\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: fixture\n' \
        "$1" "$2" "$3" "$4" "$5" "$1" > "$M/$1.md"
}
printf 'v1.0.0\ttrue\t2026-01-01\tfalse\nv1.0.1\tfalse\t\tfalse\nv1.0.2\tfalse\t\tfalse\nv0.9.9\tfalse\t\ttrue\nzz-throwaway\tfalse\t\ttrue\n' > "$WORK/jira-mirror/HIMMEL.versions.tsv"

mk HIMMEL-1 Task "In Progress" "In Progress" '["v1.0.2"]'
mk HIMMEL-2 Task "To Do" "To Do" '["v1.0.0"]'
mk HIMMEL-3 Bug "IN CI" "In Progress" '[]'
mk HIMMEL-4 Epic "In Progress" "In Progress" '[]'
mk HIMMEL-5 Task "Done" "Done" '["v1.0.0"]'
mk HIMMEL-6 Task "In Progress" "In Progress" '["v1.0.1"]'
mk HIMMEL-7 Task "In Review" "In Progress" '["v1.0.2"]'
mk HIMMEL-8 Task "To Do" "To Do" '["v1.0.2"]'
mk HIMMEL-9 Task "Closed" "Done" '["v1.0.0"]'
mk HIMMEL-10 Task "In Progress" "In Progress" '["v1.0.2"]'

mkdir -p "$WORK/legs"
printf '# leg\n\n## Results\n- 10:00 LIVE — up\n' > "$WORK/legs/HIMMEL-7-N1-x.md"
printf '{"legs":[{"label":"N1","doc":"%s"}]}\n' "$WORK/legs/HIMMEL-7-N1-x.md" > "$WORK/fleet.json"
printf '#!/usr/bin/env bash\nif [ -f "$GH_FAIL" ]; then exit 1; fi\nprintf "9999\\tfeat: [HIMMEL-1] x\\tfeat/himmel-1-x\\n"\n' > "$WORK/gh"
chmod +x "$WORK/gh"

run() { VSA_GH_CMD="$WORK/gh" GH_FAIL="$WORK/nofail" bash "$SUT" --mirror "$M" "$@" 2>&1; }

out="$(run --legs-from "$WORK/fleet.json")"; rc=$?
has "later-version started ticket without an owner is a RESET row" "$out" "LATER-VERSION	HIMMEL-10	In Progress	v1.0.2	none	RESET"
has "released-version open ticket yields a row" "$out" "RELEASED-NOT-DONE	HIMMEL-2	To Do	v1.0.0	none	RESET"
has "versionless started Bug yields a row" "$out" "NO-VERSION	HIMMEL-3	IN CI	-	none	RESET"
lacks "an Epic with no version yields no row" "$out" "HIMMEL-4	"
lacks "a Done row yields no row" "$out" "HIMMEL-5	"
lacks "a Closed row in a released version yields no row" "$out" "HIMMEL-9	"
lacks "a To Do row in a later version yields no row" "$out" "HIMMEL-8	"
lacks "a started row in the earliest unreleased version yields no row" "$out" "HIMMEL-6	"
has "later-version ticket owned by an open PR is OWNED" "$out" "HIMMEL-1	In Progress	v1.0.2	PR:9999	OWNED"
has "later-version ticket owned by a live leg is OWNED" "$out" "HIMMEL-7	In Review	v1.0.2	leg:N1	OWNED"
has "count line counts every row" "$out" "vmismatch=5"
[ "$rc" = 1 ] && pass "exit 1 when a RESET row exists" || fail "exit 1 when a RESET row exists (rc=$rc)"

# clean mirror
C="$WORK/clean/HIMMEL"; mkdir -p "$C"; cp "$WORK/jira-mirror/HIMMEL.versions.tsv" "$WORK/clean/HIMMEL.versions.tsv"
cp "$M/HIMMEL-5.md" "$M/HIMMEL-4.md" "$M/HIMMEL-8.md" "$M/HIMMEL-6.md" "$C/"
out="$(VSA_GH_CMD="$WORK/gh" GH_FAIL="$WORK/nofail" bash "$SUT" --mirror "$C" 2>&1)"; rc=$?
has "clean mirror prints vmismatch=0" "$out" "vmismatch=0"
[ "$rc" = 0 ] && pass "clean mirror exits 0" || fail "clean mirror exits 0 (rc=$rc)"

# gh failure must not hide rows as owned or clean
: > "$WORK/gh-fail"
out="$(VSA_GH_CMD="$WORK/gh" GH_FAIL="$WORK/gh-fail" bash "$SUT" --mirror "$M" 2>&1)"
has "unreadable open-PR set is reported" "$out" "open PRs unknown"
has "rows still print when gh fails" "$out" "HIMMEL-10"

printf '%s fail(s)\n' "$fails"
[ "$fails" = 0 ]
