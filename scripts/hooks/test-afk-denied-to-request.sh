#!/usr/bin/env bash
# shellcheck disable=SC2015 # compact status assertions
# Suite for scripts/hooks/afk-denied-to-request.sh: a Bash call the auto-mode
# classifier refused files ONE run-kind request through `afk-run --no-wait --blocked-by
# classifier`, carrying the refused call's exact argv, only while the root helper's `mode`
# answers enabled=true and run_enabled=true. Nothing runs at filing, the hook prints nothing and
# exits 0 on every path. A fake `sudo` on PATH stands in for the root helper and logs each call.
# env: HOOK overrides the hook under test (RED run against a tree without it).
#
# bash 3.2-safe.
set -uo pipefail
unset AFK_DENIED_TO_REQUEST_OFF

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK:-$HERE/afk-denied-to-request.sh}"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/afk-denied.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/scripts/hooks" "$T/repo/scripts/lib" "$T/bin" "$T/calls" || exit 1
cp "$HOOK" "$T/repo/scripts/hooks/afk-denied-to-request.sh" 2>/dev/null
cp "$HERE/../lib/git-clean.sh" "$T/repo/scripts/lib/git-clean.sh" || exit 1
cp "$HERE/../lib/afk-run" "$T/repo/scripts/lib/afk-run" || exit 1
H="$T/repo/scripts/hooks/afk-denied-to-request.sh"
# Fake sudo: refuses when $T/mode is absent (helper not installed or sudo refused). Otherwise it
# logs the verb to $T/verbs and the full argv, NUL-separated, to $T/calls/<verb>; it answers
# `mode` from $T/mode and `run-request` with pending, or busy while $T/busy exists.
cat > "$T/bin/sudo" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "-n /usr/local/libexec/himmel/afk-sudo" ] || exit 1
[ -r "$T/mode" ] || { echo "sudo: a password is required" >&2; exit 1; }
shift 2
printf '%s\n' "\$1" >> "$T/verbs"
printf '%s\0' "\$@" > "$T/calls/\$1"
case "\$1" in
    mode) cat "$T/mode" ;;
    run-request) if [ -e "$T/busy" ]; then echo "result=busy"; else echo "result=pending id=abcdefgh expires=9 operator=1"; fi ;;
    *) echo "result=bad-verb" ;;
esac
EOF
chmod +x "$T/bin/sudo"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/systemctl"
chmod +x "$T/bin/systemctl"
git init -q -b fix/demo-77-x "$T/wt" || exit 1
mkdir -p "$T/nobranch"
ON='result=mode mode=afk enabled=true run_enabled=true'
setmode() { if [ -n "$1" ]; then printf '%s\n' "$1" > "$T/mode"; else rm -f "$T/mode"; fi; }
reset() { rm -f "$T/verbs" "$T/busy" "$T/calls/"*; }

# run <tool> <command> [cwd]: feeds a PermissionDenied payload; sets OUT (stdout) and RC.
run() {
    reset
    OUT="$(jq -cn --arg tool "$1" --arg cmd "$2" --arg cwd "${3:-$T/wt}" \
        '{hook_event_name:"PermissionDenied",session_id:"S-1",transcript_path:"/dev/null",cwd:$cwd,permission_mode:"auto",tool_name:$tool,tool_input:{command:$cmd,description:"d"},tool_use_id:"toolu_1",reason:"Auto-Mode Bypass"}' \
        | PATH="$T/bin:$PATH" TELEGRAM_ENV="$T/no-bridge.env" AFK_RUN_WAIT_S=1 AFK_RUN_POLL_S=1 AFK_RUN_BUSY_EVERY_S=1 \
            bash "$H" 2>/dev/null)"
    RC=$?
}
requests() { cat "$T/verbs" 2>/dev/null | grep -c '^run-request$'; }
# filed_argv: the run-request argv the helper got, one '|' after each element.
filed_argv() { [ -r "$T/calls/run-request" ] && tr '\0' '|' < "$T/calls/run-request"; }
# files <label> <tool> <command> <expected argv after --, '|'-joined> [cwd] [ticket]
files() {
    local label="$1" want
    want="run-request|--session|S-1|--ticket|${6:-DEMO-77}|--blocked-by|classifier|--cwd|${5:-$T/wt}|--why|Auto-Mode Bypass|--|$4"
    run "$2" "$3" "${5:-$T/wt}"
    if [ "$(requests)" = 1 ] && [ "$(filed_argv)" = "$want" ]; then ok "$label"; else bad "$label (requests=$(requests) got: $(filed_argv))"; fi
}
# quiet <label> <tool> <command>: no run-request, no stdout, exit 0.
quiet() {
    run "$2" "$3"
    if [ "$(requests)" = 0 ] && [ -z "$OUT" ] && [ "$RC" = 0 ]; then ok "$1"; else bad "$1 (requests=$(requests) rc=$RC out=$OUT)"; fi
}

