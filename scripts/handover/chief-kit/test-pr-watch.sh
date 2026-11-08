#!/usr/bin/env bash
# PLATFORM GUARD: The chief kit is Linux-only (util-linux flock, /proc).
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
# shellcheck disable=SC2154  # fails, W, SUT, HERE come from the sourced tick-test-fixture.sh
# test-pr-watch.sh — a worker waiting on an outside event closes, and code wakes the chief.
#   A. chief-wait.sh polls each watch row of the fleet manifest over REST (no GraphQL, no model turn):
#      a new head, comment count or review count wakes ONCE as `WAKE pr-watch <pr> <detail>`; no
#      change is silent (the RED control); a REST failure is silent; a successor's waiter on the same
#      manifest picks the row up with no re-arm.
#   B. tick.sh flags a worker whose newest marker is `LIVE — HOLD-OUTSIDE pr=<n>` and that is idle
#      (IDLE-HELD) as `holdout=<label>:<pr>`; a busy worker, a worker whose newest marker moved on,
#      and a wrapped one are never flagged.
# Hermetic: tick.sh and the bank are stubbed or run over tick-test-fixture.sh; gh is the CHIEF_WAIT_GH
# stub below, which fails the row on any GraphQL argument and logs every call.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"
FM="$HERE/fleet-manifest.sh"
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }

# ---- A. the waiter ----------------------------------------------------------------------------
S="$W/pw"; mkdir -p "$S"
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
cat > "$S/tick.sh" <<'EOF'
#!/usr/bin/env bash
cat "$S/tick.line"
EOF
printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\n' > "$S/tick.line"
printf '#!/usr/bin/env bash\nprintf "PROCEED\\n"\n' > "$S/bank.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$S/budget.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/off.sh"
# the gh stub: `gh api repos/<slug>/pulls/<n>` and `.../pulls/<n>/reviews`; any GraphQL argument, any
# non-`api` verb (gh pr view is GraphQL under the hood) or a `{owner}/{repo}` that is not a slug fails the row.
cat > "$S/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$S/gh.log"
case " $* " in *graphql*|*" pr "*|*" repo "*) printf 'VIOLATION %s\n' "$*" >> "$S/gh.log"; exit 99 ;; esac
[ "${1:-}" = api ] || { printf 'VIOLATION %s\n' "$*" >> "$S/gh.log"; exit 99; }
[ ! -f "$S/gh.fail" ] || exit 1
case "$2" in
    repos/*/pulls/*/reviews*) n="$(cat "$S/reviews")"; i=0; printf '['; while [ "$i" -lt "$n" ]; do [ "$i" -eq 0 ] || printf ','; printf '{"id":%s}' "$i"; i=$((i+1)); done; printf ']\n' ;;
    repos/*/pulls/*) printf '{"head":{"sha":"%s"},"comments":%s,"review_comments":%s,"state":"%s","merged":%s}\n' "$(cat "$S/head")" "$(cat "$S/comments")" "$(cat "$S/rcomments")" "$(cat "$S/state")" "$(cat "$S/merged")" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$S/gh" "$S/tick.sh" "$S/bank.sh" "$S/budget.sh" "$S/off.sh"
export S
gh_state() { # <head> <comments> <review comments> <reviews> [state: open] [merged: false]
    printf '%s\n' "$1" > "$S/head"; printf '%s\n' "$2" > "$S/comments"; printf '%s\n' "$3" > "$S/rcomments"; printf '%s\n' "$4" > "$S/reviews"
    printf '%s\n' "${5:-open}" > "$S/state"; printf '%s\n' "${6:-false}" > "$S/merged"; rm -f "$S/gh.fail"
}
gh_state "$H1" 2 1 1
wenv() { # run the waiter under the suite's seams for $3 seconds: <inbox> <manifest> <secs> <out>
    mkdir -p "$(dirname "$1")"; : > "$1"
    CHIEF_WAIT_TICK="$S/tick.sh" CHIEF_WAIT_USAGE="$S/bank.sh" CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 \
    CHIEF_WAIT_DISPATCH="$S/no-dispatch.sh" CHIEF_WAIT_FAIL_WAKE=1000 CHIEF_WAIT_BUDGET="$S/budget.sh" \
    WAIT_SWEEP_CMD="$S/off.sh" WAIT_FOCUS_CMD="$S/off.sh" CHIEF_WAIT_PAGE_CMD="$S/off.sh" \
    CHIEF_WAIT_GH="$S/gh" CHIEF_WAIT_PR_WATCH_SEC=0 HIMMEL_DENIAL_ACK_DIR="$W/acks" \
        timeout -k 2 "$3" bash "$WAIT" "$1" --workers-from "$2" > "$4" 2>"$4.err"
}
wd="$S/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$wd"
M="$S/chief.fleet.json"
bash "$FM" add "$M" --lane native "$wd" >/dev/null 2>&1
bash "$FM" watch "$M" add 77 --head "$H1" --comments 3 --reviews 1 >/dev/null 2>&1; rc=$?
check 'A0. the watch verb adds a row (RED at base: usage error)' 0 "$rc"

: > "$S/gh.log"
wenv "$S/in1/consoles/c.md" "$M" 4 "$S/o1"; rc=$?
check 'A1. no change in head, comments or reviews: the waiter stays silent to its timeout' 124 "$rc"
check 'A1. and prints no pr-watch wake' 0 "$(grep -c 'WAKE pr-watch' "$S/o1")"
check 'A1. the poll did run: the stub saw the pull request' yes "$(grep -qE 'pulls/77$' "$S/gh.log" && echo yes)"
check 'A1. the poll did run: the stub saw its reviews' yes "$(grep -q 'pulls/77/reviews' "$S/gh.log" && echo yes)"

gh_state "$H2" 2 1 1
wenv "$S/in2/consoles/c.md" "$M" 8 "$S/o2"; rc=$?
check 'A2. a new head wakes (rc 0)' 0 "$rc"
check 'A2. one WAKE pr-watch line naming the PR and the head move' 1 "$(grep -c '^WAKE pr-watch 77 .*head 1111111' "$S/o2")"
check 'A2. the row now holds the new head' "$H2" "$(jq -r '.watch[0].head' "$M" 2>/dev/null)"
wenv "$S/in2/consoles/c.md" "$M" 4 "$S/o3"; rc=$?
check 'A3. the same change never wakes twice (a re-armed waiter stays silent)' 124 "$rc"
check 'A3. and prints no second wake' 0 "$(grep -c 'WAKE pr-watch' "$S/o3")"

gh_state "$H2" 3 1 1
wenv "$S/in3/consoles/c.md" "$M" 8 "$S/o4"; rc=$?
check 'A4. a new comment wakes' 1 "$(grep -c '^WAKE pr-watch 77 .*comments 3→4' "$S/o4")"
gh_state "$H2" 3 1 2
wenv "$S/in3/consoles/c.md" "$M" 8 "$S/o5"; rc=$?
check 'A4. a new review wakes' 1 "$(grep -c '^WAKE pr-watch 77 .*reviews 1→2' "$S/o5")"

gh_state "$H1" 9 9 9; : > "$S/gh.fail"
before="$(jq -c '.watch' "$M")"
wenv "$S/in4/consoles/c.md" "$M" 4 "$S/o6"; rc=$?
check 'A5. a REST failure never wakes' 124 "$rc"
check 'A5. and leaves the row untouched, to be retried next interval' "$before" "$(jq -c '.watch' "$M")"

# A6. a successor chief: a new inbox, the manifest it inherits, no `watch add`, no re-arm of the predecessor
gh_state "$H1" 3 1 2
M2="$S/succ.fleet.json"; cp "$M" "$M2"
wenv "$S/in5/consoles/successor.md" "$M2" 8 "$S/o7"; rc=$?
check "A6. a successor's waiter on the inherited manifest wakes on the watched PR with no re-arm" 1 "$(grep -c '^WAKE pr-watch 77 ' "$S/o7")"

# A8. a merge or a close moves no head, comment or review count: the state alone must wake
gh_state "$H2" 3 1 2 closed true
wenv "$S/in6/consoles/c.md" "$M" 8 "$S/o8"; rc=$?
check 'A8. a merge with the head and counts unchanged wakes, naming the state move' 1 "$(grep -c '^WAKE pr-watch 77 state open→merged' "$S/o8")"
wenv "$S/in6/consoles/c.md" "$M" 4 "$S/o9"; rc=$?
check 'A8. and wakes once: the row holds merged' "124 merged" "$rc $(jq -r '.watch[0].state' "$M" 2>/dev/null)"
gh_state "$H2" 3 1 2 closed false
M4="$S/closed.fleet.json"; bash "$FM" add "$M4" --lane native "$wd" >/dev/null 2>&1
bash "$FM" watch "$M4" add 78 --head "$H2" --comments 4 --reviews 2 --state open >/dev/null 2>&1
wenv "$S/in7/consoles/c.md" "$M4" 8 "$S/o10"; rc=$?
check 'A8. a PR closed without a merge wakes too' 1 "$(grep -c '^WAKE pr-watch 78 state open→closed' "$S/o10")"

# A9. the same PR number in two repositories is two rows, each polled and updated on its own
gh_state "$H1" 3 1 2
M3="$S/tworepo.fleet.json"; bash "$FM" add "$M3" --lane native "$wd" >/dev/null 2>&1
bash "$FM" watch "$M3" add 90 --repo acme/one --head "$H1" --comments 4 --reviews 2 --state open >/dev/null 2>&1
bash "$FM" watch "$M3" add 90 --repo acme/two --head "$H1" --comments 4 --reviews 2 --state open >/dev/null 2>&1
check 'A9. one row per repository, never an overwrite' 2 "$(jq '.watch | length' "$M3" 2>/dev/null)"
gh_state "$H2" 3 1 2
wenv "$S/in8/consoles/c.md" "$M3" 8 "$S/o11"; rc=$?
check 'A9. the first repository wakes, and the wake line names it' 1 "$(grep -c '^WAKE pr-watch 90 repo=acme/one head' "$S/o11")"
check 'A9. its row moved and the other repository row kept what it had seen' "$H2 $H1" "$(jq -r '[.watch[] | select(.repo == "acme/one") | .head][0] + " " + [.watch[] | select(.repo == "acme/two") | .head][0]' "$M3" 2>/dev/null)"
check 'A9. the stub saw the repository named in the row' yes "$(grep -q 'repos/acme/one/pulls/90' "$S/gh.log" && echo yes)"

# A7. REST only: not one GraphQL, `pr` or `repo` call across every run above
check 'A7. the stub logged calls (the check is not vacuous)' yes "$([ "$(grep -c . "$S/gh.log")" -gt 4 ] && echo yes)"
check 'A7. the poll made no GraphQL call and no gh pr view' 0 "$(grep -c VIOLATION "$S/gh.log")"
check 'A7. every call was gh api' 0 "$(grep -vc '^api ' "$S/gh.log")"
# the RED control for A7: a poll that does call GraphQL trips the stub
: > "$S/gh.log"; "$S/gh" api graphql -f query=x >/dev/null 2>&1
check 'A7. control: a GraphQL argument is a VIOLATION in the stub' 1 "$(grep -c VIOLATION "$S/gh.log")"

# ---- B. the tick flag --------------------------------------------------------------------------
hold_cases() {
    local stamp out
    export WORKERS=HIMMEL-111-legN61
    export STUB_FLEET_LINE='bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/1'
    export HIMMEL_CLASSIFIER_DENIALS_LOG="$W/hold-denials.jsonl"
    mk_pgrep_x "$W/bin" 101
    printf '# worker\n\n## Results\n- 12:00 LIVE — HOLD-OUTSIDE pr=4761 owes: the reply on the outside review\n' > "$doc_n61"
    stamp="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"custom-title","customTitle":"HIMMEL-111-legN61"}\n{"type":"user","timestamp":"%s","message":{"content":[]}}\n' "$stamp" > "$TICK_PROJECTS_DIR/p/hold.jsonl"
    out="$(bash "$SUT")"
    contains 'B0. control: a recent transcript reads FRESH' "$out" 'workers=N61:FRESH'
    not_contains 'B1. a busy worker is never flagged, whatever its marker says' "$out" 'holdout='
    stamp="$(date -u -d '46 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"user","timestamp":"%s","message":{"content":[]}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/hold.jsonl"
    out="$(bash "$SUT")"
    contains 'B2. control: 46 idle minutes read IDLE-HELD' "$out" 'workers=N61:IDLE-HELD'
    contains 'B2. an idle worker whose newest marker is HOLD-OUTSIDE is flagged with its PR' "$out" ' holdout=N61:4761'
    printf -- '- 12:50 LIVE — back at work on the diff\n' >> "$doc_n61"
    out="$(bash "$SUT")"
    contains 'B3. control: still idle' "$out" 'workers=N61:IDLE-HELD'
    not_contains 'B3. a newer marker that is not a hold clears the flag' "$out" 'holdout='
    printf -- '- 12:55 LIVE — HOLD-OUTSIDE pr=4761 owes: the reply\n- 12:56 WRAPPED — closed with the debt written down\n' >> "$doc_n61"
    out="$(bash "$SUT")"
    not_contains 'B4. a worker that wrapped after the hold is not flagged' "$out" 'holdout='
    printf '%s\n' '---' 'description: Add a login form' '---' '# worker' '- LIVE — working' > "$doc_n61"
    rm -f "$TICK_PROJECTS_DIR/p/hold.jsonl"
}
hold_cases

[ "$fails" -eq 0 ] || { printf 'test-pr-watch: %s FAILED\n' "$fails"; exit 1; }
printf 'test-pr-watch: all rows passed\n'
