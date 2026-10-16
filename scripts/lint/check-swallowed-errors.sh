#!/usr/bin/env bash
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows.
#
# check-swallowed-errors.sh — refuse NEW swallowed errors in gate and hook scripts.
# A read whose failure is turned into a plausible value reaches the decision as
# an answer; scripts/lib/result.sh (run_or_unknown, require_ok) is the fail-closed way.
#
# Scans scripts/{hooks,cr,handover,ci}/**/*.sh (not test-*.sh, fixtures/, testdata/)
# for three shapes, one count per (file, shape):
#   cmdsub-devnull   2>/dev/null inside a $(...) on one line
#   true-after-read  `|| true` / `|| :` on a line that reads ($(...) or `read`)
#   default-zero     `|| echo 0` / `|| echo []` (also printf, quoted forms)
# A line is exempt with `swallow-ok: <reason>` on it or on the comment line above.
# Existing findings live in the baseline (path, shape, count); only a count ABOVE
# its baseline row fails, so the lint lands green and refuses only new ones.
# ponytail: per-line regexes, so a $(...) split over lines or a || on a continuation
# line slips through, and a count baseline cannot tell WHICH line of a file is new
# (every line of an over-budget shape is listed); upgrade to a tokenizer if either bites.
#
# Usage: check-swallowed-errors.sh [--root DIR] [--baseline FILE] [--write-baseline]
# Exit: 0 clean · 1 new findings (path:line: shape: text) · 2 cannot evaluate (fail-closed)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
BASELINE=""
WRITE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)           [ $# -ge 2 ] || { echo "check-swallowed-errors: --root needs a dir" >&2; exit 2; }
                          ROOT="$2"; shift 2 ;;
        --baseline)       [ $# -ge 2 ] || { echo "check-swallowed-errors: --baseline needs a file" >&2; exit 2; }
                          BASELINE="$2"; shift 2 ;;
        --write-baseline) WRITE=1; shift ;;
        *) echo "usage: check-swallowed-errors.sh [--root DIR] [--baseline FILE] [--write-baseline]" >&2; exit 2 ;;
    esac
done
[ -d "$ROOT" ] || { echo "check-swallowed-errors: root '$ROOT' is not a directory" >&2; exit 2; }
[ -n "$BASELINE" ] || BASELINE="$SELF_DIR/swallowed-errors-baseline.txt"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/swallowed-errors.XXXXXX")" || { echo "check-swallowed-errors: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

FILES="$WORK/files"
( cd "$ROOT" && find scripts/hooks scripts/cr scripts/handover scripts/ci -type f -name '*.sh' \
    ! -name 'test-*.sh' ! -path '*/fixtures/*' ! -path '*/testdata/*' 2>/dev/null ) | LC_ALL=C sort > "$FILES"
[ -s "$FILES" ] || { echo "check-swallowed-errors: no scripts found under $ROOT/scripts/{hooks,cr,handover,ci}" >&2; exit 2; }

export P_DEVNULL='\$\(.*2>/dev/null.*\)'
export P_TRUE='(\$\(|(^|[ \t;|&])read[ \t]).*\|\|[ \t]*(true|:)([ \t;)]|$)'
export P_ZERO="\\|\\|[ \\t]*(echo|printf)[ \\t]+(0|\"0\"|'0'|\\[\\]|\"\\[\\]\"|'\\[\\]')([ \\t;)\"'|&]|\$)"

HITS="$WORK/hits"
( cd "$ROOT" && while IFS= read -r f; do
    awk -v F="$f" '
    BEGIN { pd = ENVIRON["P_DEVNULL"]; pt = ENVIRON["P_TRUE"]; pz = ENVIRON["P_ZERO"]; prev_ok = 0 }
    {
        s = $0; sub(/^[ \t]+/, "", s)
        is_comment = (s ~ /^#/)
        ok = (index($0, "swallow-ok:") > 0)
        if (!is_comment && !ok && !prev_ok) {
            if ($0 ~ pd) printf "%s\tcmdsub-devnull\t%d\t%s\n", F, NR, s
            if ($0 ~ pt) printf "%s\ttrue-after-read\t%d\t%s\n", F, NR, s
            if ($0 ~ pz) printf "%s\tdefault-zero\t%d\t%s\n", F, NR, s
        }
        prev_ok = (is_comment && ok)
    }' "$f" || exit 2
done < "$FILES" ) > "$HITS" || { echo "check-swallowed-errors: scan failed" >&2; exit 2; }

if [ "$WRITE" -eq 1 ]; then
    awk -F'\t' '{ c[$1 "\t" $2]++ } END { for (k in c) printf "%s\t%d\n", k, c[k] }' "$HITS" | LC_ALL=C sort > "$BASELINE" \
        || { echo "check-swallowed-errors: cannot write $BASELINE" >&2; exit 2; }
    echo "check-swallowed-errors: baseline written to $BASELINE ($(wc -l < "$BASELINE" | tr -d ' ') rows)"
    exit 0
fi

[ -r "$BASELINE" ] || { echo "check-swallowed-errors: baseline '$BASELINE' not readable (fail-closed)" >&2; exit 2; }

awk -F'\t' '
FILENAME == ARGV[1] { base[$1 "\t" $2] = $3 + 0; next }
{ key = $1 "\t" $2; n[key]++; rows[key] = rows[key] sprintf("%s:%s: %s: %s\n", $1, $3, $2, $4) }
END {
    for (k in n) if (n[k] > (k in base ? base[k] : 0)) { printf "%s", rows[k]; bad = 1 }
    exit bad ? 1 : 0
}' "$BASELINE" "$HITS" > "$WORK/out"
rc=$?
if [ "$rc" -eq 1 ]; then
    LC_ALL=C sort "$WORK/out"
    echo "check-swallowed-errors: a failed read became a plausible value (listed above). Use run_or_unknown/require_ok from scripts/lib/result.sh," >&2
    echo "  or mark the line '# swallow-ok: <reason>'. Existing findings are the baseline: scripts/lint/swallowed-errors-baseline.txt." >&2
elif [ "$rc" -ne 0 ]; then
    echo "check-swallowed-errors: awk failed (rc=$rc)" >&2
    rc=2
fi
exit "$rc"
