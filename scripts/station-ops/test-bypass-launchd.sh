#!/usr/bin/env bash
# Tests for scripts/station-ops/bypass-launchd.sh, the go-code launch route for allowlisted HIMMEL_*_OK flags.
# Usage: bash scripts/station-ops/test-bypass-launchd.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/lib/portable-timeout.sh
. "$REPO_ROOT/scripts/lib/portable-timeout.sh"
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

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bypass-launchd-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
DPID=""
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

cat > "$tmp/send" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$2" "${1%%$'\n'*}" >> "$BYPASSD_TEST_DIR/kinds"
[ "$2" != bypass-ask ] || printf '%s' "$1" > "$BYPASSD_TEST_DIR/ask"
printf '%s\n' "$1" >> "$BYPASSD_TEST_DIR/sent"
STUB
cat > "$tmp/launcher" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = --dry-run ]; then
    printf '%s\n' "$@" >> "$BYPASSD_TEST_DIR/dry.args"
    [ ! -s "$BYPASSD_TEST_DIR/dry.msg" ] || cat "$BYPASSD_TEST_DIR/dry.msg" >&2
    exit "$(cat "$BYPASSD_TEST_DIR/dry.rc" 2>/dev/null || echo 0)"
fi
env | grep -E '^([A-Za-z0-9_]*_OK|WORKER_SESSION_EFFORT|WORKER_SESSION_API_LANE|WORKER_SESSION_API_ACCOUNT|SKIP_FORCE_PUSH_GATE|IMPL_GUARD_DISABLE|SECURITY_REVIEW_NO_FETCH)=' | sort > "$BYPASSD_TEST_DIR/launch.env"
printf '%s\n' "$@" > "$BYPASSD_TEST_DIR/launch.args"
ps -o sid= -p $$ 2>/dev/null | tr -d ' ' > "$BYPASSD_TEST_DIR/launch.sid"
echo $$ > "$BYPASSD_TEST_DIR/launch.pid"
exit "${BYPASSD_TEST_RC:-0}"
STUB
chmod +x "$tmp/send" "$tmp/launcher"
UNTIL="$(date -u -d '+3 days' +%F 2>/dev/null || date -u -v+3d +%F)"

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
    printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief "$@" recommend=go > "$Q/$n.req"
    wait_for "$D/sent" " → launch · no " || return 1
    sed -n 's/^go \([A-Z2-9]\{6\}\) → launch · no [A-Z2-9]\{6\} → refuse$/\1/p' "$D/sent" | tail -n 1
}
last_ask() { cat "$D/ask" 2>/dev/null; }
kind_seq() { cut -d'|' -f1 "$D/kinds" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
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
        timeout 5 bash "$DAEMON" --bucket "$B" --until "$UNTIL" 2>&1 # gnu-ok: portable-timeout.sh above supplies a timeout on macOS
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
assert_contains "the ask names the paid run and its decision" "DECISION 921 · PAID RUN" "$(last_ask)"
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_contains "RED 9922: the go code launches with the billed flag set (GRANT log line)" \
    "GRANT HIMMEL-1-N1-sweep-pr1 env=HIMMEL_BILLED_OK=1 WORKER_SESSION_EFFORT=high decision=921 go=$CODE" "$(cat "$Q/daemon.log")"
assert_eq "the launcher runs with exactly the granted flag and effort" \
    "HIMMEL_BILLED_OK=1"$'\n'"WORKER_SESSION_EFFORT=high" "$(cat "$D/launch.env" 2>/dev/null)"
assert_contains "the request records the grant: go code and decision" "go=$CODE" "$(cat "$Q/r.req.done" 2>/dev/null)"
assert_contains "the launcher gets the brief and model" "claude-sonnet-5-5" "$(cat "$D/launch.args" 2>/dev/null)"
stop

echo "== api_account= carries a named API account into the launch =="
setup api-account
start
CODE=$(ask_code r api_account=A)
assert_contains "the ask names the API lane and the account" "API account A" "$(last_ask)"
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_eq "api_account=A launches with the lane seam on and account A" \
    "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1"$'\n'"WORKER_SESSION_API_ACCOUNT=A"$'\n'"WORKER_SESSION_API_LANE=on" "$(cat "$D/launch.env" 2>/dev/null)"
assert_contains "the GRANT log line names the seam and the account" "WORKER_SESSION_API_LANE=on WORKER_SESSION_API_ACCOUNT=A" "$(cat "$Q/daemon.log")"
stop

echo "== no api_account= leaves the API lane seam out =="
setup api-account-absent
start WORKER_SESSION_API_LANE=on WORKER_SESSION_API_ACCOUNT=B
CODE=$(ask_code r flags=HIMMEL_HOOK_INTEGRITY_BYPASS_OK)
reply "$OPERATOR" "$OPERATOR" "go $CODE"
if wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"; then pass "the omitted-account launch ran"; else fail "the omitted-account launch ran"; fi
if [ -e "$D/launch.env" ]; then pass "the omitted-account launch wrote its env record"; else fail "the omitted-account launch wrote its env record"; fi
assert_absent "without the field the launch carries no API lane seam" "WORKER_SESSION_API" "$(cat "$D/launch.env" 2>/dev/null)"
stop

echo "== a malformed api_account= is refused =="
setup api-account-bad
start
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief 'api_account=not-a-name' recommend=go > "$Q/r.req"
wait_for "$Q/daemon.log" "REFUSED malformed: api_account $Q/r.req"
assert_contains "a non-name api_account is refused and named" "REFUSED malformed: api_account $Q/r.req" "$(cat "$Q/daemon.log" 2>/dev/null)"
assert_absent "and launches nothing" "launched" "$([ -e "$D/launch.env" ] && echo launched)"
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
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief flags=HIMMEL_BILLED_OK,NOT_A_HOOK_GUARD_OK recommend=go > "$Q/a.req"
wait_for "$Q/daemon.log" "REFUSED flag NOT_A_HOOK_GUARD_OK is not in bypass-flags.json"
assert_eq "an unlisted flag is refused" "a.req.refused" "$(cd "$Q" && ls a.req.* 2>/dev/null)"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief flags=HIMMEL_BILLED_OK recommend=go > "$Q/b.req"
wait_for "$Q/daemon.log" "REFUSED HIMMEL_BILLED_OK needs decision"
assert_eq "a billed request with no decision is refused" "b.req.refused" "$(cd "$Q" && ls b.req.* 2>/dev/null)"
printf '%s\n' "brief=/etc/passwd" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief recommend=go > "$Q/c.req"
wait_for "$Q/daemon.log" "REFUSED malformed: brief-path"
assert_eq "a brief outside the bucket is refused" "c.req.refused" "$(cd "$Q" && ls c.req.* 2>/dev/null)"
ln -s "$BRIEF" "$B/HIMMEL-1-N2-link.md"
printf '%s\n' "brief=$B/HIMMEL-1-N2-link.md" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief recommend=go > "$Q/d.req"
wait_for "$Q/daemon.log" "REFUSED malformed: brief-path $Q/d.req"
assert_eq "RED 9922: a symlinked brief inside the bucket is refused" "d.req.refused" "$(cd "$Q" && ls d.req.* 2>/dev/null)"
assert_absent "no refusal sends an ask" " → launch · no " "$(cat "$D/sent" 2>/dev/null)"
stop

echo "== current-style worker names are accepted, N-series stays accepted =="
for name in HIMMEL-10310-F10310h-macos-hook-ports-2026-11-21 HIMMEL-2-U2-slug-2026-11-21 HIMMEL-1-N1-sweep-pr1; do
    setup "name-$name"
    BRIEF="$B/$name.md"
    printf -- '---\ndescription: "a stub brief"\n---\n# brief\n' > "$BRIEF"
    start
    CODE=$(ask_code r)
    assert_contains "RED 10542: $name is asked to the operator" " → launch · no " "$(cat "$D/sent" 2>/dev/null)"
    assert_eq "$name: the request is pending, not refused" "r.req.pending" "$(cd "$Q" && ls r.req.* 2>/dev/null)"
    stop
done

echo "== every refusal names the failed field and no value =="
setup field-names
start
CH=HIMMEL-nextleg-2026-11-13A-roadmap-chief
for n in n3 NN3; do
    printf -- '---\n---\n' > "$B/HIMMEL-3-$n-slug.md"
done
ln -s "$BRIEF" "$B/HIMMEL-1-N2-link.md"
refuse_row() {
    local n=$1 label=$2 want=$3; shift 3
    printf '%s\n' "$@" recommend=go > "$Q/$n.req"
    wait_for "$Q/daemon.log" "REFUSED $want $Q/$n.req"
    wait_for "$D/sent" "refused $n.req: $want"
    assert_eq "$label: the request is refused" "$n.req.refused" "$(cd "$Q" && ls "$n".req.* 2>/dev/null)"
    assert_contains "$label: the log names the field" "REFUSED $want $Q/$n.req" "$(cat "$Q/daemon.log" 2>/dev/null)"
    assert_contains "$label: the Telegram line names the field" "refused $n.req: $want" "$(cat "$D/sent" 2>/dev/null)"
    assert_contains "RED 10558 $label: the refusal is bypass-result" "bypass-result|bypass-launchd refused $n.req: $want" "$(cat "$D/kinds" 2>/dev/null)"
    assert_eq "RED 10558 $label: every send so far is bypass-result" 0 "$(kind_seq | tr ' ' '\n' | grep -vxc bypass-result || true)"
}
refuse_row m1 "a lowercase series" "malformed: brief-name" "brief=$B/HIMMEL-3-n3-slug.md" model=claude-sonnet-5-5 "chief=$CH"
refuse_row m2 "a two-letter series" "malformed: brief-name" "brief=$B/HIMMEL-3-NN3-slug.md" model=claude-sonnet-5-5 "chief=$CH"
refuse_row m3 "a bad model" "malformed: model" "brief=$BRIEF" model=claude-opus-4-1 "chief=$CH"
refuse_row m4 "a bad chief" "malformed: chief" "brief=$BRIEF" model=claude-sonnet-5-5 "chief=a b"
refuse_row m5 "a bad effort" "malformed: effort" "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" effort=ultra
refuse_row m6 "a bad api_account" "malformed: api_account" "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" api_account=not-a-name
refuse_row m7 "a brief outside the bucket" "malformed: brief-path, brief-name" "brief=/etc/passwd" model=claude-sonnet-5-5 "chief=$CH"
refuse_row m8 "a symlinked brief" "malformed: brief-path" "brief=$B/HIMMEL-1-N2-link.md" model=claude-sonnet-5-5 "chief=$CH"
refuse_row m9 "a bad model and a bad effort" "malformed: model, effort" "brief=$BRIEF" model=claude-opus-4-1 "chief=$CH" effort=ultra
assert_absent "no refusal sends an ask" " → launch · no " "$(cat "$D/sent" 2>/dev/null)"
assert_absent "no reason carries a field value" "claude-opus-4-1" "$(cat "$D/sent" "$Q/daemon.log" 2>/dev/null)"
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
wait_for "$D/kinds" "refused after your go"
assert_contains "RED 10558: a refusal after the go is bypass-result" "bypass-result|bypass launch HIMMEL-1-N1-sweep-pr1: refused after your go" "$(cat "$D/kinds" 2>/dev/null)"
assert_eq "RED 10558: a refusal after the go sends exactly the ask then bypass-result" "bypass-ask bypass-result" "$(kind_seq)"
stop

echo "== a launcher that fails is reported as failed =="
setup failed
start BYPASSD_TEST_RC=3
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCH-FAILED"
assert_contains "LAUNCH-FAILED names the launcher's rc" "LAUNCH-FAILED HIMMEL-1-N1-sweep-pr1 rc=3" "$(cat "$Q/daemon.log")"
wait_for "$D/sent" "FAILED (rc 3)"
assert_contains "RED 10558: the ask goes out as bypass-ask" "bypass-ask|go " "$(cat "$D/kinds" 2>/dev/null)"
assert_contains "RED 10558: the failed launch goes out as bypass-failed" "bypass-failed|bypass launch HIMMEL-1-N1-sweep-pr1: FAILED (rc 3)" "$(cat "$D/kinds" 2>/dev/null)"
assert_eq "RED 10558: a failed launch sends exactly the ask then bypass-failed" "bypass-ask bypass-failed" "$(kind_seq)"
stop

echo "== verdict lines go out as bypass-result =="
setup kinds-go
start
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
wait_for "$D/sent" "launched with"
assert_contains "RED 10558: launched is bypass-result" "bypass-result|bypass launch HIMMEL-1-N1-sweep-pr1: launched with" "$(cat "$D/kinds" 2>/dev/null)"
assert_eq "RED 10558: a launch sends exactly the ask then bypass-result" "bypass-ask bypass-result" "$(kind_seq)"
stop
setup kinds-no
start
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "no $CODE"
wait_for "$D/sent" "no, nothing ran"
assert_contains "RED 10558: a no is bypass-result" "bypass-result|bypass launch HIMMEL-1-N1-sweep-pr1: no, nothing ran." "$(cat "$D/kinds" 2>/dev/null)"
assert_eq "RED 10558: a no sends exactly the ask then bypass-result" "bypass-ask bypass-result" "$(kind_seq)"
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

echo "== 9973 R1: a registered guard flag launches with it set =="
setup_repo r1
start
launch_env_after_go flags=DESTRUCTIVE_OK
assert_eq "R1 line 3 of the ask names the flag" "flag DESTRUCTIVE_OK" "$(last_ask | sed -n 3p)"
assert_eq "R1 the launch holds DESTRUCTIVE_OK and no other flag" "DESTRUCTIVE_OK=1" "$(cat "$D/launch.env" 2>/dev/null)"
stop

echo "== 9973 R3: the ask and the log name every granted flag =="
setup_repo r3
start
launch_env_after_go flags=DESTRUCTIVE_OK,GIT_STASH_OK
assert_contains "R3 line 3 of the ask names the first flag" "flags DESTRUCTIVE_OK, " "$(last_ask | sed -n 3p)"
assert_contains "R3 line 3 of the ask names the second flag" ", GIT_STASH_OK" "$(last_ask | sed -n 3p)"
assert_contains "R3 the GRANT line names both" "env=DESTRUCTIVE_OK=1 GIT_STASH_OK=1" "$(grep GRANT "$Q/daemon.log" 2>/dev/null)"
assert_eq "R3 the launch holds exactly both" "DESTRUCTIVE_OK=1"$'\n'"GIT_STASH_OK=1" "$(cat "$D/launch.env" 2>/dev/null)"
stop

echo "== 9973 R2 R4 R5 R6 R7: refusals before any ask =="
setup_repo refuse
start
refusal() {
    local label=$1 n=$2 frag=$3; shift 3
    printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief "$@" recommend=go > "$Q/$n.req"
    wait_for "$Q/daemon.log" "REFUSED $frag"
    assert_contains "$label is refused with its reason" "REFUSED $frag" "$(cat "$Q/daemon.log" 2>/dev/null)"
    assert_eq "$label ends .refused" "$n.req.refused" "$(cd "$Q" && ls "$n".req.* 2>/dev/null)"
}
refusal "R2 an invented flag" r2 "flag NOT_A_HOOK_GUARD_OK is not in bypass-flags.json" flags=NOT_A_HOOK_GUARD_OK
refusal "R4 a floor flag" r4 "flag ROGUE_SCHEDULE_OK is floor" flags=ROGUE_SCHEDULE_OK
refusal "R5 a decision flag with no decision" r5 "SKIP_SECURITY_REVIEW needs decision=" flags=SKIP_SECURITY_REVIEW
refusal "R6 a name that is not a switch" r6 "flag BWIMC_ENGINE is not a switch" flags=BWIMC_ENGINE
refusal "R7 six flags" r7 "more than 5 flags" flags=DESTRUCTIVE_OK,GIT_STASH_OK,AGENTS_MD_OK,BRANCH_NAME_OK,CHIEF_FG_OK,DOC_GUARD_OK
assert_absent "R2 R4 R5 R6 R7 no refusal sends an ask" " → launch · no " "$(cat "$D/sent" 2>/dev/null)"
stop

echo "== 9973 R5: a decision flag with a decision says so in the ask =="
setup_repo r5
start
CODE=$(ask_code r flags=SKIP_SECURITY_REVIEW decision=948)
assert_contains "R5 the ask carries the operator decision" "DECISION 948" "$(last_ask)"
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

echo "== 9973 R13: a replace ref cannot forge the tier file the daemon reads =="
setup_repo r13
awk -F'\t' -v OFS='\t' '$1 == "ROGUE_SCHEDULE_OK" { $2 = "grant"; $4 = "-" } 1' "$R/$TIER_REL" > "$D/forged.tsv"
g -C "$R" replace "$(g -C "$R" rev-parse "HEAD:$TIER_REL")" "$(g -C "$R" hash-object -w "$D/forged.tsv")"
assert_contains "R13 control: an ordinary git read sees the forged tier file" $'ROGUE_SCHEDULE_OK\tgrant' "$(g -C "$R" show "HEAD:$TIER_REL")"
start
refusal "R13 a floor flag under a forged tier blob" r13 "flag ROGUE_SCHEDULE_OK is floor" flags=ROGUE_SCHEDULE_OK
assert_absent "R13 no ask is sent" " → launch · no " "$(cat "$D/sent" 2>/dev/null)"
stop

echo "== 9973 R14: a configured fsmonitor does not run inside the daemon =="
setup_repo r14
printf '#!/bin/sh\n: > "%s/fsm.ran"\nexit 0\n' "$D" > "$D/fsm.sh"; chmod +x "$D/fsm.sh"
g -C "$R" config core.fsmonitor "$D/fsm.sh"
g -C "$R" diff --quiet HEAD
assert_eq "R14 control: an ordinary git diff runs the fsmonitor command" "ran" "$([ -e "$D/fsm.ran" ] && echo ran || echo no)"
rm -f "$D/fsm.ran"
start
wait_for "$Q/daemon.log" "start pid="
assert_eq "R14 the fsmonitor command never ran" "no" "$([ -e "$D/fsm.ran" ] && echo ran || echo no)"
stop

CH=HIMMEL-nextleg-2026-11-13A-roadmap-chief
blob() { g -C "$R" rev-parse "HEAD:$1" | cut -c1-12; }
commit_tiers() { printf '# %s\n' "$1" >> "$R/$TIER_REL"; g -C "$R" commit -q -am "$1"; }
n_lines() { grep -cF -- "$1" "$2" 2>/dev/null || true; }
has_hold() { [ -e "$Q/.hold" ] && echo yes || echo no; }

echo "== HIMMEL-10717 DoD 1, 2: a stale daemon holds a request only the new code accepts, and tells =="
setup_repo stale
start
wait_for "$Q/daemon.log" "start pid="
self_a=$(blob "$DAEMON_REL")
assert_contains "RED 10717: the start line names the daemon's own blob" "self=$self_a " "$(start_line)"
sed -i.bak 's/-\[A-Z\]\[0-9\]+\[a-z\]?-/-[A-Z]{1,2}[0-9]+[a-z]?-/' "$R/$DAEMON_REL"; rm -f "$R/$DAEMON_REL.bak"
assert_contains "control: commit B widens the brief-name pattern" '-[A-Z]{1,2}[0-9]+[a-z]?-' "$(cat "$R/$DAEMON_REL")"
g -C "$R" commit -q -am "B widens brief names"
self_b=$(blob "$DAEMON_REL")
NN="$B/HIMMEL-3-NN3-slug.md"
printf -- '---\ndescription: "a two-letter series brief"\n---\n' > "$NN"
printf '%s\n' "brief=$NN" model=claude-sonnet-5-5 "chief=$CH" recommend=go > "$Q/r.req"
wait_for "$Q/daemon.log" "STALE hold"
wait_for "$D/sent" "bypass request r.req waits"
sleep 1
assert_absent "RED 10717 DoD1: the stale daemon refuses nothing" "REFUSED" "$(cat "$Q/daemon.log")"
assert_absent "10717 guard, also true before the change: the stale daemon asks nothing" "ASK " "$(cat "$Q/daemon.log")"
assert_eq "RED 10717 DoD1: the request is still queued" "r.req" "$(cd "$Q" && ls r.req* 2>/dev/null)"
assert_eq "RED 10717 DoD1: one STALE hold line over many passes" "1" "$(n_lines 'STALE hold' "$Q/daemon.log")"
assert_contains "RED 10717 DoD1: the hold names the changed file" "(bypass-launchd.sh changed)" "$(grep 'STALE hold' "$Q/daemon.log")"
assert_eq "RED 10717 DoD1: the hold writes .hold" "yes" "$(has_hold)"
CAUSE_CARD="bypass-failed|bypass-launchd runs older code than its checkout (bypass-launchd.sh changed). It reads no request until you restart it: touch $Q/stop, wait for \`stop file\` in daemon.log, remove stop, start it again."
assert_eq "RED 10717 DoD2: one card names the cause and the restart steps" "1" "$(n_lines "$CAUSE_CARD" "$D/kinds")"
assert_eq "RED 10717 DoD2: one card names the held request" "1" "$(n_lines 'bypass-failed|bypass request r.req waits: the daemon needs a restart' "$D/kinds")"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" recommend=go > "$Q/s.req"
wait_for "$D/sent" "bypass request s.req waits"
sleep 1
assert_eq "RED 10717 DoD2: a request queued during the hold gets one card" "1" "$(n_lines 'bypass-failed|bypass request s.req waits: the daemon needs a restart' "$D/kinds")"
assert_eq "RED 10717 DoD2: no card repeats across passes" "1 1" \
    "$(n_lines "$CAUSE_CARD" "$D/kinds") $(n_lines 'bypass request r.req waits' "$D/kinds")"
out=$(CLAUDECODE=1 bash "$DAEMON" --check --bucket "$B" 2>&1)
assert_contains "RED 10717 DoD4: --check reports the holding daemon" \
    "daemon: live pid=$(readlink "$Q/.lock.pid"), holding (bypass-launchd.sh changed)" "$out"
stop; rm -f "$Q/stop"
start
for _ in $(seq 100); do [ "$(grep -c 'start pid=' "$Q/daemon.log")" -ge 2 ] && break; sleep 0.1; done
assert_contains "RED 10717 DoD1: the restarted daemon's start line carries B's self=" "self=$self_b " "$(grep 'start pid=' "$Q/daemon.log" | sed -n 2p)"
wait_for "$Q/daemon.log" "ASK HIMMEL-3-NN3-slug"
assert_contains "RED 10717 DoD1: after the restart the held request is asked" "ASK HIMMEL-3-NN3-slug" "$(cat "$Q/daemon.log")"
assert_eq "10717 guard, also true before the change: the restart removes .hold" "no" "$(has_hold)"
stop

echo "== HIMMEL-10717 DoD 1: a tier-file change holds with its own cause =="
setup_repo stale-tiers
start
wait_for "$Q/daemon.log" "start pid="
commit_tiers "B changes the tiers"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" recommend=go > "$Q/r.req"
wait_for "$Q/daemon.log" "STALE hold"
sleep 0.5
assert_contains "RED 10717 DoD1: a tier change holds, naming the tier file" "(bypass-flag-tiers.tsv changed)" "$(grep 'STALE hold' "$Q/daemon.log")"
assert_absent "RED 10717 DoD1: nothing is asked on old tiers" "ASK " "$(cat "$Q/daemon.log")"
assert_eq "RED 10717 DoD1: the request stays queued" "r.req" "$(cd "$Q" && ls r.req* 2>/dev/null)"
stop

echo "== HIMMEL-10717 G6: the hold latches until a restart =="
setup_repo stale-latch
start
wait_for "$Q/daemon.log" "start pid="
tiers_a=$(blob "$TIER_REL")
commit_tiers "B changes the tiers"
wait_for "$Q/daemon.log" "STALE hold"
g -C "$R" checkout -q HEAD~1 -- "$TIER_REL"; g -C "$R" commit -q -m "C restores A's tiers"
assert_eq "control: commit C restores A's tier blob" "$tiers_a" "$(blob "$TIER_REL")"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" recommend=go > "$Q/r.req"
sleep 1
assert_absent "RED 10717 G6: after A's ids return nothing is asked" "ASK " "$(cat "$Q/daemon.log")"
assert_eq "RED 10717 G6: the request stays queued" "r.req" "$(cd "$Q" && ls r.req* 2>/dev/null)"
assert_eq "RED 10717 G6: .hold stays" "yes" "$(has_hold)"
assert_eq "RED 10717 G6: still one STALE hold line" "1" "$(n_lines 'STALE hold' "$Q/daemon.log")"
stop

echo "== HIMMEL-10717 DoD 3: a change during the wait does not launch on old rules =="
setup_repo stale-go
start
CODE=$(ask_code r)
commit_tiers "B changes the tiers during the wait"
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "STALE after go"
wait_for "$D/sent" "bypass request r.req waits"
assert_eq "RED 10717 DoD3: the stub launcher never runs" "no" "$([ -e "$D/launch.args" ] && echo yes || echo no)"
assert_contains "RED 10717 DoD3: the log says the go was not used" "STALE after go $(basename "$BRIEF" .md): go not used, re-queued" "$(cat "$Q/daemon.log")"
assert_eq "RED 10717 DoD3: one bypass-result card says the go was not used" "1" "$(n_lines "bypass-result|bypass launch $(basename "$BRIEF" .md): your go was not used" "$D/kinds")"
assert_eq "RED 10717 DoD3: the request is queued again" "r.req" "$(cd "$Q" && ls r.req* 2>/dev/null)"
assert_eq "RED 10717 DoD3: the daemon then holds" "yes" "$(has_hold)"
assert_absent "RED 10717 DoD3: no GRANT line" "GRANT" "$(cat "$Q/daemon.log")"
stop

echo "== HIMMEL-10717 DoD 1: a change during one ask holds the next request of the same pass =="
setup_repo stale-pass
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" recommend=go > "$Q/a.req"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" recommend=go > "$Q/b.req"
start
wait_for "$D/sent" " → launch · no "
CODE=$(sed -n 's/^go \([A-Z2-9]\{6\}\) → launch.*/\1/p' "$D/sent" | tail -n 1)
commit_tiers "B changes the tiers during the first ask"
reply "$OPERATOR" "$OPERATOR" "no $CODE"
wait_for "$Q/daemon.log" "STALE hold"
sleep 0.5
assert_eq "RED 10717 DoD1: only the first request of the pass is asked" "1" "$(n_lines 'ASK ' "$Q/daemon.log")"
assert_absent "RED 10717 DoD1: the second request is not refused" "REFUSED" "$(cat "$Q/daemon.log")"
assert_eq "RED 10717 DoD1: the second request stays queued" "b.req" "$(cd "$Q" && ls b.req* 2>/dev/null)"
assert_contains "RED 10717 DoD1: the hold names the tier file" "(bypass-flag-tiers.tsv changed)" "$(grep 'STALE hold' "$Q/daemon.log")"
stop

echo "== HIMMEL-10717 DoD 1: a checkout that lost a loaded file holds, failing closed =="
setup_repo stale-gone
start
wait_for "$Q/daemon.log" "start pid="
g -C "$R" rm -q "$REG_REL"; g -C "$R" commit -q -m "B deletes the flag registry"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" recommend=go > "$Q/r.req"
wait_for "$Q/daemon.log" "STALE hold"
sleep 0.5
assert_contains "RED 10717 DoD1: an unreadable file holds with cannot read HEAD" "(cannot read HEAD)" "$(grep 'STALE hold' "$Q/daemon.log")"
assert_absent "RED 10717 DoD1: nothing is asked when a file cannot be read" "ASK " "$(cat "$Q/daemon.log")"
assert_eq "RED 10717 DoD1: the request stays queued when a file cannot be read" "r.req" "$(cd "$Q" && ls r.req* 2>/dev/null)"
stop

echo "== HIMMEL-10717 DoD 4: --check and blocks= =="
setup_repo check
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" recommend=go > "$D/ok.req"
printf '%s\n' "brief=$BRIEF" model=claude-opus-4-1 "chief=$CH" recommend=go > "$D/bad.req"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" "blocks=#5700 #5699" recommend=go > "$D/blocks.req"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 "chief=$CH" "blocks=5700" recommend=go > "$D/badblocks.req"
out=$(env -u CLAUDECODE bash "$DAEMON" --check --bucket "$B" --request "$D/ok.req" 2>&1); rc=$?
assert_eq "RED 10717 DoD4: --check on a valid request exits 0" "0" "$rc"
assert_contains "RED 10717 DoD4: --check prints accepted" "accepted" "$out"
assert_contains "RED 10717 DoD4: with no daemon, daemon: none" "daemon: none" "$out"
out=$(env -u CLAUDECODE bash "$DAEMON" --check --bucket "$B" --request "$D/bad.req" 2>&1); rc=$?
assert_eq "RED 10717 DoD4: a bad model exits 1" "1" "$rc"
assert_contains "RED 10717 DoD4: a bad model is refused by name" "refused: malformed: model" "$out"
out=$(env -u CLAUDECODE bash "$DAEMON" --check --bucket "$B" --request "$D/blocks.req" 2>&1); rc=$?
assert_eq "RED 10717 DoD4: blocks=#5700 #5699 is accepted" "0 accepted" "$rc $(head -n 1 <<<"$out")"
out=$(env -u CLAUDECODE bash "$DAEMON" --check --bucket "$B" --request "$D/badblocks.req" 2>&1); rc=$?
assert_eq "RED 10717 DoD4: blocks=5700 is refused malformed: blocks" "1 refused: malformed: blocks" "$rc $(head -n 1 <<<"$out")"
out=$(CLAUDECODE=1 bash "$DAEMON" --check --bucket "$B" --request "$D/ok.req" 2>&1); rc=$?
assert_eq "RED 10717 DoD4: --check runs under CLAUDECODE=1" "0 accepted" "$rc $(head -n 1 <<<"$out")"
assert_eq "10717 guard, also true before the change: --check under CLAUDECODE=1 takes no lock, logs nothing and sends nothing" "none" \
    "$( { [ -e "$Q/.lock.pid" ] || [ -L "$Q/.lock.pid" ]; } && echo lock; [ -e "$Q/daemon.log" ] && echo log; [ -e "$D/sent" ] && echo sent; [ -e "$Q/.hold" ] && echo hold; echo none)"
assert_absent "10717 guard, also true before the change: --check leaves no daemon running" "bypass-launchd.sh --bucket $B" "$(ps -eo args= 2>/dev/null)"
printf '\n# dirty\n' >> "$R/$TIER_REL"
out=$(env -u CLAUDECODE bash "$DAEMON" --check --bucket "$B" --request "$D/ok.req" 2>&1); rc=$?
assert_eq "10717 guard, also true before the change: a dirty tier file fails the start check, exit 2" "2" "$rc"
g -C "$R" reset -q --hard
start
wait_for "$Q/daemon.log" "start pid="
out=$(env -u CLAUDECODE bash "$DAEMON" --check --bucket "$B" 2>&1)
assert_contains "RED 10717 DoD4: with the daemon running, daemon: live pid=<p>" "daemon: live pid=$(readlink "$Q/.lock.pid")" "$out"
assert_absent "10717 guard, also true before the change: a fresh daemon is not holding" "holding" "$out"
cp "$D/badblocks.req" "$Q/m.req"
wait_for "$Q/daemon.log" "REFUSED malformed: blocks $Q/m.req"
assert_contains "RED 10717 DoD4: the daemon refuses blocks=5700" "REFUSED malformed: blocks $Q/m.req" "$(cat "$Q/daemon.log")"
CODE=$(ask_code r "blocks=#5700 #5699")
assert_contains "RED 10717 DoD4: the ask names the blocked PRs" "Blocks PRs: #5700 #5699" "$(cat "$D/sent" 2>/dev/null)"
stop

if [ "$(uname -s)" = Darwin ]; then
    echo "SKIP: the BSD-like shim section simulates macOS on a GNU host"
    echo
    echo "bypass-launchd: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
    exit
fi
SHIM="$tmp/macshim"
mk_shim() {
    local d=$1 t p real_date real_sha
    mkdir -p "$d"
    for t in bash env jq git awk sed grep cut tr head tail sort mkdir mv rm cat sleep touch dirname basename id ps readlink wc nohup perl ln rmdir; do
        p=$(command -v "$t") && ln -sf "$p" "$d/$t"
    done
    ln -sf "$BASH" "$d/bash"
    real_date=$(command -v date); real_sha=$(command -v sha256sum)
    printf '#!/bin/sh\necho Darwin\n' > "$d/uname"
    # shellcheck disable=SC2016 # the shim's own source
    printf '#!/bin/sh\n[ -z "$SHIM_DATE_ALLOW_D" ] || exec %s "$@"\nu=; str=; fmt=; out=\nwhile [ $# -gt 0 ]; do\n  case $1 in\n    -d) echo "date: illegal option -- d" >&2; exit 1 ;;\n    -u) u=-u ;;\n    -j) ;;\n    -f) fmt=$2; shift ;;\n    +*) out=$1 ;;\n    *) str=$1 ;;\n  esac\n  shift\ndone\nif [ -n "$fmt" ]; then exec %s $u -d "$str" ${out:+"$out"}; fi\nexec %s $u ${out:+"$out"}\n' "$real_date" "$real_date" "$real_date" > "$d/date"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "stat $*" >> "%s/stat.calls"\ncase $1 in\n  -c) echo "stat: illegal option -- c" >&2; exit 1 ;;\n  -f) wc -c < "$3" | tr -d " " ;;\n  *) exit 1 ;;\nesac\n' "$d" > "$d/stat" # read-sink-ok: writes a fake BSD stat into a test temp dir; it reads only files the test made
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = -a ] && [ "$2" = 256 ]; then shift 2; fi\nexec %s "$@"\n' "$real_sha" > "$d/shasum"
    chmod +x "$d/uname" "$d/date" "$d/stat" "$d/shasum"
}
mk_shim "$SHIM"
assert_eq "control: the shim has no flock, setsid or sha256sum" "none" "$(for t in flock setsid sha256sum; do [ -e "$SHIM/$t" ] && echo "$t"; done | head -n 1 | grep . || echo none)"
assert_eq "control: the shim date rejects -d like BSD date" "1" "$(PATH="$SHIM" date -d 2026-01-01 +%s >/dev/null 2>&1; echo $?)" # gnu-ok: the control proves the shim refuses the GNU flag
assert_eq "control: the shim stat rejects -c like BSD stat" "1" "$(PATH="$SHIM" stat -c %s /dev/null >/dev/null 2>&1; echo $?)" # gnu-ok: the control proves the shim refuses the GNU flag
rm -f "$SHIM/stat.calls"

