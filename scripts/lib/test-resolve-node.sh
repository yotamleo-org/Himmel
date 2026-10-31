#!/usr/bin/env bash
# Smoke test for scripts/lib/resolve-node.sh.
# Usage: bash scripts/lib/test-resolve-node.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/resolve-node.sh"

[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# A realistic "node not on PATH" still needs coreutils — but on apt-node
# systems node LIVES in the coreutils dir (/usr/bin), so use
# a curated symlink dir carrying only the tools these cases need.
UTILS_ROOT="$(mktemp -d)"
trap 'rm -rf "$UTILS_ROOT"' EXIT
UTILS_DIR="$UTILS_ROOT/utils"
mkdir -p "$UTILS_DIR"
for _t in sort tail; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -s "$_p" "$UTILS_DIR/$_t" 2>/dev/null
done

# A fake node binary (executable, content irrelevant — resolve_node only checks -x).
make_fake_node() {
    # $1 = dir, $2 = optional basename (default node)
    local dir="$1" name="${2:-node}"
    mkdir -p "$dir"
    printf '#!/bin/sh\necho fake\n' > "$dir/$name"
    chmod +x "$dir/$name"
}

echo "== resolve_node: PATH wins over a former nvm-windows install (HIMMEL-8171) =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resolve-node-test.XXXXXX")" || exit 1
make_fake_node "$tmp/c/nvm4w/nodejs"
make_fake_node "$tmp/chosen-on-path"
out="$(PATH="$tmp/chosen-on-path:$UTILS_DIR" NVM_SYMLINK="$tmp/c/nvm4w/nodejs" RESOLVE_NODE_NVM4W_DIR="$tmp/c/nvm4w/nodejs" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/chosen-on-path/node" ]; then
    pass "PATH node beats the former nvm4w node"
else
    fail "PATH priority: rc=$rc out='$out' (want $tmp/chosen-on-path/node)"
fi
rm -rf "$tmp"
if [ "${1:-}" = --posix-defaults-only ]; then
    [ "$failures" -eq 0 ] || exit 1
    echo "ALL PASS (POSIX defaults)"
    exit 0
fi

echo "== resolve_node: real node on PATH =="
# This box may or may not have node on PATH; only assert when it does.
if command -v node >/dev/null 2>&1; then
    out="$(resolve_node)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then pass "PATH node -> '$out' rc0"; else fail "PATH node -> rc=$rc out='$out'"; fi
else
    pass "PATH node -> (skipped: no node on PATH here)"
fi

echo "== resolve_node: found in an injected probe dir (PATH cleared) =="
tmp="$(mktemp -d)" || exit 1; make_fake_node "$tmp/bin"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/bin/node" ]; then pass "probe dir -> '$out'"; else fail "probe dir -> rc=$rc out='$out' (want $tmp/bin/node)"; fi
rm -rf "$tmp"

echo "== resolve_node: node.exe variant in probe dir =="
tmp="$(mktemp -d)" || exit 1; make_fake_node "$tmp/bin" "node.exe"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then pass "node.exe is not a POSIX candidate"; else fail "node.exe -> rc=$rc out='$out' (want rc1 empty)"; fi
rm -rf "$tmp"

echo "== resolve_node: a generic OTHER absolute location does NOT beat a chosen PATH node (codex CR round on HIMMEL-2077) =="
# Generic locations (/usr/bin, homebrew, ...) stay behind an operator's
# deliberately chosen PATH entry (a version manager or asdf shim).
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resolve-node-test.XXXXXX")"
make_fake_node "$tmp/chosen-on-path"
make_fake_node "$tmp/generic-other-location"
out="$(PATH="$tmp/chosen-on-path:$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/generic-other-location" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/chosen-on-path/node" ]; then
    pass "chosen PATH node beats a generic other-location node -> '$out'"
else
    fail "chosen PATH node beats a generic other-location node -> rc=$rc out='$out' (want $tmp/chosen-on-path/node, NOT $tmp/generic-other-location/node)"
fi
rm -rf "$tmp"

echo "== resolve_node: no node anywhere -> rc1, empty =="
tmp="$(mktemp -d)"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then pass "no node -> rc1 empty"; else fail "no node -> rc=$rc out='$out'"; fi
rm -rf "$tmp"

