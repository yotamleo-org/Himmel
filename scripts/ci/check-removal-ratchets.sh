#!/usr/bin/env bash
# scripts/ci/check-removal-ratchets.sh — a removal ratchet is a one-shot helper,
# never a suite and never wired into pre-commit or CI.
#
# A removal ratchet checks that a removed thing (a term, a file, a platform)
# stays removed. Run once by hand, it proves the removal; run forever, it only
# fails on unrelated work. Its one home is scripts/one-shot/: nothing there is a
# suite, so run-shell-tests.sh, impacted-suites and the `all` mode never run it.
#
# The key is a directory and a filename, never the script's shell text:
#   - a tracked test-no-*.sh anywhere is a removal ratchet named as a suite;
#   - a tracked test-*.sh under scripts/one-shot/ is a suite the runner discovers;
#   - a scripts/one-shot/ path with a suite-tiers.tsv row is a registered suite;
#   - a scripts/one-shot/ helper named (by basename) in .pre-commit-config.yaml
#     or a .github/workflows/ file is wired into a hook or a CI step;
#   - a scripts/one-shot/ helper with a `# selector: tree-scan` line is picked
#     by impacted-suites.
#
# Usage: check-removal-ratchets.sh [--root DIR]   (default: this repo)
# Exit codes: 0 clean; 1 one FAIL line per violation; 2 usage or git error.
set -uo pipefail

HELPERS=scripts/one-shot/
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [ $# -gt 0 ]; then
  if [ "$1" != "--root" ] || [ $# -ne 2 ]; then
    echo "usage: $0 [--root DIR]" >&2; exit 2
  fi
  root="$2"
fi

if ! tracked="$(git -C "$root" ls-files)"; then
  echo "check-removal-ratchets: git ls-files failed in $root" >&2; exit 2
fi

bad=0
flag() { printf 'FAIL %s\n' "$1"; bad=$((bad + 1)); }

helpers=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  b="${p##*/}"
  case "$p" in
    "$HELPERS"*)
      case "$b" in
        test-*.sh) flag "test-*.sh under $HELPERS is a suite the runner discovers: $p" ;;
        *) helpers="$helpers$p
" ;;
      esac ;;
  esac
  case "$b" in
    test-no-*.sh) flag "removal ratchet named as a suite (test-no-*.sh): $p; move it to $HELPERS under another name, or delete it" ;;
  esac
done <<EOF
$tracked
EOF

tiers="$root/scripts/ci/suite-tiers.tsv"
if [ -r "$tiers" ]; then
  while IFS="$(printf '\t')" read -r p t _; do
    case "$p" in
      "$HELPERS"*) flag "one-shot helper has a suite-tiers row (tier $t): $p" ;;
    esac
  done < "$tiers"
else
  flag "cannot read $tiers"
fi

# has <grep-flag> <text> <file>: 0 found, 1 not found; an unreadable file is a FAIL.
has() {
  grep -q"$1" -- "$2" "$3"; local rc=$?
  [ "$rc" -le 1 ] || flag "cannot read $3 (grep rc=$rc)"
  return "$rc"
}

wired="$(printf '%s\n' "$tracked" | grep -E '^(\.pre-commit-config\.yaml|\.github/workflows/[^/]+\.ya?ml)$')"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  b="${p##*/}"
  if has x '# selector: tree-scan' "$root/$p"; then
    flag "one-shot helper carries '# selector: tree-scan': $p"
  fi
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    if has F "$b" "$root/$w"; then
      flag "one-shot helper wired in $w: $p"
    fi
  done <<EOF
$wired
EOF
done <<EOF
$helpers
EOF

[ "$bad" -eq 0 ]
