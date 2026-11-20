#!/usr/bin/env bash
# scripts/t3/test-t3-send.sh - fixture suite for t3-send.sh.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SEND="$HERE/t3-send.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/t3send-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect_rc() { local n="$1" want="$2" rc; shift 2; "$@" >"$T/out" 2>"$T/err"; rc=$?; if [ "$rc" = "$want" ]; then ok "$n"; else bad "$n (rc=$rc)"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2)"; fi; }
expect_in() { if grep -q -- "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }

cat > "$T/t3" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "thread list") cat "$STUB_LIST" ;;
  "thread send") echo "$*" >> "$STUB_LOG"; cat > "$STUB_STDIN"
                 [ "${STUB_SEND_RC:-0}" = 0 ] || { echo "send boom" >&2; exit "$STUB_SEND_RC"; } ;;
esac
STUB
chmod +x "$T/t3"
cat > "$T/list.json" <<'JSON'
[{"threadId":"id-a","title":"alpha-chief","status":"idle","settled":false},
 {"threadId":"id-b","title":"  dup thread ","status":"idle","settled":false},
 {"threadId":"id-c","title":"dup thread","status":"running","settled":false}]
JSON
export T3_SEND_BIN="$T/t3" T3_SEND_PROJECT="$T" STUB_LIST="$T/list.json" STUB_LOG="$T/log" STUB_STDIN="$T/stdin"
printf 'hello chief\n' > "$T/msg"

expect_rc "id hit exits 0" 0 bash "$SEND" id-a "$T/msg"
expect_in "id hit prints sent line" "^sent id-a (alpha-chief)$" "$T/out"
expect_eq "send called with id and -" "$(cat "$T/log")" "thread send id-a -"
expect_eq "message file passed on stdin" "$(cat "$T/stdin")" "hello chief"

: > "$T/log"
expect_rc "exact title hit exits 0" 0 bash "$SEND" "  alpha-chief " "$T/msg"
expect_eq "title resolved to its id" "$(cat "$T/log")" "thread send id-a -"
expect_rc "partial title is not a hit" 4 bash "$SEND" "alpha" "$T/msg"

: > "$T/log"
expect_rc "ambiguous title exits 3" 3 bash "$SEND" "dup thread" "$T/msg"
expect_in "ambiguous lists first id" "id-b" "$T/err"
expect_in "ambiguous lists second id with status" "id-c  \[running\]" "$T/err"
expect_eq "ambiguous sends nothing" "$(cat "$T/log")" ""

expect_rc "missing title exits 4" 4 bash "$SEND" "no such" "$T/msg"
expect_in "missing title says so" "no thread titled 'no such'" "$T/err"
expect_rc "unreadable msg file exits 2" 2 bash "$SEND" id-a "$T/nope"
expect_rc "no args exits 2" 2 bash "$SEND"

mkdir "$T/msgdir"
: > "$T/log"
expect_rc "msg-file that is a directory exits 2" 2 bash "$SEND" id-a "$T/msgdir"
expect_eq "directory msg-file sends nothing" "$(cat "$T/log")" ""

printf 'from stdin\n' | bash "$SEND" id-a - >"$T/out" 2>&1; rc=$?
expect_eq "stdin dash exits 0" "$rc" 0
expect_eq "stdin body forwarded" "$(cat "$T/stdin")" "from stdin"

STUB_SEND_RC=7 bash "$SEND" id-a "$T/msg" >"$T/out" 2>"$T/err"; rc=$?
expect_eq "CLI failure exits 1" "$rc" 1
expect_in "CLI stderr passes through" "send boom" "$T/err"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
