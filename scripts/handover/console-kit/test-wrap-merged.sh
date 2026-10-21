#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # SC2016: the case-12 stubs are written with literal $ for the stub to expand; SC2015: A && B || C is intentional in check()/the final line, as in test-append-results.sh
# scripts/handover/console-kit/test-wrap-merged.sh - suite for wrap-merged.sh
# the one-call MERGED + WRAPPED for a leg. Hermetic: gh, git,
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
#   6. re-run (close reports 0 sessions): close asked again, entry retired, no duplicate bullet, rc 0
#   7. pull failure                                        -> rc 5, no bullet
#   8. no PR in the doc and no --pr                        -> rc 2
#   9. manifest failure (inside close, or retiring an entry) -> rc 1, no pull, no bullet
#  10. relative / symlinked-dir leg path resolves to the manifest's absolute form
#  11. WRAPPED, absent from the manifest, window alive     -> close still asked; its
#      refusal (rc 6, or 2 sessions rc 5) propagates, no pull, no bullet
#  12. checkout path with a space: default close/board commands still run
#  13. board failure -> rc 7;  14. append failure -> rc 6, board not run
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
[ -z "${WM_CLOSE_ERR:-}" ] || echo "$WM_CLOSE_ERR" >&2
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
exit "${WM_BOARD_RC:-0}"
EOF
cat > "$W/bin/jira" <<'EOF'
#!/usr/bin/env bash
echo "jira $*" >> "$WM_CALLS"
[ "$1" != versions ] || { printf 'v1.0.1\tfalse\t2026-12-01\n'; exit 0; }
[ "$1" != mirror ] || exit "${WM_MIRROR_RC:-0}"
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
    export WM_PR_STATE=MERGED WM_CLOSE_RC=0 WM_PULL_RC=0 WM_BOARD_RC=0 WM_CLOSE_ERR=""
}
NO_SESSION='close-wrapped-leg: refusing - 0 live session(s) matched leg names [x] (need exactly 1)'
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
: > "$WM_CALLS"
# second run: the window is gone, so close reports 0 sessions (the stub left the entry in the manifest)
WM_CLOSE_RC=5 WM_CLOSE_ERR="$NO_SESSION" run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "6: re-run rc 0" "$rc" 0
check "6: exactly one MERGED bullet" "$(grep -c 'MERGED #777' "$CONSOLE")" 1
contains "6: close asked again, never skipped" "$calls" "close --fleet $MANIFEST $LEG"
check "6: the stale manifest entry is retired" "$(bash "$HERE/fleet-manifest.sh" list "$MANIFEST")" ""

# --- 7. pull failure ------------------------------------------------------
fixture
WM_PULL_RC=1 run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "7: rc 5" "$rc" 5
contains "7: names the step" "$out" "pull"
check "7: no bullet" "$(tail -n 1 "$CONSOLE")" "- 10:00 LIVE console"

# --- 9. a manifest failure inside close is a failure ----------------------
fixture
WM_CLOSE_RC=1 WM_CLOSE_ERR='close-wrapped-leg: session closed but fleet manifest update failed' run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "9: rc 1" "$rc" 1
contains "9: names the step" "$out" "close-wrapped-leg"
lacks "9: no pull" "$calls" "pull"
check "9: no bullet" "$(tail -n 1 "$CONSOLE")" "- 10:00 LIVE console"
# 0 sessions but the manifest entry cannot be retired: rc 1, no pull, no bullet
fixture
printf 'not json' > "$MANIFEST"
WM_CLOSE_RC=5 WM_CLOSE_ERR="$NO_SESSION" run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "9: manifest remove failure rc 1" "$rc" 1
contains "9: names the manual step" "$out" "fleet-manifest.sh remove"
lacks "9: no pull" "$calls" "pull"
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

