#!/usr/bin/env bash
# Tests for scripts/station-ops/bypass-launchd.sh, the go-code launch route for allowlisted HIMMEL_*_OK flags.
# Usage: bash scripts/station-ops/test-bypass-launchd.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/scripts/station-ops/bypass-launchd.sh"
OPERATOR=4242
PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }
assert_absent() { case "$3" in *"$2"*) fail "$1" "$3" ;; *) pass "$1" ;; esac; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$3"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "SKIP: flock not on PATH"; exit 0; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bypass-launchd-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
DPID=""
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

cat > "$tmp/send" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$BYPASSD_TEST_DIR/sent"
STUB
cat > "$tmp/launcher" <<'STUB'
#!/usr/bin/env bash
env | grep -E '^([A-Za-z0-9_]*_OK|WORKER_SESSION_EFFORT|SKIP_FORCE_PUSH_GATE|IMPL_GUARD_DISABLE|SECURITY_REVIEW_NO_FETCH)=' | sort > "$BYPASSD_TEST_DIR/launch.env"
printf '%s\n' "$@" > "$BYPASSD_TEST_DIR/launch.args"
exit "${BYPASSD_TEST_RC:-0}"
STUB
chmod +x "$tmp/send" "$tmp/launcher"
UNTIL="$(date -u -d '+3 days' +%F)"

setup() {
    D="$tmp/$1"; B="$D/bucket"; Q="$B/bypass-queue"; DAEMON=""
    mkdir -p "$Q" "$D/bridge" "$D/run"
    BRIEF="$B/HIMMEL-1-N1-sweep-pr1.md"
    printf -- '---\ndescription: "a stub sweep brief"\n---\n# brief\n' > "$BRIEF"
    printf '{"allowFrom": ["%s"]}\n' "$OPERATOR" > "$D/access.json"
    : > "$D/bridge/inbound.jsonl"
}
start() {
    env -u CLAUDECODE -u HIMMEL_BILLED_OK -u HIMMEL_HOOK_INTEGRITY_BYPASS_OK BYPASSD_TEST_DIR="$D" \
        BYPASSD_SEND="$tmp/send" BYPASSD_LAUNCHER="$tmp/launcher" BYPASSD_POLL=0.1 BYPASSD_SETTLE=0.5 \
        BRIDGE_ROOT="$D/bridge" TELEGRAM_ACCESS_PATH="$D/access.json" XDG_RUNTIME_DIR="$D/run" \
        "$@" bash "${DAEMON:-$SUT}" --bucket "$B" --until "$UNTIL" > "$D/daemon.out" 2>&1 &
    DPID=$!
}
stop() { touch "$Q/stop"; wait "$DPID" 2>/dev/null; DPID=""; }
wait_for() { local _; for _ in $(seq 100); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
ask_code() {
    local n=$1; shift
    printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief "$@" > "$Q/$n.req"
    wait_for "$D/sent" "Reply: go " || return 1
    sed -n 's/.*Reply: go \([A-Z2-9]\{6\}\) to launch.*/\1/p' "$D/sent" | tail -n 1
}
reply() { printf '{"from": %s, "chat_id": %s, "text": "%s", "forwarded": %s}\n' "$1" "$2" "$3" "${4:-false}" >> "$D/bridge/inbound.jsonl"; }

TIER_REL=scripts/station-ops/bypass-flag-tiers.tsv
REG_REL=scripts/himmelctl/lib/bypass-flags.json
DAEMON_REL=scripts/station-ops/bypass-launchd.sh
g() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
mk_repo() {
    mkdir -p "$1/scripts/station-ops" "$1/scripts/himmelctl/lib"
    cp "$REPO_ROOT/$DAEMON_REL" "$1/$DAEMON_REL"
    cp "$REPO_ROOT/$REG_REL" "$1/$REG_REL"
    [ -f "$REPO_ROOT/$TIER_REL" ] && cp "$REPO_ROOT/$TIER_REL" "$1/$TIER_REL"
    g -C "$1" init -q && g -C "$1" add -A && g -C "$1" commit -q -m seed
}
setup_repo() { setup "$1"; R="$D/repo"; mk_repo "$R"; DAEMON="$R/$DAEMON_REL"; }
run_repo() {
    env -u CLAUDECODE BYPASSD_TEST_DIR="$D" BYPASSD_SEND="$tmp/send" BYPASSD_LAUNCHER="$tmp/launcher" BYPASSD_POLL=0.1 \
        BRIDGE_ROOT="$D/bridge" TELEGRAM_ACCESS_PATH="$D/access.json" XDG_RUNTIME_DIR="$D/run" \
        timeout 5 bash "$DAEMON" --bucket "$B" --until "$UNTIL" 2>&1 # gnu-ok: the daemon is Linux-only and this suite skips without flock
}
start_line() { grep -m1 'start pid=' "$Q/daemon.log" 2>/dev/null; }
launch_env_after_go() {
    local code
    code=$(ask_code r "$@"); reply "$OPERATOR" "$OPERATOR" "go $code"
    wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
}
tier_problems() {
    local tiers="$REPO_ROOT/$TIER_REL" reg ovr names n t s w extra out=""
    [ -f "$tiers" ] || { echo "no tier file"; return; }
    reg=$(jq -r '.flags[].name' "$REPO_ROOT/$REG_REL" | sort)
    ovr=$(sed -n '/^HIMMEL_OVERRIDE_ENV_OK_VARS="/,/"$/p;/^HIMMEL_OVERRIDE_ENV_MARKERS="/,/"$/p' "$REPO_ROOT/scripts/lib/override-env.sh" \
        | sed 's/^[A-Z_]*="//; s/"$//' | tr -s ' ' '\n' | grep -v '^$' | sort -u)
    names=$(grep -v '^#' "$tiers" | cut -f1 | sort)
    out+=$(comm -23 <(printf '%s\n%s\n' "$reg" "$ovr" | sort -u) <(printf '%s\n' "$names" | sort -u) | sed 's/^/no row: /')
    out+=$(printf '%s\n' "$names" | uniq -d | sed 's/^/two rows: /')
    while IFS=$'\t' read -r n t s w extra; do
        case "$t" in grant|decision|floor|none) ;; *) out+=" $n: tier '$t'" ;; esac
        [ -z "$extra" ] || out+=" $n: more than four columns"
        [ "$w" != "-" ] || [ "$t" = grant ] || out+=" $n: only a grant row has why -"
        case "$s" in
            registry) grep -qxF -- "$n" <<<"$reg" || out+=" $n: source registry but not in the registry" ;;
            eval) [ "$n" = HIMMEL_BILLED_OK ] || out+=" $n: source eval" ;;
            *) [ -f "$REPO_ROOT/${s%%:*}" ] || out+=" $n: source path ${s%%:*} does not exist"
               case "$t" in grant|decision) out+=" $n: a $t row needs source registry or eval" ;; esac ;;
        esac
    done < <(grep -v '^#' "$tiers")
    printf '%s' "$out"
}

