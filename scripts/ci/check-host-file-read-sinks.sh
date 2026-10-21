#!/usr/bin/env bash
# scripts/ci/check-host-file-read-sinks.sh -- flag NEWLY ADDED shell code that
# reads a file whose path is taken from argv or an environment variable with no
# allowlist in sight (the PR 2878 launcher class: any host file read as a prompt).
#
# Usage: check-host-file-read-sinks.sh --range [--merge-ref] <base>
#   Scans the net diff merge-base(<base>, HEAD)..HEAD (with --merge-ref the
#   range is HEAD^1..HEAD, for a CI merge-ref checkout). Only ADDED lines of
#   *.sh / *.bash are considered, so the large pre-existing count never blocks
#   an unrelated change. Fail-closed: an unresolvable base is an error.
#
# A line is a sink when a reader (cat head tail less more source `.` or a `<`
# redirect) takes, as its whole operand, one of:
#   - an argv expansion       $1  ${1:-}  $@  $*
#   - a variable assigned from argv in the same added lines (path laundering; the first
#     name of the NAME=value run at the head of a line, or a later UPPER_CASE one), unless it was last assigned a
#     value that IS a mktemp substitution (a file the script made itself); a value
#     that merely contains the word, appends anything after the closing of the
#     substitution, or is followed by a command word (out=$(mktemp) env true) does
#     not count
#   - an UPPER_CASE variable the file never assigns (environment-supplied path);
#     a name counts as assigned only from the NAME=value run at the head of a line:
#     plain, a command prefix (NAME=x cmd), or an export / local / readonly /
#     declare / typeset list. NAME=x in a comment, a quoted or heredoc usage text,
#     a case arm or as a command argument (run x NAME=1) is not an assignment
# An operand with a suffix ("$ROOT/x", "$(dirname "$0")/lib.sh") is rooted and
# passes. A sink passes when, within 3 lines either side, there is an allowlist
# signal (`case ... in`, the word allowlist/allowed, or a realpath/readlink -f
# compared with ==, =~ or a # prefix strip), or when the line (or the one above)
# carries `# read-sink-ok: <why>`.
#
# ponytail: shell readers only, and a window heuristic rather than data flow;
# python/node readers (open(sys.argv[1]), readFileSync(process.env.X)) are not
# scanned, upgrade path is an AST rule in the swallowed-error lint family.
#
# Exit: 0 clean; 1 sink(s) found (file:line printed); 2 usage / git error.
# Platform guard (gitbash-only): POSIX bash 3.2+, git, awk.
set -uo pipefail

usage() { echo "usage: check-host-file-read-sinks.sh --range [--merge-ref] <base>" >&2; exit 2; }

MODE="" MERGE_REF=0 BASE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --range) MODE=range ;;
    --merge-ref) MERGE_REF=1 ;;
    -*) usage ;;
    *) BASE="$1" ;;
  esac
  shift
done
[ "$MODE" = range ] || usage
[ "$MERGE_REF" = 1 ] || [ -n "$BASE" ] || usage

if [ "$MERGE_REF" = 1 ]; then
  OLD="$(git rev-parse --verify -q 'HEAD^1')" || OLD=""
else
  OLD="$(git merge-base "$BASE" HEAD)" || OLD=""
fi
if [ -z "$OLD" ]; then
  echo "FAIL: check-host-file-read-sinks: cannot resolve the range base '${BASE:-HEAD^1}' (fail-closed)" >&2
  exit 2
fi

FILES_LIST="$(mktemp "${TMPDIR:-/tmp}/read-sinks.XXXXXX")" || { echo "FAIL: check-host-file-read-sinks: cannot allocate scratch file (fail-closed)" >&2; exit 2; }
: "${FILES_LIST:?}"
trap 'rm -f "$FILES_LIST"' EXIT
git diff -z --name-only --diff-filter=AMRT "$OLD" HEAD -- '*.sh' '*.bash' > "$FILES_LIST" || {
  echo "FAIL: check-host-file-read-sinks: git diff failed (fail-closed)" >&2
  exit 2
}