echo "== HIMMEL-10430 B1: --until parses with BSD date =="
setup_repo b1
start PATH="$SHIM"
wait_for "$Q/daemon.log" "start pid="
assert_contains "RED B1: the daemon starts when date has no -d" "start pid=" "$(start_line)"
assert_absent "RED B1: --until is not called a non-date" "is not a date" "$(cat "$D/daemon.out")"
stop
setup_repo b1bad
env -u CLAUDECODE PATH="$SHIM" TELEGRAM_ACCESS_PATH="$D/access.json" bash "$DAEMON" --bucket "$B" --until 2026-13-45 > "$D/bad.out" 2>&1
assert_contains "B1: a real non-date is still refused" "is not a date" "$(cat "$D/bad.out")"

echo "== HIMMEL-10430 B2: the single-instance lock needs no flock =="
setup_repo b2
start PATH="$SHIM" SHIM_DATE_ALLOW_D=1
wait_for "$Q/daemon.log" "start pid="
assert_contains "RED B2: the daemon holds its lock and starts without flock" "start pid=" "$(start_line)"
assert_absent "RED B2: a missing flock is not reported as already running" "already running" "$(cat "$D/daemon.out")"
env -u CLAUDECODE PATH="$SHIM" SHIM_DATE_ALLOW_D=1 BRIDGE_ROOT="$D/bridge" TELEGRAM_ACCESS_PATH="$D/access.json" XDG_RUNTIME_DIR="$D/run" \
    bash "$DAEMON" --bucket "$B" --until "$UNTIL" > "$D/second.out" 2>&1