echo "== a billed request launches only on the operator's go code =="
setup billed-go
start
CODE=$(ask_code r flags=HIMMEL_BILLED_OK decision=921 effort=high)
assert_contains "the ask names the paid run and its decision" "PAID RUN (decision 921)" "$(cat "$D/sent" 2>/dev/null)"
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_contains "RED 9922: the go code launches with the billed flag set (GRANT log line)" \
    "GRANT HIMMEL-1-N1-sweep-pr1 env=HIMMEL_BILLED_OK=1 WORKER_SESSION_EFFORT=high decision=921 go=$CODE" "$(cat "$Q/daemon.log")"
assert_eq "the launcher runs with exactly the granted flag and effort" \
    "HIMMEL_BILLED_OK=1"$'\n'"WORKER_SESSION_EFFORT=high" "$(cat "$D/launch.env" 2>/dev/null)"
assert_contains "the request records the grant: go code and decision" "go=$CODE" "$(cat "$Q/r.req.done" 2>/dev/null)"
assert_contains "the launcher gets the brief and model" "claude-sonnet-5-5" "$(cat "$D/launch.args" 2>/dev/null)"
stop

echo "== a request with no go code launches nothing =="
setup no-go
start
CODE=$(ask_code r flags=HIMMEL_BILLED_OK decision=921)
reply 9999 9999 "go $CODE"
sleep 1
assert_eq "another sender's go launches nothing" "no-launch r.req.pending" \
    "$([ -e "$D/launch.env" ] && echo launched || echo no-launch) $(cd "$Q" && ls r.req.*)"
