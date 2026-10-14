#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # SC2016: the case-12 stubs are written with literal $ for the stub to expand; SC2015: A && B || C is intentional in check()/the final line, as in test-append-results.sh
# scripts/handover/console-kit/test-wrap-merged.sh - suite for wrap-merged.sh
# (HIMMEL-5594), the one-call MERGED + WRAPPED for a leg. Hermetic: gh, git,
# close-wrapped-leg.sh, board.mjs and the Jira CLI are stubs (the WM_* seams);
# fleet-manifest.sh and append-results.sh are real, against temp files.
#
# Cases:
#   1. usage: missing --doc / --fleet / leg doc            -> rc 2
#   2. happy path: PR read from the leg doc, bullet carries mergeCommit.oid's
#      first 8 chars (NOT the head oid the leg reported), close + pull + board
#      each called once, ticket status read, Jira never transitioned -> rc 0
#   3. --pr overrides the doc's PR
#   4. PR not MERGED                                       -> rc 3, nothing else ran
#   5. close refusal (rc 4) propagates, names the step; no pull, no bullet
#   6. re-run after success: no duplicate bullet, close not run again, rc 0
#   7. pull failure                                        -> rc 5, no bullet
#   8. no PR in the doc and no --pr                        -> rc 2
#   9. unreadable manifest                                 -> rc 1, no close, no bullet
#  10. relative / symlinked-dir leg path resolves to the manifest's absolute form
#  11. leg not in the manifest and not WRAPPED             -> rc 4, no pull, no bullet
#  12. checkout path with a space: default close/board commands still run
#
# Platform guard: Linux bash 3.2+ (fleet-manifest.sh needs flock + jq).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/wrap-merged.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/wm-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
W="$(cd "$W" && pwd)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] does not contain [$3]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: [$2] contains [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

HEAD_OID="1111111111111111111111111111111111111111"
MERGE_OID="abcdef0123456789abcdef0123456789abcdef01"

# --- stubs (each appends its argv to a call log) --------------------------
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$WM_CALLS"
if [ "$WM_PR_STATE" = MERGED ]; then
    printf '{"state":"MERGED","headRefOid":"%s","mergeCommit":{"oid":"%s"}}\n' "$WM_HEAD_OID" "$WM_MERGE_OID"
else
    printf '{"state":"%s","headRefOid":"%s","mergeCommit":null}\n' "$WM_PR_STATE" "$WM_HEAD_OID"