second_rc=$?
assert_eq "RED B2: a second daemon on the bucket exits 1" "1" "$second_rc"
assert_contains "RED B2: a second daemon says already running" "bypass-launchd: already running" "$(cat "$D/second.out")"
stop
assert_eq "B2: a stopped daemon leaves no lock behind" "none" "$([ -e "$Q/.lock.pid" ] || [ -L "$Q/.lock.pid" ] && echo held || echo none)"
start PATH="$SHIM" SHIM_DATE_ALLOW_D=1
for _ in $(seq 100); do [ "$(grep -c 'start pid=' "$Q/daemon.log")" -ge 2 ] && break; sleep 0.1; done
assert_eq "B2: the bucket can be started again after a stop" "2" "$(grep -c 'start pid=' "$Q/daemon.log")"
stop
setup_repo b2stale
ln -s 999999 "$Q/.lock.pid"
start PATH="$SHIM" SHIM_DATE_ALLOW_D=1
wait_for "$Q/daemon.log" "start pid="
assert_contains "B2: a lock naming a dead pid is reclaimed" "start pid=" "$(start_line)"
stop
setup_repo b2reuse
ln -s $$ "$Q/.lock.pid"
start PATH="$SHIM" SHIM_DATE_ALLOW_D=1
wait_for "$Q/daemon.log" "start pid="
assert_contains "B2: a lock naming a live pid that is not a daemon is reclaimed" "start pid=" "$(start_line)"
stop

