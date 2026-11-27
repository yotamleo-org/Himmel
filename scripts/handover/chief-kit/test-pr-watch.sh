#!/usr/bin/env bash
# PLATFORM GUARD: The chief kit is Linux-only (util-linux flock, /proc).
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
# shellcheck disable=SC2154  # fails, W, SUT, HERE come from the sourced tick-test-fixture.sh
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
gh_state() {
    printf '%s\n' "$1" > "$S/head"; printf '%s\n' "$2" > "$S/comments"; printf '%s\n' "$3" > "$S/rcomments"; printf '%s\n' "$4" > "$S/reviews"
    printf '%s\n' "${5:-open}" > "$S/state"; printf '%s\n' "${6:-false}" > "$S/merged"; rm -f "$S/gh.fail"
}
gh_state "$H1" 2 1 1
wexec() {
    local inbox="$1" m="$2"; shift 2
    mkdir -p "$(dirname "$inbox")"; : > "$inbox"
    CHIEF_WAIT_TICK="$S/tick.sh" CHIEF_WAIT_USAGE="$S/bank.sh" CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 \
    CHIEF_WAIT_DISPATCH="$S/no-dispatch.sh" CHIEF_WAIT_FAIL_WAKE=1000 CHIEF_WAIT_BUDGET="$S/budget.sh" \
    WAIT_SWEEP_CMD="$S/off.sh" WAIT_FOCUS_CMD="$S/off.sh" CHIEF_WAIT_PAGE_CMD="$S/off.sh" \
    CHIEF_WAIT_GH="$S/gh" CHIEF_WAIT_PR_WATCH_SEC=0 HIMMEL_DENIAL_ACK_DIR="$W/acks" \
        "$@" bash "$WAIT" "$inbox" --workers-from "$m"
}
wenv() { wexec "$1" "$2" timeout -k 2 "$3" > "$4" 2>"$4.err"; }
pr_reads() { grep -cE '/pulls/[0-9]+$' "$S/gh.log" 2>/dev/null; }
wenv_quiet() {
    local pid i=0 n0
    n0="$(pr_reads)"; quiet_state=""
    wexec "$1" "$2" exec > "$3" 2>"$3.err" &
    pid=$!; quiet_pid=$pid
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do
        if [ $(( $(pr_reads) - n0 )) -ge 2 ]; then
            kill -STOP "$pid" 2>/dev/null
            quiet_state="$(sed -n "s/.* pid=$pid .* state=\([a-z]*\).*/\1/p" "$1.wait" 2>/dev/null)"
            [ "$quiet_state" != waiting ] || break
            kill -CONT "$pid" 2>/dev/null
        fi
        sleep 0.1; i=$((i + 1))
    done
    quiet_polls=$(( $(pr_reads) - n0 ))
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; return; fi
    kill "$pid" 2>/dev/null; kill -CONT "$pid" 2>/dev/null
    i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=137; return; fi
    wait "$pid" 2>/dev/null; rc=124
    [ "$quiet_polls" -ge 2 ] || rc=125
}
mkdir -p "$S/slow"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$(cat "${2:-/dev/null}" 2>/dev/null)" in *" exit=signal-"*) printf "%s\n" "$PPID" > "$S/slow.held"; sleep "$(cat "$S/slow.hold")" ;; esac'  # read-sink-ok: the test's mv shim reads only the heartbeat temp file the waiter under test hands mv
    printf '%s\n' 'PATH="${PATH#"$S/slow:"}"; exec mv "$@"'
} > "$S/slow/mv"
chmod +x "$S/slow/mv"; printf '3\n' > "$S/slow.hold"
wd="$S/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$wd"
M="$S/chief.fleet.json"
bash "$FM" add "$M" --lane native "$wd" >/dev/null 2>&1
bash "$FM" watch "$M" add 77 --head "$H1" --comments 3 --reviews 1 >/dev/null 2>&1; rc=$?
check 'A0. the watch verb adds a row (RED at base: usage error)' 0 "$rc"

: > "$S/gh.log"
wenv_quiet "$S/in1/consoles/c.md" "$M" "$S/o1"
check 'A1. no change in head, comments or reviews: the waiter stays silent until the row ends' 124 "$rc"
check 'A1. and prints no pr-watch wake' 0 "$(grep -c 'WAKE pr-watch' "$S/o1")"
check 'A1. the poll did run: the stub saw the pull request' yes "$(grep -qE 'pulls/77$' "$S/gh.log" && echo yes)"
check 'A1. the poll did run: the stub saw its reviews' yes "$(grep -q 'pulls/77/reviews' "$S/gh.log" && echo yes)"

