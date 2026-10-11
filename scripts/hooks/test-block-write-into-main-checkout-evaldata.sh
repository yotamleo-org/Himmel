#!/usr/bin/env bash
# Unit test for scripts/hooks/block-write-into-main-checkout.sh — the
# HIMMEL-5098 rows: eval / source / `.` / bash -c / sh -c / zsh -c whose
# argument is (or contains) a command substitution that READS repository or
# file data (git log, git show, git cat-file, cat, head, tail, `$(<f)`) is
# denied, because the text scan never sees the write hidden in that data.
# Ordinary eval of a literal string and of a benign substitution stays allowed.
# Platform guard: Git Bash on Windows / any POSIX bash 3.2+ (same as the
# guard; no .ps1 twin). A sibling of test-block-write-into-main-checkout.sh,
# split out so the parent suite stays under the CI per-suite cap; the harness
# below is a trimmed copy of the -wrappers sibling's (same fixtures).
#
# Every row runs BOTH entry modes via `check_both`: direct-exec
# (`bash block-write-into-main-checkout.sh` with the JSON payload on stdin)
# and sourced (`bash block-terminal-write-fence.sh`, the codex adapter).
#
# FIXTURE RULE (load-bearing): fixtures are rooted under the REAL $HOME, NOT
# a bare `mktemp -d`. `/tmp` paths are exempted by is_temp_or_devnull, so a
# DENY row rooted under mktemp -d would pass as ALLOW for the wrong reason.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
DIRECT="$HOOKS/block-write-into-main-checkout.sh"
FENCE="$HOOKS/block-terminal-write-fence.sh"
[ -f "$DIRECT" ] || { echo "guard not found: $DIRECT" >&2; exit 1; }
[ -f "$FENCE" ]  || { echo "guard not found: $FENCE" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

_REAL_HOME="$HOME"
FIX=$(mktemp -d "${_REAL_HOME}/.himmel-5098-fencefix-XXXXXX") || exit 1
trap 'rm -rf "$FIX"' EXIT

export HOME="$FIX/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.email t@example.invalid
git config --global user.name t
unset CODEX_EXTERNAL_WRITES_OK 2>/dev/null || true
unset EDIT_ON_MAIN_OK 2>/dev/null || true

mkrepo_committed() {  # mkrepo_committed <dir> <branch>
    git init -q -b "$2" "$1" >/dev/null 2>&1
    mkdir -p "$1/scripts/hooks" "$1/handovers"
    : > "$1/README.md"
    git -C "$1" add README.md >/dev/null 2>&1
    git -C "$1" commit -q -m init >/dev/null 2>&1
}

# $FIX/primary — main; $FIX/wt — linked worktree off it, feat/x.
mkrepo_committed "$FIX/primary" main
git -C "$FIX/primary" worktree add -q -b feat/x "$FIX/wt" >/dev/null 2>&1
# a failed fixture setup would leave every row testing nonexistent checkouts
for _d in "$FIX/primary" "$FIX/wt"; do
    if [ "$(git -C "$_d" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
        echo "fixture setup failed: $_d is not a work tree" >&2
        exit 1
    fi
done

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# _run <script> <json> -> echoes allow/block/?(rc=N)
_run() {
    local script="$1" json="$2" rc got
    printf '%s' "$json" | bash "$script" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    printf '%s' "$got"
}

# check_both <label> <block|allow> <json> — both entry modes must agree.
check_both() {
    local label="$1" expect="$2" json="$3" got
    got=$(_run "$DIRECT" "$json")
    if [ "$got" = "$expect" ]; then ok "$label (direct-exec)"; else bad "$label (direct-exec) — expected $expect got $got"; fi
    got=$(_run "$FENCE" "$json")
    if [ "$got" = "$expect" ]; then ok "$label (sourced/codex)"; else bad "$label (sourced/codex) — expected $expect got $got"; fi
}

_subst_row() { # label verdict command [cwd]
    local j
    j="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$3" | jq -Rs .),\"cwd\":\"${4:-$FIX/wt}\"}}"
    check_both "$1" "$2" "$j"
}
_PR="$FIX/primary"; _WR="$FIX/wt"

# _r5098 runs a row from cwd /tmp, the primary checkout and the worktree.
_r5098() { # label verdict template
    local c="$3"
    c="${c//@P@/$_PR}"; c="${c//@W@/$_WR}"
    _subst_row "$1, cwd /tmp" "$2" "$c" /tmp
    _subst_row "$1, cwd the primary" "$2" "$c" "$_PR"
    _subst_row "$1, cwd the worktree" "$2" "$c" "$_WR"
}
printf 'touch %s/pwned\n' "$_PR" > "$FIX/msg"
NL=$'\n'

echo "== HIMMEL-5098 eval of repository / file data =="
# shellcheck disable=SC2016  # row templates are literal shell text
{
# the two shapes in the ticket
_r5098 "201a commit -m then eval git log"            block "git commit -q --allow-empty -m 'touch @P@/pwned'; eval \"\$(git log -1 --format=%B)\""
_r5098 "201b heredoc message then eval git log"      block "git commit -q --allow-empty -F - <<'EOF'${NL}touch @P@/pwned${NL}EOF${NL}eval \"\$(git log -1 --format=%B)\""
# data readers
_r5098 "202a eval git log"                           block 'eval "$(git log -1 --format=%B)"'
_r5098 "202b eval git show, unquoted"                block 'eval $(git show -s --format=%B HEAD)'
_r5098 "202c eval git cat-file"                      block 'eval "$(git cat-file -p HEAD)"'
_r5098 "202d eval git -C wt log"                     block 'eval "$(git -C @W@ log -1 --format=%B)"'
_r5098 "202e eval cat file"                          block 'eval "$(cat @W@/msg)"'
_r5098 "202f eval head file"                         block 'eval "$(head -1 @W@/msg)"'
_r5098 "202g eval tail file"                         block 'eval "$(tail -n1 @W@/msg)"'
_r5098 "202h eval \$(<file)"                         block 'eval "$(<@W@/msg)"'
_r5098 "202i eval \$( < file)"                       block 'eval "$( < @W@/msg)"'
_r5098 "202j eval backticks git log"                 block 'eval "`git log -1 --format=%B`"'
_r5098 "202k eval reader in a pipeline"              block 'eval "$(git log -1 --format=%B | head -1)"'
_r5098 "202l eval reader after a benign command"     block 'eval "$(echo x; cat @W@/msg)"'
_r5098 "202m eval nested substitution"               block 'eval "$(echo "$(cat @W@/msg)")"'
_r5098 "202n eval /usr/bin/cat"                      block 'eval "$(/usr/bin/cat @W@/msg)"'
_r5098 "202o eval sed file"                          block 'eval "$(sed -n 1p @W@/msg)"'
_r5098 "202p eval word then substitution"            block 'eval echo hi "$(cat @W@/msg)"'
# the other interpreters
_r5098 "203a bash -c git log"                        block 'bash -c "$(git log -1 --format=%B)"'
_r5098 "203b sh -c cat"                              block 'sh -c "$(cat @W@/msg)"'
_r5098 "203c zsh -c head"                            block 'zsh -c "$(head -1 @W@/msg)"'
_r5098 "203d source <(git log)"                      block 'source <(git log -1 --format=%B)'
_r5098 "203e . <(cat file)"                          block '. <(cat @W@/msg)'
_r5098 "203f source <(<file)"                        block 'source <(<@W@/msg)'
_r5098 "203g bash -c with an eval of git log inside" block "bash -c 'eval \"\$(git log -1 --format=%B)\"'"
# behind a wrapper
_r5098 "204a nice eval git log"                      block 'nice eval "$(git log -1 --format=%B)"'
_r5098 "204b env FOO=1 bash -c cat"                  block 'env FOO=1 bash -c "$(cat @W@/msg)"'
_r5098 "204c timeout 5 sh -c git log"                block 'timeout 5 sh -c "$(git log -1 --format=%B)"'
_r5098 "204d command eval git log"                   block 'command eval "$(git log -1 --format=%B)"'
_r5098 "204e nice source <(cat file)"                block 'nice source <(cat @W@/msg)'
# variable indirection inside one command
_r5098 "205a var from git log then eval"             block 'm=$(git log -1 --format=%B); eval "$m"'
_r5098 "205b var from cat && eval"                   block 'm=$(cat @W@/msg) && eval "$m"'
_r5098 "205c read from process substitution"         block 'read -r m < <(git log -1 --format=%B); eval "$m"'
_r5098 "205d var from backticks then eval"           block 'm=`git log -1 --format=%B`; eval $m'
_r5098 "205e var then bash -c"                       block 'm=$(cat @W@/msg); bash -c "$m"'
_r5098 "205f reader after a semicolon in the substitution" block "m=\$(printf ''; cat @W@/msg); eval \"\$m\""
_r5098 "205g reader after a semicolon, backticks"    block "m=\`printf ''; cat @W@/msg\`; eval \"\$m\""
_r5098 "205h reader after a semicolon, bash -c"      block "m=\$(echo x; git log -1 --format=%B); bash -c \"\$m\""
_r5098 "206a source of data, shell word as argument" block "source \"\$(cat @W@/msg)\" bash"
_r5098 "206b dot of data, shell word as argument"    block ". \"\$(git log -1 --format=%B)\" sh"
_r5098 "206c bash option then <(cat file)"           block 'bash --noprofile <(cat @W@/msg)'
_r5098 "206d bash options then <(git log)"           block 'bash --norc --noprofile <(git log -1 --format=%B)'
_r5098 "206e source of literal, shell word argument" allow 'source ./env.sh bash'
_r5098 "206f bash option then <(echo literal)"       allow 'bash --noprofile <(echo ls)'
# escape-hiding class (backslash, $'..', a # comment opening a fake quote)
_r5098 "206a backslash inside the verb"              block 'eval "$(g\it log -1 --format=%B)"'
_r5098 "206b quotes inside the verb"                 block "eval \"\$(git 'lo'g -1 --format=%B)\""
_r5098 "206c ANSI-C quoted subcommand"               block "eval \"\$(git \$'log' -1 --format=%B)\""
_r5098 "206d empty quotes in cat"                    block "eval \"\$(c''at @W@/msg)\""
_r5098 "206e comment with a fake quote opener"       block "echo hi # '${NL}eval \"\$(git log -1 --format=%B)\""
_r5098 "206f escaped quote before the eval"          block "echo \\' ; eval \"\$(cat @W@/msg)\""
_r5098 "206g ANSI-C span with an escaped quote"      block "echo \$'it\\'s' ; eval \"\$(cat @W@/msg)\""
_r5098 "206h quoted eval name"                       block "'eval' \"\$(git log -1 --format=%B)\""
_r5098 "206i backslash in eval name"                 block 'ev\al "$(git log -1 --format=%B)"'
# ALLOW: literals and known-benign substitutions
_r5098 "210a eval literal double quotes"             allow 'eval "echo hi"'
_r5098 "210b eval literal single quotes"             allow "eval 'ls -la'"
_r5098 "210c eval ssh-agent"                         allow 'eval "$(ssh-agent -s)"'
_r5098 "210d eval pyenv init"                        allow 'eval "$(pyenv init -)"'
_r5098 "210e eval direnv"                            allow 'eval "$(direnv export bash)"'
_r5098 "210f eval date"                              allow 'eval "$(date +%s)"'
_r5098 "210g bash -c literal"                        allow "bash -c 'echo hi'"
_r5098 "210h bash -c echo substitution"              allow 'bash -c "$(echo ls)"'
_r5098 "210i script with a git log argument"         allow 'bash @W@/x.sh "$(git log -1 --format=%s)"'
_r5098 "210j source a literal file"                  allow 'source @W@/env.sh'
_r5098 "210k dot a literal file"                     allow '. @W@/env.sh'
_r5098 "210l plain git log"                          allow 'git log -1 --format=%B'
_r5098 "210m plain cat"                              allow 'cat @W@/msg'
_r5098 "210n git log into a variable only"           allow 'm=$(git log -1 --format=%B); echo "$m"'
_r5098 "210o eval of an unassigned variable"         allow 'eval "$m"'
_r5098 "210p eval var from a benign command"         allow 'm=$(date); eval "$m"'
_r5098 "210q nice ls"                                allow 'nice ls "$(git log -1 --format=%s)"'
}

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