setup_repo b2reclaim
ln -s 999999 "$Q/.lock.pid"; ln -s 999998 "$Q/.lock.pid.reclaim"
env -u CLAUDECODE PATH="$SHIM" SHIM_DATE_ALLOW_D=1 BRIDGE_ROOT="$D/bridge" TELEGRAM_ACCESS_PATH="$D/access.json" XDG_RUNTIME_DIR="$D/run" \
    bash "$DAEMON" --bucket "$B" --until "$UNTIL" > "$D/reclaim.out" 2>&1
assert_eq "B2: a dead reclaim link refuses the start with exit 2" "2" "$?"
assert_contains "B2: the refusal names the reclaim link to remove" ".lock.pid.reclaim was left by a starter that died" "$(cat "$D/reclaim.out")"
assert_eq "B2: the daemon leaves the dead reclaim link for the operator" "left" "$([ -L "$Q/.lock.pid.reclaim" ] && echo left || echo gone)"
rm -f "$Q/.lock.pid.reclaim"
start PATH="$SHIM" SHIM_DATE_ALLOW_D=1
wait_for "$Q/daemon.log" "start pid="
assert_contains "B2: once the reclaim link is removed the dead lock is reclaimed" "start pid=" "$(start_line)"
assert_eq "B2: the reclaim link is gone once the lock is taken" "gone" "$([ -L "$Q/.lock.pid.reclaim" ] && echo left || echo gone)"
stop

