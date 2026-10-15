#!/usr/bin/env bash
# Smoke test for the nested-xargs render budget of scripts/hooks/lib/guard-unwrap.sh
#
#
# A stripped `xargs` adds a second, xargs-kept child render per level. That
# child re-derived the stripped render its parent had already scanned, so each
# nested `xargs sh -c` cost two depth units: a benign 3-deep shape hit the
# 8-level cap, and the work grew with every level.
#
# Usage: bash scripts/hooks/test-guard-unwrap-nested-xargs.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REAL_HOOK="$HERE/block-git-stash.sh"
LIB="$HERE/lib/guard-unwrap.sh"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/guard-unwrap-nested-xargs.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

FAILED=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label - expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_le() {
    local label="$1" limit="$2" actual="$3"
    if [ "$actual" -le "$limit" ]; then
        echo "PASS $label ($actual <= $limit)"
    else
        echo "FAIL $label - expected <= $limit, got $actual"
        FAILED=$((FAILED + 1))
    fi
}

# nest N BODY — BODY wrapped in N levels of `xargs sh -c "…"`, fed by one
# `printf a |` at the outermost level (the J1946 T2 shape). Double quotes
# matter: a double-quoted body is what sets the render trigger.
nest() {
    local n=$1 body=$2 q
    while [ "$n" -gt 0 ]; do
        q=${body//\\/\\\\}
        q=${q//\"/\\\"}
        body="xargs sh -c \"$q\""
        n=$((n - 1))
    done
    printf 'printf a | %s' "$body"
}

# A stand-in for a lib consumer: denies a command-position `git stash` by text
# scan, then unwraps through the lib. block-git-stash.sh no longer unwraps, so
# the lib's deny properties are driven through this instead.
HOOK="$SCRATCH/stash-hook.sh"
cat >"$HOOK" <<EOF
#!/usr/bin/env bash
set -uo pipefail
cmd=\$(jq -r '.tool_input.command // empty') || exit 3
[ -n "\$cmd" ] || exit 3
if printf '%s' "\$cmd" | grep -Eq '(^|[|;&(\`])[[:space:]]*git[[:space:]]+stash'; then
    echo "stand-in: git stash" >&2
    exit 2
fi
. "$LIB" || exit 2
guard_unwrap "\${BASH_SOURCE[0]}" "\$cmd" || exit 2
exit 0
EOF

j_bash() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

run_hook() {
    local f="$SCRATCH/payload.json"
    j_bash "$1" >"$f"
    bash "$HOOK" <"$f" >/dev/null 2>&1
    echo "$?"
}

# A stand-in hook that only logs each invocation then unwraps through the lib,
# so the log line count is the number of renders the lib scanned.
RENDER_LOG="$SCRATCH/renders.log"
COUNT_HOOK="$SCRATCH/count-hook.sh"
cat >"$COUNT_HOOK" <<EOF
#!/usr/bin/env bash
set -uo pipefail
cmd=\$(jq -r '.tool_input.command // empty') || exit 3
[ -n "\$cmd" ] || exit 3
printf 'x\n' >>"$RENDER_LOG"
. "$LIB" || exit 2
guard_unwrap "\${BASH_SOURCE[0]}" "\$cmd" || exit 2
exit 0
EOF

count_renders() {
    local f="$SCRATCH/count-payload.json"
    : >"$RENDER_LOG"
    j_bash "$1" >"$f"
    bash "$COUNT_HOOK" <"$f" >/dev/null 2>&1
    echo "$?" >"$SCRATCH/count-rc"
    wc -l <"$RENDER_LOG" | tr -d ' '
}

# block-git-stash itself no longer unwraps: a wrapped stash is an accepted miss
run_real() {
    j_bash "$1" >"$SCRATCH/real.json"
    bash "$REAL_HOOK" <"$SCRATCH/real.json" >/dev/null 2>&1
    echo "$?"
}
assert_rc "block-git-stash: direct git stash" 2 "$(run_real 'git stash')"
assert_rc "block-git-stash: 2-deep xargs sh -c 'git stash' (accepted miss)" 0 "$(run_real "$(nest 2 'git stash')")"

# --- benign nested xargs: must stay rc 0 at every depth the cap allows ---
for d in 1 2 3 4; do
    assert_rc "benign ${d}-deep xargs sh -c" 0 "$(run_hook "$(nest "$d" 'echo hi')")"
done

# --- the deny ladder: a stash at any depth is still denied by a lib consumer ---
for d in 1 2 3 4; do
    assert_rc "${d}-deep xargs sh -c 'git stash'" 2 "$(run_hook "$(nest "$d" 'git stash')")"
done
assert_rc "xargs git stash"            2 "$(run_hook 'printf a | xargs git stash')"
assert_rc "xargs -n1 git stash push"   2 "$(run_hook 'printf a | xargs -n1 git stash push')"
assert_rc "env xargs git stash"        2 "$(run_hook 'printf a | env X=1 xargs git stash')"
assert_rc "xargs xargs git stash"      2 "$(run_hook 'printf a | xargs xargs git stash')"
assert_rc "benign xargs echo"          0 "$(run_hook 'printf a | xargs echo hi')"

# --- a shell word in a non-executing builtin's data position is
# not read, but every executing position still is ---
assert_rc "echo bash -c 'git stash' is data"   0 "$(run_hook "echo bash -c 'git stash'")"
assert_rc "printf a | xargs echo bash -c 'git stash' (wrapper: fails safe)" 2 "$(run_hook "printf a | xargs echo bash -c 'git stash'")"
assert_rc "sudo -R echo bash -c 'git stash'"   2 "$(run_hook "sudo -R echo bash -c 'git stash'")"
assert_rc "echo(){ ...; }; echo bash -c 'git stash'" 2 "$(run_hook "echo(){ \"\$@\"; }; echo bash -c 'git stash'")"
assert_rc "echo() ( \"\$@\" ); echo bash -c 'git stash'" 2 "$(run_hook "echo() ( \"\$@\" ); echo bash -c 'git stash'")"
assert_rc "alias echo=eval; echo bash -c 'git stash'" 2 "$(run_hook "alias echo=eval; echo bash -c 'git stash'")"
assert_rc "exported function reaches a child shell" 2 "$(run_hook "echo() ( \"\$@\" ); export -f echo; bash -c \"echo bash -c 'git stash'\"")"
assert_rc "enable -n echo; echo bash -c 'git stash'" 2 "$(run_hook "enable -n echo; echo bash -c 'git stash'")"
assert_rc "find -exec sh -c 'git stash'"       2 "$(run_hook "find . -exec sh -c 'git stash' \\;")"
assert_rc "xargs bash -c 'git stash'"          2 "$(run_hook "printf a | xargs bash -c 'git stash'")"
assert_rc "sudo -u u bash -c 'git stash'"      2 "$(run_hook "sudo -u u bash -c 'git stash'")"
assert_rc "echo x; bash -c 'git stash'"        2 "$(run_hook "echo x; bash -c 'git stash'")"
assert_rc "echo \$(bash -c 'git stash')"       2 "$(run_hook "echo \$(bash -c 'git stash')")"
assert_rc "echo | bash -c 'git stash'"         2 "$(run_hook "echo | bash -c 'git stash'")"

# --- render budget: linear in depth, not doubling per level ---
# Each level costs the stripped render, the xargs-kept render (scanned once,
# never unwrapped again) and its body: 3 per level plus the top call. Before
# the fix the same shapes cost 6, 16, 35 scans at depth 1-3.
for d in 1 2 3 4; do
    n=$(count_renders "$(nest "$d" 'echo hi')")
    # An early deny or cap abort would shrink the count and pass the budget.
    assert_rc "count hook ${d}-deep ran to completion" 0 "$(cat "$SCRATCH/count-rc")"
    assert_le "render count, ${d}-deep" "$((d * 3 + 1))" "$n"
done

# --- the xargs-kept marker is an internal channel, not an input ---
# A caller-set marker at depth 0 must not make the guard skip its children
# (that would let every nested body through), and the marker must not reach a
# process the hook spawns after unwrapping (block-tail-pipe-on-gates.sh runs
# its expanded forms that way).
run_hook_env() {
    local f="$SCRATCH/payload.json" cmd=$1
    shift
    j_bash "$cmd" >"$f"
    env "$@" bash "$HOOK" <"$f" >/dev/null 2>&1
    echo "$?"
}

assert_rc "XKEPT=1 at depth 0 still denies a nested stash" 2 \
    "$(run_hook_env 'sh -c "git stash"' GUARD_UNWRAP_XKEPT=1)"
assert_rc "XKEPT=1 at depth 0 still denies a nested xargs stash" 2 \
    "$(run_hook_env "$(nest 2 'git stash')" GUARD_UNWRAP_XKEPT=1)"
assert_rc "xargs-kept child still runs the hook's own text scan" 2 \
    "$(run_hook_env 'git stash' GUARD_UNWRAP_DEPTH=1 GUARD_UNWRAP_XKEPT=1)"

LEAK_HOOK="$SCRATCH/leak-hook.sh"
cat >"$LEAK_HOOK" <<EOF
#!/usr/bin/env bash
set -uo pipefail
cmd=\$(jq -r '.tool_input.command // empty') || exit 3
. "$LIB" || exit 2
guard_unwrap "\${BASH_SOURCE[0]}" "\$cmd" || exit 2
bash -c 'printf "%s" "\${GUARD_UNWRAP_XKEPT-unset}"' >"$SCRATCH/leak.out"
exit 0
EOF
j_bash 'echo hi' >"$SCRATCH/leak-payload.json"
env GUARD_UNWRAP_DEPTH=1 GUARD_UNWRAP_XKEPT=1 bash "$LEAK_HOOK" <"$SCRATCH/leak-payload.json" >/dev/null 2>&1
leak=$(cat "$SCRATCH/leak.out" 2>/dev/null)
if [ "$leak" = unset ]; then
    echo "PASS marker not inherited by a process the hook spawns"
else
    echo "FAIL marker not inherited by a process the hook spawns - got '$leak'"
    FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -ne 0 ]; then
    echo "FAILED: $FAILED case(s)"
    exit 1
fi
echo "all cases passed"
exit 0
