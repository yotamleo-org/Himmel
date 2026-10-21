#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-git-stash.sh.
#
# Usage: bash scripts/hooks/test-block-git-stash.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-git-stash.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

FAILED=0

run_case() {
    local input="$1"
    local env_assign="${2:-}"
    if [ -n "$env_assign" ]; then
        printf '%s' "$input" | env "$env_assign" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label - expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# --- BLOCK cases (expect rc=2): every shape that writes the SHARED refs/stash ---
assert_rc "bare git stash"            2 "$(run_case "$(j_bash 'git stash')")"
assert_rc "git stash push"            2 "$(run_case "$(j_bash 'git stash push -m wip')")"
assert_rc "git stash save"            2 "$(run_case "$(j_bash 'git stash save wip')")"
assert_rc "git stash pop"             2 "$(run_case "$(j_bash 'git stash pop')")"
assert_rc "git stash drop"            2 "$(run_case "$(j_bash 'git stash drop stash@{0}')")"
assert_rc "git stash clear"           2 "$(run_case "$(j_bash 'git stash clear')")"
assert_rc "git stash branch"          2 "$(run_case "$(j_bash 'git stash branch wip stash@{0}')")"
assert_rc "git stash store"           2 "$(run_case "$(j_bash 'git stash store -m x deadbeef')")"
# Bare stash WITH options is still `push` — the option forms must not read as a
# verb-less allow.
assert_rc "git stash -u"              2 "$(run_case "$(j_bash 'git stash -u')")"
assert_rc "git stash --all"           2 "$(run_case "$(j_bash 'git stash --all')")"
assert_rc "git stash -- path"         2 "$(run_case "$(j_bash 'git stash -- scripts/x.sh')")"
# codex-1 (CR r2): a bare stash whose next token is a redirection, a comment or
# a subshell close is still a bare stash.
assert_rc "git stash >file"           2 "$(run_case "$(j_bash 'git stash >/tmp/out')")"
assert_rc "git stash 2>&1"            2 "$(run_case "$(j_bash 'git stash 2>&1 | cat')")"
assert_rc "git stash # comment"       2 "$(run_case "$(j_bash 'git stash # save wip')")"
assert_rc "(git stash)"               2 "$(run_case "$(j_bash '(git stash)')")"
# The cross-worktree shapes that make this guard necessary: an explicit
# repo/git-dir still lands on the SAME shared ref.
assert_rc "git -C <path> stash drop"  2 "$(run_case "$(j_bash 'git -C /c/repo/.claude/worktrees/other stash drop')")"
assert_rc "git --git-dir= stash pop"  2 "$(run_case "$(j_bash 'git --git-dir=/c/repo/.git stash pop')")"
assert_rc "git --git-dir <d> stash"   2 "$(run_case "$(j_bash 'git --git-dir /c/repo/.git stash')")"
assert_rc "git -c k=v stash pop"      2 "$(run_case "$(j_bash 'git -c core.pager=cat stash pop')")"
# codex-2 (CR r4): a git global option's value may be QUOTED and then carries
# spaces. An unquoted-only value token stopped at the space and dropped `stash`
# out of position, so these evaded the guard entirely.
assert_rc "git -c 'q=a b' stash drop"  2 "$(run_case "$(j_bash "git -c 'foo.bar=a b' stash drop")")"
assert_rc "git -c \"q=a b\" stash drop" 2 "$(run_case "$(j_bash 'git -c "foo.bar=a b" stash drop')")"
assert_rc "git -C 'p with space' pop"  2 "$(run_case "$(j_bash "git -C '/c/re po' stash pop")")"
# Command position, not first position: a chained clause and the .exe / path /
# wrapper spellings the sibling grammar also covers.
assert_rc "chained ; git stash drop"  2 "$(run_case "$(j_bash 'git status; git stash drop')")"
assert_rc "git.exe stash pop"         2 "$(run_case "$(j_bash 'git.exe stash pop')")"
assert_rc "/usr/bin/git stash clear"  2 "$(run_case "$(j_bash '/usr/bin/git stash clear')")"
assert_rc "env prefix git stash pop"  2 "$(run_case "$(j_bash 'GIT_PAGER=cat git stash pop')")"
assert_rc "uppercase GIT STASH DROP"  2 "$(run_case "$(j_bash 'GIT STASH DROP')")"
# An allowed read does NOT launder a mutation later in the same command line.
assert_rc "stash list; stash drop"    2 "$(run_case "$(j_bash 'git stash list; git stash drop')")"
# codex-1 (CR r1): a backslash line continuation is whitespace to the shell, and
# the guard folds newlines to ';' before matching — so `git \<newline>stash drop`
# must still be refused, at every token boundary of the rule.
assert_rc "continuation before stash" 2 "$(run_case "$(j_bash 'git \
stash drop')")"
assert_rc "continuation before verb"  2 "$(run_case "$(j_bash 'git stash \
pop')")"
assert_rc "continuation before flag"  2 "$(run_case "$(j_bash 'git stash \
-u')")"
assert_rc "continuation in -C value"  2 "$(run_case "$(j_bash 'git -C \
/c/repo stash clear')")"

# refs/stash is an ordinary ref, reachable through low-level
# plumbing that bypasses the `stash` keyword grammar entirely.
assert_rc "update-ref -d refs/stash"   2 "$(run_case "$(j_bash 'git update-ref -d refs/stash')")"
assert_rc "update-ref write refs/stash" 2 "$(run_case "$(j_bash 'git update-ref refs/stash deadbeef')")"
assert_rc "symbolic-ref -d refs/stash" 2 "$(run_case "$(j_bash 'git symbolic-ref -d refs/stash')")"
assert_rc "update-ref -d via -C worktree" 2 "$(run_case "$(j_bash 'git -C /c/repo/.claude/worktrees/other update-ref -d refs/stash')")"
# `update-ref --stdin` reads its ref
# commands from STDIN DATA, so `refs/stash` in a piped `printf` sits in a
# DIFFERENT clause than `update-ref` and the same-clause rule above never
# sees it — refuse `--stdin` unconditionally instead (the batch target is
# opaque to a command-string regex).
assert_rc "update-ref --stdin (refs/stash via piped data)" 2 "$(run_case "$(j_bash "printf 'delete refs/stash\n' | git update-ref --stdin")")"
assert_rc "update-ref --stdin (unrelated target, still refused)" 2 "$(run_case "$(j_bash "printf 'delete refs/heads/foo\n' | git update-ref --stdin")")"
# The command-position model reads words after quote removal, so a quoted or
# backslashed spelling of refs/stash or --stdin is the same word.
assert_rc 'update-ref -d refs/sta\sh' 2 "$(run_case "$(j_bash 'git update-ref -d refs/sta\sh')")"
assert_rc 'update-ref -d refs/"stash"' 2 "$(run_case "$(j_bash 'git update-ref -d refs/"stash"')")"
assert_rc 'update-ref --st"d"in' 2 "$(run_case "$(j_bash 'printf "delete refs/stash\n" | git update-ref --st"d"in')")"

# --- ALLOW cases (expect rc=0) ---
assert_rc "git stash list"            0 "$(run_case "$(j_bash 'git stash list')")"
assert_rc "git stash show -p"         0 "$(run_case "$(j_bash 'git stash show -p stash@{0}')")"
assert_rc "git stash apply"           0 "$(run_case "$(j_bash 'git stash apply stash@{0}')")"
assert_rc "git stash create"          0 "$(run_case "$(j_bash 'git stash create')")"
assert_rc "git stash --help"          0 "$(run_case "$(j_bash 'git stash --help')")"
assert_rc "git -C <path> stash list"  0 "$(run_case "$(j_bash 'git -C /c/repo stash list')")"
assert_rc "git -c 'q=a b' stash list" 0 "$(run_case "$(j_bash "git -c 'foo.bar=a b' stash list")")"
# The race-free snapshot the deny message prescribes must not be denied by the
# very guard that prescribes it: `create` writes no ref, and the `$(` puts it at
# command position, so both halves have to pass.
# shellcheck disable=SC2016  # the literal $(...) is the payload under test
assert_rc "tag \"$(git stash create)\""  0 "$(run_case "$(j_bash 'git tag wip-leg16 "$(git stash create)"')")"
assert_rc "git stash apply <tag>"     0 "$(run_case "$(j_bash 'git stash apply wip-leg16')")"
# The continuation tolerance must not swallow the verb: a continued READ is
# still a read. And SEP requires the backslash, so a plain `;` stays a command
# boundary — `stash` alone is not git.
assert_rc "continuation before list"  0 "$(run_case "$(j_bash 'git stash \
list')")"
assert_rc "git ; stash drop"          0 "$(run_case "$(j_bash 'git status; stash drop')")"
# The whole point of the COMMAND-POSITION anchor: reading/searching for the
# string must never be refused (this suite's own source contains it).
assert_rc "grep for 'git stash'"      0 "$(run_case "$(j_bash 'grep -rn "git stash" scripts/')")"
assert_rc "grep for git stash drop"   0 "$(run_case "$(j_bash 'grep -rn "git stash drop" scripts/hooks/')")"
assert_rc "comment mentions git stash" 0 "$(run_case "$(j_bash 'echo "# never git stash pop here"')")"
assert_rc "cat the guard itself"      0 "$(run_case "$(j_bash 'cat scripts/hooks/block-git-stash.sh')")"
# Neighbouring git verbs are none of this hook's business.
assert_rc "git status"                0 "$(run_case "$(j_bash 'git status -sb')")"
assert_rc "git push"                  0 "$(run_case "$(j_bash 'git push')")"
assert_rc "gitk stash"                0 "$(run_case "$(j_bash 'gitk stash')")"
# The sanctioned alternative must not be caught by its own deny message.
assert_rc "checkpoint ref update"     0 "$(run_case "$(j_bash 'git update-ref refs/checkpoints/leg16 HEAD')")"
# Non-shell tools are out of scope.
assert_rc "Read tool payload"         0 "$(run_case '{"tool_name":"Read","tool_input":{"command":"git stash drop"}}')"

# --- MALFORMED JSON case (expect rc=2, fail closed) ---
assert_rc "truncated JSON + stash drop" 2 "$(run_case '{"tool_name":"Bash","tool_input":{"command":"git stash drop"')"

# --- EMPTY/BLANK stdin (expect rc=2, fail closed):
# `read -d ''` on EOF leaves $input empty with no error to catch, and `jq
# <<<""` emits zero values with zero errors, so the malformed-JSON guard
# never fired and this silently fell open (rc=0) before the explicit blank
# check was added.
assert_rc "empty stdin"      2 "$(run_case '')"
assert_rc "whitespace-only stdin" 2 "$(run_case '   ')"

# --- NON-STRING command field (expect rc=2, fail closed):
# jq's `+` is type-strict, so a present-but-non-string
# `command` (e.g. a JSON array) made the combined extraction throw a type
# error that the `catch empty` swallowed, silently blanking BOTH tool and
# cmd and falling through to allow. The hook now closes it by EXPLICITLY
# erroring (`error("non-string-command")`) whenever `command`/`cmd` is
# present with a non-string, non-null type -- caught by the same
# `if ! result=$(...)` branch as malformed JSON, so it fails CLOSED. (An
# earlier `|tostring` attempt was rejected: it renders arrays COMPACT,
# while old's `jq -r` rendered them pretty-printed multi-line, and that
# multi-line shape was what actually let the stash-mutation match still
# fire on old -- `tostring` doesn't reproduce it, so explicit fail-closed
# is the correct fix, not a tostring-based allow.)
assert_rc "array command + stash drop" 2 "$(run_case '{"tool_name":"Bash","tool_input":{"command":["git stash drop"]}}')"
# jq's `//` treats a present false as absent; select on the key.
assert_rc "command:false + cmd:ls" 2 "$(run_case '{"tool_name":"Bash","tool_input":{"command":false,"cmd":"ls"}}')"
# A null command still reads cmd, as `//` did: never allow what main refused.
assert_rc "command:null + cmd:stash drop" 2 "$(run_case '{"tool_name":"Bash","tool_input":{"command":null,"cmd":"git stash drop"}}')"

# --- wrappers and quote splitting are read as the shell runs them ---
assert_rc "bash -c 'git stash'"  2 "$(run_case "$(j_bash "bash -c 'git stash'")")"
assert_rc "g'i't stash"          2 "$(run_case "$(j_bash "g'i't stash")")"
assert_rc "command git stash drop" 2 "$(run_case "$(j_bash 'command git stash drop')")"
assert_rc "exec git stash pop"   2 "$(run_case "$(j_bash 'exec git stash pop')")"
assert_rc "nohup git stash"      2 "$(run_case "$(j_bash 'nohup git stash')")"
assert_rc "time git stash clear" 2 "$(run_case "$(j_bash 'time git stash clear')")"
assert_rc "timeout 5 git stash drop" 2 "$(run_case "$(j_bash 'timeout 5 git stash drop')")"
assert_rc "xargs git stash drop" 2 "$(run_case "$(j_bash 'echo x | xargs git stash drop')")"
assert_rc "find -exec git stash drop" 2 "$(run_case "$(j_bash 'find . -maxdepth 0 -exec git stash drop \;')")"
assert_rc "eval 'git stash pop'" 2 "$(run_case "$(j_bash "eval 'git stash pop'")")"
# shellcheck disable=SC2016  # the literal $v is the payload under test
assert_rc "git stash \$v (a verb the model cannot read)" 2 "$(run_case "$(j_bash 'v=drop; git stash $v')")"
assert_rc "5745 echo 'git stash' (data)"              0 "$(run_case "$(j_bash "echo 'git stash'")")"

# --- The path prefix stops at an open paren (linear on a `(` run) ---
# Every `(` is a CMDPOS anchor; a prefix that crosses `(` rescans the whole run
# from each one (quadratic), and a timed-out PreToolUse hook does not deny.
# shellcheck disable=SC2046 # one word per repeat is the point
printf -v pad_o '(%.0s' $(seq 1 20000)
printf -v pad_a 'a%.0s' $(seq 1 20000)
# Timed against a same-size run of a non-paren character in the same process, so
# runner load scales both sides; a fixed wall-clock budget failed on loaded CI.
now_ms() { local n; n=$(date +%s%N 2>/dev/null); case "$n" in ''|*[!0-9]*) echo $((SECONDS * 1000)) ;; *) echo $((n / 1000000)) ;; esac; }
t0=$(now_ms)
run_case "$(j_bash "echo hi$pad_a; git stash drop")" >/dev/null
t1=$(now_ms)
assert_rc 'open-paren run x20000 then git stash drop (linear)' 2 "$(run_case "$(j_bash "echo hi$pad_o; git stash drop")")"
t2=$(now_ms)
if [ $((t2 - t1)) -gt $(( (t1 - t0) * 3 + 500 )) ]; then
    echo "FAIL open-paren run x20000 took $((t2 - t1))ms (control $((t1 - t0))ms, budget 3x + 500ms)"; FAILED=$((FAILED + 1)); fi
