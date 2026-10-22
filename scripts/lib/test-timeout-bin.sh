#!/usr/bin/env bash
# scripts/lib/test-timeout-bin.sh — tests for scripts/lib/timeout-bin.sh
#. Hermetic: every PATH is a stub dir; nothing touches the host's
# real timeout except T1, which needs a GNU one to prove the bound still bites.
#
#   T1  GNU timeout present -> resolved, and a sleeping child IS killed (rc 124)
#   T2  neither timeout nor gtimeout -> empty + ONE stderr note; the
#       `${_TIMEOUT_BIN:+...}` idiom then runs the child unbounded
#   T3  only gtimeout (the macOS+brew shape) -> gtimeout is resolved
#   T4  a non-GNU `timeout` (Windows timeout.exe shape: --version fails) is
#       rejected, and does not shadow a working gtimeout behind it
#   T5  sourcing under `set -u` with an empty PATH does not error
#   T6  a relative PATH dir is stored ABSOLUTE (survives a cd); a shell function
#       named timeout (command -v prints a bare name) is rejected

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBF="$SCRIPT_DIR/timeout-bin.sh"
BASH_BIN="$(command -v bash)"   # absolute: the stub PATHs below hold no bash

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-timeout-bin.XXXXXX")" || exit 1; trap 'rm -rf "$W"' EXIT

# stub_dir <name> [tool ...] — a dir holding symlinks to just <tool>s (found on
# the REAL path, resolved before PATH is replaced).
stub_dir() {
    local d="$W/$1" t p; shift
    mkdir -p "$d"
    for t in "$@"; do
        p="$(command -v "$t")" && ln -sf "$p" "$d/$t"
    done
    printf '%s' "$d"
}
# fake_gnu <dir> <name> — a stub that claims GNU coreutils on --version and
# otherwise runs its command (dropping the leading duration).
fake_gnu() {
    cat > "$1/$2" <<'EOF'
#!/bin/sh
case "$1" in --version) echo "timeout (GNU coreutils) 9.5"; exit 0 ;; esac
shift
exec "$@"
EOF
    chmod +x "$1/$2"
}

# resolve <PATH> — print "<_TIMEOUT_BIN>|<stderr>" from a fresh shell on that PATH.
resolve() {
    local p="$1" err
    err="$W/err.$$"
    # shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
    PATH="$p" "$BASH_BIN" -c '. "$1"; printf "%s" "$_TIMEOUT_BIN"' _ "$LIBF" 2>"$err"
    printf '|%s' "$(cat "$err")"
}

echo "[test-timeout-bin] T1 GNU timeout present: resolved AND still bounds a sleeper"
if timeout --version >/dev/null 2>&1 && [ "$(dirname "$(command -v timeout)")" != "$SCRIPT_DIR/shims" ]; then
    real="$(dirname "$(command -v timeout)")"
    d1="$(stub_dir t1 sleep)"
    got="$(resolve "$d1:$real")"
    case "${got%%|*}" in */timeout) ok "T1 resolved a timeout path (${got%%|*})" ;; *) bad "T1 resolved [$got]" ;; esac
    eq "T1 no stderr note when resolved" "${got#*|}" ""
    rc=0
    # shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
    PATH="$d1:$real" "$BASH_BIN" -c '. "$1"; ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 1} sleep 30' _ "$LIBF" 2>/dev/null || rc=$?
    eq "T1 sleeping child killed by the bound (rc 124)" "$rc" "124"
else
    echo "  SKIP T1: no real GNU timeout on this host (absent, or only the portable shim, whose env-bash shebang needs a PATH T1 does not give it)"
fi