echo "== HIMMEL-10430 B3: no /run/user on macOS =="
setup_repo b3
mkdir -p "$D/tmpdir"
start PATH="$SHIM" SHIM_DATE_ALLOW_D=1 XDG_RUNTIME_DIR= TMPDIR="$D/tmpdir/"
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_eq "RED B3: with no XDG_RUNTIME_DIR the launch log lands under TMPDIR" "yes" \
    "$([ -e "$D/tmpdir/himmel-chief/gen-briefs/$(basename "$BRIEF" .md).launch.out" ] && echo yes || echo no)"
stop

echo "== HIMMEL-10430 B4: the journal offset needs no GNU stat =="
setup_repo b4
rm -f "$SHIM/stat.calls"
start PATH="$SHIM" SHIM_DATE_ALLOW_D=1
CODE=$(ask_code r)
assert_absent "B4: no GNU stat flag reaches the BSD-like stat" "stat -c" "$(cat "$SHIM/stat.calls" 2>/dev/null)" # gnu-ok: the assertion looks for the GNU flag among the shim calls
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_contains "B4: the go reply written after the ask is still read" "LAUNCHED HIMMEL-1-N1-sweep-pr1" "$(cat "$Q/daemon.log")"
stop

echo "== HIMMEL-10430 B5: the brief hash needs no sha256sum =="
setup_repo b5
start PATH="$SHIM" SHIM_DATE_ALLOW_D=1
CODE=$(ask_code r)
assert_absent "RED B5: the request is not refused as unreadable" "brief unreadable" "$(cat "$Q/daemon.log" "$D/sent" 2>/dev/null)"
assert_contains "RED B5: the ASK line carries a 12-character brief hash" "sha=$(sha256sum "$BRIEF" | cut -c1-12)" "$(cat "$Q/daemon.log")"
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_contains "B5: the re-hash after the go matches, so the worker launches" "LAUNCHED HIMMEL-1-N1-sweep-pr1" "$(cat "$Q/daemon.log")"
stop