echo "== resolve_node: nvm picks newest (sort -V, not lexical) =="
tmp="$(mktemp -d)"; nvm="$tmp/nvm"
make_fake_node "$nvm/v8.9.0/bin"
make_fake_node "$nvm/v20.5.0/bin"
make_fake_node "$nvm/v18.0.0/bin"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$nvm" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$nvm/v20.5.0/bin/node" ]; then pass "nvm newest -> '$out'"; else fail "nvm newest -> rc=$rc out='$out' (want v20.5.0; lexical bug would give v8.9.0)"; fi
rm -rf "$tmp"

echo "== resolve_node: POSIX-safe scoping, no \`local\` (HIMMEL-3182 slice 3) =="
# run-node.sh sources resolve-node.sh under whatever `sh` the hook shell has;
# ksh93 `sh` has no `local`. dash is the only POSIX shell we can assume is
# installed and it DOES implement `local`, so a dash run proves nothing here:
# the guard is (1) a static check of both shipped copies and (2) a run with the
# builtin shadowed by a no-op, i.e. a shell that cannot declare function locals.
PLUGIN_LIB="$REPO_ROOT/marketplace/plugins/himmel-ops/hooks/resolve-node.sh"
for _f in "$LIB" "$PLUGIN_LIB"; do
    _hits="$(grep -nE '(^|[[:space:];&|(])local([[:space:]]|$)' "$_f" | grep -vE '^[0-9]+:[[:space:]]*#')"
    if [ -z "$_hits" ]; then pass "no \`local\` keyword in ${_f#"$REPO_ROOT"/}"; else fail "\`local\` still used in ${_f#"$REPO_ROOT"/}: $_hits"; fi
done
if cmp -s "$LIB" "$PLUGIN_LIB"; then pass "plugin copy byte-identical to scripts/lib copy"; else fail "plugin copy differs from scripts/lib copy"; fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/resolve-node-test.XXXXXX")" || exit 1
make_fake_node "$tmp/probe"
out="$(
    # shellcheck disable=SC2317,SC2329 # the stub is what the sourced function calls
    local() { return 127; }
    set +u
    PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/probe" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node
)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/probe/node" ]; then pass "probe-dir node found with the \`local\` builtin unavailable"; else fail "no-\`local\` shell, probe dir: rc=$rc out='$out' (want $tmp/probe/node)"; fi
nvm="$tmp/nvm"; make_fake_node "$nvm/v20.5.0/bin"
out="$(
    # shellcheck disable=SC2317,SC2329 # the stub is what the sourced function calls
    local() { return 127; }
    set +u
    PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$nvm" FNM_DIR="$tmp/none" resolve_node
)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$nvm/v20.5.0/bin/node" ]; then pass "nvm node found with the \`local\` builtin unavailable"; else fail "no-\`local\` shell, nvm: rc=$rc out='$out' (want $nvm/v20.5.0/bin/node)"; fi
out="$(
    # shellcheck disable=SC2317,SC2329 # the stub is what the sourced function calls
    local() { return 127; }
    set +u
    PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node
)"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then pass "no node -> rc1 empty with the \`local\` builtin unavailable"; else fail "no-\`local\` shell, no node: rc=$rc out='$out'"; fi
rm -rf "$tmp"

# The unprefixed names the function used to `local`-ise must survive a
# same-shell (non-subshell) call: with no `local`, scoping is the _rn_ prefix.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resolve-node-test.XXXXXX")"; make_fake_node "$tmp/probe"
d=keep-d; dirs=keep-dirs; newest=keep-newest; save_ifs=keep-ifs; nvm_root=keep-root; fnm_root=keep-fnm; fnm_newest=keep-fn
PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/probe" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node >/dev/null
_got="$d $dirs $newest $save_ifs $nvm_root $fnm_root $fnm_newest"
if [ "$_got" = "keep-d keep-dirs keep-newest keep-ifs keep-root keep-fnm keep-fn" ]; then pass "caller's same-named variables untouched by an in-shell call"; else fail "caller variables clobbered: '$_got'"; fi
rm -rf "$tmp"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