found=0
while IFS= read -r -d '' path; do
  case "$path" in archive/*|*/testdata/*) continue ;; esac
  # Added line numbers (new-file side) from the -U0 hunk headers.
  added="$(git diff -U0 "$OLD" HEAD -- "$path" | awk '
    /^@@ / {
      s = $3; sub(/^\+/, "", s)
      n = split(s, p, ","); start = p[1] + 0; cnt = (n > 1) ? p[2] + 0 : 1
      for (i = 0; i < cnt; i++) printf "%d,", start + i
    }')" || { echo "FAIL: check-host-file-read-sinks: diff of $path failed (fail-closed)" >&2; exit 2; }
  [ -n "$added" ] || continue
  body="$(git show "HEAD:$path")" || { echo "FAIL: check-host-file-read-sinks: cannot read $path at HEAD (fail-closed)" >&2; exit 2; }
  out="$(printf '%s\n' "$body" | awk -v ADDED=",$added" -v FILE="$path" '
    function is_added(n) { return index(ADDED, "," n ",") > 0 }
    function varname(tok,   t) {          # "${1:-}" -> 1 ; "$CONFIG" -> CONFIG
      t = tok; gsub(/["\047{}]/, "", t); sub(/^\$/, "", t)
      if (match(t, /^([0-9@*]|[A-Za-z_][A-Za-z0-9_]*)/)) return substr(t, 1, RLENGTH)
      return ""
    }
    function allow_near(n,   i, w) {
      for (i = n - 3; i <= n + 3; i++) {
        if (i < 1 || i > total) continue
        w = line[i]
        if (w ~ /(^|[ \t;])case[ \t].*[ \t]in([ \t]|$)/) return 1
        if (w ~ /allowlist|allowed/) return 1
        if (w ~ /(realpath|readlink -f)/ && w ~ /(==|=~|#)/) return 1
      }
      return 0
    }
    BEGIN {
      VAL = "^(\"[^\"]*\"|\047[^\047]*\047|\\$\\([^)]*\\)|\\$\\{[^}]*\\}|\\$[A-Za-z0-9_@*#?!-]|`[^`]*`|[^ \t\"\047`$;&|)}])*"
      HPRE = "^[ \t]*((local|export|readonly|declare|typeset)([ \t]+-[A-Za-z]+)*[ \t]+)?"
    }
    function hrun(l,   s, nm) {   # the NAME=value run at the head of a line, after an optional export/local/readonly/declare/typeset
      HCNT = 0; HREST = ""; s = l
      match(s, HPRE); s = substr(s, RLENGTH + 1)
      while (match(s, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        nm = substr(s, 1, RLENGTH - 1); s = substr(s, RLENGTH + 1)
        HCNT++; HN[HCNT] = nm; HP[HCNT] = length(l) - length(s) + 1
        match(s, VAL); HV[HCNT] = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
        if (match(s, /^[ \t]+/)) s = substr(s, RLENGTH + 1); else break
      }
      HREST = s
    }
    { line[NR] = $0; total = NR
      hrun($0)
      for (k = 1; k <= HCNT; k++) assigned[HN[k]] = 1
    }
    # ponytail: a name counts as assigned only from the head of a line (plain, command-prefix or an export/local/readonly/declare/typeset list); NAME=x anywhere else (a run argument, a case arm, a comment, a usage string) is not, so such a read is flagged and takes a read-sink-ok marker, upgrade path is real shell parsing
    END {
      OPER = "\"?\\$(\\{[^}]*\\}|[A-Za-z0-9_@*]+)\"?"
      CMD  = "(^|[;&|({`]|[ \t](then|do|else))[ \t]*(cat|head|tail|less|more|source|\\.)([ \t]+(-[A-Za-z0-9]+([ \t]+[0-9]+)?|--))*[ \t]+"
      RED  = "(^|[^<0-9&>])<[ \t]*"
      for (n = 1; n <= total; n++) {
        if (!is_added(n)) continue
        l = line[n]
        if (l ~ /^[ \t]*#/) continue
        # taint: the first name of the line-head run, or a later UPPER_CASE one, whose value or the
        # rest of the line after it holds argv (x="${2:-}", x=$(realpath "$1"), export A=1 CFG="$1");
        # a later lowercase name (local p="$1" f="$2") stays untainted as on main; a mktemp
        # result is a file the script made itself, so a lasting assignment of one clears the taint
        hrun(l)
        lasting = (HREST == "" || HREST ~ /^[;&|)}#]/)   # a run followed by a command word only sets that command environment
        for (k = 1; k <= HCNT; k++) {
          if (lasting && HV[k] ~ /^"?(\$\([ \t]*|`[ \t]*)mktemp([ \t][^)`]*)?[)`]"?$/) delete tainted[HN[k]]
          else if (substr(l, HP[k]) ~ /\$(\{[1-9@*][^}]*\}|[1-9@*])/ && (k == 1 || HN[k] ~ /^[A-Z][A-Z0-9_]*$/)) tainted[HN[k]] = 1
        }
        hit = ""
        s = l
        while (match(s, CMD OPER "([ \t;|&)]|$)")) {
          ms = RSTART; ml = RLENGTH
          tok = substr(s, ms, ml); sub(/^.*[ \t]+("|\047)?\$/, "$", tok)
          v = varname(tok); hit = v
          if (v ~ /^[1-9@*]$/ || (v in tainted) || (v ~ /^[A-Z][A-Z0-9_]*$/ && !(v in assigned))) break
          hit = ""; s = substr(s, ms + ml)
        }
        if (hit == "") {
          s = l
          while (match(s, RED OPER "([ \t;|&)]|$)")) {
            ms = RSTART; ml = RLENGTH
            tok = substr(s, ms, ml); sub(/^[^$]*\$/, "$", tok)
            v = varname(tok); hit = v
            if (v ~ /^[1-9@*]$/ || (v in tainted) || (v ~ /^[A-Z][A-Z0-9_]*$/ && !(v in assigned))) break
            hit = ""; s = substr(s, ms + ml)
          }
        }
        if (hit == "") continue
        if (l ~ /read-sink-ok:[ \t]*[^ \t]/ || (n > 1 && line[n-1] ~ /read-sink-ok:[ \t]*[^ \t]/)) continue
        if (allow_near(n)) continue
        printf "%s:%d: reads a file named by %s with no allowlist: %s\n", FILE, n, (hit ~ /^[1-9@*]$/ ? "argv $" hit : "$" hit), l
      }
    }')" || { echo "FAIL: check-host-file-read-sinks: scan of $path failed (fail-closed)" >&2; exit 2; }
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
    found=1
  fi
done < "$FILES_LIST"

if [ "$found" -ne 0 ]; then
  echo "FAIL: check-host-file-read-sinks: added code reads a host file from argv/env without an allowlist. Add a realpath prefix check (case \"\$real\" in \"\$ROOT\"/*) ...) within 3 lines, or mark a reviewed read with '# read-sink-ok: <why>'." >&2
  exit 1
fi
echo "OK: check-host-file-read-sinks: no unguarded host-file read sink added"