echo "== HIMMEL-10430 B6: the worker detaches without setsid =="
setup_repo b6
start PATH="$SHIM" SHIM_DATE_ALLOW_D=1
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_absent "B6: the launch does not fail for want of setsid" "LAUNCH-FAILED" "$(cat "$Q/daemon.log")"
assert_eq "B6: the launcher runs as the leader of its own session" "$(cat "$D/launch.pid" 2>/dev/null)" "$(cat "$D/launch.sid" 2>/dev/null)"
stop

echo "== HIMMEL-10430: every fix together under the BSD-like tools =="
setup_repo e2e
mkdir -p "$D/tmpdir"
start PATH="$SHIM" XDG_RUNTIME_DIR= TMPDIR="$D/tmpdir"
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_contains "RED 10430: one go code launches a worker with BSD-like date, stat, hash and no flock, setsid or /run/user" "LAUNCHED HIMMEL-1-N1-sweep-pr1" "$(cat "$Q/daemon.log")"
stop

echo "== the requesting chief's manifest is the launch's explicit --fleet locator =="
if command -v flock >/dev/null 2>&1; then
    setup fleet-locator
    MF="$B/HIMMEL-nextleg-2026-11-13A-roadmap-chief.fleet.json"
    bash "$REPO_ROOT/scripts/handover/chief-kit/fleet-manifest.sh" control init "$MF" --target 4 >/dev/null 2>&1
    start
    CODE=$(ask_code r)
    reply "$OPERATOR" "$OPERATOR" "go $CODE"
    wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
    assert_contains "RED: a chief with a manifest launches with --fleet <its manifest>" "--fleet"$'\n'"$MF" "$(cat "$D/launch.args" 2>/dev/null)"
    stop