echo "[test-timeout-bin] T2 no timeout/gtimeout: empty, one note, idiom runs unbounded"
d2="$(stub_dir t2 sleep)"
got="$(resolve "$d2")"
eq "T2 _TIMEOUT_BIN empty" "${got%%|*}" ""
case "${got#*|}" in *"no GNU 'timeout'/'gtimeout'"*) ok "T2 stderr note names the miss" ;; *) bad "T2 note missing: [${got#*|}]" ;; esac
eq "T2 exactly one note line" "$(printf '%s\n' "${got#*|}" | grep -c .)" "1"
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
PATH="$d2" "$BASH_BIN" -c '. "$1"; ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 1} sleep 0' _ "$LIBF" 2>/dev/null || rc=$?
eq "T2 idiom ran the child unbounded (rc 0, not 127)" "$rc" "0"

echo "[test-timeout-bin] T3 only gtimeout (macOS + brew coreutils)"
d3="$(stub_dir t3)"; fake_gnu "$d3" gtimeout
got="$(resolve "$d3")"
eq "T3 resolved gtimeout" "${got%%|*}" "$d3/gtimeout"

echo "[test-timeout-bin] T4 a non-GNU timeout is rejected, gtimeout behind it wins"
d4="$(stub_dir t4)"; fake_gnu "$d4" gtimeout
printf '#!/bin/sh\nexit 1\n' > "$d4/timeout"; chmod +x "$d4/timeout"
got="$(resolve "$d4")"
eq "T4 resolved gtimeout, not the fake timeout.exe" "${got%%|*}" "$d4/gtimeout"
d4b="$(stub_dir t4b)"; printf '#!/bin/sh\nexit 1\n' > "$d4b/timeout"; chmod +x "$d4b/timeout"
got="$(resolve "$d4b")"
eq "T4 a lone non-GNU timeout resolves to nothing" "${got%%|*}" ""

echo "[test-timeout-bin] T5 sourcing under set -u with an empty PATH"
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
out="$(PATH="$W/nonexistent" "$BASH_BIN" -c 'set -u; . "$1"; printf "[%s]" "$_TIMEOUT_BIN"' _ "$LIBF" 2>/dev/null)" || rc=$?
eq "T5 rc 0" "$rc" "0"
eq "T5 empty" "$out" "[]"

echo "[test-timeout-bin] T6 relative PATH dir: stored ABSOLUTE, survives a cd; a shell function is not a binary"
d6="$W/t6"; mkdir -p "$d6/bin"; fake_gnu "$d6/bin" timeout
d6t="$(stub_dir t6tools cat)"; mkdir -p "$d6/elsewhere"
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
out="$(cd "$d6" && PATH="bin:$d6t" "$BASH_BIN" -c '. "$1"; printf "%s" "$_TIMEOUT_BIN"; cd "$2"; "$_TIMEOUT_BIN" 5 cat /dev/null' _ "$LIBF" "$d6/elsewhere" 2>/dev/null)" || rc=$?
case "$out" in /*/t6/bin/timeout) ok "T6 relative PATH result stored as an absolute path ($out)" ;; *) bad "T6 stored [$out]" ;; esac
eq "T6 the stored path still runs after a cd (rc 0, not 127)" "$rc" "0"
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
out="$(PATH="$d2" "$BASH_BIN" -c 'timeout() { [ "$1" = "--version" ]; }; . "$1"; printf "[%s]" "$_TIMEOUT_BIN"' _ "$LIBF" 2>/dev/null)"
eq "T6 a shell function named timeout is rejected" "$out" "[]"

echo "[test-timeout-bin] T7 portable fallback (macOS shape: no timeout, no gtimeout) puts a bash timeout on PATH"
PORTF="$SCRIPT_DIR/portable-timeout.sh"
d7="$(stub_dir t7 env bash sleep awk mktemp rm cat pkill sh)"
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
got="$(PATH="$d7" "$BASH_BIN" -c '. "$1"; command -v timeout; timeout --version >/dev/null; echo "ver=$?"' _ "$PORTF" 2>&1)"
case "$got" in */shims/timeout*ver=0) ok "T7 timeout resolves to the shim and answers --version" ;; *) bad "T7 got [$got]" ;; esac
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
got="$(PATH="$d7" "$BASH_BIN" -c '. "$1"; . "$2"; printf "%s" "$_TIMEOUT_BIN"' _ "$PORTF" "$LIBF" 2>/dev/null)"
case "$got" in */shims/timeout) ok "T7 timeout-bin.sh resolves the shim afterwards" ;; *) bad "T7 timeout-bin got [$got]" ;; esac
t0=$SECONDS; rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
PATH="$d7" "$BASH_BIN" -c '. "$1"; timeout 1 sleep 30' _ "$PORTF" >/dev/null 2>&1 || rc=$?
eq "T7 a sleeper is killed by the bound (rc 124)" "$rc" "124"
if [ $((SECONDS - t0)) -lt 10 ]; then ok "T7 the bound fired in time"; else bad "T7 the bound took $((SECONDS - t0))s"; fi
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
PATH="$d7" "$BASH_BIN" -c '. "$1"; timeout 5 sh -c "exit 3"' _ "$PORTF" >/dev/null 2>&1 || rc=$?
eq "T7 the command's own exit status passes through" "$rc" "3"
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
PATH="$d7" "$BASH_BIN" -c '. "$1"; timeout 5 /nonexistent/cmd' _ "$PORTF" >/dev/null 2>&1 || rc=$?
eq "T7 a missing command is rc 127" "$rc" "127"
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
PATH="$d7" "$BASH_BIN" -c '. "$1"; timeout -k 1 1 sh -c "trap \"\" TERM; sleep 30"' _ "$PORTF" >/dev/null 2>&1 || rc=$?
eq "T7 -k escalates to KILL for a TERM-ignoring child (rc 137)" "$rc" "137"
t0=$SECONDS
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
PATH="$d7" "$BASH_BIN" -c '. "$1"; out="$(timeout 1 sh -c "sleep 30 & wait")"' _ "$PORTF" >/dev/null 2>&1 || true
if [ $((SECONDS - t0)) -lt 10 ]; then ok "T7 a grandchild holding stdout does not outlive the bound"; else bad "T7 command substitution hung $((SECONDS - t0))s"; fi
d7b="$(stub_dir t7b)"; fake_gnu "$d7b" timeout
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
got="$(PATH="$d7b" "$BASH_BIN" -c '. "$1"; printf "%s" "$PATH"' _ "$PORTF" 2>/dev/null)"
eq "T7 a host with a real timeout keeps its PATH untouched" "$got" "$d7b"
d7c="$(stub_dir t7c env bash sleep awk mktemp rm cat pkill sh)"; fake_gnu "$d7c" gtimeout
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
got="$(PATH="$d7c" "$BASH_BIN" -c '. "$1"; command -v timeout' _ "$PORTF" 2>&1)"
case "$got" in */shims/timeout) ok "T7 a gtimeout-only host still gets a bare timeout (the suites call it bare)" ;; *) bad "T7 gtimeout-only got [$got]" ;; esac
t7sig="$W/t7-sig.sh"
# shellcheck disable=SC2016 # single quotes intentional: the script body is expanded by the child shell
printf '%s\n' \
    '. "$1"' \
    'timeout -k 1 60 sh -c '"'"'echo $$ > "$1"; trap "" TERM; sleep 30'"'"' _ "$2" &' \
    'tp=$!' \
    'i=0; while [ ! -s "$2" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done' \
    'kill -s TERM "$tp"' \
    'wait "$tp"' >"$t7sig"
