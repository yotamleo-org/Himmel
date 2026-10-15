#!/usr/bin/env bash
# real filesystem boundary, not assertions about bwrap flags.
# Regression: dropping the read-only root lets the executing canary row escape.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT/scripts/lib/sandbox-run.sh"
TMP="$(mktemp -d /tmp/sandbox-run-test.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
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
else
    OUT=$(bash "$RUNNER" -- bash -c 'test ! -S "$1"' _ "$TMP/host.sock" 2>&1); RC=$?
    if [ "$RC" = 0 ]; then ok 'host Unix socket absent inside'; else bad "host Unix socket exposed: rc=$RC $OUT"; fi
fi
OUT=$(bash "$RUNNER" -- bash -c 'touch "$HOME/ok" "$TMPDIR/ok"; test -f "$HOME/ok" && test -f "$TMPDIR/ok" && echo WRITABLE' 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ "$OUT" == *WRITABLE* ]]; then ok 'HOME and scratch are writable'; else bad "writable fixtures: $OUT"; fi
OUT=$(bash "$RUNNER" -- bash -c 'echo HOOK_DENY; exit 2' 2>&1); RC=$?
if [ "$RC" = 2 ] && [[ "$OUT" == *HOOK_DENY* ]]; then ok 'hook deny status and output preserved'; else bad "hook status: rc=$RC $OUT"; fi
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
OUT=$(bwrap "${OUTER[@]}" --ro-bind "$TMP/runtime" /etc --ro-bind "$ROOT" "$ROOT" \
    --unshare-all --unshare-user --die-with-parent --proc /proc --dev /dev \
    --tmpfs /tmp --chdir "$ROOT" -- bash "$RUNNER" -- \
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
fi
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