reply "$OPERATOR" "$OPERATOR" "go $CODE" true
sleep 1
assert_eq "the operator's forwarded go launches nothing" "no-launch r.req.pending" \
    "$([ -e "$D/launch.env" ] && echo launched || echo no-launch) $(cd "$Q" && ls r.req.*)"
reply "$OPERATOR" 9999 "go $CODE"
sleep 1
assert_eq "RED 9922: the operator's go from another chat launches nothing" "no-launch r.req.pending" \
    "$([ -e "$D/launch.env" ] && echo launched || echo no-launch) $(cd "$Q" && ls r.req.*)"
reply "$OPERATOR" "$OPERATOR" "no $CODE"
wait_for "$Q/daemon.log" "no HIMMEL-1-N1-sweep-pr1"
assert_eq "the operator's no code launches nothing" "no-launch r.req.no" \
    "$([ -e "$D/launch.env" ] && echo launched || echo no-launch) $(cd "$Q" && ls r.req.*)"
assert_absent "no GRANT line without a go code" "GRANT" "$(cat "$Q/daemon.log")"
stop

echo "== refusals before any ask =="
setup refusals
start
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief flags=HIMMEL_BILLED_OK,NOT_A_HOOK_GUARD_OK > "$Q/a.req"
wait_for "$Q/daemon.log" "REFUSED flag NOT_A_HOOK_GUARD_OK is not in bypass-flags.json"
assert_eq "an unlisted flag is refused" "a.req.refused" "$(cd "$Q" && ls a.req.* 2>/dev/null)"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief flags=HIMMEL_BILLED_OK > "$Q/b.req"
wait_for "$Q/daemon.log" "REFUSED HIMMEL_BILLED_OK needs decision"
assert_eq "a billed request with no decision is refused" "b.req.refused" "$(cd "$Q" && ls b.req.* 2>/dev/null)"
printf '%s\n' "brief=/etc/passwd" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief > "$Q/c.req"
wait_for "$Q/daemon.log" "REFUSED malformed"
assert_eq "a brief outside the bucket is refused" "c.req.refused" "$(cd "$Q" && ls c.req.* 2>/dev/null)"
ln -s "$BRIEF" "$B/HIMMEL-1-N2-link.md"
printf '%s\n' "brief=$B/HIMMEL-1-N2-link.md" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief > "$Q/d.req"
wait_for "$Q/daemon.log" "REFUSED malformed $Q/d.req"
assert_eq "RED 9922: a symlinked brief inside the bucket is refused" "d.req.refused" "$(cd "$Q" && ls d.req.* 2>/dev/null)"
assert_absent "no refusal sends an ask" "Reply: go" "$(cat "$D/sent" 2>/dev/null)"
stop

echo "== nothing else sets the flag =="
setup inherited
start HIMMEL_BILLED_OK=1 WORKER_SESSION_EFFORT=xhigh SOME_GUARD_OK=1
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_eq "RED 9922: no *_OK in the daemon's own environment reaches a launch, only the granted flag" \
    "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1" "$(cat "$D/launch.env" 2>/dev/null)"
stop

echo "== inner whitespace in a reply collapses to one space =="
for variant in two-spaces tab padded; do
    setup "ws-$variant"
    start
    CODE=$(ask_code r)
    case "$variant" in
        two-spaces) reply "$OPERATOR" "$OPERATOR" "go  $CODE" ;;
        tab) reply "$OPERATOR" "$OPERATOR" "go\\t$CODE" ;;
        padded) reply "$OPERATOR" "$OPERATOR" "  Go $CODE  " ;;
    esac
    wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
    tag="RED 10085"; [ "$variant" = padded ] && tag="control 10085"
    assert_eq "$tag: a go code typed with $variant launches" "r.req.done" "$(cd "$Q" && ls r.req.* 2>/dev/null)"
    stop
done
setup ws-negative
start
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "go ${CODE}X"
reply "$OPERATOR" "$OPERATOR" "go$CODE"
sleep 1
assert_eq "a wrong code or a code with no separator launches nothing" "no-launch r.req.pending" \
    "$([ -e "$D/launch.env" ] && echo launched || echo no-launch) $(cd "$Q" && ls r.req.*)"
