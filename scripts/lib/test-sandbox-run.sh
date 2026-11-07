#!/usr/bin/env bash
# real filesystem boundary, not assertions about bwrap flags.
# Regression: dropping the read-only root lets the executing canary row escape.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT/scripts/lib/sandbox-run.sh"
TMP="$(mktemp -d /tmp/sandbox-run-test.XXXXXX)" || exit 1
trap '[ -z "${churn_pid:-}" ] || kill "$churn_pid" 2>/dev/null; [ -z "${listener_pid:-}" ] || kill "$listener_pid" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# The Darwin dependency is unavailable on Linux: intercept only that boundary.
# These controls catch wrong dispatch, unconfined fallback and profile setup
# failures; the stub never executes the payload. Real OS controls follow below.
mkdir -p "$TMP/darwin-bin"
printf '#!/bin/bash\nprintf "Darwin\\n"\n' > "$TMP/darwin-bin/uname"
chmod +x "$TMP/darwin-bin/uname"
OUT=$(PATH="$TMP/darwin-bin" /bin/bash "$RUNNER" -- /usr/bin/true 2>&1); RC=$?
if [ "$RC" = 125 ] && [[ "$OUT" == *'sandbox-exec is required'* ]]; then
    ok 'Darwin missing sandbox-exec fails closed'
