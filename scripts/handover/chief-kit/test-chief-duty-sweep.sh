#!/usr/bin/env bash
# test-chief-duty-sweep.sh — chief-duty-sweep.sh prints one DUTY line per owed chief
# action and nothing for a clean fleet: a fixture row per class, a control per class,
# and the two auto-run acts (the masked-CI rerun, the finding-delta judge spec).
#
# Linux-only kit (touch -d).
#
# CHIEF_DUTY_SWEEP overrides the script under test.
# Run: bash scripts/handover/chief-kit/test-chief-duty-sweep.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="${CHIEF_DUTY_SWEEP:-$HERE/chief-duty-sweep.sh}"
OWE="$HERE/owe.sh"
JUDGE="$HERE/gen-judge-brief.py"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in: $3)" ;; esac
}
hasnt() {
    case "$3" in *"$2"*) fail "$1 (found '$2' in: $3)" ;; *) pass "$1" ;; esac
}
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-duty-sweep-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

NOW=1800000000
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H7_1=${H1:0:7}

STUB="$WORK/stub"; mkdir -p "$STUB/bin"
export STUB
# shellcheck disable=SC2016  # the stub body expands when the stub runs
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$STUB/path-gh-calls"\nexit 99\n' > "$STUB/bin/gh"
: > "$STUB/path-gh-calls"
cat > "$STUB/seam-gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/gh-calls"
exit "$(cat "$STUB/gh.rc" 2>/dev/null || echo 0)"
EOF
cat > "$STUB/delta" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/delta-calls"
cat "$STUB/delta.out" 2>/dev/null || echo trust
EOF
chmod +x "$STUB/bin/gh" "$STUB/seam-gh" "$STUB/delta"
export PATH="$STUB/bin:$PATH"

world() {
    rm -rf "$WORK/w"; mkdir -p "$WORK/w/bucket/verdicts" "$WORK/w/go/.locks/go" "$WORK/w/state" "$WORK/w/mirror"
    : > "$STUB/gh-calls"; : > "$STUB/delta-calls"; rm -f "$STUB/gh.rc" "$STUB/delta.out"
    B="$WORK/w/bucket"
    CHIEF="$B/2026-11-25XX-chief.md"
    printf '# chief\n' > "$CHIEF"
    DOC1="$B/HIMMEL-9100-N1-thing-2026-11-25.md"
    set_tail "- 10:00 LIVE — working"
    set_lane t3
    printf '[{"number":101,"headRefName":"feat/himmel-9100-thing","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"}]\n' "$H1" > "$WORK/w/prs.json"
    printf '[{"id":11,"name":"CI","event":"pull_request","status":"completed","conclusion":"success","created_at":"2026-11-25T09:00:00Z","head_sha":"%s","run_attempt":1}]\n' "$H1" > "$WORK/w/runs.json"
    printf '# source mirror_age_min=1\n' > "$WORK/w/dispositions.txt"
}
set_tail() { printf '# HIMMEL-9100 — worker N1\n\n## Results (newest at the bottom)\n%s\n' "$1" > "$DOC1"; }
set_lane() { printf '{"schema":1,"legs":[{"doc":"%s","label":"N1","lane":"%s"}]}\n' "$DOC1" "$1" > "$WORK/w/fleet.json"; }

sweep_env() {
    local rlog="${REFUSALS_AT:-$WORK/w/refusals.jsonl}"
    [ "$rlog" != default ] || rlog=""
    HIMMEL_GUARD_REFUSALS_LOG="$rlog" CHIEF_DUTY_STALL_SECS="${STALL_SECS:-3600}" CHIEF_DUTY_SWEEP_NOW="${SWEEP_AT:-$NOW}" CHIEF_DUTY_SWEEP_PRS="$WORK/w/prs.json" CHIEF_DUTY_SWEEP_RUNS="$WORK/w/runs.json" \
        CHIEF_DUTY_SWEEP_GO_ROOT="$WORK/w/go" CHIEF_DUTY_SWEEP_MIRROR="$WORK/w/mirror" \
        CHIEF_DUTY_SWEEP_DISPOSITIONS="$WORK/w/dispositions.txt" CHIEF_DUTY_SWEEP_GH="$STUB/seam-gh" \
        CHIEF_DUTY_SWEEP_DELTA="$STUB/delta" TICK_STATE_DIR="$WORK/w/state" CANCEL_RUNS_PACE_STATE="$WORK/w/pace" \
        bash "$SWEEP" --doc "$CHIEF" --workers-from "$WORK/w/fleet.json" --bucket "$B"
}
sweep() {
    OUT=$(sweep_env 2>"$WORK/w/err")
    RC=$?
}

world
sweep
check "clean: exit 0" 0 "$RC"
check "clean: prints nothing" "" "$OUT"
check "clean: no gh call at all" "" "$(cat "$STUB/gh-calls" "$STUB/path-gh-calls")"