# --- 11. WRAPPED but absent from the manifest with the window alive ---------
# (a symlinked root, a // path or a leg added without --fleet): the manifest is
# no proof, so close still runs, and its refusal stops the run.
fixture
bash "$HERE/fleet-manifest.sh" remove "$MANIFEST" "$LEG" >/dev/null 2>&1 || { echo "FAIL: fixture manifest remove" >&2; exit 1; }
WM_CLOSE_RC=6 WM_CLOSE_ERR='close-wrapped-leg: refusing - subtree alive' run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "11: rc 6 propagates" "$rc" 6
contains "11: close was asked" "$calls" "close --fleet $MANIFEST $LEG"
lacks "11: no pull" "$calls" "pull"
check "11: no bullet" "$(tail -n 1 "$CONSOLE")" "- 10:00 LIVE console"
lacks "11: never says window closed" "$out" "window already closed"
# more than one session matched: also a refusal, not an already-closed
WM_CLOSE_RC=5 WM_CLOSE_ERR='close-wrapped-leg: refusing - 2 live session(s) matched' run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "11: 2 sessions rc 5" "$rc" 5
lacks "11: 2 sessions: no pull" "$calls" "pull"
check "11: 2 sessions: no bullet" "$(tail -n 1 "$CONSOLE")" "- 10:00 LIVE console"

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

# --- 13. board failure -> rc 7, the bullet is already written ---------------
fixture
WM_BOARD_RC=1 run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
check "13: rc 7" "$rc" 7
contains "13: names the step" "$out" "board"
contains "13: bullet was written first" "$(tail -n 1 "$CONSOLE")" "MERGED #777"

# --- 14. append failure -> rc 6, board not run ------------------------------
fixture
chmod 444 "$CONSOLE"
run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
chmod 644 "$CONSOLE"
check "14: rc 6" "$rc" 6
contains "14: names the step" "$out" "append-results"
lacks "14: board not run" "$calls" "board "