else bad "Darwin missing dependency: rc=$RC $OUT"; fi
{
    printf '#!/bin/bash\nPROFILE_LOG=%q\nCALL_LOG=%q\n' "$TMP/darwin-profile" "$TMP/darwin-calls"
    cat <<'STUB'
set -uo pipefail
[ "$1" = -f ] && [ -f "$2" ] && [ "$3" = -D ] || exit 64
cp "$2" "$PROFILE_LOG"
case "$4" in SCRATCH=/*) ;; *) exit 64 ;; esac
printf '%s\n' "$4" >> "$CALL_LOG"
shift 4
[ "$1" = -- ] || exit 64
shift
if [ "$1" = /usr/bin/true ]; then exit 0; fi
printf 'DARWIN_PAYLOAD_STARTED\n'
exit 2
STUB
} > "$TMP/darwin-bin/sandbox-exec"
chmod +x "$TMP/darwin-bin/sandbox-exec"
OUT=$(PATH="$TMP/darwin-bin:$PATH" bash "$RUNNER" -- /usr/bin/false 2>&1); RC=$?
if [ "$RC" = 2 ] && [[ "$OUT" == *DARWIN_PAYLOAD_STARTED* ]]; then
    ok 'Darwin sandbox launch preserves payload deny status'
else bad "Darwin sandbox launch: rc=$RC $OUT"; fi
if [ -f "$TMP/darwin-profile" ] && grep -Fq '(deny network*)' "$TMP/darwin-profile" \
    && grep -Fq '(deny file-write*)' "$TMP/darwin-profile" \
    && grep -Fq '(subpath (param "SCRATCH"))' "$TMP/darwin-profile" \
    && grep -Fq '(literal "/dev/null")' "$TMP/darwin-profile"; then
    ok 'Darwin emitted profile denies network and confines writable paths'
else bad 'Darwin confinement profile not passed to sandbox-exec'; fi
# Apple bash 3.2 puts here-document temp files in /private/var/tmp and ignores TMPDIR,
# so the profile lets that directory and its sh-thd names through; a subpath grant would be a hole.
if grep -Fq '(allow file-write* (regex #"^/private/var/tmp(/+sh-thd[-._0-9A-Za-z]*)?$"))' "$TMP/darwin-profile" \
    && ! grep -Eq 'subpath "/(private/)?(var/)?tmp"' "$TMP/darwin-profile" \
    && [ "$(grep -c '^(allow file-write\*' "$TMP/darwin-profile")" -eq 2 ]; then
    ok 'Darwin profile allows only bash 3.2 here-document temp files in /private/var/tmp'
else bad 'Darwin profile misses the narrow here-document temp-file allow (or grants a tmp subpath)'; fi
if [ -f "$TMP/darwin-calls" ] && [ "$(wc -l < "$TMP/darwin-calls")" -eq 2 ]; then
    ok 'Darwin validates profile before payload launch'
else bad 'Darwin profile preflight did not precede payload'; fi
printf '#!/bin/bash\nprintf "PROFILE_UNUSABLE\\n" >&2\nexit 64\n' > "$TMP/darwin-bin/sandbox-exec"
OUT=$(PATH="$TMP/darwin-bin:$PATH" bash "$RUNNER" -- /usr/bin/true 2>&1); RC=$?
if [ "$RC" = 125 ] && [[ "$OUT" == *'profile unusable'* ]]; then
    ok 'Darwin unusable sandbox profile fails closed before payload'
else bad "Darwin unusable profile: rc=$RC $OUT"; fi

# RED control: this harmless corpus row really executes, only in throwaway tmp.
CANARY="$TMP/canary"
printf 'touch %q\n' "$CANARY" > "$TMP/row.sh"
bash "$TMP/row.sh"
if [ ! -e "$CANARY" ]; then
    bad 'unsandboxed canary control did not execute'
else
    printf 'RED control: canary untouched assertion FAILS without sandbox\n'
    ok 'unsandboxed harmless row trips canary check'
fi
rm -f "$CANARY"

if [ ! -f "$RUNNER" ]; then
    bad 'sandbox runner missing: filesystem isolation not implemented'
    exit 1
fi

OUT=$(bash "$RUNNER" --canary "$CANARY" --read-only "$TMP/row.sh" -- bash -c 'echo ROW_STARTED; bash "$1"' _ "$TMP/row.sh" 2>&1); RC=$?
case "$(uname -s)" in
    Darwin) canary_rc=1 ;;  # Seatbelt denies the original host path write.
    *) canary_rc=0 ;;       # Linux writes only its private tmpfs counterpart.
esac
if [ "$RC" = "$canary_rc" ] && [ ! -e "$CANARY" ] && [[ "$OUT" == *ROW_STARTED* ]]; then
    ok 'executing harmless canary row cannot write outside sandbox'
else
    bad "canary boundary: rc=$RC output=$OUT"
fi
# A real Unix socket inode on the host must not cross the bind boundary.
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$TMP/host.sock"
if [ ! -S "$TMP/host.sock" ]; then bad 'host socket control missing'; exit 1; fi
if [ "$(uname -s)" = Darwin ]; then
    OUT=$(bash "$RUNNER" -- python3 -I -c 'import socket,sys; print("CONNECT_STARTED",flush=True); s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])' "$TMP/host.sock" 2>&1); RC=$?
    if [ "$RC" -ne 0 ] && [[ "$OUT" == *CONNECT_STARTED* ]] && [[ "$OUT" == *'Operation not permitted'* ]]; then
        ok 'Darwin denies host Unix socket connection'
    else bad "Darwin host socket permission: rc=$RC $OUT"; fi
    OUT=$(bash "$RUNNER" -- /bin/bash -c 'cat <<<HEREDOC_OK' 2>&1); RC=$?
    if [ "$RC" = 0 ] && [[ "$OUT" == *HEREDOC_OK* ]]; then
        ok 'Darwin system bash can create a here-document inside the sandbox'
    else bad "Darwin here-document temp file: rc=$RC $OUT"; fi
else
    OUT=$(bash "$RUNNER" -- bash -c 'test ! -S "$1"' _ "$TMP/host.sock" 2>&1); RC=$?
    if [ "$RC" = 0 ]; then ok 'host Unix socket absent inside'; else bad "host Unix socket exposed: rc=$RC $OUT"; fi
fi
OUT=$(bash "$RUNNER" -- bash -c 'touch "$HOME/ok" "$TMPDIR/ok"; test -f "$HOME/ok" && test -f "$TMPDIR/ok" && echo WRITABLE' 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ "$OUT" == *WRITABLE* ]]; then ok 'HOME and scratch are writable'; else bad "writable fixtures: $OUT"; fi
OUT=$(bash "$RUNNER" -- bash -c 'echo HOOK_DENY; exit 2' 2>&1); RC=$?
if [ "$RC" = 2 ] && [[ "$OUT" == *HOOK_DENY* ]]; then ok 'hook deny status and output preserved'; else bad "hook status: rc=$RC $OUT"; fi
OUT=$(bash "$RUNNER" -- bash -c 'echo FD_CHECK_STARTED; if { printf leaked >&9; } 2>/dev/null; then exit 1; fi' 9> "$TMP/fd9" 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ "$OUT" == *FD_CHECK_STARTED* ]] && [ ! -s "$TMP/fd9" ]; then
    ok 'caller fd 9 cannot write its host file inside sandbox'
else bad "inherited fd 9: rc=$RC $OUT"; fi
OUT=$(bash "$RUNNER" -- bash -c 'echo FD_CHECK_STARTED; if { printf leaked >&123; } 2>/dev/null; then exit 1; fi' 123> "$TMP/fd123" 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ "$OUT" == *FD_CHECK_STARTED* ]] && [ ! -s "$TMP/fd123" ]; then
    ok 'caller high fd cannot write its host file inside sandbox'
else bad "inherited fd 123: rc=$RC $OUT"; fi
if [ "$(uname -s)" = Linux ]; then
    mkdir -p "$TMP/linux-bin"
    printf '#!/bin/bash\nprintf "Linux\\n"\n' > "$TMP/linux-bin/uname"
    chmod +x "$TMP/linux-bin/uname"
    OUT=$(PATH="$TMP/linux-bin" /bin/bash "$RUNNER" -- /bin/true 2>&1); RC=$?
    if [ "$RC" = 125 ] && [[ "$OUT" == *'bwrap is required'* ]]; then ok 'missing bwrap fails closed'; else bad "missing dependency: rc=$RC $OUT"; fi
fi
OUT=$(SANDBOX_TEST_SECRET=private-fixture bash "$RUNNER" -- bash -c 'printf "%s" "${SANDBOX_TEST_SECRET-unset}"' 2>&1); RC=$?
if [ "$RC" = 0 ] && [ "$OUT" = unset ]; then ok 'ambient environment not inherited'; else bad "environment: rc=$RC $OUT"; fi
OUT=$(bash "$RUNNER" -- python3 -I -c 'import socket; print("NETWORK_STARTED",flush=True); s=socket.socket(); s.settimeout(1); s.connect(("1.1.1.1",443))' 2>&1); RC=$?
case "$(uname -s)" in
    Darwin) network_denial='Operation not permitted' ;;
    *) network_denial='Network is unreachable' ;;
esac
if [ "$RC" -ne 0 ] && [[ "$OUT" == *NETWORK_STARTED* ]] && [[ "$OUT" == *"$network_denial"* ]]; then ok 'sandbox blocks outbound connection'; else bad "network isolation: rc=$RC $OUT"; fi
mkdir "$TMP/readonly"
OUT=$(bash "$RUNNER" --read-only "$TMP/readonly" -- bash -c 'echo WRITE_STARTED; touch "$1/escape"' _ "$TMP/readonly" 2>&1); RC=$?
case "$(uname -s)" in
    Darwin) write_denial='Operation not permitted' ;;
    *) write_denial='Read-only file system' ;;
esac
if [ "$RC" -ne 0 ] && [[ "$OUT" == *WRITE_STARTED* ]] && [[ "$OUT" == *"$write_denial"* ]] && [ ! -e "$TMP/readonly/escape" ]; then
    ok 'explicit fixture bind is read-only'
else bad "fixture bind writable or command did not run: rc=$RC $OUT"; fi
OUT=$(bash "$RUNNER" --read-only "$TMP/host.sock" -- /usr/bin/true 2>&1); RC=$?
if [ "$RC" = 125 ] && [[ "$OUT" == *'refusing socket/device/FIFO input'* ]]; then ok 'socket input refused'; else bad "socket input: rc=$RC $OUT"; fi
if [ "$(uname -s)" = Linux ]; then
# Give the runner a real socket-bearing /etc in an outer namespace, never on
# the station. No dependency mock or production-only injection flag is needed.
mkdir -p "$TMP/runtime/hidden"
touch "$TMP/runtime/hidden/canary"
chmod 111 "$TMP/runtime/hidden"
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$TMP/runtime/host.sock"
OUTER=()
for input in /usr /bin /sbin /lib /lib64; do
    [ ! -e "$input" ] || OUTER+=(--ro-bind "$input" "$input")
done
# Bind the checkout after tmpfs so a checkout under /tmp remains visible.
OUT=$(bwrap "${OUTER[@]}" --ro-bind "$TMP/runtime" /etc \
    --unshare-all --unshare-user --die-with-parent --proc /proc --dev /dev \
    --tmpfs /tmp --ro-bind "$ROOT" "$ROOT" --chdir "$ROOT" -- bash "$RUNNER" -- \
    bash -c 'if test -S /etc/host.sock; then echo RUNTIME_SOCKET_VISIBLE; else echo RUNTIME_MASKED; fi; if test -d /etc/hidden && test ! -e /etc/hidden/canary; then echo HIDDEN_MASKED; else echo HIDDEN_CANARY_VISIBLE; fi' 2>&1); RC=$?
chmod 700 "$TMP/runtime/hidden"
if [ "$RC" = 0 ] && [[ "$OUT" == *RUNTIME_MASKED* ]]; then
    ok 'runtime Unix socket masked'
else bad "runtime socket input: rc=$RC $OUT"; fi
if [ "$RC" = 0 ] && [[ "$OUT" == *HIDDEN_MASKED* ]]; then
    ok 'unreadable runtime directory masked'
else bad "unreadable runtime directory: rc=$RC $OUT"; fi
OUT=$(bash "$RUNNER" -- python3 -I -c 'import resource; assert resource.getrlimit(resource.RLIMIT_AS)==(1073741824,1073741824); assert resource.getrlimit(resource.RLIMIT_CPU)==(60,60); assert resource.getrlimit(resource.RLIMIT_NPROC)==(128,128)' 2>&1); RC=$?
if [ "$RC" = 0 ]; then ok 'child address-space CPU and process limits enforced'; else bad "resource limits: rc=$RC $OUT"; fi

# one validated runtime mask list per run. A stub find logs each
# call, so the rows count runtime walks (the -prune call) instead of timing.
STUBBIN="$TMP/findstub"; FINDLOG="$TMP/finds.log"
mkdir -p "$STUBBIN"
# shellcheck disable=SC2016  # the stub's own variables expand when it runs
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$STUB_FIND_LOG"\nexec /usr/bin/find "$@"\n' > "$STUBBIN/find"
chmod +x "$STUBBIN/find"
walks() { grep -c -- '-prune' "$FINDLOG" 2>/dev/null || true; }
counted() { STUB_FIND_LOG="$FINDLOG" PATH="$STUBBIN:$PATH" "$@"; }
: > "$FINDLOG"
for _ in 1 2 3; do counted bash "$RUNNER" -- /usr/bin/true >/dev/null 2>&1; done
if [ "$(walks)" = 3 ]; then ok 'uncached launches each walk the runtime roots'; else bad "uncached walks: $(walks)"; fi
ML="$TMP/mask-list"
: > "$FINDLOG"
OUT=$(counted bash "$RUNNER" --write-mask-list "$ML" 2>&1); RC=$?
if [ "$RC" = 0 ] && [ -f "$ML" ] && [ "$(walks)" = 1 ] && [ "$(stat -c %a "$ML")" = 600 ]; then # gnu-ok: bwrap suite is Linux only
    ok 'mask list built with one walk, mode 600'
else bad "mask list build: rc=$RC walks=$(walks) $OUT"; fi
: > "$FINDLOG"
cached_rc=0
for _ in 1 2 3; do
    SANDBOX_RUN_MASK_LIST="$ML" counted bash "$RUNNER" -- /usr/bin/true >/dev/null 2>&1 || cached_rc=$?
done
if [ "$cached_rc" = 0 ] && [ "$(walks)" = 0 ]; then ok 'three launches with a valid mask list walk zero times'; else bad "cached launches: rc=$cached_rc walks=$(walks)"; fi
read -r h_magic h_epoch h_uid h_roots h_fp h_cnt < "$ML"
mutated() { # name header-line [mode]
    { printf '%s\n' "$2"; tail -n +2 "$ML"; } > "$TMP/ml.$1"
    chmod "${3:-600}" "$TMP/ml.$1"
}
mutated stale "$h_magic 1 $h_uid $h_roots $h_fp $h_cnt"
mutated future "$h_magic 99999999999 $h_uid $h_roots $h_fp $h_cnt"
mutated roots "$h_magic $h_epoch $h_uid /usr:/bin $h_fp $h_cnt"
mutated magic "bogus $h_epoch $h_uid $h_roots $h_fp $h_cnt"
mutated fp "$h_magic $h_epoch $h_uid $h_roots 0000 $h_cnt"
mutated octal "$h_magic 0000000008 $h_uid $h_roots $h_fp $h_cnt"
mutated count "$h_magic $h_epoch $h_uid $h_roots $h_fp $((h_cnt + 1))"
mutated nocount "$h_magic $h_epoch $h_uid $h_roots $h_fp"
head -c -1 "$ML" > "$TMP/ml.trunc"; chmod 600 "$TMP/ml.trunc"
mutated worldw "$(head -n1 "$ML")" 666
mutated groupw "$(head -n1 "$ML")" 664
ln -s "$ML" "$TMP/ml.link"
for variant in stale future roots magic fp octal count nocount trunc worldw groupw link; do
    : > "$FINDLOG"
    OUT=$(SANDBOX_RUN_MASK_LIST="$TMP/ml.$variant" counted bash "$RUNNER" -- /usr/bin/true 2>&1); RC=$?
    if [ "$RC" = 0 ] && [ "$(walks)" = 1 ]; then ok "untrusted mask list ($variant) rejected, full walk ran"; else bad "mask list $variant: rc=$RC walks=$(walks) $OUT"; fi
done
# A cache this user does not own: the same file seen from another uid.
: > "$FINDLOG"
OUT=$(SANDBOX_RUN_MASK_LIST="$ML" STUB_FIND_LOG="$FINDLOG" PATH="$STUBBIN:$PATH" \
    bwrap "${OUTER[@]}" --ro-bind /etc /etc --ro-bind "$ROOT" "$ROOT" --bind "$TMP" "$TMP" \
    --unshare-all --unshare-user --uid 4242 --gid 4242 --die-with-parent --proc /proc --dev /dev \
    --chdir "$ROOT" -- bash "$RUNNER" -- /usr/bin/true 2>&1); RC=$?
if [ "$RC" = 0 ] && [ "$(walks)" = 1 ]; then ok 'mask list owned by another uid rejected, full walk ran'; else bad "foreign-owner mask list: rc=$RC walks=$(walks) $OUT"; fi
# Nodes present at build time are masked from the cache; nodes created after
# it (shallow or deep) change a fingerprinted directory and force a walk.
mkdir -p "$TMP/rt2/late-dir/sub"
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$TMP/rt2/early.sock"
cat > "$TMP/outer-late.sh" <<'LATE'
R=$1; ML=$2
bash "$R" --write-mask-list "$ML" || echo BUILD_FAIL
masked() { for f in "$@"; do if test -S "/etc/$f"; then echo "VISIBLE $f"; else echo "MASKED $f"; fi; done; }
SANDBOX_RUN_MASK_LIST="$ML" bash "$R" -- bash -c "$(declare -f masked); masked early.sock"
echo "WALKS-AFTER-CLEAN-CACHE $(grep -c -- -prune "$STUB_FIND_LOG")"
sleep 0.3
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' /etc/late-dir/sub/deep.sock
SANDBOX_RUN_MASK_LIST="$ML" bash "$R" -- bash -c "$(declare -f masked); masked early.sock late-dir/sub/deep.sock"
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' /etc/late.sock
SANDBOX_RUN_MASK_LIST="$ML" bash "$R" -- bash -c "$(declare -f masked); masked late.sock"
LATE
: > "$FINDLOG"
OUT=$(STUB_FIND_LOG="$FINDLOG" PATH="$STUBBIN:$PATH" bwrap "${OUTER[@]}" --bind "$TMP/rt2" /etc \
    --ro-bind "$ROOT" "$ROOT" --bind "$TMP" "$TMP" --unshare-all --unshare-user --die-with-parent \
    --proc /proc --dev /dev --chdir "$ROOT" -- bash "$TMP/outer-late.sh" "$RUNNER" "$TMP/ml.late" 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ "$OUT" == *'MASKED early.sock'* ]] && [[ "$OUT" == *'WALKS-AFTER-CLEAN-CACHE 1'* ]]; then
    ok 'node present at cache build is masked from the cache without a second walk'
else bad "cached mask of pre-existing socket: rc=$RC $OUT"; fi
if [[ "$OUT" == *'MASKED late-dir/sub/deep.sock'* ]] && [[ "$OUT" == *'MASKED late.sock'* ]] \
    && [[ "$OUT" != *VISIBLE* ]] && [ "$(walks)" = 3 ]; then
    ok 'socket created after the cache was built is still masked via a full walk'
else bad "late socket: rc=$RC walks=$(walks) $OUT"; fi

# Another suite changing the checkout during a launch must not turn into a silent
# rc 125. ROOT is bound whole, so a transient FIFO under it is masked
# (as runtime special nodes are), never a refusal; a vanished entry is a race.
# These rows stage a copy of the runner under their own TMP so the ROOT they plant
# nodes in and churn is private, never the checkout other suites are using.
STAGE="$TMP/stage"; mkdir -p "$STAGE/scripts/lib"
cp "$RUNNER" "$STAGE/scripts/lib/sandbox-run.sh"
SRUNNER="$STAGE/scripts/lib/sandbox-run.sh"
RACE="$STAGE/race"; mkdir -p "$RACE"
staged() { (cd "$STAGE" && "$@"); }
# an absent path also reads as not-a-FIFO and fails to read, so the fixture must exist first.
if ! mkfifo "$RACE/pipe" || [ ! -p "$RACE/pipe" ]; then bad 'FIFO fixture could not be created under the staged ROOT'; fi
# shellcheck disable=SC2016  # the hook body's variables expand inside the sandbox
OUT=$(staged bash "$SRUNNER" -- bash -c 'echo RAN; if test -p "$1"; then echo FIFO_VISIBLE; else echo FIFO_MASKED; fi; timeout 5 cat "$1" >/dev/null; echo "READ_RC=$?"' _ "$RACE/pipe" 2>&1); RC=$?
rm -f "$RACE/pipe"
read_rc=${OUT##*READ_RC=}; read_rc=${read_rc%%[!0-9]*}
if [ "$RC" = 0 ] && [[ "$OUT" == *RAN* ]] && [[ "$OUT" == *FIFO_MASKED* ]] && [ -n "$read_rc" ] && [ "$read_rc" != 0 ] && [ "$read_rc" != 124 ]; then
    ok 'FIFO planted under ROOT is masked, its read fails (no data, no hang) and the hook still runs'
else bad "FIFO under ROOT: rc=$RC read_rc=$read_rc $OUT"; fi
# a live listener under ROOT: no connection crosses the mask, and the listener never sees one.
python3 -I -c '
import os,socket,sys
os.chdir(sys.argv[1])
s=socket.socket(socket.AF_UNIX); s.bind("l.sock"); s.listen(5)
open("ready","w").close()
s.settimeout(30)
n=0
try:
    while True:
        c,_=s.accept(); n+=1; open("accepted","w").write(str(n)); c.close()
except Exception:
    pass
' "$RACE" &
listener_pid=$!
for _ in $(seq 1 50); do [ -e "$RACE/ready" ] && break; sleep 0.1; done
PROBE='import os,socket,sys
s=socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1]); print("CONNECTED")
except Exception as e:
    print("CONNECT_FAILED", type(e).__name__)'
OUT=$(python3 -I -c "$PROBE" "$RACE/l.sock" 2>&1)
sleep 0.3
if [ -S "$RACE/l.sock" ] && [[ "$OUT" == CONNECTED ]] && [ "$(cat "$RACE/accepted" 2>/dev/null)" = 1 ]; then
    ok 'live listener control: an unsandboxed connection is accepted'
else bad "listener control: $OUT accepted=$(cat "$RACE/accepted" 2>/dev/null)"; fi
OUT=$(staged bash "$SRUNNER" -- python3 -I -c "$PROBE" "$RACE/l.sock" 2>&1); RC=$?
sleep 0.3
if [ "$RC" = 0 ] && [[ "$OUT" == *CONNECT_FAILED* ]] && [ "$(cat "$RACE/accepted" 2>/dev/null)" = 1 ]; then
    ok 'live socket under ROOT: connect refused inside the sandbox and the listener sees no connection'
else bad "live socket under ROOT: rc=$RC $OUT accepted=$(cat "$RACE/accepted" 2>/dev/null)"; fi
kill "$listener_pid" 2>/dev/null; wait "$listener_pid" 2>/dev/null
rm -f "$RACE/l.sock" "$RACE/ready" "$RACE/accepted"
# shellcheck disable=SC2016  # the stub's own variables expand when it runs
printf '#!/bin/bash\n/usr/bin/find "$@"\nrc=$?\nif [ -n "${STUB_FIND_ERR:-}" ]; then printf "%%s\\n" "$STUB_FIND_ERR" >&2; exit "${STUB_FIND_RC:-1}"; fi\nexit $rc\n' > "$STUBBIN/find"
OUT=$(staged env STUB_FIND_ERR="find: '$STAGE/gone': No such file or directory" PATH="$STUBBIN:$PATH" bash "$SRUNNER" -- bash -c 'echo RAN' 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ "$OUT" == *RAN* ]]; then ok 'entry vanished mid-walk is tolerated, the hook still runs'
else bad "vanished entry: rc=$RC $OUT"; fi
OUT=$(staged env STUB_FIND_ERR="find: '$STAGE/locked': Permission denied" PATH="$STUBBIN:$PATH" bash "$SRUNNER" -- bash -c 'echo RAN' 2>&1); RC=$?
if [ "$RC" = 125 ] && [[ "$OUT" == *'Permission denied'* ]] && [[ "$OUT" != *RAN* ]]; then ok 'unreadable entry is still refused with the printed reason'
else bad "unreadable entry: rc=$RC $OUT"; fi
# a path that merely contains the vanished-entry words must not excuse an unreadable entry.
OUT=$(staged env STUB_FIND_ERR="find: '$STAGE/x: No such file or directory/y': Permission denied" PATH="$STUBBIN:$PATH" bash "$SRUNNER" -- bash -c 'echo RAN' 2>&1); RC=$?
if [ "$RC" = 125 ] && [[ "$OUT" == *'Permission denied'* ]] && [[ "$OUT" != *RAN* ]]; then ok 'a path naming the vanished-entry words does not excuse an unreadable entry'
else bad "path with the vanished-entry words: rc=$RC $OUT"; fi
# only find's own exit 1 is a race: a find that exited another way (killed, failed) refuses even
# when its stderr reads as a vanished entry, and so does a grep that itself failed.
OUT=$(staged env STUB_FIND_RC=137 STUB_FIND_ERR="find: '$STAGE/gone': No such file or directory" PATH="$STUBBIN:$PATH" bash "$SRUNNER" -- bash -c 'echo RAN' 2>&1); RC=$?
if [ "$RC" = 125 ] && [[ "$OUT" == *'find exit 137'* ]] && [[ "$OUT" != *RAN* ]]; then ok 'a find that exited 137 refuses with its exit status'
else bad "killed find: rc=$RC $OUT"; fi
mkdir -p "$TMP/grepfail"
printf '#!/bin/bash\nexit 2\n' > "$TMP/grepfail/grep"; chmod +x "$TMP/grepfail/grep"
OUT=$(staged env STUB_FIND_ERR="find: '$STAGE/gone': No such file or directory" PATH="$TMP/grepfail:$STUBBIN:$PATH" bash "$SRUNNER" -- bash -c 'echo RAN' 2>&1); RC=$?
if [ "$RC" = 125 ] && [[ "$OUT" == *'find exit 1'* ]] && [[ "$OUT" != *RAN* ]]; then ok 'a grep that failed does not excuse a find diagnostic'
else bad "failed grep: rc=$RC $OUT"; fi
churn() { while [ ! -e "$RACE/stop" ]; do
    mkdir -p "$RACE/d/e"; touch "$RACE/d/e/f" "$RACE/d/g"; mkfifo "$RACE/d/p" 2>/dev/null
    rm -rf "$RACE/d"
done; }
# The hook runs, or bwrap says why it could not mount over a node that vanished after the
# scan (a few ms window): never a launch that ends without a reason. bwrap words that
# reason differently by version (Read-only file system, No such file, and on the CI image
# "Unable to find ... in mount table"), so the reason is a bwrap setup error that names a
# node of the churn directory, whatever its wording.
churn_reasoned_launch() { [ "$1" = 1 ] && [[ "$2" == "bwrap: Can't "*"$RACE/d/"* ]]; }
# fixture copied from CI run 42262795231 job 128048101493 (shell-unit-shard 5), mount path as logged
ci_line="bwrap: Can't bind mount /oldroot/dev/null on /newroot$RACE/d/p: Unable to find \"/newroot$RACE/d/p\" in mount table"
if churn_reasoned_launch 1 "$ci_line"; then ok 'the bwrap mount-table wording CI logged counts as a reasoned churn launch'
else bad "CI bwrap wording not accepted as a reasoned churn launch: $ci_line"; fi
if ! churn_reasoned_launch 1 "bwrap: Can't bind mount /oldroot/dev/null on /newroot/etc/x: Unable to find in mount table" \
    && ! churn_reasoned_launch 1 "something else wrote $RACE/d/p" \
    && ! churn_reasoned_launch 125 "$ci_line" && ! churn_reasoned_launch 1 ''; then
    ok 'a bwrap error off the churn directory, a bare rc 1, or another rc is not a reasoned churn launch'
else bad 'churn reason accepts something it should refuse'; fi
churn & churn_pid=$!
churn_bad=0; churn_reasoned=0; churn_start=$SECONDS; churn_done=0
for _ in $(seq 1 30); do
    # a launch that never returns would eat the suite's whole cap: a launch gets at most 60 s,
    # never more than what is left of the row's 120 s, and is killed 5 s after the TERM.
    churn_left=$((120 - (SECONDS - churn_start)))
    [ "$churn_left" -gt 0 ] || break
    OUT=$(staged timeout -k 5 "$((churn_left < 60 ? churn_left : 60))" bash "$SRUNNER" -- bash -c 'echo RAN' 2>&1); RC=$?
    churn_done=$((churn_done + 1))
    if [ "$RC" = 0 ] && [[ "$OUT" == *RAN* ]]; then :
    elif churn_reasoned_launch "$RC" "$OUT"; then churn_reasoned=$((churn_reasoned + 1))
    else churn_bad=$((churn_bad + 1)); churn_first=${churn_first:-"rc=$RC $OUT"}; fi
done
touch "$RACE/stop"; kill "$churn_pid" 2>/dev/null; wait "$churn_pid" 2>/dev/null
churn_pid=
[ "$churn_done" = 30 ] || { churn_bad=$((churn_bad + 1)); churn_first=${churn_first:-"only $churn_done of 30 launches finished in 120 s"}; }
if [ "$churn_bad" = 0 ]; then ok "launches under a FIFO and directory churning in ROOT run the hook or say why (30 of 30, $churn_reasoned reasoned)"
else bad "churn under ROOT: $churn_bad of 30 launches failed, first: ${churn_first:-}"; fi
# containment control: a real FIFO in a bound input is still refused, with the reason.
mkdir -p "$TMP/ro-fifo/sub"; mkfifo "$TMP/ro-fifo/sub/pipe"
OUT=$(bash "$RUNNER" --read-only "$TMP/ro-fifo" -- bash -c 'echo RAN' 2>&1); RC=$?
if [ "$RC" = 125 ] && [[ "$OUT" == *'refusing socket/device/FIFO input'* ]] && [[ "$OUT" == *"$TMP/ro-fifo/sub/pipe"* ]] && [[ "$OUT" != *RAN* ]]; then
    ok 'FIFO inside a --read-only input is refused with the path'
else bad "FIFO in bound input: rc=$RC $OUT"; fi
# guard-corpus diff keeps the runner's reason on its ODD-RC row instead of discarding it.
printf '#!/bin/bash\nexit 0\n' > "$TMP/stub-hook.sh"
printf '%s\n' '{"tool_input":{"command":"ls"}}' > "$TMP/one-row.jsonl"
mkdir -p "$TMP/findfail"   # diff passes only an allowlisted environment, so the stub must not need a variable
printf '#!/bin/bash\nprintf "find: %%s\\n" "%s: Permission denied" >&2\nexit 1\n' "'$ROOT/locked'" > "$TMP/findfail/find"
chmod +x "$TMP/findfail/find"
OUT=$(HIMMEL_EVAL_RUNS_LEDGER="$TMP/eval-runs.jsonl" PATH="$TMP/findfail:$PATH" \
    python3 -I "$ROOT/scripts/eval/guard-corpus/diff" --base "$TMP/stub-hook.sh" --head "$TMP/stub-hook.sh" \
    --corpus "$TMP/one-row.jsonl" --repo "$ROOT" --no-json 2>&1); RC=$?
if [ "$RC" = 3 ] && [[ "$OUT" == *'ODD-RC idx=0'*'base-stderr='*'Permission denied'* ]]; then
    ok "diff ODD-RC row shows the runner's stderr"
else bad "diff ODD-RC stderr: rc=$RC $OUT"; fi
# every exit-125 path says why (callers send stderr away, so a bare 125 reads as a hook verdict).
for spec in '--canary' '--read-only' '--write-mask-list' '--read-only /nonexistent/himmel-8736'; do
    # shellcheck disable=SC2086  # the spec is a fixed word list
    OUT=$(bash "$RUNNER" $spec 2>&1); RC=$?
    if [ "$RC" = 125 ] && [ -n "$OUT" ]; then ok "refusal of '$spec' prints a reason"
    else bad "bare refusal of '$spec': rc=$RC out='$OUT'"; fi
done
fi
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
