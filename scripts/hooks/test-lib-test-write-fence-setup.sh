#!/usr/bin/env bash
# Unit test for the fixture-setup checks in lib-test-write-fence.sh.
# That lib builds the fixture repos every block-write-into-
# main-checkout shard's rows run against. If git init / commit / worktree add
# fails there and nobody notices, the rows test a MISSING fixture instead of
# the checkout topology they claim, and can still pass. So the lib must abort
# the suite, loudly, at the first failed step.
#
# Each case sources the real lib in a child bash with a `git` shim first on
# PATH that fails exactly one subcommand (FAKE_GIT_FAIL). The control case
# (shim present, nothing failing) proves the shim itself does not break the
# setup, so a red case is red for the injected failure and nothing else.
#
# Platform: any POSIX bash 3.2+ with git and jq (the lib SKIPs without them).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib-test-write-fence.sh"
[ -f "$LIB" ] || { echo "lib not found: $LIB" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

REAL_GIT="$(command -v git)"
SHIM="$(mktemp -d "${TMPDIR:-/tmp}/himmel-4391-gitshim.XXXXXX")" || exit 1
OUT="$SHIM/out"; ERR="$SHIM/err"
trap 'rm -rf "$SHIM"' EXIT

cat > "$SHIM/git" <<'SHIMEOF'
#!/usr/bin/env bash
# Fail the one subcommand named in FAKE_GIT_FAIL, pass everything else through.
for a in "$@"; do
    if [ -n "${FAKE_GIT_FAIL:-}" ] && [ "$a" = "$FAKE_GIT_FAIL" ]; then
        echo "fake-git: $a failed on purpose" >&2
        exit 1
    fi
done
exec "$REAL_GIT" "$@"
SHIMEOF
chmod +x "$SHIM/git"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# _source_lib <failing-subcommand|""> -> sets RC; stdout in $OUT, stderr in $ERR
_source_lib() {
    FAKE_GIT_FAIL="$1" REAL_GIT="$REAL_GIT" PATH="$SHIM:$PATH" \
        bash -c '. "$1"; echo REACHED-END-OF-LIB' "$HERE/probe" "$LIB" >"$OUT" 2>"$ERR"
    RC=$?
}

echo "== lib-test-write-fence.sh fixture setup (HIMMEL-4391) =="

_source_lib ""
if [ "$RC" = 0 ] && grep -q REACHED-END-OF-LIB "$OUT"; then
    ok "control: no step failing -> lib sources to the end (rc=0)"
else
    bad "control: expected the lib to source cleanly, got rc=$RC; stderr: $(tr '\n' '|' < "$ERR" | cut -c1-200)"
fi

for sub in init commit worktree; do
    _source_lib "$sub"
    if [ "$RC" != 0 ] && ! grep -q REACHED-END-OF-LIB "$OUT" && grep -q 'FIXTURE SETUP FAILED' "$ERR"; then
        ok "git $sub fails -> suite aborts non-zero with FIXTURE SETUP FAILED (rc=$RC)"
    else
        bad "git $sub fails -> expected abort + FIXTURE SETUP FAILED; got rc=$RC reached=$(grep -c REACHED-END-OF-LIB "$OUT") stderr: $(tr '\n' '|' < "$ERR" | cut -c1-200)"
    fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