# A `(` or `)` inside the path must still reach the program name.
assert_rc 'path with (b) then git stash drop'         2 "$(run_case "$(j_bash '/tmp/a(b)/git stash drop')")"
assert_rc 'quoted path with (b) git stash drop' 2 "$(run_case "$(j_bash '"/tmp/a(b)/git" stash drop')")"
assert_rc 'path with ) then git stash drop'           2 "$(run_case "$(j_bash '/tmp/a)/git stash drop')")"
assert_rc 'path with )) then git stash drop'          2 "$(run_case "$(j_bash '/tmp/a))/git stash drop')")"
assert_rc 'path with ){ then git stash drop'          2 "$(run_case "$(j_bash '/tmp/a){/git stash drop')")"
assert_rc 'c: path with (x86) then git stash drop'    2 "$(run_case "$(j_bash 'c:/p(x86)/git stash drop')")"
assert_rc 'sudo path with (b) then git stash drop'    2 "$(run_case "$(j_bash 'sudo /tmp/a(b)/git stash drop')")"
assert_rc 'path with (b) then git stash list allowed' 0 "$(run_case "$(j_bash '/tmp/a(b)/git stash list')")"

# --- the command-position corpus: the command-position model reads where a command
# runs, so quoted data and heredoc bodies are not commands and a cd never hides
# one. The cwd rows pin the verdict: refs/stash is shared by every worktree, so
# no cd changes it.
assert_rc "jq string '.[] | git stash drop' is data" 0 "$(run_case "$(j_bash "jq '.[] | git stash drop' notes.json")")"
assert_rc "gh --jq string with a pipe and git stash" 0 "$(run_case "$(j_bash "gh run view 5 --json jobs --jq '(.jobs | git stash pop)'")")"
assert_rc "heredoc body naming git stash drop is data" 0 "$(run_case "$(j_bash "cat <<'EOF' > notes.txt
git stash drop
EOF")")"
assert_rc "heredoc body feeding wc is data" 0 "$(run_case "$(j_bash "wc -l <<EOF
git stash pop
EOF")")"
# A heredoc fed to a shell is a script, not data: the model marks such a
# position opaque and the regex keeps reading the text.
assert_rc "heredoc into bash runs git stash drop" 2 "$(run_case "$(j_bash "bash <<'EOF'
git stash drop
EOF")")"
assert_rc "heredoc into sh -s runs git stash drop" 2 "$(run_case "$(j_bash "sh -s <<EOF
git stash drop
EOF")")"
assert_rc "eval of a command substitution runs git stash drop" 2 "$(run_case "$(j_bash "eval \"\$(cat <<'EOF'
git stash drop
EOF
)\"")")"
# A shell option the model does not read, and an interpreter payload, leave a
# position with no parsed body: the regex still reads the text.
assert_rc "bash --rcfile heredoc runs git stash drop" 2 "$(run_case "$(j_bash "bash --rcfile /dev/null <<'EOF'
git stash drop
EOF")")"
assert_rc "zsh --emulate sh heredoc runs git stash drop" 2 "$(run_case "$(j_bash "zsh --emulate sh <<'EOF'
git stash drop
EOF")")"
assert_rc "bash --init-file -c body runs git stash drop" 2 "$(run_case "$(j_bash "bash --init-file /dev/null -c 'true; git stash drop'")")"
assert_rc "rbash --rcfile heredoc runs git stash drop" 2 "$(run_case "$(j_bash "rbash --rcfile /dev/null <<'EOF'
git stash drop
EOF")")"
assert_rc "rbash --init-file -c body runs git stash drop" 2 "$(run_case "$(j_bash "rbash --init-file /dev/null -c 'true; git stash drop'")")"
# Every shell the bash-ast model knows must also be in the guards' interp list, or the regex fallback skips it.
drift=""
for sh_name in $(sed -n 's/^def _shells: \[\(.*\)\];$/\1/p' "$(dirname "$HOOK")/../lib/bash-ast.sh" | tr -d '"' | tr ',' ' '); do
    for guard in block-git-stash.sh block-graphify-egress.sh; do
        grep -q "def interp:.*[(|]${sh_name}[|)]" "$(dirname "$HOOK")/$guard" || drift="$drift $guard:$sh_name"
    done
