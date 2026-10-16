#!/usr/bin/env bash
# Unit test for scripts/hooks/block-write-into-main-checkout.sh — the
# rows: eval / source / `.` / bash -c / sh -c / zsh -c whose
# argument is (or contains) a command substitution that READS repository or
# file data (git log, git show, git cat-file, cat, head, tail, `$(<f)`) is
# denied, because the text scan never sees the write hidden in that data.
# Ordinary eval of a literal string and of a benign substitution stays allowed.
# every rule runs on the dequoted, tokenised words of the whole
# command (the shared tokenizer), so a quoted, escaped or spaced spelling of a
# shadowing word or a PATH change is the same word (rows 218-220), and an eval
# of ANY variable is denied (a variable set by an earlier call is not seen).
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
# primary cwd only: the interpreter-body check still denies there
_r5098p() { # label verdict template
    local c="$3"
    c="${c//@P@/$_PR}"; c="${c//@W@/$_WR}"
    _subst_row "$1, cwd the primary" "$2" "$c" "$_PR"
}
printf 'touch %s/pwned\n' "$_PR" > "$FIX/msg"
NL=$'\n'
_PAD=$(printf '%8200s' '' | tr ' ' a)

echo "== HIMMEL-5098 eval of repository / file data =="
# shellcheck disable=SC2016  # row templates are literal shell text
{
# the two shapes in the ticket
_r5098p "201a commit -m then eval git log"            block "git commit -q --allow-empty -m 'touch @P@/pwned'; eval \"\$(git log -1 --format=%B)\""
_r5098p "201b heredoc message then eval git log"      block "git commit -q --allow-empty -F - <<'EOF'${NL}touch @P@/pwned${NL}EOF${NL}eval \"\$(git log -1 --format=%B)\""
# data readers
# the other interpreters
_r5098p "203g bash -c with an eval of git log inside" block "bash -c 'eval \"\$(git log -1 --format=%B)\"'"
# behind a wrapper
# variable indirection inside one command
_r5098 "208d source =(echo literal)"                 allow 'source =(echo ls)'
# the allow-list is keyed on the whole argv shape, not the first word
_r5098 "214k ssh-agent -s"                           allow 'eval "$(ssh-agent -s)"'
_r5098 "214l ssh-agent -c -a socket"                 allow 'eval "$(ssh-agent -c -a /tmp/s.sock)"'
_r5098 "214m direnv export bash"                     allow 'eval "$(direnv export bash)"'
_r5098 "214n direnv hook zsh"                        allow 'eval "$(direnv hook zsh)"'
_r5098 "214o pyenv init - bash"                      allow 'eval "$(pyenv init - bash)"'
_r5098 "214p rbenv init -"                           allow 'eval "$(rbenv init -)"'
_r5098 "214q nodenv init"                            allow 'eval "$(nodenv init)"'
_r5098 "214r pyenv sh-shell"                         allow 'eval "$(pyenv sh-shell 3.9)"'
# a function, alias, PATH or hash -p can re-point a listed name
# an assignment is skipped only when the name is a valid identifier
# the shadowing rule is whole-command, and the allow-list is case-sensitive
_r5098 "217g control: source <(echo literal)"        allow 'source <(echo ls)'
_r5098 "217h control: lower-case echo and date"      allow 'eval "$(date +%s)"'
_r5098p "211f unlisted program after a pipe"          block 'eval "$(echo x | tee f)"'
_r5098 "212a source of toplevel plus path"           allow 'source "$(git rev-parse --show-toplevel)/scripts/lib/x.sh"'
_r5098 "206e source of literal, shell word argument" allow 'source ./env.sh bash'
_r5098 "206f bash option then <(echo literal)"       allow 'bash --noprofile <(echo ls)'
# escape-hiding class (backslash, $'..', a # comment opening a fake quote)
_r5098p "220e comment with a fake quote opener"       block "echo hi # '${NL}eval \"\$(git log -1 --format=%B)\""
# a shadowing word or PATH change is judged on the
# dequoted word, whatever quotes, backslashes or spacing spell it
# deferrals, folded in
# A generator whose output its arguments shape is only
# trusted when that output is computed and inert
_r5098 "222l control: eval echo of one word"         allow 'eval "$(echo ls)"'
_r5098 "222m control: bash -c printf of one word"    allow 'bash -c "$(printf ls)"'
_r5098 "222n control: numeric date format"           allow 'eval "$(date -u +%Y-%m-%d)"'
# a shell is matched by its basename, wherever it is spelled
_r5098 "223h control: /bin/sh runs a script"         allow '/bin/sh @W@/x.sh'
# a shell reading a redirected or piped standard input runs that data
_r5098 "224l control: script with a redirected input" allow 'bash @W@/x.sh < @W@/msg'
_r5098 "224m control: a pipe beside a script run"    allow 'cat @W@/msg | grep x; bash @W@/x.sh'
# a path is anyone's text: path generators count only where a path is read
_r5098 "225b toplevel inside a -c body"              block 'bash -c "cd $(git rev-parse --show-toplevel) && ls"'
_r5098 "225d control: script under the toplevel"     allow 'bash "$(git rev-parse --show-toplevel)/x.sh"'
# -s: the script is standard input, later words are positionals
_r5098 "226d control: -s after the script operand"    allow 'bash @W@/x.sh -s < @W@/msg'
# a heredoc body is located as the tokenizer reads it, not by the first <<
_r5098 "227e control: nested heredoc in a shell body"  allow "bash <<'EOF'${NL}cat > /tmp/x <<'X'${NL}hi${NL}X${NL}EOF"
_r5098 "227f control: second heredoc, literal body"    allow "cat <<'A' >/dev/null; bash <<'B'${NL}a${NL}A${NL}ls${NL}B"
# past 8 KiB the crude fallback cannot name a command held in a variable
_r5098 "228e control: padded variable argument"        allow ": ${_PAD}; ls \"\$HOME\""
_r5098 "228f control: padded assignment from date"     allow ": ${_PAD}; x=\$(date); echo \"\$x\""
_r5098 "228l control: padded quoted heredoc of prose"   allow "cat > @W@/n.md <<'EOF'${NL}\`foo\` is done! \`bar\` too.${NL}\$x\$y \"\$(cat f)\"${NL}${_PAD}${NL}EOF"
_r5098 "228n control: padded closing backtick ends its word" allow ": ${_PAD}; echo \`date\`/x"
_r5098 "228m control: padded <<- body with tab-led end" allow "cat > @W@/n.md <<-'EOF'${NL}\$x run${NL}${_PAD}${NL}	EOF"
# a quoted or escaped blank inside an assignment value is not a word break
_r5098 "228u control: padded quoted-blank assignment before ls" allow "A=\"x y\" ls; : ${_PAD}"
# a wrapper's option argument is part of the prefix, not the command
_r5098 "228za control: padded sudo option argument before ls" allow "sudo -u root ls \"\$HOME\"; : ${_PAD}"
# an ANSI-C span after a split assignment keeps its $: the name it decodes to is unknown
_r5098 "228ze control: padded ANSI-C argument after a quoted-blank assignment" allow "A='x y' printf \$'a\\tb'; : ${_PAD}"
# quoted heredoc prose naming a shell is not code, past 8 KiB too
_r5098 "228zf control: padded quoted heredoc naming bash x.sh" allow "cat > @W@/n.md <<'EOF'${NL}bash x.sh | sort runs the lint${NL}${_PAD}${NL}EOF"
# shell options: an o in a cluster takes a word, -c's body follows its options
_r5098 "230g control: bash -euo pipefail script"       allow 'bash -euo pipefail @W@/x.sh'
_r5098 "230h control: bash -c -- literal body"         allow "bash -c -- 'echo ok'"
_r5098 "230i control: bash -s with a positional"       allow 'bash -s "$(cat @W@/msg)"'
# under xargs a script operand keeps the data positional
_r5098 "231a control: xargs bash -n"                   allow "git ls-files '*.sh' | xargs bash -n @W@/x.sh"
_r5098 "231b control: xargs bash script"               allow "git ls-files '*.sh' | xargs bash scripts/lint.sh"
# a path command word whose basename is a variable names an unknown command
_r5098 "232d control: literal basename under \$HOME"  allow '"$HOME/bin/tool" "$(git log -1 --format=%s)"'
# a variable in option position may itself be -c
_r5098 "233i control: bash \$OPTS ./run.sh"             allow 'bash $OPTS ./run.sh'
_r5098 "233j control: bash -e \$X -c literal body"      allow "bash -e \$X -c 'ls'"
_r5098 "233k control: bash -x \$F"                      allow 'bash -x $F'
# pins for option shapes the judge probed
_r5098 "233p control: bash -O extglob -c literal"      allow "bash -O extglob -c 'ls'"
# an unquoted variable in a shell's argv, assigned earlier in the
# command from data (a non-generator substitution) or from text carrying -c
_r5098 "234i control: path literal var"                 allow 'F=@W@/x.sh; bash $F'
_r5098 "234j control: toplevel var"                     allow 'F=$(git rev-parse --show-toplevel)/x.sh; bash $F'
_r5098 "234k control: quoted data var is one word"      allow 'F=$(git log -1 --format=%s); bash "$F"'
_r5098 "234l control: data var only echoed"             allow 'F=$(git log -1 --format=%s); echo $F'
_r5098 "234m control: data var after the script"        allow 'F=$(git log -1 --format=%s); bash @W@/x.sh $F'
_r5098 "234n control: unrelated data var"               allow 'F=$(git log -1 --format=%s); bash -x @W@/x.sh'
_r5098 "234r control: quoted data var as the -o name"   allow 'F=$(git log -1 --format=%s); bash -o "$F" @W@/x.sh'
_r5098 "234s control: literal -o argument"              allow 'bash -o errexit @W@/x.sh'
# controls: ordinary commands that only mention the words
_r5098 "221a toplevel substitution as the command"   allow '"$(git rev-parse --show-toplevel)/scripts/x.sh" a'
_r5098 "221b script with a variable argument"        allow 'bash @W@/x.sh "$HOME"'
_r5098 "221c echo of shadowing words"                allow "echo 'hash alias PATH'"
_r5098 "221d grep for eval"                          allow 'grep -n eval @W@/x.sh'
_r5098 "221e source of a variable path"              allow 'source "$HOME/env.sh"'
_r5098 "221f quoted heredoc into bash, literal body" allow "bash <<'EOF'${NL}ls${NL}EOF"
_r5098 "221g literal here-string into bash"          allow "bash <<< 'ls'"
_r5098 "221h path command word"                      allow '"$HOME/bin/tool" x'
# only a path generator may build the command word
_r5098 "229g control: pwd builds the command path"   allow '"$(pwd)"/x'
_r5098 "229h control: toplevel builds a script path" allow '$(git rev-parse --show-toplevel)/scripts/x.sh'
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
_r5098 "210q nice ls"                                allow 'nice ls "$(git log -1 --format=%s)"'
}

echo "== HIMMEL-5349 inlined tokenizer matches the lib =="
# The hook carries a byte-identical copy of the shared tokenizer (a sourced lib
# would be unpinned by hook-integrity); the same block extraction as
# test-shell-tokenize.sh, which does not yet list this hook in its HOOKS.
_TK_LIB="$HOOKS/lib/shell-tokenize.sh"
_TK_B='# >>> BEGIN shell-tokenize (HIMMEL-3546; canonical: scripts/hooks/lib/shell-tokenize.sh) >>>'
_TK_E='# <<< END shell-tokenize <<<'
_tk_block() { awk -v b="$_TK_B" -v e="$_TK_E" '$0 == b {p = 1; n++} p {print} $0 == e {p = 0} END {if (n != 1) print "MARKERS:" n}' "$1"; }
_tk_lib=$(_tk_block "$_TK_LIB"); _tk_hook=$(_tk_block "$DIRECT")
if [ -n "$_tk_lib" ] && [ "$_tk_lib" = "$_tk_hook" ]; then ok "tokenizer block is byte-identical to the lib"
else bad "tokenizer block in $(basename "$DIRECT") differs from lib/shell-tokenize.sh (copy the lib's BEGIN/END block)"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