t7pid="$W/t7-child.pid"; rm -f "$t7pid"
t0=$SECONDS
PATH="$d7" "$BASH_BIN" "$t7sig" "$PORTF" "$t7pid" >/dev/null 2>&1 || true
if [ -s "$t7pid" ] && ! kill -0 "$(cat "$t7pid")" 2>/dev/null; then ok "T7 a TERM sent to the wrapper still runs the -k escalation (TERM-ignoring child gone)"; else bad "T7 a TERM-ignoring child outlived a TERM sent to the wrapper"; fi
[ ! -s "$t7pid" ] || kill -s KILL "$(cat "$t7pid")" 2>/dev/null || true
if [ $((SECONDS - t0)) -lt 20 ]; then ok "T7 the wrapper returned in time after the TERM"; else bad "T7 the wrapper hung $((SECONDS - t0))s after the TERM"; fi
t7fg="$W/t7-fg.sh"
# shellcheck disable=SC2016 # single quotes intentional: the script body is expanded by the child shell
printf '%s\n' \
    '. "$1"' \
    'timeout --foreground -k 1 60 sh -c '"'"'echo $$ > "$1"; trap "" TERM; sleep 30'"'"' _ "$2" &' \
    'tp=$!' \
    'i=0; while [ ! -s "$2" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done' \
    'kill -s TERM "$tp"' \
    'wait "$tp"' >"$t7fg"
