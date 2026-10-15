# shellcheck shell=bash
# guard-empty-expansion.sh — re-read a command with its variable expansions
# removed. Sourced by
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
# The command is re-read a second time with each `${name[:]-word}`,
# `${name[:]=word}` and `${name[:]+word}` replaced by its word, because the word
# is what runs when the variable is unset or empty (`${V:-git} stash drop`);
# dropping the expansion alone never shows it. A plain `${V}` has
# no word and is only dropped.
#
# ponytail: every `${…}` and `$name` is dropped, empty or not, so a hook can
# over-deny a command whose expansion was a real, non-empty word that made the
# protected program a mere argument (`$RUNNER git stash`) — the safe direction;
# `$(…)` and `$'…'` are untouched. A default word is read as if the variable
# were unset, so the word of `${V:+x}` is taken even when V is empty (also the
# safe direction). Upgrade path: track variable values across the command
#
# ponytail: a `${…}` body is an ALLOWLIST (letters, digits, `_`, `: - + = ? # % /
# @ * ^ , . ~`, space, or a nested `${…}`); anything else in it (`$(`, a backtick,
# a quote, a backslash, `$[`, a bracket or paren, a bare `$`), or a body the
# scanner cannot prove balanced, is the class five review rounds kept finding new
# bypass spellings in, so when such a command also names the
# hook's protected target (TARGET_ERE) it
# is denied outright, whatever the scanner made of it; this over-denies a real
# `git stash "${X:-$(cmd)}"`-style call. Upgrade path: a real shell parser
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
  s = $0; out = ""; n = length(s); i = 1; hard = 0; k = 0
  safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:+=?#%/@*^,.~ -}"
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "$" && substr(s, i + 1, 1) == "{") {
      depth = 1; i += 2; q = ""; bt = 0; L = 0; h0 = hard; hard = 0; bs = i
      while (i <= n && depth > 0) {
        c = substr(s, i, 1)
        if (!(c == "$" && substr(s, i + 1, 1) == "{") && index(safe, c) == 0) hard = 1
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
      else if (!hard && (mode == "dflt" || mode == "count" || mode == "all") && match(substr(s, bs, i - 1 - bs), /^[A-Za-z_][A-Za-z0-9_]*:?[-=+]/)) {
        if (mode == "all" || (mode == "dflt" && int(mask / (2 ^ k)) % 2 == 1)) out = out substr(s, bs + RLENGTH, i - 1 - bs - RLENGTH)
        k++; hard = h0; continue
      }
      if (h0) hard = 1
      if (mode == "dflt" || mode == "all") out = out substr(s, bs - 2, i - bs + 2)
    } else { out = out c; i++ }
  }
  if (mode == "hard") print hard + 0; else if (mode == "count") print k; else print out
}'

guard_expansion_recheck() {
    local hook=$1 input=$2 cmd=$3 target=${4:-} hard stripped dflt count full mask depth=${GUARD_EXPANSION_DEPTH:-0}
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
    # the command with each ${name[:]-word}, ${name[:]=word} and ${name[:]+word}
    # replaced by its word: the protected program can ride in the default word
    # which removing the expansion never shows.
    # Each default expansion is independently set or unset at run time, so every
    # word-or-dropped combination is a form (`${A:-git} ${B:-x} stash drop` with
    # B empty runs `git stash drop`); bit k of the mask picks the word of the
    # k-th one.
    # ponytail: past 5 default expansions only the all-words form is re-read (2^n
    # forms), upgrade path a real shell parser.
    if ! count=$(printf '%s' "$cmd" | LC_ALL=C tr '\n' '\001' | LC_ALL=C awk -v mode=count "$_GEE_AWK"); then
        echo "guard-empty-expansion: cannot count default words - failing closed" >&2
        return 2
    fi
    case "$count" in
        ''|*[!0-9]*) echo "guard-empty-expansion: cannot count default words - failing closed" >&2; return 2 ;;
    esac
    _gee_rerun "$hook" "$input" "$cmd" "$stripped" "$depth" || return 2
    [ "$count" -gt 0 ] || return 0
    if [ "$count" -le 5 ]; then
        mask=1; full=$(( (1 << count) - 1 ))
    else
        mask=0; full=0
        if ! dflt=$(printf '%s' "$cmd" | LC_ALL=C tr '\n' '\001' \
            | LC_ALL=C awk -v mode=all "$_GEE_AWK" | LC_ALL=C tr '\001' '\n'); then
            echo "guard-empty-expansion: cannot read default words - failing closed" >&2
            return 2
        fi
        _gee_rerun "$hook" "$input" "$cmd" "$dflt" "$depth" || return 2
    fi
    while [ "$mask" -ge 1 ] && [ "$mask" -le "$full" ]; do
        if ! dflt=$(printf '%s' "$cmd" | LC_ALL=C tr '\n' '\001' \
            | LC_ALL=C awk -v mode=dflt -v mask="$mask" "$_GEE_AWK" | LC_ALL=C tr '\001' '\n'); then
            echo "guard-empty-expansion: cannot read default words - failing closed" >&2
            return 2
        fi
        _gee_rerun "$hook" "$input" "$cmd" "$dflt" "$depth" || return 2
        mask=$((mask + 1))
    done
    return 0
}

# _gee_rerun HOOK INPUT CMD FORM DEPTH — run the hook on FORM; 2 when it denies.
_gee_rerun() {
    local hook=$1 input=$2 cmd=$3 form=$4 depth=$5 child err rc
    [ "$form" != "$cmd" ] || return 0
    if ! child=$(jq -c --arg c "$form" '
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
    echo "    (denied with its variable expansions removed or defaulted — a variable that expands to nothing, or to its default word, leaves this command; rc=$rc)" >&2
    return 2
}