echo "== run kind on: a refused Bash call files one request with its exact argv =="
setmode "$ON"
files "RED: a refused plain command files one classifier request as its own argv" \
    Bash "systemctl restart nginx" "systemctl|restart|nginx|"
files "a command with shell syntax files as bash -c with its exact bytes" \
    Bash "ls /root | head -1" "bash|-c|ls /root | head -1|"
files "a trailing newline is kept byte for byte" \
    Bash $'echo hi\n' "bash|-c|echo hi
|"
files "a leading assignment files as bash -c" \
    Bash "FOO=bar env" "bash|-c|FOO=bar env|"
files "a shell builtin files as bash -c" \
    Bash "cd /work" "bash|-c|cd /work|"
files "no ticket in the branch names ticket none" \
    Bash "id" "id|" "$T/nobranch" none
run Bash "systemctl restart nginx"
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "filing prints nothing and exits 0" || bad "filing prints nothing and exits 0 (rc=$RC out=$OUT)"
[ "$(tr '\n' ' ' 2>/dev/null < "$T/verbs")" = "mode run-request " ] && ok "nothing runs: no approve, no poll, only mode and one run-request" \
    || bad "nothing runs (verbs: $(tr '\n' ' ' 2>/dev/null < "$T/verbs"))"

echo "== busy: nothing filed, no retry loop, no output =="
reset; : > "$T/busy"
OUT="$(jq -cn '{session_id:"S-1",cwd:"'"$T/wt"'",tool_name:"Bash",tool_input:{command:"id"},reason:"r"}' \
    | PATH="$T/bin:$PATH" TELEGRAM_ENV="$T/no-bridge.env" AFK_RUN_WAIT_S=3 AFK_RUN_BUSY_EVERY_S=1 bash "$H" 2>/dev/null)"
RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ "$(requests)" = 1 ] && ok "a busy helper is asked once; no output, exit 0" \
    || bad "a busy helper is asked once (requests=$(requests) rc=$RC out=$OUT)"

echo "== everything else files nothing =="
quiet "a non-Bash tool" Edit "x"
quiet "an empty command" Bash ""
quiet "a refused afk-run call is never turned into a request" Bash "bash scripts/lib/afk-run --session S --ticket T --blocked-by classifier -- id"
quiet "a refused afk-run wait is never turned into a request" Bash "/opt/himmel/scripts/lib/afk-run wait abcdefgh"
quiet "afk-run after a separator is never turned into a request" Bash "cd /w && ./scripts/lib/afk-run --session S --ticket T --blocked-by classifier -- id"
setmode 'result=mode mode=afk enabled=true run_enabled=false'
quiet "run kind off" Bash "id"
setmode 'result=mode mode=present enabled=false run_enabled=true'
quiet "station off" Bash "id"
setmode ''
quiet "helper absent or sudo refused" Bash "id"
setmode "$ON"
reset
jq -cn '{session_id:"S-1",tool_name:"Bash",tool_input:{command:"id"}}' > "$T/in.json"
OUT="$(AFK_DENIED_TO_REQUEST_OFF=1 PATH="$T/bin:$PATH" bash "$H" < "$T/in.json" 2>/dev/null)"
RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$T/verbs" ] && ok "the bypass makes no helper call" || bad "the bypass makes no helper call (rc=$RC out=$OUT)"
OUT="$(printf 'not json' | PATH="$T/bin:$PATH" bash "$H" 2>/dev/null; echo "rc=$?")"
[ "$OUT" = "rc=0" ] && ok "unparseable input fails open" || bad "unparseable input fails open (got: $OUT)"

echo
echo "afk-denied-to-request: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