else
    echo "SKIP - fleet locator row (fleet-manifest.sh needs util-linux flock)"
fi

echo "== 10866: the row the daemon writes before a go-code launch is a pending registration the fleet admits =="
if command -v flock >/dev/null 2>&1; then
    setup fleet-admit
    MF="$B/HIMMEL-nextleg-2026-11-13A-roadmap-chief.fleet.json"
    FM="$REPO_ROOT/scripts/handover/chief-kit/fleet-manifest.sh"
    bash "$FM" control init "$MF" --target 4 >/dev/null 2>&1
    bash "$FM" control set "$MF" --mode active --expect-gen 1 >/dev/null 2>&1
    admit() { env HOME="$D" HIMMEL_FLEET_SLOTS="$D/slots" HIMMEL_POLICY_FOLLOWS_HOME=1 \
        bash "$FM" runtime admit --doc "$BRIEF" --manifest "$MF" --name "$(basename "$BRIEF" .md)" 2>&1; }
    start
    CODE=$(ask_code r)
    reply "$OPERATOR" "$OPERATOR" "go $CODE"
    wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
    stop
    assert_eq "RED 10866: the daemon's row for the brief is a pending registration" "pending" \
        "$(jq -r --arg d "$BRIEF" '.workers[] | select(.doc == $d) | .registration // "none"' "$MF" 2>/dev/null)"
    out=$(admit)
    assert_absent "RED 10866: the fleet admits the go-code launch on the daemon's own row" "unknown legacy family ownership" "$out"
    assert_contains "RED 10866: the admit for the daemon's row is managed" '"managed": true' "$out"
    LEGACY="$B/HIMMEL-1-N2-earlier.md"
    printf -- '---\ndescription: "a live legacy worker"\n---\n# brief\n' > "$LEGACY"
    jq -n --arg d "$LEGACY" '{schema: 1, workers: [{doc: $d, label: "N2", lane: "native", added: "2026-11-01T00:00:00Z"}]}' > "$B/earlier-chief.fleet.json"
    assert_contains "10866 control: a genuine legacy owner of the same ticket still refuses the admit" "unknown legacy family ownership" "$(admit)"
else
    echo "SKIP - fleet admit rows (fleet-manifest.sh needs util-linux flock)"
fi
setup fleet-none
start
CODE=$(ask_code r)
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_absent "a chief with no manifest launches without --fleet" "--fleet" "$(cat "$D/launch.args" 2>/dev/null)"
stop

echo "== 10735: an ask leads with the code and the reply, then the worker, the flag and the chief's word =="
setup short-ask
BRIEF="$B/HIMMEL-10561-Y10561a-unwire-write-hold-2026-11-22.md"
printf -- '---\ndescription: "%s"\n---\n# brief\n' "The switched-off file-hold barrier is unwired: its hook leaves the Edit/Write chain and the two pre-commit entries go, while the one-writer hold on state-repo files stays" > "$BRIEF"
start
printf '%s\n' "brief=$BRIEF" model=claude-opus-5-5 chief=HIMMEL-nextleg-2026-11-22AY-recovery-chief \
    flags=HIMMEL_HOOK_INTEGRITY_BYPASS_OK effort=high recommend=go > "$Q/r.req"