rm -f "$t7pid"
t0=$SECONDS
PATH="$d7" "$BASH_BIN" "$t7fg" "$PORTF" "$t7pid" >/dev/null 2>&1 || true
if [ -s "$t7pid" ] && ! kill -0 "$(cat "$t7pid")" 2>/dev/null; then ok "T7 --foreground: a TERM sent to the wrapper still runs the -k escalation"; else bad "T7 --foreground: a TERM-ignoring child outlived a TERM sent to the wrapper"; fi
[ ! -s "$t7pid" ] || kill -s KILL "$(cat "$t7pid")" 2>/dev/null || true
if [ $((SECONDS - t0)) -lt 20 ]; then ok "T7 --foreground: the wrapper returned in time after the TERM"; else bad "T7 --foreground: the wrapper hung $((SECONDS - t0))s after the TERM"; fi
d7e="$(stub_dir t7e env bash sleep awk mktemp rm cat pkill sh)"
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
got="$(echo hello | PATH="$d7e" "$BASH_BIN" -c '. "$1"; timeout --foreground 5 cat' _ "$PORTF" 2>&1)"
eq "T7 --foreground hands the caller's stdin to the command" "$got" "hello"
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
PATH="$d7e" "$BASH_BIN" -c '. "$1"; timeout -s BOGUS 5 sh -c "exit 0"' _ "$PORTF" >/dev/null 2>&1 || rc=$?
eq "T7 an invalid --signal is a usage error (rc 125)" "$rc" "125"
t7ic="$W/t7-int-child.sh"
# shellcheck disable=SC2016 # single quotes intentional: the child body is expanded by the child shell
printf '%s\n' 'echo $$ > "$1"' 'trap "" TERM' 'trap "exit 0" INT' 'while :; do sleep 1; done' >"$t7ic"
t7int="$W/t7-int.sh"
# shellcheck disable=SC2016 # single quotes intentional: the script body is expanded by the child shell
printf '%s\n' \
    'set -m' \
    '. "$1"' \
    'timeout -k 2 60 sh "$3" "$2" &' \
    'tp=$!' \
    'i=0; while [ ! -s "$2" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done' \
    'kill -s INT "$tp"' \
    'wait "$tp"; echo "rc=$?"' >"$t7int"
rm -f "$t7pid"
got="$(PATH="$d7" "$BASH_BIN" "$t7int" "$PORTF" "$t7pid" "$t7ic" 2>/dev/null)"
[ ! -s "$t7pid" ] || kill -s KILL "$(cat "$t7pid")" 2>/dev/null || true
eq "T7 an INT sent to the wrapper reaches the command as INT (its handler ran, rc 0, not a KILL)" "$got" "rc=0"
d7d="$(stub_dir t7d env bash sleep awk mktemp rm cat pkill sh ps)"
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1
got="$(PATH="$d7d" "$BASH_BIN" -c '. "$1"; mine="$(ps -o pgid= -p $$)"; fg="$(timeout --foreground 5 sh -c "ps -o pgid= -p \$\$")"; bg="$(timeout 5 sh -c "ps -o pgid= -p \$\$")"; a=differ; [ "${mine// /}" = "${fg// /}" ] && a=same; b=differ; [ "${mine// /}" = "${bg// /}" ] && b=same; echo "fg=$a plain=$b"' _ "$PORTF" 2>&1)"
eq "T7 --foreground keeps the command in the caller's process group, plain does not" "$got" "fg=same plain=differ"
for iv in . 1h2 1ss h; do
    rc=0
    # shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$2
    PATH="$d7" "$BASH_BIN" -c '. "$1"; timeout "$2" sh -c "exit 0"' _ "$PORTF" "$iv" >/dev/null 2>&1 || rc=$?
    eq "T7 a malformed interval [$iv] is a usage error (rc 125)" "$rc" "125"
done
for iv in .5 2s 1m 0; do
    rc=0
    # shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$2
    PATH="$d7" "$BASH_BIN" -c '. "$1"; timeout "$2" sh -c "exit 0"' _ "$PORTF" "$iv" >/dev/null 2>&1 || rc=$?
    eq "T7 a valid interval [$iv] runs the command (rc 0)" "$rc" "0"
done

echo "[test-timeout-bin] $pass passed, $fail failed"
[ "$fail" -eq 0 ]
