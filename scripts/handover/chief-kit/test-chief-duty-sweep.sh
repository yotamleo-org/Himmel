#!/usr/bin/env bash
# test-chief-duty-sweep.sh — chief-duty-sweep.sh prints one DUTY line per owed chief
# action and nothing for a clean fleet: a fixture row per class, a control per class,
# and the two auto-run acts (the masked-CI rerun, the finding-delta judge spec).
#
# Sandboxed: a temp bucket, fleet manifest, worker docs, PR list, CI runs cache, GO root,
# Jira mirror, pool dispositions, and stub `gh` / delta-class binaries. A `gh` stub that
# exits 99 sits first on PATH, so any GitHub call outside the CHIEF_DUTY_SWEEP_GH seam
# fails the row. Linux-only kit (touch -d).
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
    : > "$STUB/gh-calls"; : > "$STUB/path-gh-calls"; : > "$STUB/delta-calls"; rm -f "$STUB/gh.rc" "$STUB/delta.out"
    B="$WORK/w/bucket"
    CHIEF="$B/2026-11-25XX-chief.md"
    printf '# chief\n' > "$CHIEF"
    DOC1="$B/HIMMEL-9100-N1-thing-2026-11-25.md"
    set_tail "- 10:00 LIVE — working"
    set_lane t3
    printf '[{"number":101,"headRefName":"feat/himmel-9100-thing","headRefOid":"%s","isDraft":false,"isCrossRepository":false,"baseRefName":"main"}]\n' "$H1" > "$WORK/w/prs.json"
    printf '[{"id":11,"name":"CI","event":"pull_request","status":"completed","conclusion":"success","created_at":"2026-11-25T09:00:00Z","head_sha":"%s","run_attempt":1}]\n' "$H1" > "$WORK/w/runs.json"
    : > "$WORK/w/dispositions.txt"
}
set_tail() { printf '# HIMMEL-9100 — worker N1\n\n## Results (newest at the bottom)\n%s\n' "$1" > "$DOC1"; }
set_lane() { printf '{"schema":1,"legs":[{"doc":"%s","label":"N1","lane":"%s"}]}\n' "$DOC1" "$1" > "$WORK/w/fleet.json"; }

# shellcheck disable=SC2120  # no row passes an extra arg today
sweep() {
    OUT=$(CHIEF_DUTY_SWEEP_NOW="$NOW" CHIEF_DUTY_SWEEP_PRS="$WORK/w/prs.json" CHIEF_DUTY_SWEEP_RUNS="$WORK/w/runs.json" \
        CHIEF_DUTY_SWEEP_GO_ROOT="$WORK/w/go" CHIEF_DUTY_SWEEP_MIRROR="$WORK/w/mirror" \
        CHIEF_DUTY_SWEEP_DISPOSITIONS="$WORK/w/dispositions.txt" CHIEF_DUTY_SWEEP_GH="$STUB/seam-gh" \
        CHIEF_DUTY_SWEEP_DELTA="$STUB/delta" TICK_STATE_DIR="$WORK/w/state" CANCEL_RUNS_PACE_STATE="$WORK/w/pace" \
        bash "$SWEEP" --doc "$CHIEF" --workers-from "$WORK/w/fleet.json" --bucket "$B" "$@" 2>"$WORK/w/err")
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
check "ci-masked: one rerun, --failed" "run rerun 12 --failed" "$(sed -n 1p "$STUB/gh-calls" | sed 's/ -R [^ ]*//')"
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
python3 -I "$JUDGE" "$SPEC" --chief test-chief --dispatch-json >"$WORK/w/spec.out" 2>"$WORK/w/spec.err"
check "judge-owed: gen-judge-brief accepts the spec" 0 "$?"
sum1=$(sha256sum "$SPEC" 2>/dev/null | cut -d' ' -f1)
sweep
check "judge-owed: spec never rewritten" "$sum1" "$(sha256sum "$SPEC" 2>/dev/null | cut -d' ' -f1)"
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

world
OWE_NOW_EPOCH=$((NOW - 20000)) bash "$OWE" add --bucket "$B" --chief c --kind proof --text "quote the live wake" --key HIMMEL-9100 >/dev/null
OWE_NOW_EPOCH=$((NOW - 600)) bash "$OWE" add --bucket "$B" --chief c --kind ticket --text "file the follow-up" --key HIMMEL-9100 >/dev/null
sweep
has "owed-stale: an old row" "DUTY owed-stale o1 :: " "$OUT"
hasnt "owed-stale: a fresh row is not stale" "owed-stale o2" "$OUT"

world; set_tail "- 10:05 READY 101 $H1 GREEN"; printf 'not json' > "$WORK/w/prs.json"
sweep
has "unread PR list: named" "DUTY? prs unread" "$OUT"
hasnt "unread PR list: no go-owed on a guess" "go-owed" "$OUT"

check "no gh call outside the seam" "" "$(cat "$STUB/path-gh-calls")"

bash "$SWEEP" >/dev/null 2>&1; check "usage: no args exits 2" 2 "$?"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