reply "$OPERATOR" "$OPERATOR" "no  $CODE"
wait_for "$Q/daemon.log" "no HIMMEL-1-N1-sweep-pr1"
assert_eq "RED 10085: a no code typed with two spaces refuses like no CODE" "no-launch r.req.no" \
    "$([ -e "$D/launch.env" ] && echo launched || echo no-launch) $(cd "$Q" && ls r.req.*)"
stop

echo "== a brief edited after the ask is refused after the go =="
setup changed
start
CODE=$(ask_code r flags=HIMMEL_BILLED_OK decision=921)
printf 'more\n' >> "$BRIEF"
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "REFUSED after go"
assert_eq "the changed brief launches nothing" "no-launch r.req.refused" \
    "$([ -e "$D/launch.env" ] && echo launched || echo no-launch) $(cd "$Q" && ls r.req.*)"
stop

echo "== a launcher that fails is reported as failed =="
setup failed
start BYPASSD_TEST_RC=3
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCH-FAILED"
assert_contains "LAUNCH-FAILED names the launcher's rc" "LAUNCH-FAILED HIMMEL-1-N1-sweep-pr1 rc=3" "$(cat "$Q/daemon.log")"
stop

echo "== start refusals =="
setup start
out=$(CLAUDECODE=1 bash "$SUT" --bucket "$B" --until "$UNTIL" 2>&1); rc=$?
assert_eq "it refuses to start inside a Claude session" "2" "$rc"
assert_contains "the refusal says why" "inside a Claude session" "$out"
out=$(env -u CLAUDECODE TELEGRAM_ACCESS_PATH="$D/access.json" bash "$SUT" --bucket "$B" --until "$(date -u -d '+30 days' +%F)" 2>&1); rc=$?
assert_eq "an --until more than 7 days ahead is refused" "2 at most 7 days ahead" "$rc ${out##*and }"
printf '{"allowFrom": []}\n' > "$D/access.json"
out=$(env -u CLAUDECODE TELEGRAM_ACCESS_PATH="$D/access.json" bash "$SUT" --bucket "$B" --until "$UNTIL" 2>&1); rc=$?
assert_eq "no operator id in access.json refuses to start" "2" "$rc"
assert_absent "a refused start writes no log" "start pid" "$(cat "$Q/daemon.log" 2>/dev/null)"

echo "== 9973 R8: every flag name has exactly one tier row =="
assert_eq "R8 the tier file covers the registry and both override-env lists, and every row is well formed" "" "$(tier_problems)"

DESTRUCTIVE_TEXT="$(jq -r '.flags[] | select(.name == "DESTRUCTIVE_OK") | .bypasses' "$REPO_ROOT/$REG_REL")"
echo "== 9973 R1: a registered guard flag launches with it set =="
setup_repo r1
start
launch_env_after_go flags=DESTRUCTIVE_OK
assert_contains "R1 the ask names the flag and its registry text" "DESTRUCTIVE_OK=1 ($DESTRUCTIVE_TEXT)" "$(cat "$D/sent" 2>/dev/null)"
assert_eq "R1 the launch holds DESTRUCTIVE_OK and no other flag" "DESTRUCTIVE_OK=1" "$(cat "$D/launch.env" 2>/dev/null)"
stop

echo "== 9973 R3: the ask and the log name every granted flag =="
setup_repo r3
start
launch_env_after_go flags=DESTRUCTIVE_OK,GIT_STASH_OK
assert_contains "R3 the ask names the first flag" "DESTRUCTIVE_OK=1 (" "$(cat "$D/sent" 2>/dev/null)"
assert_contains "R3 the ask names the second flag" "GIT_STASH_OK=1 (" "$(cat "$D/sent" 2>/dev/null)"
assert_contains "R3 the GRANT line names both" "env=DESTRUCTIVE_OK=1 GIT_STASH_OK=1" "$(grep GRANT "$Q/daemon.log" 2>/dev/null)"
assert_eq "R3 the launch holds exactly both" "DESTRUCTIVE_OK=1"$'\n'"GIT_STASH_OK=1" "$(cat "$D/launch.env" 2>/dev/null)"
stop

