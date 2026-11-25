#!/usr/bin/env bash
# scripts/t3/test-thread-list.sh - fixture suite for thread-list.sh (a thread list and a process tree, both faked).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIST="$HERE/thread-list.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/t3list-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect_rc() { local n="$1" want="$2" rc; shift 2; "$@" >"$T/out" 2>"$T/err"; rc=$?; if [ "$rc" = "$want" ]; then ok "$n"; else bad "$n (rc=$rc)"; fi; }
expect_jq() { local got; got="$(jq -c "$2" "$T/out" 2>/dev/null)"; if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 (got: $got want: $3)"; fi; }

cat > "$T/t3" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "thread list") cat "$STUB_LIST" ;;
  "thread show") cat "$STUB_DIR/show-$3.json" ;;
esac
STUB
chmod +x "$T/t3"

ago() { date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%S.123Z 2>/dev/null || date -u -v-"$1"M +%Y-%m-%dT%H:%M:%S.123Z; }
M90="$(ago 90)"; M5="$(ago 5)"
cat > "$T/list.json" <<JSON
[{"threadId":"t-run","title":"Build the thing","status":"running","settled":false,"blockedOnThreadWait":false,"providerInstanceId":"claudeAgent","model":"claude-opus-5-5","createdAt":"$M90","updatedAt":"$M5","pullRequestCount":1,"openPullRequestCount":1,"pendingBackgroundTasks":[{"id":"b1"}]},
 {"threadId":"t-wait","title":"Wait on a peer","status":"idle","settled":false,"blockedOnThreadWait":true,"providerInstanceId":"codex","createdAt":"$M90","updatedAt":"$M90"},
 {"threadId":"t-reply","title":"Needs a reply","status":"completed","settled":false,"blockedOnThreadWait":false,"createdAt":"$M90","updatedAt":"$M90"},
 {"threadId":"t-blk","title":"Broke","status":"error","settled":false,"blockedOnThreadWait":false,"createdAt":"$M90","updatedAt":"$M90"},
 {"threadId":"t-set","title":"Done","status":"completed","settled":true,"settledAt":"$M5","createdAt":"$M90","updatedAt":"$M5"}]
JSON
for id in t-run t-wait t-reply t-blk; do
    wt=null; [ "$id" = t-run ] && wt='"/wt/run"'
    echo "{\"thread\":{\"threadId\":\"$id\",\"worktreePath\":$wt},\"messages\":[]}" > "$T/show-$id.json"
done

mkproc() { mkdir -p "$T/proc/$1"; echo "$1 ($2) S $3 $1 $1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ${5:-$1} 0" > "$T/proc/$1/stat"; ln -s "$4" "$T/proc/$1/cwd"; }
mkdir -p "$T/proc/sys/kernel/random"
echo "boot-1" > "$T/proc/sys/kernel/random/boot_id"
mkproc 100 t3code 1 /srv
mkproc 200 claude 100 /wt/run
mkproc 201 "bash -c (x)" 200 /wt/run
mkproc 202 sleep 201 /wt/run
mkproc 210 claude 100 /wt/other
mkproc 300 bash 1 /wt/run
mkproc 301 cloudflared 100 /srv
mkproc 400 t3code 1 /srv 777
mkproc 410 claude 400 /wt/run
mkdir -p "$T/userdata/provider-processes"
echo '{"version":1,"instanceId":"a","owner":{"pid":100,"startTime":"boot-1:100"},"processes":[{"pid":200,"startTime":"boot-1:200","pgid":200},{"pid":210,"startTime":"boot-1:210","pgid":210}]}' > "$T/userdata/provider-processes/a.json"
echo '{"version":1,"instanceId":"dead","owner":{"pid":999,"startTime":"boot-1:1"},"processes":[{"pid":300,"startTime":"boot-1:300","pgid":300}]}' > "$T/userdata/provider-processes/dead.json"
echo '{"version":1,"instanceId":"reused","owner":{"pid":400,"startTime":"boot-1:5"},"processes":[{"pid":410,"startTime":"boot-1:410","pgid":410}]}' > "$T/userdata/provider-processes/reused.json"

export T3_SEND_BIN="$T/t3" T3_SEND_PROJECT="$T" STUB_LIST="$T/list.json" STUB_DIR="$T" T3_USERDATA="$T/userdata" T3_PROC="$T/proc"

expect_rc "a healthy list exits 0" 0 bash "$LIST"
expect_jq "every thread is listed" '[.threads[].threadId]' '["t-run","t-wait","t-reply","t-blk","t-set"]'
expect_jq "a running thread is running" '.threads[0] | [.state, .waitingOn]' '["running",null]'
expect_jq "a thread blocked on another thread waits on a thread" '.threads[1] | [.state, .waitingOn]' '["waiting","thread"]'
expect_jq "an unsettled finished thread waits on a reply" '.threads[2] | [.state, .waitingOn]' '["waiting","reply"]'
expect_jq "an errored thread is blocked" '.threads[3].state' '"blocked"'
expect_jq "a settled thread is settled" '.threads[4].state' '"settled"'
expect_jq "a row carries its title, provider, PR count and background tasks" '.threads[0] | [.title, .provider, .model, .pullRequests, .backgroundTasks]' '["Build the thing","claudeAgent","claude-opus-5-5",1,1]'
expect_jq "a row carries its creation and last-update times" '.threads[0] | [.createdAt, .updatedAt] | map(type)' '["string","string"]'
expect_jq "the provider, its shell and the shell's child are owned; the server's own cloudflared and an unrelated shell are not" '[.owned[].pid] | sort' '[200,201,202,210]'
expect_jq "a process whose cwd is a thread's worktree belongs to that thread" '[.owned[] | select(.pid == 202) | .thread]' '["t-run"]'
expect_jq "a process in no thread's worktree is owned with no thread" '[.owned[] | select(.pid == 210) | .thread]' '[null]'
expect_jq "a thread lists the pids it owns" '.threads[0].pids | sort' '[200,201,202]'

jq -c '. + [{"threadId":"t-twin","title":"Same checkout","status":"idle","settled":false,"blockedOnThreadWait":false,"createdAt":.[0].createdAt,"updatedAt":.[0].updatedAt}]' "$T/list.json" > "$T/twin.json"
echo '{"thread":{"threadId":"t-twin","worktreePath":"/wt/run"},"messages":[]}' > "$T/show-t-twin.json"
STUB_LIST="$T/twin.json" expect_rc "two threads sharing one worktree still list" 0 bash "$LIST"
expect_jq "a process in a worktree two threads share belongs to neither" '[.owned[] | select(.pid == 202) | .thread]' '[null]'
expect_jq "a registry record whose owner pid was reused by another process owns nothing" '[.owned[].pid] | index(410)' 'null'

echo '[]' > "$T/empty.json"
STUB_LIST="$T/empty.json" expect_rc "an empty list exits 0" 0 bash "$LIST"
expect_jq "an empty list has no threads, and every owned pid has thread null" '[.threads, ([.owned[].thread] | unique)]' '[[],[null]]'

echo 'not json' > "$T/bad.json"
STUB_LIST="$T/bad.json" expect_rc "a list that is not JSON exits 2" 2 bash "$LIST"
T3_SEND_BIN="$T/missing" expect_rc "a missing t3 CLI exits 2" 2 bash "$LIST"
T3_USERDATA="$T/none" expect_rc "no provider registry still lists the threads" 0 bash "$LIST"
expect_jq "no provider registry owns no pids" '.owned' '[]'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
