#!/usr/bin/env bash
# shell-lint.sh — Pre-emptive advisory shell lint.
#
# Runs shellcheck plus advisory byte/regex portability checks (errexit leak, POSIX-ERE classes, mktemp template, bash-3.2 constructs, GNU-only
# flags, echo -e/-n) BEFORE the commit attempt, so the autonomous loop fixes
# issues instead of bouncing off the real pre-commit gate mid-run. The
# authoritative gate (.pre-commit-config.yaml) stays the source of truth and is
# UNCHANGED — this is additive and runs earlier. Advisory: it reports findings
# and exits non-zero if any are found; it never modifies files.
#
# Usage:
#   bash scripts/lint/shell-lint.sh [FILE...]   # lint the named shell files
#   bash scripts/lint/shell-lint.sh --staged    # lint staged shell files (git)
#   bash scripts/lint/shell-lint.sh --changed BASE..HEAD   # lint shell files changed in a git range
#   bash scripts/lint/shell-lint.sh --baseline FILE [...]  # accept findings up to FILE's per-file counts
#   bash scripts/lint/shell-lint.sh --baseline FILE --write-baseline [...]  # (re)write FILE from the findings
#   bash scripts/lint/shell-lint.sh --help
#
# Checks:
#   [parse]       the file does not parse (`bash -n`). A hook file is LIVE the
#                 instant it is written, so a parse error denies EVERY command
#                 fleet-wide before any commit gate can run. The commonest cause
#                 is an apostrophe in prose inside a single-quoted awk/sed/perl
#                 program (`# it's the entry point`) — it ends the shell string
#                 early.
#   [quote-break] an apostrophe that TERMINATED a single-quoted awk/sed/perl
#                 program body: the closing quote is immediately followed by a
#                 word character, the signature of prose (`it's`, `don't`)
#                 rather than an intended end-of-program. Catches the same class
#                 as [parse] in the case where the file still happens to parse
#                 (the stray quote re-balanced) but awk receives a TRUNCATED
#                 program.
#   [errexit]     `set -e` / `-eu` / `-euo` / `-o errexit` — errexit leaks into a
#                 sourcing shell; himmel convention is `set -uo pipefail`.
#   [shellcheck]  the same linter the pre-commit gate runs (when installed).
#   [regex-class] \s / \d / \w in a grep -E / egrep / sed -E / sed -e pattern —
#                 POSIX ERE has no such classes (they match a literal letter).
#   [mktemp]      `mktemp` / `mktemp -d` with no template arg (BSD/macOS needs one).
#   [bash32]      bash 4+ constructs (declare -A, mapfile/readarray, ${var,,}/
#                 ${var^^}, |&, &>>) — not 3.2-safe, the macOS default.
#   [gnu-flag]    GNU-only flags (sed -i no-suffix, date -d, readlink -f, grep -P,
#                 stat -c) without a same-line BSD fallback; exempt via
#                 `# gnu-ok: <reason>`.
#   [echo-e]      `echo -e` / `echo -n` — non-portable; use printf.
#   [prim-tmpdir] `mktemp -d` in a non-test script: use `tmpdir` from scripts/lib/prim.sh.
#   [prim-lock]   a `mkdir` lock directory or a raw `flock`: use `with_lock`.
#   [prim-atomic] `mv` of a tmp variable into place or `sed -i`: use `atomic_write`.
#   [prim-canon]  `readlink -f` / `realpath`: use `canon_path`.
#                 The four [prim-*] tags skip test-* files, tests/ and fixtures/ paths and
#                 prim.sh / canon-path.sh themselves; exempt a line (or the one above) with
#                 `# prim-ok: <reason>`.
#   [octal-arith] a variable assigned from `date +%m|%d|%H|%M|%S|%j|%U|%V|%W`
#                 (or a `cut` of such a value) that later appears inside
#                 $(( )), (( )) or `let` without 10# normalization — a leading
#                 zero (08, 09) is octal there and errors. Normalize with
#                 $((10#$var)). A single-bracket [ "$m" -gt 5 ] is decimal and
#                 never flagged. Exempt via a same-line `# octal-ok: <reason>`.
#   [kill-after]  a soft kill, then a bare fixed `sleep <n>`, then `kill -9`/`-KILL`
#                 (on consecutive code lines, or all on one line). The grace is
#                 wall-clock: on a loaded runner the process has not settled when
#                 the KILL lands, so the cleanup it was trapping never runs. Poll
#                 `kill -0` against a bounded deadline instead. Exempt via
#                 `# kill-after-ok: <reason>` on the sleep or the KILL line.
#
# Baseline: rows of `path<TAB>tag<TAB>count`. A (file, tag) with at most `count`
# findings is accepted; one above it reports every finding of that tag in the
# file, so the gate lands green and refuses only NEW findings. [parse]
# is never baselined.
# Growth: under --staged / --changed the baseline may not grow silently. A row above
# its count at the base ref (HEAD, or the left side of the range), or a new row,
# fails unless the row carries a 4th column holding a reason. A row that follows a
# renamed file inherits the old row's count. [prim-*] growth only warns.
# ponytail: a count cannot tell WHICH line of an over-budget tag is new; upgrade to per-line fingerprints if that bites.
#
# Exit: 0 = clean, 1 = findings, 2 = usage error.
# bash 3.2-safe; shellcheck-clean; cross-platform (macOS / Linux).

