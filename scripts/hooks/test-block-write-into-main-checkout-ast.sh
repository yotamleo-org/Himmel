#!/usr/bin/env bash
# Shard of test-block-write-into-main-checkout.sh: the AST engine
# (BWIMC_ENGINE=ast). Rows the text scan reads wrong, the
# engine's fail-closed paths, and the drift check between the guard's inlined
# jq program and scripts/hooks/lib/bash-ast*.jq.
# Same fixtures + harness as the parent suite via lib-test-write-fence.sh;
# the FIXTURE RULE lives in test-block-write-into-main-checkout.sh.
# `--engine regex` runs the same rows against the text scan, to show the
# first block failing there.
# shellcheck disable=SC2154  # pass/fail are defined by the sourced lib
# shellcheck source=lib-test-write-fence.sh
. "$(dirname "$0")/lib-test-write-fence.sh"

if ! command -v shfmt >/dev/null 2>&1; then
    echo "SKIP: shfmt not on PATH — the BWIMC_ENGINE=ast rows did not run"
    exit 0
fi
export BWIMC_ENGINE=ast
[ "${1:-}" = --engine ] && BWIMC_ENGINE="$2"

_ast_row() { # label verdict command [cwd]
    check_one "$1" "$DIRECT" "$2" \
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$3" | jq -Rs .),\"cwd\":\"${4:-$FIX/wt}\"}}"
}

echo "== HIMMEL-6014: writes the text scan reads wrong (engine: $BWIMC_ENGINE) =="
_ast_row "ast1 env -S runs its string as a command" block "env -S 'touch $_PR/ast1.txt'"
_ast_row "ast2 xargs runs its command" block "printf x | xargs touch $_PR/ast2.txt"
_ast_row "ast3 a dynamic name under the primary" block "touch $_PR/ast3-\$RANDOM.txt"
_ast_row "ast4 script -c runs its string as a command" block "script -qc 'touch $_PR/ast4.txt' /dev/null"
_ast_row "ast5 a verb spelled by absolute path" block "/usr/bin/touch $_PR/ast5.txt"

if [ "$BWIMC_ENGINE" = ast ]; then
    echo "== HIMMEL-6014: the AST engine fails closed =="
    _ast_row "ast10 a parse error denies" block "echo 'never closed > $_WR/x"
    _ast_row "ast11 a worktree write still allows" allow "echo x > $_WR/ast11.txt"
    _ast_row "ast12 cd into the primary then a relative write" block "cd $_PR && touch ast12.txt"
    _ast_row "ast13 bash -c body is parsed again" block "bash -c 'cd $_PR; echo x > ast13.txt'"
    _ast_row "ast14 arm (g) still runs: git -C primary checkout" block "git -C $_PR checkout -b x"
    _ast_row "ast18 time -p -- runs its command" block "time -p -- touch $_PR/ast18.txt"
    _ast_row "ast19 env -iC bundles the chdir" block "env -iC $_PR rm ast19.txt"
    _ast_row "ast20 sudo -nu bundles the user" block "sudo -nu root touch $_PR/ast20.txt"
    _ast_row "ast21 sudo -i starts in an unknown home" block "sudo -i touch ast21.txt" /tmp
    _ast_row "ast22 an unknown sudo option denies" block "sudo -Z v touch $_PR/ast22.txt"

    # a PATH holding every tool but shfmt
    _nosh="$FIX/no-shfmt-bin"; mkdir -p "$_nosh"
    _shdir=$(dirname "$(command -v shfmt)")
    for _t in "$_shdir"/*; do
        case "${_t##*/}" in shfmt) ;; *) ln -s "$_t" "$_nosh/${_t##*/}" 2>/dev/null ;; esac
    done
    _got=$(PATH="$_nosh" _run "$DIRECT" \
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $_WR/ast15.txt\",\"cwd\":\"$_WR\"}}")
    if [ "$_got" = block ]; then ok "ast15 shfmt missing denies"; else bad "ast15 shfmt missing denies — got $_got"; fi
    _got=$(BWIMC_ENGINE=bogus _run "$DIRECT" \
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $_WR/ast16.txt\",\"cwd\":\"$_WR\"}}")
    if [ "$_got" = block ]; then ok "ast16 an unknown BWIMC_ENGINE denies"; else bad "ast16 an unknown BWIMC_ENGINE denies — got $_got"; fi
    if bash "$HOOKS/replay-bwimc-engines.sh" --check; then ok "ast17 the inlined jq program matches lib/bash-ast*.jq"
    else bad "ast17 the inlined jq program matches lib/bash-ast*.jq"; fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