gh_state "$H2" 2 1 1
wenv "$S/in2/consoles/c.md" "$M" 8 "$S/o2"; rc=$?
check 'A2. a new head wakes (rc 0)' 0 "$rc"
check 'A2. one WAKE pr-watch line naming the PR and the head move' 1 "$(grep -c '^WAKE pr-watch 77 .*head 1111111' "$S/o2")"
check 'A2. the row now holds the new head' "$H2" "$(jq -r '.watch[0].head' "$M" 2>/dev/null)"
wenv_quiet "$S/in2/consoles/c.md" "$M" "$S/o3"
check 'A3. the same change never wakes twice (a re-armed waiter stays silent)' 124 "$rc"
check 'A3. and prints no second wake' 0 "$(grep -c 'WAKE pr-watch' "$S/o3")"
rm -f "$S/slow.held"
PATH="$S/slow:$PATH" wenv_quiet "$S/in2/consoles/c.md" "$M" "$S/o3s"
a3s_hb="$(cat "$S/in2/consoles/c.md.wait" 2>/dev/null)"
a3s_diag="no (HIMMEL-11507 hb: ${a3s_hb:-none}; wake: $(grep -m1 '^WAKE' "$S/o3s" || echo none))"
check 'A3s. with the exit held 3 s (a loaded runner), the row still ends at rc 124' 124 "$rc"
check 'A3s. the stop landed while the waiter was waiting, never mid-sample where it decides a wake' waiting "$quiet_state"
check 'A3s. and prints no wake of any kind' 0 "$(grep -c '^WAKE' "$S/o3s")"
check 'A3s. control: the seam held the exit (the shim held the exit heartbeat of this waiter)' yes "$([ "$(cat "$S/slow.held" 2>/dev/null)" = "$quiet_pid" ] && echo yes || printf '%s' "$a3s_diag")"
check 'A3s. control: the held exit heartbeat still landed (with the pid of this waiter)' yes "$(case "$a3s_hb" in (*" pid=$quiet_pid "*" exit=signal-TERM"*) echo yes ;; (*) printf '%s' "$a3s_diag" ;; esac)"

gh_state "$H2" 3 1 1
wenv "$S/in3/consoles/c.md" "$M" 8 "$S/o4"; rc=$?
check 'A4. a new comment wakes' 1 "$(grep -c '^WAKE pr-watch 77 .*comments 3→4' "$S/o4")"
gh_state "$H2" 3 1 2
wenv "$S/in3/consoles/c.md" "$M" 8 "$S/o5"; rc=$?
check 'A4. a new review wakes' 1 "$(grep -c '^WAKE pr-watch 77 .*reviews 1→2' "$S/o5")"

gh_state "$H1" 9 9 9; : > "$S/gh.fail"
before="$(jq -c '.watch' "$M")"
wenv_quiet "$S/in4/consoles/c.md" "$M" "$S/o6"
check 'A5. a REST failure never wakes' 124 "$rc"
check 'A5. and leaves the row untouched, to be retried next interval' "$before" "$(jq -c '.watch' "$M")"

gh_state "$H1" 3 1 2
M2="$S/succ.fleet.json"; cp "$M" "$M2"
wenv "$S/in5/consoles/successor.md" "$M2" 8 "$S/o7"; rc=$?
check "A6. a successor's waiter on the inherited manifest wakes on the watched PR with no re-arm" 1 "$(grep -c '^WAKE pr-watch 77 ' "$S/o7")"

gh_state "$H2" 3 1 2 closed true
wenv "$S/in6/consoles/c.md" "$M" 8 "$S/o8"; rc=$?
check 'A8. a merge with the head and counts unchanged wakes, naming the state move' 1 "$(grep -c '^WAKE pr-watch 77 state open→merged' "$S/o8")"
wenv_quiet "$S/in6/consoles/c.md" "$M" "$S/o9"
check 'A8. and wakes once: the row holds merged' "124 merged" "$rc $(jq -r '.watch[0].state' "$M" 2>/dev/null)"
gh_state "$H2" 3 1 2 closed false
M4="$S/closed.fleet.json"; bash "$FM" add "$M4" --lane native "$wd" >/dev/null 2>&1
bash "$FM" watch "$M4" add 78 --head "$H2" --comments 4 --reviews 2 --state open >/dev/null 2>&1
wenv "$S/in7/consoles/c.md" "$M4" 8 "$S/o10"; rc=$?
check 'A8. a PR closed without a merge wakes too' 1 "$(grep -c '^WAKE pr-watch 78 state open→closed' "$S/o10")"

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

