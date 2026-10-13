# shellcheck shell=bash
# guard-empty-expansion.sh — re-read a command with its variable expansions
# removed (HIMMEL-5328, HIMMEL-5330, HIMMEL-5331). Sourced by
# block-bare-qmd-query.sh, block-git-stash.sh and block-read-secrets.sh.
#
# Those hooks match the command TEXT at command position. A variable expansion
# that expands to nothing (`${V:-}git stash`, `$V${Z}cat .env`, `$V qmd query x`,
# `git ${V:-} stash`, `R=Q; ${!R}git stash`, zsh `$V:t`, `$V[1,-3]`, `${(P)V}`)
# sits in front of, or between the words of, the protected command, and the
# regex reads the expansion as part of a different word. The hook cannot know
# what a variable holds, so it reads the command twice: as written, and with
# every expansion removed. The caller's own scan of the original text still
# runs, so the stripped form can only add a deny, never remove one.
#
# ponytail: every `${…}` and `$name` is dropped, empty or not, so a hook can
# over-deny a command whose expansion was a real, non-empty word that made the
# protected program a mere argument (`$RUNNER git stash`) — the safe direction;
# `$(…)` and `$'…'` are untouched. Upgrade path: track variable values across
# the command (HIMMEL-4178).
#
# ponytail: a `${…}` holding `$(`, a backtick, any quote or backslash (the flat
# quote scan ends early on nested double quotes and ANSI-C `$'\''`), or that the
# scanner cannot prove balanced is the class four review rounds kept finding new bypass spellings in,
# so when such a command also names the hook's protected target (TARGET_ERE) it
# is denied outright, whatever the scanner made of it; this over-denies a real
# `git stash "${X:-$(cmd)}"`-style call. Upgrade path: a real shell parser
# (HIMMEL-4178).
#
# guard_expansion_recheck HOOK INPUT_JSON COMMAND [TARGET_ERE]
#   returns 0 when the command holds no expansion, the stripped form equals it,
#   or the hook (re-run on the stripped form) allows it; 2 otherwise, with the
#   child's deny text on stderr.

# `$name`, `$1`, `$@` and zsh's braceless `:t`/`:r`/`[1,-3]` tails first, so
# `$V${Z}git` does not read `$Vgit` once `${Z}` is gone; then nested-brace
# expansions, innermost first (the loop label).
# shellcheck disable=SC2016 # sed program text: the `$` is a regex literal
_GEE_SED='s/\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?!])(:[A-Za-z]|\[[^]]*\])*//g'
# `${…}` is cut by a scanner, not a regex: a quoted brace inside it
# (`${V+'"'"'{}'"'"'}git stash`) must not end the expansion early. Single
# quotes, double quotes and backslashes are honoured; only `${` nests (a bare
# `{` is a pattern character, as in `${V#{}`); a `}` inside `$(…)` or backticks
# does not close it (`${V:-$(true })}git stash`); an unterminated expansion
# drops the rest of the line.
# shellcheck disable=SC2016 # awk program text
_GEE_AWK='{
  s = $0; out = ""; n = length(s); i = 1; hard = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "$" && substr(s, i + 1, 1) == "{") {
      depth = 1; i += 2; q = ""; bt = 0; L = 0
      while (i <= n && depth > 0) {
        c = substr(s, i, 1)
        if (c == "\047" || c == "\"" || c == "\\") hard = 1
        if (q == "\047") { if (c == "\047") q = "" }
        else if (c == "\\") i++
        else if (bt) { if (c == "`") bt = 0 }
        else if (c == "`") { bt = 1; hard = 1 }
        else if (c == "\047" && q == "") q = "\047"
        else if (c == "\"") q = (q == "\"") ? "" : "\""
        else if (c == "$" && substr(s, i + 1, 1) == "(") { L++; sq[L] = q; sp[L] = 0; q = ""; i++; hard = 1 }
        else if (L > 0 && q == "" && c == "(") sp[L]++
        else if (L > 0 && q == "" && c == ")") { if (sp[L] > 0) sp[L]--; else { q = sq[L]; L-- } }
        else if (L == 0 && q == "" && c == "$" && substr(s, i + 1, 1) == "{") { depth++; i++ }
        else if (L == 0 && q == "" && c == "}") depth--
        i++
      }
      if (depth > 0) hard = 1
    } else { out = out c; i++ }
  }
  if (mode == "hard") print hard + 0; else print out
}'

guard_expansion_recheck() {
    local hook=$1 input=$2 cmd=$3 target=${4:-} hard stripped child err rc depth=${GUARD_EXPANSION_DEPTH:-0}
    case "$cmd" in *'$'*) ;; *) return 0 ;; esac
    case "$depth" in
        *[!0-9]*|'') depth=0 ;;
    esac
    if [ "$depth" -ge 4 ]; then
        echo "guard-empty-expansion: refusing a command re-read more than 4 levels deep." >&2
        return 2
    fi
    if [ -n "$target" ]; then
        if ! hard=$(printf '%s' "$cmd" | LC_ALL=C tr '\n' '\001' | LC_ALL=C awk -v mode=hard "$_GEE_AWK"); then
            echo "guard-empty-expansion: cannot scan expansions - failing closed" >&2
            return 2
        fi
        if [ "$hard" = 1 ] && printf '%s' "$cmd" | LC_ALL=C tr '\n' ' ' | LC_ALL=C grep -Eqi -- "$target"; then
            echo "guard-empty-expansion: a \${...} holding a command substitution or an unbalanced quote sits in a command that names this guard's target - denied (the scan cannot prove what it expands to)." >&2
            return 2
        fi
    fi
    # newlines ride as SOH so an expansion that spans lines is one match.
    if ! stripped=$(printf '%s' "$cmd" | LC_ALL=C tr '\n' '\001' \
        | LC_ALL=C sed -E "$_GEE_SED" | LC_ALL=C awk "$_GEE_AWK" | LC_ALL=C tr '\001' '\n'); then
        echo "guard-empty-expansion: cannot strip expansions - failing closed" >&2
        return 2
    fi
    [ "$stripped" != "$cmd" ] || return 0
    if ! child=$(jq -c --arg c "$stripped" '
        if (.tool_input | has("command")) and .tool_input.command != null
        then .tool_input.command = $c else .tool_input.cmd = $c end' <<<"$input" 2>/dev/null); then
        echo "guard-empty-expansion: cannot build the stripped call - failing closed" >&2
        return 2
    fi
    if err=$(GUARD_EXPANSION_DEPTH=$((depth + 1)) "${BASH:-bash}" "$hook" <<<"$child" 2>&1 >/dev/null); then
        return 0
    else
        rc=$?
    fi
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    echo "    (denied with its variable expansions removed — a variable that expands to nothing leaves this command; rc=$rc)" >&2
    return 2
}