fi
EOF
cat > "$W/bin/close" <<'EOF'
#!/usr/bin/env bash
echo "close $*" >> "$WM_CALLS"
exit "${WM_CLOSE_RC:-0}"
EOF
cat > "$W/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$WM_CALLS"
exit "${WM_PULL_RC:-0}"
EOF
cat > "$W/bin/board" <<'EOF'
#!/usr/bin/env bash
echo "board $*" >> "$WM_CALLS"
EOF
cat > "$W/bin/jira" <<'EOF'
#!/usr/bin/env bash
echo "jira $*" >> "$WM_CALLS"
printf 'HIMMEL-5594\tTask\tIn Review\ttitle\n'
EOF
chmod +x "$W"/bin/*

export WM_GH="$W/bin/gh" WM_CLOSE="$W/bin/close" WM_GIT="$W/bin/git" WM_BOARD="$W/bin/board" WM_JIRA="$W/bin/jira"
export WM_PRIMARY="$W/primary" WM_CALLS="$W/calls" WM_HEAD_OID="$HEAD_OID" WM_MERGE_OID="$MERGE_OID"
mkdir -p "$W/primary"

# fresh fixture: console doc, manifest with the leg, leg doc naming PR 777
fixture() {
    : > "$WM_CALLS"
    CONSOLE="$W/2026-roadmap-console.md"
    MANIFEST="$W/2026-roadmap-console.fleet.json"
    LEG="$W/HIMMEL-5594-N2034-wrap-merged-2026-10-14.md"
    rm -f "$MANIFEST" "$MANIFEST.lock"
    printf '# console\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE console\n' > "$CONSOLE"
    printf '# leg\nRETASK token x\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE x\n- 10:30 READY 777 %s GREEN\n- 10:40 WRAPPED\n' "$HEAD_OID" > "$LEG"
    bash "$HERE/fleet-manifest.sh" add "$MANIFEST" "$LEG" >/dev/null || { echo "FAIL: fixture manifest add" >&2; exit 1; }
    export WM_PR_STATE=MERGED WM_CLOSE_RC=0 WM_PULL_RC=0
}
run() { rc=0; out="$(bash "$SCRIPT" "$@" 2>&1)" || rc=$?; calls="$(cat "$WM_CALLS")"; }

# --- 1. usage -------------------------------------------------------------
fixture
run --fleet "$MANIFEST" "$LEG";                     check "1: no --doc -> rc 2" "$rc" 2
run --doc "$CONSOLE" "$LEG";                        check "1: no --fleet -> rc 2" "$rc" 2
run --doc "$CONSOLE" --fleet "$MANIFEST";           check "1: no leg doc -> rc 2" "$rc" 2

# --- 2. happy path --------------------------------------------------------
fixture
run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "2: rc 0" "$rc" 0
contains "2: gh asked about PR 777" "$calls" "pr view 777"
contains "2: close called with --fleet and the leg doc" "$calls" "close --fleet $MANIFEST $LEG"
contains "2: primary fast-forwarded" "$calls" "git -C $WM_PRIMARY pull --ff-only"
contains "2: board re-rendered with --changed" "$calls" "board --doc $CONSOLE --changed"
check "2: close, pull and board each ran exactly once" "$(grep -c -e '^close ' -e '^git ' -e '^board ' "$WM_CALLS")" 3
bullet="$(tail -n 1 "$CONSOLE")"
contains "2: bullet records mergeCommit.oid[0:8]" "$bullet" "MERGED #777 → abcdef01"
lacks "2: bullet never carries the head oid" "$bullet" "11111111"
contains "2: bullet names label + ticket status" "$bullet" "N2034"
contains "2: bullet names ticket status" "$bullet" "HIMMEL-5594 In Review"
contains "2: bullet says window closed" "$bullet" "WRAPPED, window closed."
lacks "2: bullet has no >" "$bullet" ">"
lacks "2: Jira never transitioned" "$calls" "jira transition"

# --- 3. --pr overrides ----------------------------------------------------
fixture
run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG" --pr 888
contains "3: gh asked about PR 888" "$calls" "pr view 888"
contains "3: bullet names #888" "$(tail -n 1 "$CONSOLE")" "MERGED #888"

# --- 4. not merged --------------------------------------------------------
fixture
WM_PR_STATE=OPEN run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "4: rc 3" "$rc" 3
contains "4: names the step" "$out" "pr-state"
lacks "4: close not called" "$calls" "close "
check "4: console doc unchanged" "$(tail -n 1 "$CONSOLE")" "- 10:00 LIVE console"

# --- 5. close refusal propagates -----------------------------------------
fixture
WM_CLOSE_RC=4 run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "5: close rc 4 propagates" "$rc" 4
contains "5: names the step" "$out" "close-wrapped-leg"
lacks "5: no pull" "$calls" "pull"
check "5: no bullet" "$(tail -n 1 "$CONSOLE")" "- 10:00 LIVE console"

# --- 6. re-run is idempotent ---------------------------------------------
fixture
run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
# the real close removes the leg from the manifest; the stub does not
bash "$HERE/fleet-manifest.sh" remove "$MANIFEST" "$LEG" >/dev/null 2>&1 || { echo "FAIL: fixture manifest remove" >&2; exit 1; }
: > "$WM_CALLS"
run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "6: re-run rc 0" "$rc" 0
check "6: exactly one MERGED bullet" "$(grep -c 'MERGED #777' "$CONSOLE")" 1
lacks "6: close not run again" "$calls" "close "

# --- 7. pull failure ------------------------------------------------------
fixture
WM_PULL_RC=1 run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "7: rc 5" "$rc" 5
contains "7: names the step" "$out" "pull"
check "7: no bullet" "$(tail -n 1 "$CONSOLE")" "- 10:00 LIVE console"

# --- 9. unreadable manifest is a failure, not an absent leg ---------------
fixture
printf 'not json' > "$MANIFEST"
run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "9: rc 1" "$rc" 1
contains "9: names the step" "$out" "manifest"
lacks "9: close not called" "$calls" "close "
check "9: no bullet" "$(tail -n 1 "$CONSOLE")" "- 10:00 LIVE console"

# --- 8. no PR anywhere ----------------------------------------------------
fixture
printf '# leg\n\n## Results\n\n- 10:00 LIVE x\n' > "$LEG"
run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "8: rc 2" "$rc" 2
contains "8: says no PR" "$out" "no PR"

# --- 10. relative / symlinked-dir leg path still matches the manifest -----
fixture
cd "$W" || exit 1
run --doc "$CONSOLE" --fleet "$MANIFEST" "${LEG##*/}"
cd "$HERE" || exit 1
check "10: relative leg path rc 0" "$rc" 0
contains "10: close ran for the absolute path" "$calls" "close --fleet $MANIFEST $LEG"
fixture
ln -s "$W" "$W/dirlink"
run --doc "$CONSOLE" --fleet "$MANIFEST" "$W/dirlink/${LEG##*/}"
contains "10: symlinked dir resolves, close ran" "$calls" "close --fleet $MANIFEST $LEG"
rm -f "$W/dirlink"