done
if [ -z "$drift" ]; then echo "PASS every bash-ast _shells name is in both guards' interp list"; else echo "FAIL interp list drifted from bash-ast _shells:$drift"; FAILED=$((FAILED + 1)); fi
assert_rc "python3 heredoc os.system runs git stash drop" 2 "$(run_case "$(j_bash "python3 - <<'EOF'
import os
os.system('git stash drop')
EOF")")"
assert_rc "perl -e system runs git stash drop" 2 "$(run_case "$(j_bash "perl -e 'system(q(git stash drop))'")")"
assert_rc "node -e execSync runs git stash drop" 2 "$(run_case "$(j_bash "node -e 'require(\"child_process\").execSync(\"git stash drop\")'")")"
assert_rc "awk system runs git stash drop" 2 "$(run_case "$(j_bash "awk 'BEGIN { system(\"git stash drop\") }'")")"
assert_rc "bash --rcfile heredoc, no stash in it" 0 "$(run_case "$(j_bash "bash --rcfile /dev/null <<'EOF'
git stash list
EOF")")"
assert_rc "heredoc into bash, no stash in it" 0 "$(run_case "$(j_bash "bash <<'EOF'
git stash list
EOF")")"
assert_rc "cd right of a pipe, then git stash drop" 2 "$(run_case "$(j_bash 'echo x | cd sub && git stash drop')")"
assert_rc "cd behind ||, then git stash drop" 2 "$(run_case "$(j_bash 'cd R || cd V && git stash drop')")"
assert_rc "cd right of a pipe, then git stash list" 0 "$(run_case "$(j_bash 'echo x | cd sub && git stash list')")"
assert_rc "cd behind ||, then git stash list" 0 "$(run_case "$(j_bash 'cd R || cd V && git stash list')")"