world; set_tail "- 10:05 READY 101 $H1 GREEN"
sweep
has "go-owed: listed" "DUTY go-owed 101@$H7_1 :: " "$OUT"
has "go-owed: carries a next command" " :: next: " "$OUT"
touch "$WORK/w/go/.locks/go/101.$H1"
sweep
hasnt "go-owed: a GO file clears it" "go-owed" "$OUT"
world; set_tail "- 10:05 READY 101 $H1 GREEN
- 10:20 BLOCKED — needs a ruling"
sweep
hasnt "go-owed: a later BLOCKED supersedes the READY" "go-owed" "$OUT"
world; set_tail "- 10:05 READY 101 $H2 GREEN"
sweep
hasnt "go-owed: a READY at a head the PR no longer has is not listed" "go-owed" "$OUT"

world; set_tail "- 10:05 READY 101 $H1 GREEN"
touch -d "@$((NOW - 660))" "$WORK/w/go/.locks/go/101.$H1"
sweep
has "merge-owed: t3 lane, GO file 11 min old" "DUTY merge-owed 101@$H7_1 :: " "$OUT"
hasnt "merge-owed: and no go-owed beside it" "go-owed" "$OUT"
touch -d "@$((NOW - 540))" "$WORK/w/go/.locks/go/101.$H1"
sweep
hasnt "merge-owed: GO file 9 min old waits" "merge-owed" "$OUT"
touch -d "@$((NOW - 660))" "$WORK/w/go/.locks/go/101.$H1"; set_lane native
sweep
hasnt "merge-owed: a native worker merges itself" "merge-owed" "$OUT"

world; set_tail "- 10:05 FINDING — which path do you want?"
sweep
has "answer-owed: an open FINDING" "DUTY answer-owed N1 :: " "$OUT"
world; set_tail "- 10:05 FINDING — which path?
- 10:20 RESOLVED — ruling received"
sweep
hasnt "answer-owed: RESOLVED retires it" "answer-owed" "$OUT"
world; set_tail "- 10:05 BLOCKED — a permission prompt
- 10:30 LIVE — still waiting"
sweep
has "answer-owed: a BLOCKED stays owed under later LIVE bullets" "DUTY answer-owed N1 :: " "$OUT"