set -uo pipefail

# statusline is vendored byte-for-byte; mirror the gate's exclude.
EXCLUDE_SUBSTR='scripts/statusline/'

# Resolve sibling helpers (hook-parse-check.sh) relative to this script, not cwd.
LINT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    # Print only the contiguous header doc block (stop at the first non-# line),
    # so inline implementation comments never leak into --help.
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

# True for a path the gate would lint as shell: a .sh extension or a sh shebang.
_is_shell_file() {
    case "$1" in
        *.sh) return 0 ;;
    esac
    case "$(head -n1 "$1" 2>/dev/null)" in
        '#!'*sh*) return 0 ;;
    esac
    return 1
}

# Print "lineno: line" for every non-comment line in file $1 matching ERE $2.
# Full-line comments are excluded so a construct merely NAMED in a doc comment
# — e.g. "# bash 3.2-safe: no mapfile" — is not a false positive. (Inline
# comments and heredoc/string bodies can still match; these checks are advisory.)
_grep_hits() {
    grep -nE "$2" -- "$1" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# Append one "  [tag] line N: text — hint" per "lineno: line" entry in $2, and
# bump file_issues once if any. Empty $2 is a no-op. file_report/file_issues are
# the caller's loop-scoped accumulators (not local here).
_report_hits() {
    # $1=tag  $2=hits (lineno:line lines)  $3=hint
    [ -n "$2" ] || return 0
    local _ln _rest
    while IFS=: read -r _ln _rest; do
        [ -n "$_ln" ] || continue
        file_report="${file_report}  [$1] line $_ln: $_rest — $3"$'\n'
    done <<EOF
$2
EOF
    file_issues=$((file_issues + 1))
}

# True if line $2 (1-indexed) of file $1 carries a `# gnu-ok: <reason>` marker,
# on that line or the line immediately above.
_has_gnu_ok() {
    local file="$1" line_no="$2"
    sed -n "${line_no}p" "$file" 2>/dev/null | grep -q 'gnu-ok' && return 0
    if [ "$line_no" -gt 1 ]; then
        sed -n "$((line_no - 1))p" "$file" 2>/dev/null | grep -q 'gnu-ok' && return 0
    fi
    return 1
}

# True if line $2 (1-indexed) of file $1 carries a `# prim-ok: <reason>` marker,
# on that line or the line immediately above.
_has_prim_ok() {
    local file="$1" line_no="$2"
    sed -n "${line_no}p" "$file" 2>/dev/null | grep -qE '# prim-ok:[[:space:]]*[^[:space:]]' && return 0
    if [ "$line_no" -gt 1 ]; then
        sed -n "$((line_no - 1))p" "$file" 2>/dev/null | grep -qE '# prim-ok:[[:space:]]*[^[:space:]]' && return 0
    fi
    return 1
}

# _prim_report FILE TAG PATTERN HINT — report each non-comment line of FILE
# with a non-probe ERE PATTERN hit and no reasoned prim-ok marker, as [TAG]. Appends to the
# caller's file_report/file_issues.
_prim_report() {
    local _pf="$1" _ptag="$2" _ppat="$3" _phint="$4" _ph _pln _prest _pout="" _pall _pstrip
    _pall="$(_grep_hits "$_pf" "$_ppat")"
    _ph=""
    # Only the probe text is dropped: a call sharing the line with its probe
    # (`command -v flock && flock -x 9`) still matches the pattern.
    while IFS=: read -r _pln _prest; do
        [ -n "$_pln" ] || continue
        _pstrip="$(printf '%s\n' "$_prest" | sed -E -e "s/$PRIM_MESSAGE/\1\2 /g" \
            -e ':probe' -e "s/$PRIM_PROBE/\1\4/g" -e 't probe')"
        printf '%s\n' "$_pstrip" | grep -qE "$_ppat" || continue
        _ph="${_ph}${_pln}:${_prest}"$'\n'
    done <<EOF
$_pall
EOF
    [ -n "$_ph" ] || return 0
    while IFS=: read -r _pln _prest; do
        [ -n "$_pln" ] || continue
        _has_prim_ok "$_pf" "$_pln" && continue
        _pout="${_pout}  [$_ptag] line $_pln: $_prest — $_phint"$'\n'
    done <<EOF
$_ph
EOF
    if [ -n "$_pout" ]; then
        file_report="${file_report}${_pout}"
        file_issues=$((file_issues + 1))
    fi
}

# Print "lineno:line" for every arithmetic use ($(( )), (( )), let) of a variable
# that was assigned from a leading-zero date field (see [octal-arith] above) and
# is not 10#-normalized there. A same-line `octal-ok` marker exempts the line.
# ponytail: same-file single-pass scan, nesting-blind, cross-file values unseen; upgrade path HIMMEL-6020 portable primitives lib
_octal_arith_hits() {
    awk '
    function isname(c) { return c ~ /[A-Za-z0-9_]/ }
    # true if segment s holds v as a bare operand (not behind 10#)
    function uses(s, v,   rest, p, pre, post, skip) {
        rest = s
        while ((p = index(rest, v)) > 0) {
            pre = (p > 1) ? substr(rest, p - 1, 1) : ""
            post = substr(rest, p + length(v), 1)
            if (!isname(pre) && !isname(post)) {
                skip = substr(rest, 1, p - 1)
                if (skip !~ /10#[$]?[{]?$/) return 1
            }
            rest = substr(rest, p + length(v))
        }
        return 0
    }
    /^[[:space:]]*#/ { next }
    {
        line = $0
        # arithmetic uses are judged against the tracking BEFORE this line reassigns anything
        hit = 0
        segs = ""
        rest = line
        while (match(rest, /\(\([^)]*\)\)/)) {
            segs = segs " " substr(rest, RSTART, RLENGTH)
            rest = substr(rest, RSTART + RLENGTH)
        }
        if (match(line, /(^|[;&|[:space:]])let[[:space:]]+/)) segs = segs " " substr(line, RSTART)
        if (segs != "") for (v in tracked) if (uses(segs, v)) { hit = 1; break }
        if (match(line, /^[[:space:]]*(local[[:space:]]+|export[[:space:]]+|declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)?)?[A-Za-z_][A-Za-z0-9_]*=/)) {
            lhs = substr(line, RSTART, RLENGTH - 1)
            sub(/^[[:space:]]*(local[[:space:]]+|export[[:space:]]+|declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)?)?/, "", lhs)
            code = line
            sub(/[[:space:]]#.*$/, "", code)
            isdate = (line ~ /date[^#]*[+][^[:alnum:]%]?%[mdHMSjUVW][^[:alnum:]%]?([)`;[:space:]]|$)/ && code !~ /10#/)
            if (isdate && segs != "") {
                pa = index(line, "((")
                if (pa == 0) pa = index(line, "let")
                if (index(line, "date") < pa && uses(segs, lhs)) hit = 1
            }
            if (!isdate && code !~ /10#/) {
                derived = 0
                # derived only when the tracked value itself is piped into cut (or fed by here-string)
                for (v in tracked) {
                    if (line ~ ("(^|[[:space:]\"])[$][{]?" v "[}\"]*[[:space:]]*[|][[:space:]]*cut[[:space:]]")) derived = 1
                    if (line ~ ("cut[[:space:]][^|;]*<<<[[:space:]]*\"?[$][{]?" v "([^[:alnum:]_]|$)")) derived = 1
                }
                isdate = derived
            }
            if (isdate) tracked[lhs] = 1; else delete tracked[lhs]
        }
        if (hit && line !~ /octal-ok/) print NR ":" line
    }' "$1"
}

# Print "lineno:line" for the fixed sleep of every soft-kill / sleep / hard-kill
# sequence (see [kill-after] above). Comment lines between the three are skipped;
# any other line breaks the sequence, so a poll loop around the sleep is clean.
# ponytail: consecutive-line state machine; a sleep behind a function call or variable is unseen
_kill_after_hits() {
    awk '
    function hard(l) { return l ~ /(^|[;&|[:space:]])kill[[:space:]]+-(9|KILL|s[[:space:]]+KILL)([^A-Za-z0-9]|$)/ }
    function soft(l) { return l ~ /(^|[;&|[:space:]])kill[[:space:]]+(-?["$]|[0-9])/ || l ~ /(^|[;&|[:space:]])kill[[:space:]]+-(TERM|15|INT|HUP|s[[:space:]]+(TERM|INT|HUP))[[:space:]]+["$0-9-]/ }
    function fixed(l) { return l ~ /(^|[;&|[:space:]])sleep[[:space:]]+[0-9.]+[[:space:]]*(;|$|#)/ }
    FNR == 1 { st = 0 }
    /^[[:space:]]*(#|$)/ { next }
    {
        l = $0
        if (soft(l) && fixed(l) && hard(l)) { if (l !~ /kill-after-ok/) print FNR ":" l; st = 0; next }
        if (st == 2 && hard(l)) { if (l !~ /kill-after-ok/ && sl !~ /kill-after-ok/) print sn ":" sl; st = 0; next }
        if (st == 1 && fixed(l) && hard(l)) { if (l !~ /kill-after-ok/) print FNR ":" l; st = 0; next }
        if (st == 1 && l ~ /^[[:space:]]*sleep[[:space:]]+[0-9.]+[[:space:]]*(;|$|#)/) { st = 2; sn = FNR; sl = l; next }
        if (soft(l) && fixed(l) && !hard(l)) { st = 2; sn = FNR; sl = l; next }
        st = (soft(l) && !hard(l)) ? 1 : 0
    }' "$1"
}

# ── Advisory portability patterns (CR-learnings tuning)
# POSIX ERE throughout (no \s/\d/\w, no PCRE); bash 3.2-safe. Lines are scanned
# as-is (full-line comments excluded by _grep_hits); a construct inside a heredoc
# body or quoted string may still match — these checks are advisory, never a gate.

# grep -E / egrep / sed -E / sed -e invocation; check 1 then looks for a PCRE
# class escape (\s \d \w) on the same line.
REGEX_CLASS_CMD='(^|[^[:alnum:]_-])(grep[[:space:]]+-[A-Za-z]*E|egrep|sed[[:space:]]+(-[A-Za-z]*E|-[A-Za-z]*e))'
PCRE_CLASS='\\[sdw]'

# mktemp / mktemp -d with NO template arg (next token is a shell terminator or
# end-of-line, not a path). Templated forms (mktemp x.XXXX, mktemp "$x",
# mktemp -d -t p) skip — a following quote opens a template argument, so '"' is
# intentionally NOT a terminator; the close-paren ')' still covers "$(mktemp)".
MKTEMP_NOARG='(^|[^[:alnum:]_-])mktemp([[:space:]]+-[A-Za-z]+)*[[:space:]]*($|\)|\||&|;)'

# bash 4+ constructs. |& and &>> are matched only in operator position
# (whitespace-bounded) so the same tokens inside a regex char-class or quoted
# string ([;|&()], "&>>") are not false positives.
BASH32='(^|[^[:alnum:]_])(declare[[:space:]]+-[A-Za-z]*A[A-Za-z]*|mapfile|readarray)([^[:alnum:]_]|$)|\$\{[A-Za-z_][A-Za-z0-9_]*,,|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|[[:space:]]\|&[[:space:]]|[[:space:]]&>>'

# GNU-only flags. Portable code pairs them with a BSD alt on the same line
# (stat -f for stat -c, date -[vrj] for date -d); check 5 excludes those, then
# honors '# gnu-ok:'.
GNU_FLAG_PAT='(^|[^[:alnum:]_-])(sed[[:space:]]+-i([[:space:]]|$)|date[[:space:]]+(-d|--date)|readlink[[:space:]]+-f|grep[[:space:]]+-[A-Za-z]*P|stat[[:space:]]+(-c|--format))'

# echo -e / echo -n (and combined short flags such as -ne / -en).
ECHO_FLAG='(^|[^[:alnum:]_-])echo[[:space:]]+-[A-Za-z]*[en][A-Za-z]*'

# Ad-hoc forms of the scripts/lib/prim.sh primitives. A lock word must sit in the
# FIRST mkdir operand, so `mkdir -p "$d/locks"` is not a lock.
PRIM_TMPDIR='(^|[^[:alnum:]_-])mktemp[[:space:]]+(-[A-Za-z]*d|-[A-Za-z]+[[:space:]]+-d)'
PRIM_LOCK='(^|[^[:alnum:]_-])mkdir[[:space:]]+["'"'"']?[^-"'"'"'|;&[:space:]][^|;&[:space:]]*[Ll][Oo][Cc][Kk]|(^|[^[:alnum:]_./-])flock[[:space:]]'
PRIM_ATOMIC='(^|[^[:alnum:]_-])(mv[[:space:]]+(-[A-Za-z]+[[:space:]]+)*["'"'"']?\$[{]?[A-Za-z_]*([Tt][Mm][Pp]|[Tt][Ee][Mm][Pp])|sed[[:space:]]+-i)'
PRIM_CANON='(^|[^[:alnum:]_-])(readlink[[:space:]]+-f|realpath)([[:space:]]|$)'
# A probe for the tool (`command -v flock`) is not a use of it.
PRIM_PROBE='(^|[^[:alnum:]_./-])(command[[:space:]]+-v|type|which)[[:space:]]+(flock|realpath)($|[[:space:];&|()<>])'
# Literal echo/printf arguments are messages, not calls; keep expansions visible.
PRIM_MESSAGE="(^|[;&|({[:space:]])(echo|printf)([[:space:]]+(-v[[:space:]]+[[:alpha:]_][[:alnum:]_]*|--|-[[:alpha:]]+))*([[:space:]]+(\"[^\"\$\`]*\"|'[^']*'))+"

STAGED=0
CHANGED=""
BASELINE=""
WRITE_BASELINE=0
BASE_TEXT=""
BASE_REL=""
WB_OUT=""
EXPLICIT=0         # 1 once any explicit file path is given
FILES=""           # newline-separated (bash 3.2-safe; avoids array edge cases)
while [ $# -gt 0 ]; do
    case "$1" in
        --staged) STAGED=1; shift ;;
        --changed) [ $# -ge 2 ] || { printf 'shell-lint: --changed needs a git range\n' >&2; exit 2; }
                   CHANGED="$2"; shift 2 ;;
        --baseline) [ $# -ge 2 ] || { printf 'shell-lint: --baseline needs a file\n' >&2; exit 2; }
                    BASELINE="$2"; shift 2 ;;
        --write-baseline) WRITE_BASELINE=1; shift ;;
        --help|-h) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do FILES="$FILES$1"$'\n'; EXPLICIT=1; shift; done ;;
        -*) printf 'shell-lint: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) FILES="$FILES$1"$'\n'; EXPLICIT=1; shift ;;
    esac
done

if [ "$WRITE_BASELINE" -eq 1 ] && [ -z "$BASELINE" ]; then
    printf 'shell-lint: --write-baseline needs --baseline FILE\n' >&2; exit 2
fi
if [ -n "$BASELINE" ] || [ "$STAGED" -eq 1 ] || [ -n "$CHANGED" ]; then
    command -v git >/dev/null 2>&1 || { printf 'shell-lint: --staged/--changed/--baseline need git on PATH\n' >&2; exit 2; }
    # git diff yields REPO-ROOT-relative paths; resolve them against the
    # toplevel so --staged works from any subdirectory (a worktree-relative cwd
    # would otherwise silently drop every path → a false "clean" before a commit).
    _root="$(git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$_root" ] || { printf 'shell-lint: not inside a git work tree\n' >&2; exit 2; }
fi
if [ -n "$BASELINE" ] && [ "$WRITE_BASELINE" -eq 0 ]; then
    [ -f "$BASELINE" ] || { printf 'shell-lint: baseline file not found: %s\n' "$BASELINE" >&2; exit 2; }
    BASE_TEXT="$(cat "$BASELINE")" || { printf 'shell-lint: cannot read baseline: %s\n' "$BASELINE" >&2; exit 2; } # read-sink-ok: baseline path is operator/CI-supplied via the hook or workflow command line, never agent input; only counted, never executed
    case "$BASELINE" in
        /*) BASE_REL="${BASELINE#"$_root"/}"; [ "$BASE_REL" != "$BASELINE" ] || BASE_REL="" ;;
        *) BASE_REL="$(git rev-parse --show-prefix)${BASELINE#./}" ;;
    esac
    # --staged judges the commit, so the baseline it reads is the indexed one, not an unstaged edit
    if [ "$STAGED" -eq 1 ] && [ -n "$BASE_REL" ]; then
        _indexed="$(git show ":$BASE_REL" 2>/dev/null)" && BASE_TEXT="$_indexed"
    fi
fi

if [ "$STAGED" -eq 1 ] || [ -n "$CHANGED" ]; then
    # -z: git would otherwise quote a non-ASCII name and the -f test below would skip it.
    # The stream ends in an un-terminated "rc=<git exit>" so a git failure must NOT
    # read as "no changed files" (that would be a false all-clear).
    _git_changed() {
        cd "$_root" || return 2
        if [ "$STAGED" -eq 1 ]; then
            git diff --cached -z --name-only --diff-filter=ACMR
        else
            git diff -z --name-only --diff-filter=ACMR "$CHANGED" --
        fi
        printf 'rc=%s' "$?"
    }
    _rc=""
    while IFS= read -r -d '' _f || { _rc="$_f"; false; }; do
        [ -n "$_f" ] || continue
        # ponytail: the file list is newline-separated, so a newline in a name is refused, not linted; carry NUL-separated lists through if one is ever real
        case "$_f" in *$'\n'*) printf 'shell-lint: a path containing a newline cannot be linted; rename it\n' >&2; exit 2 ;; esac
        _abs="$_root/$_f"
        [ -f "$_abs" ] || continue
        _is_shell_file "$_abs" && FILES="$FILES$_abs"$'\n'
    done < <(_git_changed)
    [ "$_rc" = "rc=0" ] || { printf 'shell-lint: git diff failed (--staged or --changed %s)\n' "$CHANGED" >&2; exit 2; }
fi

# _baseline_growth — print each baseline row that grew past the base ref's version
# without a reason (stdout); returns 1 if any did. [prim-*] growth prints a warning only.
_baseline_growth() {
    local ref old renames
    if [ "$STAGED" -eq 1 ]; then ref=HEAD; else ref="${CHANGED%%..*}"; fi
    [ -n "$ref" ] || ref=HEAD
    [ -n "$BASE_REL" ] || return 0
    old="$(git show "$ref:$BASE_REL" 2>/dev/null)" || old=""
    if [ "$STAGED" -eq 1 ]; then
        renames="$(git -c core.quotePath=false diff --cached --name-status -M --diff-filter=R)"
    else
        renames="$(git -c core.quotePath=false diff --name-status -M --diff-filter=R "$CHANGED" --)"
    fi
    awk -v old="$old" -v ren="$renames" -v new="$BASE_TEXT" '
    BEGIN {
        n = split(old, o, "\n")
        for (i = 1; i <= n; i++) { m = split(o[i], p, "\t"); if (m >= 3) before[p[1] SUBSEP p[2]] = p[3] + 0 }
        n = split(ren, r, "\n")
        for (i = 1; i <= n; i++) { m = split(r[i], p, "\t"); if (m == 3) from[p[3]] = p[2] }
        n = split(new, w, "\n")
        for (i = 1; i <= n; i++) {
            m = split(w[i], p, "\t")
            if (m < 3) continue
            k = p[1] SUBSEP p[2]
            if (!(k in before) && (p[1] in from) && ((from[p[1]] SUBSEP p[2]) in before)) prev = before[from[p[1]] SUBSEP p[2]]
            else prev = (k in before) ? before[k] : 0
            if (p[3] + 0 <= prev) continue
            if (p[2] ~ /^prim-/) { printf "shell-lint: warn: prim baseline grew: %s\t%s\t%d -> %d\n", p[1], p[2], prev, p[3]; continue }
            if (m >= 4 && p[4] ~ /[^[:space:]]/) continue
            printf "shell-lint: baseline grew without a reason: %s\t%s\t%d -> %d (add a 4th column reason, or fix the finding)\n", p[1], p[2], prev, p[3]
            bad = 1
        }
        exit bad
    }'
}

# _baseline_filter KEY — stdin: a file's report. Drops each tag whose count is
# within its baseline row; the rest print unchanged.
_baseline_filter() {
    awk -v key="$1" -v base="$BASE_TEXT" -v wr="$WRITE_BASELINE" '
    BEGIN {
        n = split(base, bl, "\n")
        for (i = 1; i <= n; i++) { m = split(bl[i], p, "\t"); if (m >= 3 && p[1] == key) allow[p[2]] = p[3] + 0 }
        never["parse"] = 1
    }
    { line[NR] = $0
      if (match($0, /^  \[[A-Za-z0-9-]+\]/)) { cur = substr($0, 4, RLENGTH - 4); cnt[cur]++ }
      tag[NR] = cur }
    END {
        for (i = 1; i <= NR; i++) {
            t = tag[i]
            if (t == "" || (t in never) || (!wr && cnt[t] > allow[t])) print line[i]
        }
    }'
}

# _baseline_counts KEY — stdin: a file's report. Prints one baseline row per baselinable tag.
_baseline_counts() {
    awk -v key="$1" '
    BEGIN { never["parse"] = 1 }
    match($0, /^  \[[A-Za-z0-9-]+\]/) { t = substr($0, 4, RLENGTH - 4); if (!(t in never)) c[t]++ }
    END { for (t in c) printf "%s\t%s\t%d\n", key, t, c[t] }'
}

GROWTH_FAIL=0
if [ -n "$BASELINE" ] && [ "$WRITE_BASELINE" -eq 0 ] && { [ "$STAGED" -eq 1 ] || [ -n "$CHANGED" ]; }; then
    _baseline_growth || GROWTH_FAIL=1
fi

command -v shellcheck >/dev/null 2>&1 && HAVE_SHELLCHECK=1 || HAVE_SHELLCHECK=0
if [ "$HAVE_SHELLCHECK" -ne 1 ]; then
    # --staged/--changed are the gate paths: a skipped [shellcheck] check there reads as a clean pass.
    if [ "$STAGED" -eq 1 ] || [ -n "$CHANGED" ]; then
        printf 'shell-lint: shellcheck is required for --staged/--changed but is not on PATH\n' >&2
        exit 2
    fi
    printf 'shell-lint: shellcheck not installed — running errexit checks only\n' >&2
fi
CHECKED=0
MISSING=0
ISSUE_FILES=0

# Iterate the newline-separated file list.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
        *"$EXCLUDE_SUBSTR"*) continue ;;
    esac
    if [ ! -f "$f" ]; then
        printf 'shell-lint: skipping missing file: %s\n' "$f" >&2
        MISSING=$((MISSING + 1))
        continue
    fi
    CHECKED=$((CHECKED + 1))
    file_issues=0
    file_report=""

    # The checks below are shell-specific.
    if _is_shell_file "$f"; then

    # [errexit] — set -e / -eu / -euo / -o errexit in the prologue. A real
    # errexit directive sits at file top, before any heredoc; `set -e` text inside
    # a heredoc body is a false positive (shellcheck parses heredocs correctly), so
    # stop scanning at the first heredoc operator (`<<`).
    ee="$(awk '/<</{exit} /^[[:space:]]*set[[:space:]]+(-[a-zA-Z]*e[a-zA-Z]*|-o[[:space:]]+errexit)/{print NR": "$0}' "$f")"
    if [ -n "$ee" ]; then
        while IFS= read -r eline; do
            [ -n "$eline" ] || continue
            file_report="$file_report  [errexit] line $eline — errexit leaks into a sourcing shell; use 'set -uo pipefail'"$'\n'
        done <<EOF
$ee
EOF
        file_issues=$((file_issues + 1))
    fi

    # [parse] + [quote-break] — delegated to the shared checker so
    # there is exactly ONE implementation: scripts/hooks/check-hook-file-parse.sh
    # runs the same script at WRITE time, which is the only moment that helps a
    # live hook file. Findings already carry their own path and tag.
    if [ -f "$LINT_DIR/hook-parse-check.sh" ]; then
        if ! hpc_out="$(bash "$LINT_DIR/hook-parse-check.sh" "$f" 2>&1)"; then
            file_report="$file_report$hpc_out"$'
'
            file_issues=$((file_issues + 1))
        fi
    else
        printf 'shell-lint: hook-parse-check.sh missing next to shell-lint.sh - [parse]/[quote-break] skipped
' >&2
    fi

    # [shellcheck] — the gate's linter (when installed). Check rc directly.
    if [ "$HAVE_SHELLCHECK" -eq 1 ]; then
        if ! sc_out="$(shellcheck "$f" 2>&1)"; then
            file_report="$file_report  [shellcheck]"$'\n'"$(printf '%s\n' "$sc_out" | sed 's/^/    /')"$'\n'
            file_issues=$((file_issues + 1))
        fi
    fi

    # Advisory portability checks (CR-learnings tuning). These define their own
    # patterns/tags/hints as DATA, so this linter's own source — and its test
    # suite's fixtures/assertions, which embed the same patterns/tags on
    # purpose — would flag itself (the BASH32 pattern mentions `mapfile`; the
    # echo-e hint says `echo -e`). Skip them for these two files only —
    # errexit/shellcheck still run on both.
    case "$f" in
        *scripts/lint/shell-lint.sh|*scripts/lint/test-shell-lint.sh) _skip_advisory=1 ;;
        *) _skip_advisory=0 ;;
    esac
    if [ "$_skip_advisory" -eq 0 ]; then

    # [regex-class] — \s / \d / \w are PCRE/GNU extensions; in a grep -E / egrep
    # / sed -E / sed -e pattern they match a literal letter, not a character
    # class (POSIX ERE has none).
    _rc="$(_grep_hits "$f" "$REGEX_CLASS_CMD" | grep -E "$PCRE_CLASS")"
    _report_hits regex-class "$_rc" \
        "POSIX ERE has no \s/\d/\w (matches a literal letter); use [[:space:]]/[[:digit:]]/[[:alnum:]]"

    # [mktemp] — GNU mktemp works with no template arg; BSD/macOS requires one.
    _mt="$(_grep_hits "$f" "$MKTEMP_NOARG")"
    _report_hits mktemp "$_mt" \
        "BSD/macOS mktemp needs a template arg (e.g. mktemp -d -t prefix.XXXXXX)"

    # [bash32] — bash 4+ constructs; macOS ships bash 3.2.
    _b32="$(_grep_hits "$f" "$BASH32")"
    _report_hits bash32 "$_b32" \
        "bash 4+ construct, not 3.2-safe (macOS default) — see repo house style"

    # [echo-e] — echo -e/-n behaviour varies by shell/build; printf is portable.
    _echo="$(_grep_hits "$f" "$ECHO_FLAG")"
    _report_hits echo-e "$_echo" \
        "echo -e/-n is non-portable; use printf"

    # [octal-arith] — a leading-zero date field used in arithmetic without 10#.
    _oa="$(_octal_arith_hits "$f")"
    _report_hits octal-arith "$_oa" \
        "leading-zero operand is octal in arithmetic (08/09 error); normalize with \$((10#\$var)) or '# octal-ok: <reason>'"

    # [kill-after] — a fixed wall-clock grace between a soft kill and KILL.
    _ka="$(_kill_after_hits "$f")"
    _report_hits kill-after "$_ka" \
        "fixed grace before KILL loses the race on a loaded runner; poll kill -0 against a bounded deadline, or '# kill-after-ok: <reason>'"

    # [gnu-flag] — GNU-only flags (sed -i no-suffix, date -d, readlink -f, grep
    # -P, stat -c). Lines that already pair the GNU form with its BSD alternative
    # on the same line (stat -f for stat -c, date -[vrj] for date -d) are the
    # intended portable idiom and are dropped; the rest may be exempted with
    # `# gnu-ok: <reason>` (same-line or line above).
    _gf="$(grep -nE "$GNU_FLAG_PAT" -- "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -vE 'stat[[:space:]]+-f|date[[:space:]]+-[vrj]' || true)"
    if [ -n "$_gf" ]; then
        _gf_report=""
        while IFS=: read -r _gln _grest; do
            [ -n "$_gln" ] || continue
            if ! _has_gnu_ok "$f" "$_gln"; then
                _gf_report="${_gf_report}  [gnu-flag] line $_gln: $_grest — GNU-only flag, not portable to BSD/macOS; add a BSD fallback or '# gnu-ok: <reason>'"$'\n'
            fi
        done <<EOF
$_gf
EOF
        if [ -n "$_gf_report" ]; then
            file_report="${file_report}${_gf_report}"
            file_issues=$((file_issues + 1))
        fi
    fi

    # [prim-*] — ad-hoc equivalents of scripts/lib/prim.sh. Test code and the lib
    # itself are out of scope; existing production hits live in the baseline.
    case "$f" in
        */prim.sh|*/canon-path.sh|*/test-*|test-*|*/tests/*|*/fixtures/*) ;;
        *)
            _prim_report "$f" prim-tmpdir "$PRIM_TMPDIR" \
                "use tmpdir from scripts/lib/prim.sh, or '# prim-ok: <reason>'"
            _prim_report "$f" prim-lock "$PRIM_LOCK" \
                "use with_lock from scripts/lib/prim.sh (mkdir locks and raw flock are not portable), or '# prim-ok: <reason>'"
            _prim_report "$f" prim-atomic "$PRIM_ATOMIC" \
                "use atomic_write from scripts/lib/prim.sh (sed -i and tmp-then-mv races), or '# prim-ok: <reason>'"
            _prim_report "$f" prim-canon "$PRIM_CANON" \
                "use canon_path from scripts/lib/prim.sh, or '# prim-ok: <reason>'"
            ;;
    esac

    fi   # end advisory checks (_skip_advisory)

    fi   # end shell-specific checks (gate on _is_shell_file)

    if [ "$file_issues" -gt 0 ] && [ -n "$BASELINE" ]; then
        _key="${f#"$_root"/}"
        _key="${_key#./}"   # ponytail: only a leading ./ is normalised, a subdirectory-relative path misses its row; resolve against the toplevel if that bites
        # write mode records the baselinable counts and keeps only the findings no baseline can accept
        [ "$WRITE_BASELINE" -eq 1 ] && WB_OUT="$WB_OUT$(printf '%s' "$file_report" | _baseline_counts "$_key")"$'\n'
        file_report="$(printf '%s' "$file_report" | _baseline_filter "$_key")"
        if [ -n "$file_report" ]; then file_report="$file_report"$'\n'; else file_issues=0; fi
    fi

    if [ "$file_issues" -gt 0 ]; then
        ISSUE_FILES=$((ISSUE_FILES + 1))
        printf '%s:\n' "$f"
        printf '%s' "$file_report"
    fi
done <<EOF
$FILES
EOF

# Distinguish "checked nothing because the paths were wrong" from "checked and
# clean" — reporting clean when every named file was missing is a false all-clear.
if [ "$EXPLICIT" -eq 1 ] && [ "$CHECKED" -eq 0 ] && [ "$MISSING" -gt 0 ]; then
    printf 'shell-lint: none of the named files exist (%d missing) — checked nothing\n' "$MISSING" >&2
    exit 2
fi

if [ "$WRITE_BASELINE" -eq 1 ]; then
    if ! printf '%s' "$WB_OUT" | awk 'NF' | LC_ALL=C sort > "$BASELINE"; then
        printf 'shell-lint: could not write baseline: %s\n' "$BASELINE" >&2; exit 2
    fi
    printf 'shell-lint: wrote %d baseline row(s) to %s\n' "$(awk 'END{print NR}' "$BASELINE")" "$BASELINE"
fi

if [ "$ISSUE_FILES" -gt 0 ]; then
    printf 'shell-lint: %d file(s) with issues — fix before committing (the pre-commit gate blocks otherwise)\n' "$ISSUE_FILES"
    exit 1
fi
[ "$GROWTH_FAIL" -eq 0 ] || exit 1
printf 'shell-lint: clean (%d file(s) checked)\n' "$CHECKED"
exit 0
