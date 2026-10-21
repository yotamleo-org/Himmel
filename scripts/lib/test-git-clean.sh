#!/usr/bin/env bash
# scripts/lib/test-git-clean.sh: the shell and JS git-clean twins
# (scripts/lib/git-clean.sh, scripts/lanes/git-clean.mjs) must scrub every
# repository-redirecting GIT_* variable, identically.
#
# The set is `git rev-parse --local-env-vars` (git's own list of the
# repository-local variables) minus GIT_NO_REPLACE_OBJECTS, a hardening switch
# the helpers leave alone on purpose. Hardcoded here so a newer git adding one
# shows up as a reviewed diff, not a surprise CI failure.
#
# Platform guard: POSIX bash 3.2+ (no associative arrays), needs node for the
# .mjs twin.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
VARS="GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/git-clean-test.XXXXXX")" || exit 2
trap 'rm -rf "$STUB_DIR"' EXIT
# A stub `git` that prints the GIT_* variables it inherited, one per line.
cat > "$STUB_DIR/git" <<'STUB'
#!/bin/sh
echo STUB-RAN
env | grep '^GIT_' | sort
exit 0
STUB
chmod +x "$STUB_DIR/git"

# git_clean (shell twin): every var set to a poisoned value must be absent in
# the child.
(
    for v in $VARS; do export "$v=/poison"; done
    # shellcheck disable=SC2030
    export GIT_NO_REPLACE_OBJECTS=1
    # shellcheck source=/dev/null
    . "$REPO_ROOT/scripts/lib/git-clean.sh"
    PATH="$STUB_DIR:$PATH" git_clean rev-parse
) > "$STUB_DIR/sh-clean.out" 2>&1
sh_rc=$?
# An absent variable only proves a scrub if the stub actually ran: a helper
# that failed to source or exec would otherwise read as "scrubbed".
if [ "$sh_rc" -ne 0 ] || ! grep -q '^STUB-RAN$' "$STUB_DIR/sh-clean.out"; then
    fail "sh git_clean did not run the stub (rc=$sh_rc) — scrub rows below are void"
fi
for v in $VARS; do
    if grep -q "^$v=" "$STUB_DIR/sh-clean.out"; then
        fail "sh git_clean leaks $v"
    else
        pass "sh git_clean scrubs $v"
    fi
done
# GIT_NO_REPLACE_OBJECTS is KEPT on purpose (git lists it as
# a local var but it redirects nothing — it hardens: clear-review-marker.sh sets it
# itself). A helper that "completed" the set by scrubbing it would
# silently drop that hardening for every caller.
if grep -q '^GIT_NO_REPLACE_OBJECTS=1$' "$STUB_DIR/sh-clean.out"; then
    pass "sh git_clean keeps GIT_NO_REPLACE_OBJECTS"
else
    fail "sh git_clean dropped GIT_NO_REPLACE_OBJECTS (it must stay set)"
fi

# git_env_scrub (shell twin): every var unset in the calling shell.
for v in $VARS; do
    got="$(
        for w in $VARS; do export "$w=/poison"; done
        # shellcheck source=/dev/null
        . "$REPO_ROOT/scripts/lib/git-clean.sh"
        git_env_scrub
        eval "printf 'ran:%s' \"\${$v+set}\""
    )"
    # `ran:` proves the subshell reached the probe; bare `ran:` = unset.
    if [ "$got" = "ran:" ]; then
        pass "sh git_env_scrub unsets $v"
    else
        fail "sh git_env_scrub leaves $v set"
    fi
done
got="$(
    # shellcheck disable=SC2030,SC2031
    export GIT_NO_REPLACE_OBJECTS=1
    # shellcheck source=/dev/null
    . "$REPO_ROOT/scripts/lib/git-clean.sh"
    git_env_scrub
    printf 'ran:%s' "${GIT_NO_REPLACE_OBJECTS-unset}"
)"
if [ "$got" = "ran:1" ]; then
    pass "sh git_env_scrub keeps GIT_NO_REPLACE_OBJECTS"
else
    fail "sh git_env_scrub dropped GIT_NO_REPLACE_OBJECTS (got '$got', it must stay set)"
fi

# gitClean / gitCleanEnv (JS twin).
if command -v node >/dev/null 2>&1; then
    JS_OUT="$(
        for v in $VARS; do export "$v=/poison"; done
        # shellcheck disable=SC2031
        export GIT_NO_REPLACE_OBJECTS=1
        PATH="$STUB_DIR:$PATH" node --input-type=module -e "
import { gitClean } from '$REPO_ROOT/scripts/lanes/git-clean.mjs';
process.stdout.write(gitClean(['rev-parse'], { encoding: 'utf8' }));
" 2>&1
        echo "node-rc=$?"
    )"
    if ! grep -q '^STUB-RAN$' <<<"$JS_OUT" || ! grep -q '^node-rc=0$' <<<"$JS_OUT"; then
        fail "mjs gitClean did not run the stub cleanly — scrub rows below are void"
    fi
    for v in $VARS; do
        if grep -q "^$v=" <<<"$JS_OUT"; then
            fail "mjs gitClean leaks $v"
        else
            pass "mjs gitClean scrubs $v"
        fi
    done
    if grep -q '^GIT_NO_REPLACE_OBJECTS=1$' <<<"$JS_OUT"; then
        pass "mjs gitClean keeps GIT_NO_REPLACE_OBJECTS"
    else
        fail "mjs gitClean dropped GIT_NO_REPLACE_OBJECTS (it must stay set)"
    fi
else
    fail "node not found — cannot exercise the .mjs twin"
fi

echo
echo "== summary =="
if [ "$failures" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$failures FAILURE(S)"
    exit 1
fi