# --- 11. not in the manifest and not WRAPPED is a refusal, not a skip ------
fixture
printf '# leg\n\n## Results\n\n- 10:00 LIVE x\n- 10:30 READY 777 %s GREEN\n' "$HEAD_OID" > "$LEG"
bash "$HERE/fleet-manifest.sh" remove "$MANIFEST" "$LEG" >/dev/null 2>&1 || { echo "FAIL: fixture manifest remove" >&2; exit 1; }
run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "11: rc 4" "$rc" 4
lacks "11: no pull" "$calls" "pull"
check "11: no bullet" "$(tail -n 1 "$CONSOLE")" "- 10:00 LIVE console"
printf -- '- 10:40 WRAPPED_PENDING not yet\n' >> "$LEG"
run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "11: WRAPPED_PENDING is not WRAPPED -> rc 4" "$rc" 4

# --- 12. a checkout path with a space keeps the default commands intact ----
fixture
SP="$W/sp ace"
mkdir -p "$SP/scripts/handover" "$SP/scripts/lib"
cp -R "$HERE" "$SP/scripts/handover/console-kit"
cp -R "$HERE/../../lib/." "$SP/scripts/lib/"
printf '#!/usr/bin/env bash\necho "close $*" >> "$WM_CALLS"\n' > "$SP/scripts/handover/console-kit/close-wrapped-leg.sh"
printf 'import { appendFileSync } from "node:fs"\nappendFileSync(process.env.WM_CALLS, "board " + process.argv.slice(2).join(" ") + "\\n")\n' > "$SP/scripts/handover/console-kit/board.mjs"
rc=0; out="$(env -u WM_CLOSE -u WM_BOARD -u WM_JIRA bash "$SP/scripts/handover/console-kit/wrap-merged.sh" --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG" 2>&1)" || rc=$?
calls="$(cat "$WM_CALLS")"
check "12: space-path default commands rc 0" "$rc" 0
contains "12: default close ran" "$calls" "close --fleet $MANIFEST $LEG"
contains "12: default board ran" "$calls" "board --doc $CONSOLE --changed"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails FAILED"; exit 1; }