# --- 15-18. tracker refresh ------------------------------------
# On MERGED the wrap re-mirrors Jira, snapshots the versions and re-renders the
# roadmap tracker the console doc names, prints tracker=CHANGED|UNCHANGED|failed:<why>
# and never fails the wrap. RED on main: no tracker step, so the page stays stale.
if command -v python3 >/dev/null 2>&1; then
    printf '#!/usr/bin/env bash\nexit 3\n' > "$W/bin/boom"; chmod +x "$W/bin/boom"
    TR="$W/tracker"; TPLAN="$TR/plan"; TMIR="$TR/mirror"
    mkdir -p "$TPLAN/stage1" "$TPLAN/stage3" "$TMIR"
    printf '%s\n' '{"main_sha_at_build":"abcdef123456"}' > "$TPLAN/stage3/meta.json"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
        v1.0.1 0.1 0 0 0 0 0.1 1 > "$TPLAN/stage3/versions.tsv"
    printf '%s\t%s\t%s\t%s\n' key version layer effort_mid HIMMEL-1 v1.0.1 bugs 1 > "$TPLAN/stage3/placement.tsv"
    printf '%s\t%s\t%s\n' key close_flag close_evidence > "$TPLAN/stage3/closures.tsv"
    printf '%s\t%s\n' key reason > "$TPLAN/stage3/unplaced.tsv"
    printf '%s\t%s\n' key theme HIMMEL-1 tooling > "$TPLAN/stage1/C01.tsv"
    printf '%s\n' '---' 'key: "HIMMEL-1"' 'updated: "2026-09-30T11:30:00.000+0000"' 'statusCategory: "Done"' 'fixVersions: ["v1.0.1"]' 'type: "Bug"' '---' '# HIMMEL-1: a planned bug' > "$TMIR/HIMMEL-1.md"
    export TICK_TRACKER_MIRROR_DIR="$TMIR" TRACKER_HANDOVERS_DIR="$TR/luna/handovers/tester/himmel"
    tracker_fixture() {  # tracker_fixture [tracker: value]
        fixture
        printf '# console\n\n## Live state\n\n%s\ntracker-plan: %s\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE console\n' \
            "${1:+tracker: $1}" "$TPLAN" > "$CONSOLE"
    }
    fp_now() { python3 "$HERE/tracker.py" --emit-fp --plan-dir "$TPLAN" --out "$W/roadmap-tracker.html" --luna-map "$W/roadmap-luna-map.json" --mirror-dir "$TMIR"; }
    rm -f "$W/roadmap-tracker.html" "$W/roadmap-tracker.html.fp"

    tracker_fixture 'https://claude.ai/artifact/x'
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    check "15: rc 0" "$rc" 0
    contains "15: a stale tracker is re-rendered, tracker=CHANGED" "$out" "tracker=CHANGED"
    check "15: the page's fp now matches what tick derives (tick reads tracker=ok)" "$(fp_now)" "$(cat "$W/roadmap-tracker.html.fp" 2>/dev/null)"
    contains "15: the mirror was refreshed into the mirror dir" "$calls" "jira mirror --root $TMIR"
    contains "15: the versions snapshot was taken" "$calls" "jira versions"
    check "15: versions snapshot written next to the mirror" "v1.0.1	false	2026-12-01" "$(cat "$TMIR.versions.tsv" 2>/dev/null)"

    tracker_fixture 'https://claude.ai/artifact/x'
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    contains "16: a second wrap over an unchanged tracker is tracker=UNCHANGED" "$out" "tracker=UNCHANGED"

    tracker_fixture 'https://claude.ai/artifact/x'
    printf 'tracker-done: https://claude.ai/artifact/d\ntracker-future: https://claude.ai/artifact/f\n' >> "$CONSOLE"
    rm -f "$W/roadmap-tracker-done.html" "$W/roadmap-tracker-future.html"
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    contains "16b: a split tracker with fresh focus fp but no Done and future pages is re-rendered" "$out" "tracker=CHANGED"
    check "16b: the Done page is written beside the focus page" "yes" "$([ -f "$W/roadmap-tracker-done.html" ] && echo yes || echo no)"
    check "16b: the future page is written beside the focus page" "yes" "$([ -f "$W/roadmap-tracker-future.html" ] && echo yes || echo no)"
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    contains "16b: with all three pages current the next wrap is tracker=UNCHANGED" "$out" "tracker=UNCHANGED"

    tracker_fixture 'https://claude.ai/artifact/x'
    WM_TRACKER_PY="$W/bin/boom" run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    check "17: a failing render never fails the wrap (rc 0)" "$rc" 0
    contains "17: and says why" "$out" "tracker=failed:"
    contains "17: the bullet and board still ran" "$calls" "board --doc"

    printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$W/bin/sleeper"; chmod +x "$W/bin/sleeper"
    tracker_fixture 'https://claude.ai/artifact/x'
    WM_TRACKER_PY="$W/bin/sleeper" WM_TRACKER_TIMEOUT=1 run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    check "17b: a hung render never fails the wrap (rc 0)" "$rc" 0
    contains "17b: the render is cut at the timeout" "$out" "tracker=failed:render-rc124"
    contains "17b: the board still ran" "$calls" "board --doc"

    printf '#!/usr/bin/env bash\necho "jira $*" >> "$WM_CALLS"\nexec sleep 30\n' > "$W/bin/jira-hang"; chmod +x "$W/bin/jira-hang"
    tracker_fixture 'https://claude.ai/artifact/x'
    WM_JIRA="$W/bin/jira-hang" WM_TRACKER_TIMEOUT=1 run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    check "17d: a hung mirror never fails the wrap (rc 0)" "$rc" 0
    contains "17d: the mirror is cut at the timeout" "$out" "tracker=failed:mirror-rc124"
    contains "17d: the board still ran" "$calls" "board --doc"

    tracker_fixture 'https://claude.ai/artifact/x'
    WM_MIRROR_RC=1 run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    check "17c: a failing mirror never fails the wrap (rc 0)" "$rc" 0
    contains "17c: and says why" "$out" "tracker=failed:mirror-rc1"
    contains "17c: the board still ran" "$calls" "board --doc"

    tracker_fixture
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    contains "18: a console with no tracker: line prints tracker=skip" "$out" "tracker=skip"
    # 19-23. remaining-only board: the wrap re-renders the open tickets of the console doc's version from the fresh mirror.
    printf '%s\n' '---' 'key: "HIMMEL-2"' 'updated: "2026-09-30T11:30:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Bug"' '---' '# HIMMEL-2: an open ticket' > "$TMIR/HIMMEL-2.md"
    printf '%s\n' '---' 'key: "HIMMEL-3"' 'updated: "2026-09-30T11:30:00.000+0000"' 'statusCategory: "Done"' 'status: "Done"' 'fixVersions: ["v1.1.3"]' 'type: "Bug"' '---' '# HIMMEL-3: a finished ticket' > "$TMIR/HIMMEL-3.md"
    printf '%s\n' '---' 'key: "HIMMEL-40"' 'updated: "2026-09-30T11:30:00.000+0000"' 'statusCategory: "To Do"' 'status: "To Do"' 'fixVersions: ["v1.1.3"]' 'type: "Bug"' '---' '# HIMMEL-40: a grouped ticket' > "$TMIR/HIMMEL-40.md"
    mkdir -p "$W/specs/plans"
    printf '%s\n' '`priority:` line for the console:' '' '40 | 2 | rest of v1.1.3' > "$W/specs/plans/v1.1.3-approved-plan.md"
    printf '%s\n' '`priority:` line for the console:' '' '3 | 40 | x' > "$W/specs/plans/v1.1.4-approved-plan.md"
    printf '%s\n' '`priority:` line for the console:' '' '41 | 2 | rest of v1.1.3' > "$W/specs/plans/v1.1.3-approved-plan-2026-10-01.md"
    remaining_fixture() {  # remaining_fixture [tracker: value]
        tracker_fixture "$@"
        printf 'remaining-board: v1.1.3\n' >> "$CONSOLE"
    }
    rm -f "$W/roadmap-remaining-v1.1.3.md"
    remaining_fixture 'https://claude.ai/artifact/x'
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    contains "19: a wrap renders the remaining board, remaining=CHANGED" "$out" "remaining=CHANGED"
    contains "19: the plan is the one named for the version, not the newest of another" "$(cat "$W/roadmap-remaining-v1.1.3.md" 2>/dev/null)" "## rest of version (2)"
    contains "19: the dated plan wins over the undated one" "$(cat "$W/roadmap-remaining-v1.1.3.md" 2>/dev/null)" $'## rest of version (2)\n- HIMMEL-2 [To Do] an open ticket\n- HIMMEL-40 '
    contains "19: the board lists the open ticket" "$(cat "$W/roadmap-remaining-v1.1.3.md" 2>/dev/null)" "HIMMEL-2 [To Do] an open ticket"
    lacks "19: the board has no Done ticket" "$(cat "$W/roadmap-remaining-v1.1.3.md" 2>/dev/null)" "HIMMEL-3"

    remaining_fixture 'https://claude.ai/artifact/x'
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    contains "20: a second wrap over unchanged tickets is remaining=UNCHANGED" "$out" "remaining=UNCHANGED"

    printf '%s\n' '---' 'key: "HIMMEL-2"' 'updated: "2026-09-30T12:30:00.000+0000"' 'statusCategory: "Done"' 'status: "Done"' 'fixVersions: ["v1.1.3"]' 'type: "Bug"' '---' '# HIMMEL-2: an open ticket' > "$TMIR/HIMMEL-2.md"
    remaining_fixture 'https://claude.ai/artifact/x'
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    contains "21: a ticket that went Done drops off the board, remaining=CHANGED" "$out" "remaining=CHANGED"
    lacks "21: the finished ticket is gone from the file" "$(cat "$W/roadmap-remaining-v1.1.3.md" 2>/dev/null)" "HIMMEL-2"

    remaining_fixture
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    contains "22: no tracker: line means no fresh mirror, remaining=skip:no-fresh-mirror" "$out" "remaining=skip:no-fresh-mirror"

    tracker_fixture 'https://claude.ai/artifact/x'
    run --doc "$CONSOLE" --fleet "$MANIFEST" "$LEG"
    contains "23: no remaining-board: line prints remaining=skip" "$out" "remaining=skip"
    check "23: and the wrap still succeeds (rc 0)" "$rc" 0
    unset TICK_TRACKER_MIRROR_DIR TRACKER_HANDOVERS_DIR
else
    echo "skip - 15-18 tracker rows: no python3"
fi
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails FAILED"; exit 1; }