check 'A7. the stub logged calls (the check is not vacuous)' yes "$([ "$(grep -c . "$S/gh.log")" -gt 4 ] && echo yes)"
check 'A7. the poll made no GraphQL call and no gh pr view' 0 "$(grep -c VIOLATION "$S/gh.log")"
check 'A7. every call was gh api' 0 "$(grep -vc '^api ' "$S/gh.log")"
: > "$S/gh.log"; "$S/gh" api graphql -f query=x >/dev/null 2>&1
check 'A7. control: a GraphQL argument is a VIOLATION in the stub' 1 "$(grep -c VIOLATION "$S/gh.log")"

READTOK=ghp_READTOKEN0123456789
mkdir -p "$S/tt" "$S/root" "$S/emptyroot"
printf 'himmel_github_token_vm2=%s\n' "$READTOK" > "$S/root/.env"; : > "$S/emptyroot/.env"
ln -s "$HERE/fixtures/gh-two-token-stub.sh" "$S/tt/gh"
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY
export HIMMEL_SECRETS_KEYRING=off
wrun() {
    local inbox="$1" m="$2" secs="$3" out="$4" ev=(); shift 4
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
    [ "$#" -eq 0 ] || shift
    mkdir -p "$(dirname "$inbox")"; : > "$inbox"
    env -u CHIEF_WAIT_GH \
    CHIEF_WAIT_TICK="$S/tick.sh" CHIEF_WAIT_USAGE="$S/bank.sh" CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 \
    CHIEF_WAIT_DISPATCH="$S/no-dispatch.sh" CHIEF_WAIT_FAIL_WAKE=1000 CHIEF_WAIT_BUDGET="$S/budget.sh" \
    WAIT_SWEEP_CMD="$S/off.sh" WAIT_FOCUS_CMD="$S/off.sh" CHIEF_WAIT_PAGE_CMD="$S/off.sh" \
    CHIEF_WAIT_PR_WATCH_SEC=0 HIMMEL_DENIAL_ACK_DIR="$W/acks" \
    ${ev[@]+"${ev[@]}"} timeout -k 2 "$secs" bash "$WAIT" "$inbox" --workers-from "$m" "$@" > "$out" 2>"$out.err"
}
gh_state "$H2" 2 1 1
M5="$S/tt.fleet.json"; bash "$FM" add "$M5" --lane native "$wd" >/dev/null 2>&1
bash "$FM" watch "$M5" add 77 --head "$H1" --comments 3 --reviews 1 >/dev/null 2>&1
: > "$S/tt.log"
wrun "$S/in9/consoles/c.md" "$M5" 8 "$S/o12" PATH="$S/tt:$PATH" GHLOG="$S/tt.log" GH_STUB_DELEGATE="$S/gh" GH_STUB_READ_TOKEN="$READTOK" GH_READ_ENV_ROOT="$S/root" GH_STUB_MAINFAIL=rate; rc=$?
check 'C1. spent main token, CHIEF_WAIT_GH unset: the watch still wakes on the new head' "0 1" "$rc $(grep -c '^WAKE pr-watch 77 .*head 1111111' "$S/o12")"
check 'C1. the pull request read logged tok=read' 1 "$(grep -c '^tok=read argv=api repos/{owner}/{repo}/pulls/77$' "$S/tt.log")"
check 'C1. the reviews read logged tok=read' 1 "$(grep -c '^tok=read argv=api repos/{owner}/{repo}/pulls/77/reviews' "$S/tt.log")"
check 'C1. no watch read logged tok=main' 0 "$(grep -c '^tok=main argv=api repos/' "$S/tt.log")"
M6="$S/ttc.fleet.json"; bash "$FM" add "$M6" --lane native "$wd" >/dev/null 2>&1
bash "$FM" watch "$M6" add 77 --head "$H1" --comments 3 --reviews 1 >/dev/null 2>&1
: > "$S/tt.log"
wrun "$S/in10/consoles/c.md" "$M6" 8 "$S/o13" PATH="$S/tt:$PATH" GHLOG="$S/tt.log" GH_STUB_DELEGATE="$S/gh" GH_STUB_READ_TOKEN="$READTOK" GH_READ_ENV_ROOT="$S/emptyroot"; rc=$?
check 'C2. control: no read token, main healthy: the watch wakes' "0 1" "$rc $(grep -c '^WAKE pr-watch 77 .*head 1111111' "$S/o13")"
check 'C2. control: the pull request and reviews reads logged tok=main' 2 "$(grep -c '^tok=main argv=api repos/{owner}/{repo}/pulls/77' "$S/tt.log")"