echo "== 9973 R2 R4 R5 R6 R7: refusals before any ask =="
setup_repo refuse
start
refusal() {
    local label=$1 n=$2 frag=$3; shift 3
    printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief "$@" > "$Q/$n.req"
    wait_for "$Q/daemon.log" "REFUSED $frag"
    assert_contains "$label is refused with its reason" "REFUSED $frag" "$(cat "$Q/daemon.log" 2>/dev/null)"
    assert_eq "$label ends .refused" "$n.req.refused" "$(cd "$Q" && ls "$n".req.* 2>/dev/null)"
}
refusal "R2 an invented flag" r2 "flag NOT_A_HOOK_GUARD_OK is not in bypass-flags.json" flags=NOT_A_HOOK_GUARD_OK
refusal "R4 a floor flag" r4 "flag ROGUE_SCHEDULE_OK is floor" flags=ROGUE_SCHEDULE_OK
refusal "R5 a decision flag with no decision" r5 "SKIP_SECURITY_REVIEW needs decision=" flags=SKIP_SECURITY_REVIEW
refusal "R6 a name that is not a switch" r6 "flag BWIMC_ENGINE is not a switch" flags=BWIMC_ENGINE
refusal "R7 six flags" r7 "more than 5 flags" flags=DESTRUCTIVE_OK,GIT_STASH_OK,AGENTS_MD_OK,BRANCH_NAME_OK,CHIEF_FG_OK,DOC_GUARD_OK
assert_absent "R2 R4 R5 R6 R7 no refusal sends an ask" "Reply: go" "$(cat "$D/sent" 2>/dev/null)"
stop

echo "== 9973 R5: a decision flag with a decision says so in the ask =="
setup_repo r5
start
CODE=$(ask_code r flags=SKIP_SECURITY_REVIEW decision=948)
assert_contains "R5 the ask carries the operator decision" "OPERATOR DECISION 948" "$(cat "$D/sent" 2>/dev/null)"
stop

echo "== 9973 R9: no inherited hatch reaches a launch =="
setup_repo r9
start SKIP_FORCE_PUSH_GATE=1 IMPL_GUARD_DISABLE=1 GH_ADMIN_MERGE_OK=1 SECURITY_REVIEW_NO_FETCH=1
launch_env_after_go
assert_eq "R9 the default launch holds only its own flag" "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1" "$(cat "$D/launch.env" 2>/dev/null)"
stop

echo "== 9973 R10: a dirty trust input refuses start =="
setup_repo r10
dirty() {
    local label=$1 rel=$2 staged=$3
    printf '\n# edit\n' >> "$R/$rel"
    [ "$staged" = yes ] && g -C "$R" add "$rel"
    out=$(run_repo); rc=$?
    assert_eq "R10 $label: start is refused with exit 2" "2" "$rc"
    assert_contains "R10 $label: the refusal says uncommitted changes" "uncommitted changes" "$out"
    assert_absent "R10 $label: no start line is logged" "start pid" "$(cat "$Q/daemon.log" 2>/dev/null)"
    g -C "$R" reset -q --hard
}
dirty "the tier file" "$TIER_REL" no
dirty "the registry" "$REG_REL" no
dirty "the daemon" "$DAEMON_REL" no
dirty "a staged tier file" "$TIER_REL" yes

echo "== 9973 R11: the daemon reads HEAD =="
setup_repo r11
start
wait_for "$Q/daemon.log" "start pid="
assert_contains "R11 the start line names the tier file blob at HEAD" "tiers=$(g -C "$R" rev-parse "HEAD:$TIER_REL" | cut -c1-12) " "$(start_line)"
assert_contains "R11 the start line names the registry blob at HEAD" "registry=$(g -C "$R" rev-parse "HEAD:$REG_REL" | cut -c1-12) " "$(start_line)"
stop

echo "== 9973 R12: an inherited git location is ignored =="
setup_repo r12
mk_repo "$D/other"
printf '# other\n' >> "$D/other/$TIER_REL"; g -C "$D/other" commit -q -am other
start GIT_DIR="$D/other/.git"
wait_for "$Q/daemon.log" "start pid="
assert_contains "R12 the start line holds this repo's tier blob, not the other's" "tiers=$(g -C "$R" rev-parse "HEAD:$TIER_REL" | cut -c1-12) " "$(start_line)"
stop

echo
echo "bypass-launchd: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