wait_for "$Q/daemon.log" "ASK HIMMEL-10561-Y10561a"
wait_for "$D/sent" "brief sha"
ASK=$(last_ask)
L1=$(printf '%s\n' "$ASK" | sed -n 1p)
c1="" c2=""
[[ $L1 =~ ^go\ ([A-Z2-9]{6})\ →\ launch\ ·\ no\ ([A-Z2-9]{6})\ →\ refuse$ ]] && c1=${BASH_REMATCH[1]} c2=${BASH_REMATCH[2]}
assert_eq "RED 10735: line 1 of the HIMMEL-10561 ask is the go and no reply with one code" "yes" "$([ -n "$c1" ] && [ "$c1" = "$c2" ] && echo yes || printf '%s' "$L1")"
assert_eq "RED 10735: line 2 names the ticket, worker, model and effort" "HIMMEL-10561 Y10561a on opus-5-5 high" "$(printf '%s\n' "$ASK" | sed -n 2p)"
assert_eq "RED 10735: line 3 names the flag and the guard it skips" "flag HIMMEL_HOOK_INTEGRITY_BYPASS_OK (skips block-worker-write-fence)" "$(printf '%s\n' "$ASK" | sed -n 3p)"
assert_eq "RED 10735: line 4 is the chief's word" "Chief: GO" "$(printf '%s\n' "$ASK" | sed -n 4p)"
assert_eq "RED 10735: the last line is the expiry and the brief sha" "yes" "$(grep -qE '^Expires 6 h · brief sha [0-9a-f]{12}$' <<<"${ASK##*$'\n'}" && echo yes)"
n=$(printf '%s' "$ASK" | LC_ALL=C wc -c | tr -d ' ')
assert_eq "RED 10735: the HIMMEL-10561 ask is at most 300 bytes (it was $n)" "yes" "$([ "$n" -le 300 ] && echo yes)"
assert_absent "RED 10735: the brief description is not in the ask" "switched-off" "$ASK"
reply "$OPERATOR" "$OPERATOR" "go $c1"
wait_for "$Q/daemon.log" "GRANT HIMMEL-10561-Y10561a"
assert_contains "10735: the code on line 1 is the code the GRANT line records" "go=$c1" "$(grep GRANT "$Q/daemon.log" 2>/dev/null)"
stop

echo "== 10735: the chief's NO reaches the ask with its reason =="
setup short-ask-no
start
CODE=$(ask_code r "recommend=no:the brief widens a guard it does not need")
assert_eq "RED 10735: recommend=no puts NO and the reason on line 4" "Chief: NO — the brief widens a guard it does not need" "$(last_ask | sed -n 4p)"
stop

echo "== 10735: a request without a valid recommend= is refused before any ask =="
setup short-ask-refuse
start
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief > "$Q/m.req"
wait_for "$Q/daemon.log" "REFUSED malformed: recommend $Q/m.req"
assert_eq "RED 10735: no recommend= refuses the request" "m.req.refused" "$(cd "$Q" && ls m.req.* 2>/dev/null)"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief recommend=maybe > "$Q/x.req"
wait_for "$Q/daemon.log" "REFUSED malformed: recommend $Q/x.req"
assert_eq "RED 10735: recommend=maybe refuses the request" "x.req.refused" "$(cd "$Q" && ls x.req.* 2>/dev/null)"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief "recommend=no:$(printf 'x%.0s' $(seq 61))" > "$Q/y.req"
wait_for "$Q/daemon.log" "REFUSED malformed: recommend $Q/y.req"
assert_eq "RED 10735: a NO reason over 60 characters refuses the request" "y.req.refused" "$(cd "$Q" && ls y.req.* 2>/dev/null)"
assert_absent "10735: no refused request sends an ask" " → launch · no " "$(cat "$D/sent" 2>/dev/null)"
stop

echo "== 10735: the longest ask a request can make stays under the cap of 400 =="
setup short-ask-worst
BRIEF="$B/HIMMEL-10561-Y10561a-unwire-write-hold-2026-11-22.md"
printf -- '---\ndescription: "x"\n---\n# brief\n' > "$BRIEF"
start
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-22AY-recovery-chief effort=xhigh \
    flags=WORKER_SESSION_CONTEXT_HANDOFF_OK,HIMMEL_HOOK_INTEGRITY_BYPASS_OK,SUBAGENT_PARK_GUARD_DISABLE,HIMMEL_BILLED_OK,SKIP_SECURITY_REVIEW \
    decision=12345 api_account=auto "recommend=no:$(printf 'x%.0s' $(seq 60))" > "$Q/w.req"
wait_for "$Q/daemon.log" "ASK HIMMEL-10561-Y10561a"
wait_for "$D/sent" "brief sha"
ASK=$(last_ask)
n=$(printf '%s' "$ASK" | LC_ALL=C wc -c | tr -d ' ')
assert_eq "RED 10735: five long flags, a decision, the API lane and a 60-character NO stay at most 400 bytes (it was $n)" "yes" "$([ "$n" -le 400 ] && echo yes)"
assert_eq "RED 10735: line 1 still leads with the code" "yes" "$(grep -qE '^go [A-Z2-9]{6} → launch' <<<"${ASK%%$'\n'*}" && echo yes)"
assert_contains "10735: the flag line names all five flags" "WORKER_SESSION_CONTEXT_HANDOFF_OK, HIMMEL_HOOK_INTEGRITY_BYPASS_OK, SUBAGENT_PARK_GUARD_DISABLE, HIMMEL_BILLED_OK, SKIP_SECURITY_REVIEW" "$ASK"
assert_contains "10735: the tag line names the decision, the paid run and the API account" "DECISION 12345 · PAID RUN · API account auto" "$ASK"
stop

CH=HIMMEL-nextleg-2026-11-13A-roadmap-chief
echo "== 10912: a request whose dry-run refuses is never asked, the chief is told =="
setup preflight-ask
mkdir -p "$D/bridge/consoles"; printf '# console\n' > "$D/bridge/consoles/$CH.md"
echo 10 > "$D/dry.rc"; echo "headed-arm-worker: refused: unknown legacy family ownership (stale row)" > "$D/dry.msg"
start
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=$CH recommend=go > "$Q/r.req"
wait_for "$Q/daemon.log" "REFUSED-PREFLIGHT HIMMEL-1-N1-sweep-pr1"
sleep 0.5
assert_contains "RED 10912: the log names the refusal and its reason" "REFUSED-PREFLIGHT HIMMEL-1-N1-sweep-pr1 rc=10 headed-arm-worker: refused: unknown legacy family ownership (stale row)" "$(cat "$Q/daemon.log" 2>/dev/null)"
assert_absent "RED 10912: a refused dry-run sends no ask" " → launch · no " "$(cat "$D/sent" 2>/dev/null)"
assert_absent "10912: a refused dry-run sends the operator nothing at all" "bypass" "$(cat "$D/kinds" 2>/dev/null)"
assert_contains "RED 10912: the chief's inbox gets the refusal line" "REFUSED-PREFLIGHT HIMMEL-1-N1-sweep-pr1 rc=10 headed-arm-worker: refused: unknown legacy family ownership (stale row)" "$(cat "$D/bridge/consoles/$CH.md")"
assert_eq "10912: the request is closed as refused, not left to be re-read" "r.req.refused" "$(cd "$Q" && ls r.req.* 2>/dev/null)"
assert_absent "10912: nothing launched" "launched" "$([ -e "$D/launch.env" ] && echo launched)"
stop

echo "== 10912: a request whose dry-run passes is asked as before, with the request's own launch shape =="
setup preflight-pass
start
CODE=$(ask_code r)
assert_contains "10912: a passing dry-run still asks" " → launch · no " "$(cat "$D/sent" 2>/dev/null)"
assert_contains "10912: the dry-run got the brief" "$BRIEF" "$(cat "$D/dry.args" 2>/dev/null)"
assert_contains "10912: the dry-run got the model" "claude-sonnet-5-5" "$(cat "$D/dry.args" 2>/dev/null)"
assert_contains "10912: the dry-run got the chief" "$CH" "$(cat "$D/dry.args" 2>/dev/null)"
assert_contains "10912: the dry-run is the worker-impl profile launch" "--profile"$'\n'"worker-impl" "$(cat "$D/dry.args" 2>/dev/null)"
stop

echo "== 10912: a grant whose dry-run refuses stays pending, the go is not spent, a touch retries it =="
setup preflight-grant
mkdir -p "$D/bridge/consoles"; printf '# console\n' > "$D/bridge/consoles/$CH.md"
start
CODE=$(ask_code r)
echo 10 > "$D/dry.rc"; echo "fleet cap 18/18" > "$D/dry.msg"
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "REFUSED-PREFLIGHT after go HIMMEL-1-N1-sweep-pr1"
sleep 0.5
assert_contains "RED 10912: the log names the reason" "REFUSED-PREFLIGHT after go HIMMEL-1-N1-sweep-pr1 rc=10 fleet cap 18/18" "$(cat "$Q/daemon.log" 2>/dev/null)"
assert_eq "RED 10912: the request stays pending (not done, not failed, not refused)" "r.req.held r.req.pending" "$(cd "$Q" && printf '%s ' r.req.* | sed 's/ $//')"
assert_absent "RED 10912: no GRANT line, the go is not spent" "GRANT" "$(cat "$Q/daemon.log")"
assert_absent "10912: no LAUNCH-FAILED" "LAUNCH-FAILED" "$(cat "$Q/daemon.log")"
assert_absent "10912: nothing launched" "launched" "$([ -e "$D/launch.env" ] && echo launched)"
assert_contains "RED 10912: the chief's inbox gets the held-grant line" "REFUSED-PREFLIGHT after go HIMMEL-1-N1-sweep-pr1 rc=10 fleet cap 18/18" "$(cat "$D/bridge/consoles/$CH.md")"
sleep 1
rm -f "$D/dry.rc" "$D/dry.msg"
touch "$Q/r.req.pending"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_contains "RED 10912: after the chief touches it the same go code launches" "GRANT HIMMEL-1-N1-sweep-pr1 env=HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 decision=none go=$CODE" "$(cat "$Q/daemon.log")"
assert_eq "10912: the retried request ends done, the hold is gone" "r.req.done" "$(cd "$Q" && ls r.req.* 2>/dev/null)"
assert_eq "10912: the operator was asked once" "1" "$(grep -c ' → launch · no ' "$D/sent")"
stop

echo
echo "bypass-launchd: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