# --- quote- and backslash-split spellings of the verb reach the same denial
assert_rc "backslash-split verb (s\\tash drop)" 2 "$(run_case "$(j_bash 'git s\tash drop')")"
assert_rc "empty single quotes in the verb (sta''sh drop)" 2 "$(run_case "$(j_bash "git sta''sh drop")")"
assert_rc "empty double quotes in the verb (sta\"\"sh pop)" 2 "$(run_case "$(j_bash 'git sta""sh pop')")"
assert_rc "empty single quotes in the program (g''it stash drop)" 2 "$(run_case "$(j_bash "g''it stash drop")")"
assert_rc "line continuation inside the verb (sta\\<newline>sh drop)" 2 "$(run_case "$(j_bash "git sta\\
sh drop")")"
assert_rc "quote-split verb with an allowed subcommand (sta''sh list)" 0 "$(run_case "$(j_bash "git sta''sh list")")"

# --- a missing shfmt denies a command that names the guarded verb, and the
# message names shfmt; a command that does not mention it never pays for it.
NOSH=$(mktemp -d "${TMPDIR:-/tmp}/block-git-stash-nosh.XXXXXX") || exit 1
trap 'rm -rf "$NOSH"' EXIT
oifs=$IFS; IFS=:
for d in $PATH; do
    for t in "$d"/*; do
        case "${t##*/}" in shfmt) ;; *) [ -e "$NOSH/${t##*/}" ] || ln -s "$t" "$NOSH/${t##*/}" 2>/dev/null ;; esac
    done
done
IFS=$oifs
# stderr is the captured stream here, stdout is discarded
# shellcheck disable=SC2069
nosh_case() { printf '%s' "$(j_bash "$1")" | PATH="$NOSH" bash "$HOOK" 2>&1 >/dev/null; echo "rc=$?"; }
out=$(nosh_case 'git stash drop')
case "$out" in *shfmt*"rc=2") echo "PASS no shfmt: the verb is denied and the message names shfmt" ;; *) echo "FAIL no shfmt: the verb is denied and the message names shfmt - $out"; FAILED=$((FAILED + 1)) ;; esac
out=$(nosh_case 'git status')
case "$out" in "rc=0") echo "PASS no shfmt: a command without the verb is not denied" ;; *) echo "FAIL no shfmt: a command without the verb is not denied - $out"; FAILED=$((FAILED + 1)) ;; esac

# --- BYPASS case ---
assert_rc "GIT_STASH_OK bypass"       0 "$(run_case "$(j_bash 'git stash drop')" "GIT_STASH_OK=1")"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