masked_runs() {
    printf '[{"id":11,"name":"CI","event":"pull_request","status":"completed","conclusion":"%s","created_at":"2026-11-25T09:00:00Z","head_sha":"%s","run_attempt":1},{"id":12,"name":"CI","event":"%s","status":"completed","conclusion":"%s","created_at":"2026-11-25T09:30:00Z","head_sha":"%s","run_attempt":%s}]\n' \
        "$1" "$H1" "${4:-pull_request}" "$2" "$H1" "$3" > "$WORK/w/runs.json"
}
world; masked_runs success cancelled 1
sweep
has "ci-masked: listed" "DUTY ci-masked 101@$H7_1 :: " "$OUT"
has "ci-masked: rerun reported" "DUTY-RAN ci-masked 101@$H7_1 rerun 12 rc=0" "$OUT"
want_slug=$(git -C "$HERE" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
check "ci-masked: one rerun, --failed, against this repo" "run rerun 12 --failed -R $want_slug" "$(sed -n 1p "$STUB/gh-calls")"
sweep
check "ci-masked: a second sweep reruns nothing" "1" "$(grep -c . "$STUB/gh-calls")"
has "ci-masked: stays listed as sent" "rerun sent" "$OUT"
hasnt "ci-masked: no second DUTY-RAN" "DUTY-RAN" "$OUT"
world; masked_runs success cancelled 1
CHIEF_DUTY_AUTORUN=0 sweep
has "ci-masked: AUTORUN=0 still lists" "DUTY ci-masked 101@$H7_1" "$OUT"
check "ci-masked: AUTORUN=0 makes no gh call" "" "$(cat "$STUB/gh-calls")"
world; masked_runs success cancelled 2
sweep
has "ci-masked: attempt 2 lists cancelled x2" "cancelled x2" "$OUT"
check "ci-masked: attempt 2 is never rerun" "" "$(cat "$STUB/gh-calls")"
world; masked_runs success cancelled 1 push
sweep
check "ci-masked: a push-event run is ignored" "" "$OUT"
world; masked_runs success failure 1
sweep
has "ci-masked: a failure after green is listed" "DUTY ci-masked 101@$H7_1" "$OUT"
check "ci-masked: a failure is never rerun" "" "$(cat "$STUB/gh-calls")"
world; masked_runs success cancelled 1
printf '[{"number":101,"headRefName":"feat/x","headRefOid":"%s","isDraft":false,"isCrossRepository":true,"baseRefName":"main"}]\n' "$H1" > "$WORK/w/prs.json"
sweep
check "ci-masked: a fork PR is skipped" "" "$OUT"
world; masked_runs success cancelled 1
for n in 1 2 3 4 5 6 7 8 9 10; do printf 'reserve %s 90%s %s 9%s\n' "$((NOW - 600))" "$n" "$H2" "$n"; done > "$WORK/w/state/chief-duty-sweep-reruns"
sweep
has "ci-masked: ten reruns in the hour hold the eleventh" "held: hourly cap" "$OUT"
check "ci-masked: hourly cap means no gh call" "" "$(cat "$STUB/gh-calls")"
world; masked_runs success cancelled 1
printf '%s\n' "$((NOW - 600))" > "$WORK/w/pace"
sweep
has "ci-masked: a drain 10 min ago holds the rerun" "held: drain" "$OUT"
check "ci-masked: held means no gh call" "" "$(cat "$STUB/gh-calls")"
world; masked_runs success cancelled 1
printf '%s\n' "$((NOW - 300))" > "$WORK/w/pace"
CHIEF_DUTY_AUTORUN=0 sweep
has "ci-masked: drain beats autorun off" "held: drain 5m ago" "$OUT"
world; masked_runs success cancelled 1
sweep_env >"$WORK/w/p1" 2>&1 &
sweep_env >"$WORK/w/p2" 2>&1 &
wait
check "ci-masked: two parallel sweeps make one rerun call" "1" "$(grep -c . "$STUB/gh-calls")"
H3=3333333333333333333333333333333333333333
world
printf '[{"number":101,"headRefName":"a","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"},{"number":102,"headRefName":"b","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"},{"number":103,"headRefName":"c","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"}]\n' "$H1" "$H2" "$H3" > "$WORK/w/prs.json"
: > "$WORK/w/runs.json"
{
    printf '['
    sep=""
    for pair in "1 $H1" "2 $H2" "3 $H3"; do
        n=${pair%% *}; h=${pair#* }
        printf '%s{"id":%s1,"name":"CI","event":"pull_request","status":"completed","conclusion":"success","created_at":"2026-11-25T09:00:00Z","head_sha":"%s","run_attempt":1},{"id":%s2,"name":"CI","event":"pull_request","status":"completed","conclusion":"cancelled","created_at":"2026-11-25T09:30:00Z","head_sha":"%s","run_attempt":1}' "$sep" "$n" "$h" "$n" "$h"
        sep=","
    done
    printf ']\n'
} > "$WORK/w/runs.json"
sweep
check "ci-masked: two reruns per sweep" "2" "$(grep -c . "$STUB/gh-calls")"
has "ci-masked: the third is held, not reserved" "held: two reruns this sweep" "$OUT"
sweep
check "ci-masked: the held one is rerun by the next sweep" "3" "$(grep -c . "$STUB/gh-calls")"
world; masked_runs success cancelled 1
printf '1\n' > "$STUB/gh.rc"
sweep
has "ci-masked: a failed rerun is reported" "DUTY-RAN ci-masked 101@$H7_1 rerun 12 rc=1" "$OUT"
has "ci-masked: a failed rerun is not called sent" "the rerun failed rc=1" "$OUT"
hasnt "ci-masked: a failed rerun never says sent" "rerun sent" "$OUT"
world
printf '[{"id":11,"name":"CI","event":"pull_request","status":"completed","conclusion":"success","created_at":"2026-11-25T09:00:00Z","head_sha":"%s","run_attempt":1},{"id":12,"name":"CI","event":"pull_request","status":"completed","conclusion":"cancelled","created_at":"2026-11-25T09:30:00Z","head_sha":"%s","run_attempt":1},{"id":13,"name":"CI","event":"pull_request","status":"in_progress","conclusion":null,"created_at":"2026-11-25T10:00:00Z","head_sha":"%s","run_attempt":1}]\n' "$H1" "$H1" "$H1" > "$WORK/w/runs.json"
sweep
check "ci-masked: a newer run still in progress means nothing is masked" "" "$OUT"
check "ci-masked: and no rerun" "" "$(cat "$STUB/gh-calls")"
world; rm -f "$DOC1"
sweep
has "a missing worker doc is named" "DUTY? worker N1 unread" "$OUT"
world; chmod 000 "$DOC1"
sweep
chmod 644 "$DOC1"
if [ "$(id -u)" = 0 ]; then pass "an unreadable worker doc is named (skipped as root)"; else has "an unreadable worker doc is named" "DUTY? worker N1 unread" "$OUT"; fi
world; printf '{"schema":1,"legs":[42]}\n' > "$WORK/w/fleet.json"
sweep
has "a leg that is not an object is named" "DUTY? fleet unread" "$OUT"
world; printf '{"schema":1,"legs":[]}\n' > "$WORK/w/fleet.json"; printf '[]\n' > "$WORK/w/prs.json"
sweep
check "an empty legs array is a clean fleet" "" "$OUT"
world; : > "$WORK/w/prs.json"
sweep
has "a zero-byte PR list is named" "DUTY? prs unread" "$OUT"
world
printf '# HIMMEL-9100 — worker N1\n\n## Notes\n- BLOCKED — an example quoted from the brief\n\n## Results (newest at the bottom)\n- 10:00 LIVE — working\n' > "$DOC1"
sweep
hasnt "a marker above the Results section is not read" "answer-owed" "$OUT"
world; mkdir -p "$B/a b"; DOC1="$B/a b/doc.md"; set_tail "- 10:05 READY 101 $H1 GREEN"; set_lane t3
touch -d "@$((NOW - 660))" "$WORK/w/go/.locks/go/101.$H1"
sweep
has "a path with a space is quoted in the printed merge command" "--worker-doc $B/a\\ b/doc.md " "$OUT"
world; masked_runs success cancelled 1
printf 'reserve %s 101 %s 12\n' "$NOW" "$H1" > "$WORK/w/state/chief-duty-sweep-reruns"
sweep
has "ci-masked: a reservation with no result row is an unknown outcome" "outcome unknown" "$OUT"
hasnt "ci-masked: and is not called sent" "rerun sent" "$OUT"
check "ci-masked: and makes no gh call" "" "$(cat "$STUB/gh-calls")"

verdict() {
    mkdir -p "$B/verdicts/$1"
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
    printf '# VERDICT %s - judge\n\n## Verdict\n\n**%s** for head `%s`\n\npr: %s\n' "$1" "$4" "$3" "$2" > "$B/verdicts/$1/judge.md"
}
world; set_tail "- 10:05 READY 101 $H1 GREEN"
printf '[{"number":101,"headRefName":"feat/himmel-9100-thing","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"}]\n' "$H1" > "$WORK/w/prs.json"
verdict j101a 101 "$H2" GO
printf 'finding\n' > "$STUB/delta.out"
sweep
has "judge-owed: a verdict at an older head, delta finding" "DUTY judge-owed 101@$H7_1 :: " "$OUT"
SPEC="$WORK/w/state/chief-duty-judge/101-$H7_1.json"
if [ -s "$SPEC" ]; then pass "judge-owed: spec written"; else fail "judge-owed: spec written ($SPEC)"; fi
has "judge-owed: the next names gen-judge-brief" "gen-judge-brief.py" "$OUT"
HANDOVER_DIR="$WORK/w/handovers" USER_SLUG=u python3 -I "$JUDGE" "$SPEC" --chief test-chief --dispatch-json >"$WORK/w/spec.out" 2>"$WORK/w/spec.err"
check "judge-owed: gen-judge-brief accepts the spec" 0 "$?"
touch -d '2 hours ago' "$SPEC"
sum1=$(sha256sum "$SPEC" | cut -d' ' -f1)
mt1=$(stat -c %Y "$SPEC")  # gnu-ok: Linux-only kit
sweep
check "judge-owed: spec content never rewritten" "$sum1" "$(sha256sum "$SPEC" | cut -d' ' -f1)"
check "judge-owed: spec file never replaced" "$mt1" "$(stat -c %Y "$SPEC")"  # gnu-ok: Linux-only kit
has "judge-owed: the classifier reads the selected verdict file" "--verdict-file $B/verdicts/j101a/judge.md $H2 $H1" "$(cat "$STUB/delta-calls")"
printf 'none\n' > "$STUB/delta.out"; rm -rf "$WORK/w/state/chief-duty-judge"
sweep
hasnt "judge-owed: delta none needs no judge" "judge-owed" "$OUT"
printf 'trust\n' > "$STUB/delta.out"
verdict j101b 101 "$H1" GO
sweep
hasnt "judge-owed: a verdict at the READY head clears it" "judge-owed" "$OUT"
world; set_tail "- 10:05 READY 101 $H1 GREEN"
sweep
has "judge-owed: no verdict on the PR is a first judge, go-owed only" "DUTY go-owed 101@$H7_1" "$OUT"
hasnt "judge-owed: no prior verdict means no judge-owed" "judge-owed" "$OUT"
H3=3333333333333333333333333333333333333333
noop_record() {
    mkdir -p "$B/verdicts/$1"
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
    printf '# VERDICT %s - judge\n\n## Verdict\n\n**GO** for head `%s`\n\npr: 101\ndelta: no-op\ndelta-judged: %s\ndelta-class: none\n' "$1" "$H3" "$2" > "$B/verdicts/$1/judge.md"
}
world; set_tail "- 10:05 READY 101 $H1 GREEN"
verdict j101a 101 "$H2" GO
touch -d '2 hours ago' "$B/verdicts/j101a/judge.md"
noop_record j101n "$H2"
printf 'finding\n' > "$STUB/delta.out"
sweep
has "judge-owed: a newest no-op record is followed to the real judged head" "--verdict-file $B/verdicts/j101a/judge.md $H2 $H1" "$(cat "$STUB/delta-calls")"
hasnt "judge-owed: the no-op record is never the classifier's input" "j101n" "$(cat "$STUB/delta-calls")"
has "judge-owed: listed after a no-op record" "DUTY judge-owed 101@$H7_1 :: " "$OUT"
world; set_tail "- 10:05 READY 101 $H1 GREEN"
noop_record j101n "$H2"
sweep
check "judge-owed: a no-op record whose judged head has no record asks the classifier nothing" "" "$(cat "$STUB/delta-calls")"
has "judge-owed: and fails closed to a trust delta" "is a trust delta" "$OUT"

ticket() {
    printf -- '---\nkey: "%s"\nstatus: "%s"\nlabels: %s\nfixVersions: ["v1.1.3"]\n---\n# %s\n' "$1" "$3" "$2" "$1" > "$WORK/w/mirror/$1.md"
}
world
ticket HIMMEL-9201 '["operator-directed","phase:sliced"]' "To Do"
ticket HIMMEL-9202 '["operator-directed"]' "To Do"
ticket HIMMEL-9203 '["phase:sliced"]' "To Do"
ticket HIMMEL-9204 '["operator-directed"]' "In Progress"
printf '# disposition HIMMEL-9201 listed LOCAL tier 2\n# disposition HIMMEL-9202 owned by N3\n# disposition HIMMEL-9203 listed LOCAL tier 3\n# disposition HIMMEL-9204 listed LOCAL tier 2\n' > "$WORK/w/dispositions.txt"
sweep
has "dispatch-owed: operator-directed To Do, listed" "DUTY dispatch-owed HIMMEL-9201 :: " "$OUT"
hasnt "dispatch-owed: an owned ticket is not owed" "HIMMEL-9202" "$OUT"
hasnt "dispatch-owed: no operator-directed label" "HIMMEL-9203" "$OUT"
hasnt "dispatch-owed: not To Do" "HIMMEL-9204" "$OUT"
hasnt "dispatch-owed: a healthy read prints no pool-unread line" "pool unread" "$OUT"
printf '# open PRs unknown (the PR list failed)\n# disposition HIMMEL-9201 listed LOCAL tier 2\n' > "$WORK/w/dispositions.txt"
sweep
has "dispatch-owed: open PRs unknown reads as pool unread" "DUTY? pool unread" "$OUT"
hasnt "dispatch-owed: open PRs unknown lists no ticket" "dispatch-owed" "$OUT"
printf '# core-check failed: the classifier could not run\n# disposition HIMMEL-9201 listed LOCAL tier 2\n' > "$WORK/w/dispositions.txt"
sweep
has "dispatch-owed: core-check failed reads as pool unread" "DUTY? pool unread" "$OUT"
hasnt "dispatch-owed: core-check failed lists no ticket" "dispatch-owed" "$OUT"
printf '# disposition HIMMEL-9201 listed LOCAL tier 2\n' > "$WORK/w/dispositions.txt"
touch -d '31 minutes ago' "$WORK/w/dispositions.txt"
sweep
has "dispatch-owed: a copy older than 1800 s reads as pool unread" "DUTY? pool unread" "$OUT"
hasnt "dispatch-owed: a stale copy lists no ticket" "dispatch-owed" "$OUT"
touch -d '29 minutes ago' "$WORK/w/dispositions.txt"
sweep
has "dispatch-owed: a copy under 1800 s is judged" "DUTY dispatch-owed HIMMEL-9201 :: " "$OUT"

world
id_old=$(OWE_NOW_EPOCH=$((NOW - 20000)) bash "$OWE" add --bucket "$B" --chief c --kind proof --text "quote the live wake" --key HIMMEL-9100)
id_new=$(OWE_NOW_EPOCH=$((NOW - 600)) bash "$OWE" add --bucket "$B" --chief c --kind ticket --text "file the follow-up" --key HIMMEL-9100)
check "owed-stale: setup made the old row" "o1" "$id_old"
check "owed-stale: setup made the fresh row" "o2" "$id_new"
sweep
has "owed-stale: an old row" "DUTY owed-stale o1 :: " "$OUT"
hasnt "owed-stale: a fresh row is not stale" "owed-stale o2" "$OUT"

FIX="$HERE/fixtures/chief-duty-sweep"
stall_pair() {
    SWEEP_AT=$((NOW - $1 * 60)) sweep
    SWEEP_AT="" sweep
}
world
stall_pair 61
has "stalled-pr: unchanged head and tail for 61 min is listed" "DUTY stalled-pr 101@$H7_1 :: " "$OUT"
has "stalled-pr: names the owner" "owner N1" "$OUT"
has "stalled-pr: names the last marker" "last LIVE" "$OUT"
has "stalled-pr: names the age" "61m" "$OUT"
has "stalled-pr: names the blocker" "waiting on worker idle" "$OUT"
world
stall_pair 59
hasnt "stalled-pr: 59 min is not listed" "stalled-pr" "$OUT"
world
SWEEP_AT=$((NOW - 3660)) sweep
set_tail "- 10:00 LIVE — working
- 11:00 LIVE — a new bullet"
SWEEP_AT="" sweep
hasnt "stalled-pr: a new owner bullet restarts the clock" "stalled-pr" "$OUT"
world
SWEEP_AT=$((NOW - 3660)) sweep
printf '[{"number":101,"headRefName":"feat/himmel-9100-thing","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"}]\n' "$H2" > "$WORK/w/prs.json"
SWEEP_AT="" sweep
hasnt "stalled-pr: a new head restarts the clock" "stalled-pr" "$OUT"
world
SWEEP_AT=$((NOW - 3660)) sweep
STALL_SECS=7200 SWEEP_AT="" sweep
hasnt "stalled-pr: the threshold is configurable" "stalled-pr" "$OUT"
world; set_tail "- 10:05 READY 101 $H1 GREEN"
verdict j101b 101 "$H1" GO
stall_pair 61
has "stalled-pr: a judged READY with no GO file waits on a GO" "waiting on a GO owed" "$OUT"
touch "$WORK/w/go/.locks/go/101.$H1"
stall_pair 61
has "stalled-pr: a GO file at the head names the merge" "waiting on the merge (GO given" "$OUT"
hasnt "stalled-pr: and no longer a GO owed" "a GO owed" "$OUT"
world; set_tail "- 10:05 BLOCKED — a permission prompt"
stall_pair 61
has "stalled-pr: an open BLOCKED names a ruling owed" "waiting on a ruling owed" "$OUT"
world; printf '{"schema":1,"legs":[]}\n' > "$WORK/w/fleet.json"
stall_pair 61
has "stalled-pr: no leg for the ticket reads as no owner" "owner none" "$OUT"
has "stalled-pr: no owner is the blocker" "waiting on no owner" "$OUT"
world
printf '[{"id":13,"name":"CI","event":"pull_request","status":"in_progress","conclusion":null,"created_at":"2026-11-25T10:00:00Z","head_sha":"%s","run_attempt":1}]\n' "$H1" > "$WORK/w/runs.json"
stall_pair 61
has "stalled-pr: a CI run in progress names CI" "waiting on CI running" "$OUT"
world; set_tail "- 10:05 PARKED-USAGE — weekly budget"
mkdir -p "$B/bypass-queue"; printf 'cause=HEAD changed\n' > "$B/bypass-queue/.hold"
stall_pair 61
has "stalled-pr: a parked owner with a STALE bypass hold names the launcher" "bypass launcher STALE hold" "$OUT"
world
printf '[{"number":101,"headRefName":"feat/himmel-9100-thing","headRefOid":"%s","isDraft":true,"isCrossRepository":false,"baseRefName":"main"}]\n' "$H1" > "$WORK/w/prs.json"
stall_pair 61
hasnt "stalled-pr: a draft is not listed" "stalled-pr" "$OUT"
world; printf '{"schema":1,"workers":[{"doc":"%s","label":"N1","lane":"t3"}]}\n' "$DOC1" > "$WORK/w/fleet.json"
stall_pair 61
has "workers shape: the manifest's own owner is read" "owner N1" "$OUT"
hasnt "workers shape: an owned PR is not a dead wake" "dead-wake" "$OUT"
world; printf '{"schema":1,"legs":[42]}\n' > "$WORK/w/fleet.json"
stall_pair 61
has "unread fleet: named" "DUTY? fleet unread" "$OUT"
hasnt "unread fleet: no PR is called ownerless" "dead-wake" "$OUT"
hasnt "unread fleet: no PR is called stalled" "stalled-pr" "$OUT"
world; printf '{"schema":1}\n' > "$WORK/w/fleet.json"
stall_pair 61
has "a manifest with neither workers nor legs is unread" "DUTY? fleet unread" "$OUT"
hasnt "a manifest with neither adds no ownerless PR" "dead-wake" "$OUT"

world; CHIEF="$FIX/chief-dead-wake.md"
sweep
has "dead-wake: a hold with wake=done:KEY where KEY has no owner is listed" "DUTY dead-wake #5929 :: " "$OUT"
has "dead-wake: names the key" "done:HIMMEL-11114" "$OUT"
has "dead-wake: says to re-rule" "re-rule" "$OUT"
world; CHIEF="$FIX/chief-dead-wake.md"; rm -rf "$WORK/w/mirror"
sweep
has "dead-wake: a missing mirror is named" "DUTY? mirror unread" "$OUT"
hasnt "dead-wake: a missing mirror lists no hold as dead" "dead-wake #5929" "$OUT"
world; CHIEF="$FIX/chief-dead-wake.md"
printf -- '---\nkey: "HIMMEL-11114"\nstatus: "Done"\nstatusCategory: "Done"\n---\n' > "$WORK/w/mirror/HIMMEL-11114.md"
sweep
hasnt "dead-wake: a Done key's wake fires, so it is not dead" "dead-wake #5929" "$OUT"
chmod 000 "$WORK/w/mirror/HIMMEL-11114.md"
sweep
chmod 644 "$WORK/w/mirror/HIMMEL-11114.md"
if [ "$(id -u)" = 0 ]; then pass "dead-wake: an unreadable mirror record is not called dead (skipped as root)"; else hasnt "dead-wake: an unreadable mirror record is not called dead" "dead-wake #5929" "$OUT"; fi
world; printf '{"schema":1,"workers":[{"doc":{"path":"x"},"label":"N1","lane":"t3"}]}\n' > "$WORK/w/fleet.json"
stall_pair 61
has "a worker whose doc is not a string is an unread fleet" "DUTY? fleet unread" "$OUT"
hasnt "a worker whose doc is not a string adds no ownerless PR" "dead-wake" "$OUT"
world; CHIEF="$FIX/chief-live-wake.md"
sweep
hasnt "dead-wake: a key with a live worker is not dead" "dead-wake" "$OUT"
world; CHIEF="$FIX/chief-dispatchable-wake.md"
printf '# disposition HIMMEL-9300 listed LOCAL tier 2\n' > "$WORK/w/dispositions.txt"
sweep
hasnt "dead-wake: a key with a dispatchable row is not dead" "dead-wake" "$OUT"
world; CHIEF="$FIX/chief-live-wake.md"; set_tail "- 10:50 WRAPPED — done"
sweep
has "dead-wake: a wrapped worker no longer owns the key" "DUTY dead-wake #5929 :: " "$OUT"
world
printf '[{"number":101,"headRefName":"feat/himmel-9100-thing","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"},{"number":102,"headRefName":"feat/himmel-9999-other","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"}]\n' "$H1" "$H2" > "$WORK/w/prs.json"
sweep
has "dead-wake: an open PR with no owner is listed" "DUTY dead-wake #102 :: " "$OUT"
hasnt "dead-wake: an owned PR is not listed" "dead-wake #101" "$OUT"
CHIEF="$FIX/chief-held-pr.md"
sweep
hasnt "dead-wake: a PR named by a hold is held, not unowned" "dead-wake #102" "$OUT"

world; set_tail "- 10:05 READY 101 $H1 GREEN"; printf 'not json' > "$WORK/w/prs.json"
sweep
has "unread PR list: named" "DUTY? prs unread" "$OUT"
hasnt "unread PR list: no go-owed on a guess" "go-owed" "$OUT"

refusal() {
    jq -cn --arg ts "$1" --arg rule "$2" --arg instance "$3" --arg title "${4:-}" \
        '{v:1, ts:$ts, host:"h", source:"guard-t3-thread-tools", kind:"refusal", guard:"guard-t3-thread-tools", rule:$rule, instance:$instance, title:$title}' >> "$WORK/w/refusals.jsonl"
}
at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
rworld() { world; printf '[]\n' > "$WORK/w/prs.json"; }
replay() {
    refusal "$(at $((NOW - 600)))" off-narrow antigravity "Orchestrator (Neon) sk-SETTINGSVALUE"
    refusal "$(at $((NOW - 300)))" off-narrow antigravity "Orchestrator (Carbon)"
}
WAKE_AG="DUTY guard-refusal guard=guard-t3-thread-tools rule=off-narrow instance=antigravity :: a new guard refusal class :: next: find the open ticket that owns this guard and rule, or file one"

rworld; replay
mkdir -p "$WORK/w/nohash"
# shellcheck disable=SC2016  # the stub body expands when the stub runs
printf '#!/usr/bin/env bash\n[ "$1" != hash-object ] || exit 1\nexec %q "$@"\n' "$(command -v git)" > "$WORK/w/nohash/git"
chmod +x "$WORK/w/nohash/git"
PATH="$WORK/w/nohash:$PATH" sweep
PATH="$WORK/w/nohash:$PATH" sweep
check "refusal: a failed digest never folds a class, it wakes again" "$WAKE_AG" "$OUT"

rworld; replay
sweep
check "refusal: the 11-25 Antigravity replay wakes once, naming only the three key fields" "$WAKE_AG" "$OUT"
hasnt "refusal: no thread title in the wake" "Orchestrator" "$OUT"
hasnt "refusal: no title text in the wake" "SETTINGSVALUE" "$OUT"
sweep
check "refusal: a second sweep says nothing" "" "$OUT"
refusal "$(at $((NOW + 3600)))" off-narrow antigravity "again"
SWEEP_AT=$((NOW + 3700)) sweep
check "refusal: a repeat inside 24 h folds" "" "$OUT"
SWEEP_AT=$((NOW + 90000)) sweep
check "refusal: a folded repeat does not wake later" "" "$OUT"
refusal "$(at $((NOW + 90100)))" off-narrow antigravity
SWEEP_AT=$((NOW + 90200)) sweep
check "refusal: a repeat past 24 h wakes again" "$WAKE_AG" "$OUT"
SWEEP_AT=$((NOW + 90300)) sweep
check "refusal: the re-wake replaces the old stamp, so the next sweep says nothing" "" "$OUT"

rworld; replay
OUT=$(REFUSALS_AT=default HIMMEL_LEDGERS_JSON="$WORK/w/no-ledgers.json" sweep_env 2>"$WORK/w/err")
check "refusal: an unreadable ledger registry is named unread" "DUTY? guard-refusals unread" "$OUT"

rworld; replay; sweep
refusal "$(at $((NOW + 10)))" bypass-instance antigravity
SWEEP_AT=$((NOW + 20)) sweep
has "refusal: another rule wakes again" "rule=bypass-instance instance=antigravity " "$OUT"
hasnt "refusal: and the woken class stays folded" "rule=off-narrow" "$OUT"
refusal "$(at $((NOW + 30)))" off-narrow gemini
SWEEP_AT=$((NOW + 40)) sweep
has "refusal: another instance wakes again" "rule=off-narrow instance=gemini " "$OUT"
check "refusal: and only that one" "1" "$(printf '%s\n' "$OUT" | grep -c .)"

rworld; refusal "$(at "$NOW")" chief-title ""
sweep
has "refusal: an empty instance is the class '-'" "rule=chief-title instance=- " "$OUT"

rworld; refusal "$(at "$NOW")" non-string-instance '{"apiKey": "hunter2 value"}'
printf 'not json\n{"kind":"refusal"}\n' >> "$WORK/w/refusals.jsonl"
sweep
has "refusal: a field that is not a plain token is named non-token" "instance=non-token " "$OUT"
hasnt "refusal: and its text stays out of the wake" "hunter2" "$OUT"
check "refusal: a bad line and a keyless row add nothing" "1" "$(printf '%s\n' "$OUT" | grep -c .)"
refusal "$(at $((NOW + 10)))" non-string-instance '{"another": "value here"}'
SWEEP_AT=$((NOW + 20)) sweep
has "refusal: another instance printed as non-token still wakes" "instance=non-token " "$OUT"
check "refusal: the stamp file keeps a digest and an epoch per class, no row text" "2" \
    "$(grep -cE "^[0-9a-f]{40}$(printf '\t')[0-9]+\$" "$WORK/w/state/chief-duty-sweep-refusals.tsv")"

rworld
sweep
check "refusal: a missing row file is silent" "" "$OUT"
: > "$WORK/w/refusals.jsonl"
sweep
check "refusal: an empty row file is silent" "" "$OUT"
mkdir "$WORK/w/refusals.dir"
OUT=$(REFUSALS_AT="$WORK/w/refusals.dir" sweep_env 2>"$WORK/w/err")
check "refusal: a path that is no readable file is named unread" "DUTY? guard-refusals unread" "$OUT"

rworld; mkdir -p "$WORK/w/home/.himmel/state"; replay
mv "$WORK/w/refusals.jsonl" "$WORK/w/home/.himmel/state/guard-refusals.jsonl"
OUT=$(REFUSALS_AT=default HOME="$WORK/w/home" sweep_env 2>"$WORK/w/err")
check "refusal: with no override the path comes from the ledger registry" "$WAKE_AG" "$OUT"

world; set_tail "- 10:05 READY #101 $H1 GREEN"
sweep
has "ds-r1: a #-prefixed READY is go-owed" "DUTY go-owed 101@$H7_1" "$OUT"
world; set_tail "- 10:05 READY br-x abc1234"
sweep
hasnt "ds-r2: a br- READY has no PR row" "go-owed" "$OUT"
world; set_tail "- 10:05 READY 101 ${H1:0:12}"
sweep
hasnt "ds-r3: a short sha at a full head is a mismatch" "go-owed" "$OUT"
world; set_tail "- 10:05 READY 101 $H1 GREEN
- 10:10 LIVE — no longer holding at READY 101 $H1"
sweep
hasnt "ds-r4: a negated hold line clears the READY" "go-owed" "$OUT"
world; set_tail "- **READY 101 $H1 GREEN**"
sweep
has "ds-r5: a bold READY is read" "DUTY go-owed 101@$H7_1" "$OUT"
world; printf '[{"number":7,"headRefName":"feat/himmel-9100-thing","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"}]\n' "$H1" > "$WORK/w/prs.json"
set_tail "- 10:05 READY 7 $H1"
sweep
hasnt "ds-r5: a one-digit READY id is dropped" "go-owed" "$OUT"
world; set_tail "- 10:05 READY 101 $H1 GREEN"; mkdir -p "$WORK/w/hd/.locks/go"
touch -d "@$((NOW - 660))" "$WORK/w/hd/.locks/go/101.$H1"
OUT=$(HANDOVER_DIR="$WORK/w/hd" CHIEF_DUTY_SWEEP_NOW="$NOW" CHIEF_DUTY_SWEEP_PRS="$WORK/w/prs.json" CHIEF_DUTY_SWEEP_RUNS="$WORK/w/runs.json" \
    CHIEF_DUTY_SWEEP_MIRROR="$WORK/w/mirror" CHIEF_DUTY_SWEEP_DISPOSITIONS="$WORK/w/dispositions.txt" CHIEF_DUTY_SWEEP_GH="$STUB/seam-gh" \
    CHIEF_DUTY_SWEEP_DELTA="$STUB/delta" TICK_STATE_DIR="$WORK/w/state" CANCEL_RUNS_PACE_STATE="$WORK/w/pace" HIMMEL_GUARD_REFUSALS_LOG="$WORK/w/refusals.jsonl" \
    bash "$SWEEP" --doc "$CHIEF" --workers-from "$WORK/w/fleet.json" --bucket "$B" 2>"$WORK/w/err")
has "ds-r6: the GO root resolves through the library" "DUTY merge-owed 101@$H7_1" "$OUT"

check "no gh call outside the seam" "" "$(cat "$STUB/path-gh-calls")"

bash "$SWEEP" >/dev/null 2>&1; check "usage: no args exits 2" 2 "$?"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
