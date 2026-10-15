#!/usr/bin/env bash
# test-guard-empty-expansion.sh — block-bare-qmd-query.sh and block-read-secrets.sh
# deny their protected command behind a variable expansion that expands to
# nothing, and keep allowing read-only
# look-alikes that name no protected target. block-git-stash.sh no longer calls
# the expansion lib; its literal rows stay below.
#
# Nothing is executed: each command is only piped to a hook as JSON, with a
# scratch HOME. Platform guard: bash 3.2-safe; needs jq (SKIP without).
# shellcheck disable=SC2016  # commands are literal text with $ expansions, never expanded here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/gee.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/cwd"

pass=0; fail=0

# verdict <hook> <command> -> V=deny|allow
verdict() {
  local json rc
  json=$(jq -cn --arg c "$2" --arg d "$T/cwd" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  (cd "$T/cwd" && printf '%s' "$json" | env -i HOME="$T/home" PATH="$PATH" TMPDIR="$T" \
    bash "$HERE/$1" >/dev/null 2>&1)
  rc=$?
  case "$rc" in 2) V=deny ;; 0) V=allow ;; *) V="rc=$rc" ;; esac
}

check() {  # <want> <hook> <command>
  verdict "$2" "$3"
  if [ "$V" = "$1" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL $2: want $1, got $V: $3"
  fi
}

# the protected command, then each way an empty expansion hides it
deny_shapes() {  # <hook> <program words before the arguments> <arguments>
  local h=$1 p=$2 a=$3
  # shellcheck disable=SC2016  # the commands are literal text with $ expansions
  {
    check deny "$h" "$p $a"
    check deny "$h" "\${V:-}$p $a"
    check deny "$h" "\${V%x}$p $a"
    check deny "$h" "R=Q; \${!R}$p $a"
    check deny "$h" "\$V\${Z}$p $a"
    check deny "$h" "\$V $p $a"
    check deny "$h" "V=/; \$V:t$p $a"
    check deny "$h" "V=ab; \${V[1,-3]}$p $a"
    check deny "$h" "V=Q; \${(P)V}$p $a"
    check deny "$h" "echo hi; \${V:-}$p $a"
    # a quoted brace inside the expansion must not end it early
    check deny "$h" "\${V+'{}'}$p $a"
    check deny "$h" "\${V+'}'}$p $a"
    check deny "$h" "\${V+\"{\"}$p $a"
    check deny "$h" "\${V:-\\}}$p $a"
    check deny "$h" "\${V#{}$p $a"
    check deny "$h" "\${V:-\${Z}}$p $a"
    # a brace inside a command substitution must not end the expansion
    check deny "$h" "\${V:-\$(true })}$p $a"
    check deny "$h" "\${V:-\`true }\`}$p $a"
    check deny "$h" "\${V:-\$(echo ')}')}$p $a"
    # a quoted paren inside the substitution must not end it (delta round)
    check deny "$h" "\${V:-\$(printf \"\" \")\"; true })}$p $a"
    check deny "$h" "\${V:-\$(echo \"\$(true })\")}$p $a"
    check deny "$h" "\${V:-\$( (true) ; true })}$p $a"
    # a substitution the scanner cannot prove balanced fails closed (ruling)
    check deny "$h" "\${V:-\$(echo \"}$p $a"
    check deny "$h" "\${V:-\`echo \"}$p $a"
    # nested double quotes and an ANSI-C quote inside the expansion end the
    # flat quote scan early; any quote or backslash in the body fails closed
    check deny "$h" "\${V+\"\${Z:-\"}\"}\"}$p $a"
    check deny "$h" "\${V+\$'\\'}'}$p $a"
    # a body is an allowlist: a `$` not followed by `{`, a bracket or a paren
    # fails closed
    check deny "$h" "\${V+\$[}]}$p $a"
    check deny "$h" "\${V:-\$((1))}$p $a"
  }
}

# block-git-stash.sh keeps only its literal core: an empty expansion in front of
# or inside the command is an accepted miss. The expansion lib is
# still covered through block-bare-qmd-query.sh and block-read-secrets.sh.
check deny block-git-stash.sh 'git stash'
deny_shapes block-bare-qmd-query.sh 'qmd' 'query hello'
check deny block-bare-qmd-query.sh 'qmd ${V:-} query hello'
check deny block-bare-qmd-query.sh 'qmd $V search hello'
deny_shapes block-read-secrets.sh 'cat' '.env'
check deny block-read-secrets.sh 'cat ${V:-} .env'

# a default word is what the command runs when the variable is unset or empty:
# the protected program can ride in it
for op in ':-' '-' ':=' '=' ':+' '+'; do
  check deny block-bare-qmd-query.sh "\${V${op}qmd} query hello"
  check deny block-read-secrets.sh "\${V${op}cat} .env"
done
# each default expansion is set or unset on its own: A unset, B empty
check deny block-read-secrets.sh '${A:-cat} ${B:-x} .env'
check deny block-read-secrets.sh '${A:-cat} ${B:-x} ${C:-y} .env'
check deny block-read-secrets.sh '${B:-x} ${A:-cat} .env'
check allow block-read-secrets.sh '${A:-cat} ${B:-x} README.md'
# past the combination cap only the all-words form is read; a huge count must
# neither skip the check nor loop (63 and 64 expansions overflowed a bash shift)
for n in 6 63 64 70; do
  tail=$(i=0; while [ "$i" -lt "$n" ]; do printf ' ${Z:-}'; i=$((i+1)); done)
  check deny block-read-secrets.sh '${V:-cat} .env'"$tail"
done
check deny block-read-secrets.sh '${V:-${Z:-cat}} .env'
check allow block-git-stash.sh '${A:-git} ${B:-x} stash list'
check allow block-git-stash.sh '${V} stash drop'
check allow block-git-stash.sh '${V:-git} stash list'
check allow block-git-stash.sh '${V:-echo} stash drop'

# read-only look-alikes that name no protected target stay allowed
check allow block-git-stash.sh 'echo ${V:-x}'
# a command substitution inside an expansion stays allowed when no target is named
for h in block-git-stash.sh block-bare-qmd-query.sh block-read-secrets.sh; do
  check allow "$h" 'echo "${X:-$(date)}"'
  check allow "$h" 'ls "${D:-$(pwd)}"'
  check allow "$h" 'git log "${R:-$(cat f)}"'
done
check allow block-git-stash.sh 'ls $D'
check allow block-git-stash.sh 'git stash list'
check allow block-git-stash.sh '${V:-}git stash list'
check allow block-git-stash.sh 'git ${V:-} stash show'
check allow block-git-stash.sh 'git ${V:-} status'
check allow block-git-stash.sh 'grep -rn "git stash" $DIR'
check allow block-bare-qmd-query.sh 'echo ${V:-x}'
check allow block-bare-qmd-query.sh 'ls $D'
check allow block-bare-qmd-query.sh 'grep qmd $F'
check allow block-bare-qmd-query.sh 'qmd ${V:-} status'
check allow block-bare-qmd-query.sh '${V:-}qmd get $ID'
check allow block-bare-qmd-query.sh 'echo qmd query $X'
check allow block-read-secrets.sh 'echo ${V:-x}'
check allow block-read-secrets.sh 'ls $D'
check allow block-read-secrets.sh 'cat $F'
check allow block-read-secrets.sh 'cat ${V:-} README.md'
check allow block-read-secrets.sh '${V:-}cat README.md'
check allow block-read-secrets.sh 'grep -n foo "$DIR/notes.md"'

echo "guard-empty-expansion: $pass passed, $fail failed"
[ "$fail" = 0 ]