printf '#!/usr/bin/env bash\nenv > "$S/env.$(basename "$0" .sh)"\n' > "$S/envsg.sh"
cp "$S/envsg.sh" "$S/envwe.sh"; cp "$S/envsg.sh" "$S/envrc.sh"; cp "$S/envsg.sh" "$S/envci.sh"; cp "$S/envsg.sh" "$S/envdisp.sh"
printf 'echo "SILENT-WORKER-MERGE N1 pr=1 head=%s: merged"\n' "$H1" >> "$S/envsg.sh"
printf 'echo "ESCALATE marker-READY"; exit 10\n' >> "$S/envwe.sh"
printf 'printf "[PASS] 7. coverage\\nTRUST-PATH: no\\nREADY-CHECK PASS\\n"\n' >> "$S/envrc.sh"
printf 'echo GREEN\n' >> "$S/envci.sh"
printf 'echo "DISPOSITION PASS"\n' >> "$S/envdisp.sh"
chmod +x "$S"/env*.sh
knobs() { grep -c '^GH_READ_\(NO_MAIN_FALLBACK\|QUIET\|OFF\|TIMEOUT\|REFUSED_FILE\)=' "$1" 2>/dev/null; }
rm -f "$S"/env.env*
: > "$S/chief.md"
wrun "$S/in11/consoles/c.md" "$M6" 8 "$S/o14" GH_READ_ENV_ROOT="$S/emptyroot" CHIEF_WAIT_SILENT_GO="$S/envsg.sh" -- --doc "$S/chief.md"; rc=$?
check 'C3. the silent-go child ran and the waiter woke on it' "0 1" "$rc $(grep -c '^WAKE silent-go' "$S/o14")"
check 'C3. the silent-go child saw no GH_READ_ knob' 0 "$(knobs "$S/env.envsg")"
rm -f "$S/env.envsg"
wrun "$S/in12/consoles/c.md" "$M6" 8 "$S/o15" GH_READ_ENV_ROOT="$S/emptyroot" CHIEF_WAIT_SILENT_GO="$S/envsg.sh" GH_READ_NO_MAIN_FALLBACK=1 -- --doc "$S/chief.md"
check 'C3. control: a knob in the waiter env reaches the child (the env dump is not vacuous)' 1 "$(knobs "$S/env.envsg")"
HA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'auto_go\toff\tfeature\tHIMMEL-8349\tHIMMEL-8404\t2099-01-01\tfixture\n' > "$S/flags.tsv"
wd2="$S/HIMMEL-2-N2-b.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n- 10:00 READY 2566 %s GREEN\n' "$HA" > "$wd2"
M7="$S/ready.fleet.json"; bash "$FM" add "$M7" --lane native "$wd2" >/dev/null 2>&1
mkdir -p "$S/in13/consoles"; printf 'N2\t0\n' > "$S/in13/consoles/c.md.wait.ready"
wrun "$S/in13/consoles/c.md" "$M7" 12 "$S/o16" GH_READ_ENV_ROOT="$S/emptyroot" HIMMEL_FLAGS_TSV="$S/flags.tsv" HIMMEL_CONFIG_DIR="$S/no-conf" \
    CHIEF_WAIT_WORKER_EVENT="$S/envwe.sh" CHIEF_WAIT_READY_CHECK="$S/envrc.sh" CHIEF_WAIT_CI="$S/envci.sh" CHIEF_WAIT_DISPOSITION="$S/envdisp.sh" -- --doc "$S/chief.md"; rc=$?
check 'C4. the READY reached the worker-event and ready-check children' "0 1 1 1" "$rc $(grep -c '^WAKE ready 2566' "$S/o16") $([ -s "$S/env.envwe" ] && echo 1) $([ -s "$S/env.envrc" ] && echo 1)"
check 'C4. the worker-event child saw no GH_READ_ knob' 0 "$(knobs "$S/env.envwe")"
check 'C4. the ready-check child saw no GH_READ_ knob (no GH_READ_NO_MAIN_FALLBACK)' 0 "$(knobs "$S/env.envrc")"

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
