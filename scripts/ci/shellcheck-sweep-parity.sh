#!/usr/bin/env bash
# scripts/ci/shellcheck-sweep-parity.sh -- proves the binned sweep of shellcheck-pr-range.sh
# reports the same findings as ONE serial shellcheck invocation over the same files.
#
# The files are the ones the pre-commit shellcheck hook would lint (its `types` and `exclude`),
# listed by a throwaway local hook with the same exclude. The serial run is a single shellcheck
# process over all of them: `pre-commit run shellcheck --files` would be several processes, since
# pre-commit splits a long file list, and a verdict depends on which files share a process. Both
# runs use the same flags, one finding per line (gcc format), deduplicated. "missing" is a finding
# only the serial run reports (a false green in the sweep), "extra" one only the sweep reports (a
# false red).
#
# Usage: shellcheck-sweep-parity.sh [<list-file>]
#   <list-file>  newline-separated tracked paths to lint; default: every tracked file.
# Environment:
#   PARITY_OPTS  extra shellcheck flags for both runs; default "--enable=all --severity=style".
#                Set it to an empty string for the hook's own flags.
# Exit codes: 0 -- identical; 1 -- missing or extra findings, or a run never ran the hook; 2 -- a setup step or the serial shellcheck run failed.
set -u

root=$(git rev-parse --show-toplevel) || exit 1
cd "$root" || exit 1
opts="${PARITY_OPTS---enable=all --severity=style}"

# shellcheck source=../lib/prim.sh
. "$root/scripts/lib/prim.sh" || { echo "parity: cannot load scripts/lib/prim.sh" >&2; exit 2; }
T=$(tmpdir) || exit 1
trap 'rm -rf "$T"' EXIT
if [ -n "${1:-}" ]; then cp "$1" "$T/list" || exit 1; else git ls-files > "$T/list" || exit 1; fi

# the shellcheck hook's own exclude, copied into a local hook that prints the files it is handed
excl=$(awk '/- id: shellcheck$/ { f = 1; next } f && /^[[:space:]]*exclude:/ { sub(/^[[:space:]]*exclude:[[:space:]]*/, ""); print; exit }' .pre-commit-config.yaml)
[ -n "$excl" ] || { echo "parity: no exclude found for the shellcheck hook" >&2; exit 1; }
{
  echo 'repos:'
  echo '  - repo: local'
  echo '    hooks:'
  echo '      - id: lister'
  echo '        name: lister'
  echo '        language: system'
  printf '        entry: printf %s\n' "'%s\\n'"
  echo '        types: [shell]'
  printf '        exclude: %s\n' "$excl"
} > "$T/lister.yaml"
tr '\n' '\0' < "$T/list" | xargs -0 pre-commit run lister --config "$T/lister.yaml" --verbose --files > "$T/lister.out" 2>&1
grep -vE '^(lister\.\.\.|- hook id:|- duration:|- exit code:)|^$' "$T/lister.out" | sort -u > "$T/shell.list"
[ -s "$T/shell.list" ] || { echo "parity: the hook would lint no file; head of the lister output:" >&2; head -5 "$T/lister.out" >&2; exit 1; }
bytes=$(wc -c < "$T/shell.list" | tr -d ' ')
[ "$bytes" -lt 1000000 ] || { echo "parity: $bytes bytes of paths do not fit one shellcheck command line" >&2; exit 1; }

# gcc format: path:line:col: severity: message [SCnnnn]
findings() { grep -E '^[^ ]+:[0-9]+:[0-9]+: (error|warning|note): ' "$1" | sort -u; }

echo "parity: $(shellcheck --version | grep '^version')" >&2
t=$SECONDS
# shellcheck disable=SC2086 # the flags are a word list
tr '\n' '\0' < "$T/shell.list" | xargs -0 -s 1500000 shellcheck $opts --format=gcc > "$T/serial.out" 2>&1
serial_rc=$?
echo "parity: serial run took $((SECONDS - t))s" >&2
# The linter exits 1 for findings; any other non-zero (xargs 123 wraps it) is a run that failed
case "$serial_rc" in 0 | 1 | 123) ;; *) echo "parity: the serial shellcheck run failed (rc $serial_rc); head of its output:" >&2; head -5 "$T/serial.out" >&2; exit 2 ;; esac
grep -q 'shellcheck: ' "$T/serial.out" && { echo "parity: the serial shellcheck run reported an error:" >&2; grep 'shellcheck: ' "$T/serial.out" | head -5 >&2; exit 2; }
t=$SECONDS
SHELLCHECK_OPTS="$opts --format=gcc" bash "$root/scripts/ci/shellcheck-pr-range.sh" --sweep "$T/list" > "$T/sweep.out" 2> "$T/sweep.err"
echo "parity: sweep took $((SECONDS - t))s" >&2

findings "$T/serial.out" > "$T/serial.f"
findings "$T/sweep.out" > "$T/sweep.f"
comm -23 "$T/serial.f" "$T/sweep.f" > "$T/missing"
comm -13 "$T/serial.f" "$T/sweep.f" > "$T/extra"
serial=$(wc -l < "$T/serial.f" | tr -d ' ')
sweep=$(wc -l < "$T/sweep.f" | tr -d ' ')
missing=$(wc -l < "$T/missing" | tr -d ' ')
extra=$(wc -l < "$T/extra" | tr -d ' ')
echo "parity: files=$(wc -l < "$T/list" | tr -d ' ') linted=$(wc -l < "$T/shell.list" | tr -d ' ') opts='$opts' serial=$serial sweep=$sweep missing=$missing extra=$extra"
[ "$missing" -eq 0 ] || { echo "parity: missing (only the serial run reports):" >&2; head -20 "$T/missing" >&2; }
[ "$extra" -eq 0 ] || { echo "parity: extra (only the sweep reports):" >&2; head -20 "$T/extra" >&2; }
grep -E 'parallel full sweep|ALL FILES' "$T/sweep.err" >&2
# a sweep whose hook never ran would pass vacuously
grep -Eq '^shellcheck\.\.\.+(Passed|Failed)' "$T/sweep.out" || { echo "parity: the sweep never ran the hook; head of its output:" >&2; head -5 "$T/sweep.out" >&2; exit 1; }
[ "$missing" -eq 0 ] && [ "$extra" -eq 0 ]
