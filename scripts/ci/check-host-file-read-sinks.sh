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
#   - a variable assigned from argv in the same added lines (path laundering),
#     unless it was last assigned from mktemp (a file the script made itself)
#   - an UPPER_CASE variable the file never assigns (environment-supplied path);
#     a NAME=value token anywhere in the file counts as an assignment, including
#     the second name on an `export A=.. B=..` line and a `cmd NAME=value` argument
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
    function scan_assigns(l,   s, off, eq, eqp, m, nm, k) {   # every NAME=value token on a line
      ACNT = 0; s = l; off = 0
      while (match(s, /(^|[ \t;(&|{])[A-Za-z_][A-Za-z0-9_]*=([^=]|$)/)) {
        m = substr(s, RSTART, RLENGTH); eq = index(m, "=")
        nm = m; sub(/^[ \t;(&|{]/, "", nm); sub(/=.*$/, "", nm)
        eqp = off + RSTART - 1 + eq
        ACNT++; AN[ACNT] = nm; AP[ACNT] = eqp; AL[ACNT] = length(nm)
        s = substr(s, RSTART + eq); off = eqp
      }
      for (k = 1; k <= ACNT; k++)       # a value runs up to the next name on the line
        AV[k] = (k < ACNT) ? substr(l, AP[k] + 1, AP[k + 1] - AL[k + 1] - 1 - AP[k]) : substr(l, AP[k] + 1)
    }
    { line[NR] = $0; total = NR
      scan_assigns($0)
      for (k = 1; k <= ACNT; k++) assigned[AN[k]] = 1
    }
    # ponytail: any assignment, anywhere on any line, clears an UPPER_CASE name (X="${X:-}" then cat "$X" passes; so does the word NAME=x inside an echo), upgrade by tracking env-preserving assignments if it matters
    END {
      OPER = "\"?\\$(\\{[^}]*\\}|[A-Za-z0-9_@*]+)\"?"
      CMD  = "(^|[;&|({`]|[ \t](then|do|else))[ \t]*(cat|head|tail|less|more|source|\\.)([ \t]+(-[A-Za-z0-9]+([ \t]+[0-9]+)?|--))*[ \t]+"
      RED  = "(^|[^<0-9&>])<[ \t]*"
      for (n = 1; n <= total; n++) {
        if (!is_added(n)) continue
        l = line[n]
        if (l ~ /^[ \t]*#/) continue
        # taint: x=...$1... / x="${2:-}" / x=$(realpath "$1"), on any name of the line;
        # a mktemp result is a file the script made itself, so it clears the taint
        scan_assigns(l)
        for (k = 1; k <= ACNT; k++) {
          if (AV[k] ~ /mktemp/) delete tainted[AN[k]]
          else if (AV[k] ~ /\$(\{[1-9@*][^}]*\}|[1-9@*])/) tainted[AN[k]] = 1
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
