#!/usr/bin/env bash
# temporary diagnostic: how does this host's script(1) behave with no tty?
set -u
echo "uname: $(uname -a)"; command -v sw_vers >/dev/null 2>&1 && sw_vers
echo "script path: $(command -v script)"
echo "tty: $(tty 2>&1)"
T=$(mktemp -d "${TMPDIR:-/tmp}/zzdiag.XXXXXX") || exit 1
run() {
    local label=$1; shift
    "$@" > "$T/out" 2> "$T/err"; local rc=$?
    echo "== $label: rc=$rc out=[$(tr '\n' '|' < "$T/out" | cut -c1-200)] err=[$(tr '\n' '|' < "$T/err" | cut -c1-300)]"
}
run "script -q devnull-stdin true" script -q /dev/null true </dev/null
run "script -qe devnull-stdin true" script -qe /dev/null true </dev/null
run "script -q devnull-stdin echo" script -q /dev/null sh -c 'echo hi' </dev/null
mkfifo "$T/f"; exec 3<>"$T/f"
run "script -q fifo-stdin echo" script -q /dev/null sh -c 'echo hi' <&3
run "script -q file-arg real-file" script -q "$T/typescript" sh -c 'echo hi' <&3
run "script -q stdin-from-pipe" sh -c 'sleep 1 | script -q /dev/null sh -c "echo hi"'
command -v python3 >/dev/null && run "python pty.spawn fifo stdin" python3 -c 'import pty,sys; sys.exit(pty.spawn(["sh","-c","echo hi; test -t 0 && echo tty0"])>>8)' <&3
rm -rf "$T"
echo "FAIL diag finished on purpose to surface the output"
exit 1
