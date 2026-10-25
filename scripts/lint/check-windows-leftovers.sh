#!/usr/bin/env bash
# check-windows-leftovers.sh — a ratchet on Windows-only code and on the
# archived voice feature.
#
# Windows support is dropped and voice is archived under archive/voice/
# until it returns for Linux/macOS. Two classes are
# counted per tracked file, outside archive/, docs/release/ and changelogs:
#   win    Windows-only constructs (schtasks, commandWindows, cmd.exe, ...)
#   voice  references to the archived voice feature
# windows-leftovers-baseline.tsv lists the files still carrying them, with a
# line count. A file not in the baseline, or a count above its baseline, fails.
# A count below the baseline passes: lower the row when the branch goes.
#
# Usage:
#   check-windows-leftovers.sh [--root <dir>]          check, exit 1 on a hit
#   check-windows-leftovers.sh [--root <dir>] --print  print current counts
set -uo pipefail

root=""
print=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --print) print=1; shift ;;
    *) echo "check-windows-leftovers: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$root" ] || root="$(git rev-parse --show-toplevel)" || exit 2

WIN_RE='schtasks|commandWindows|cmd\.exe|powershell\.exe|%LOCALAPPDATA%|windows-latest|MSYS_NO_PATHCONV|cygpath|\.ps1\b|run-hook\.cmd|Get-ScheduledTask'
VOICE_RE='scripts/voice/|speak-reply|voice-policy|commands/speak\.md|docs/voice\.md|(^|[/( ])voice\.md|VOICE_SPEAK|jarvis\.py|push-to-talk|speech-daemon'
SELF='scripts/lint/check-windows-leftovers.sh'
TEST='scripts/lint/test-check-windows-leftovers.sh'
BASELINE='scripts/lint/windows-leftovers-baseline.tsv'

counts() {
  local class="$1" re="$2"
  git -C "$root" grep -c -I -i -E "$re" -- . \
    ':!archive/' ':!docs/release/' ':!**/CHANGELOG.md' ':!CHANGELOG.md' \
    ":!$SELF" ":!$TEST" ":!$BASELINE" 2>/dev/null |
    awk -F: -v c="$class" '{ n = $NF; sub(/:[0-9]+$/, ""); printf "%s\t%s\t%s\n", c, n, $0 }'
}

current="$( { counts win "$WIN_RE"; counts voice "$VOICE_RE"; } | sort -t "$(printf '\t')" -k1,1 -k3,3)"
if [ "$print" -eq 1 ]; then
  printf '%s\n' "$current"
  exit 0
fi

base="$root/$BASELINE"
if [ ! -f "$base" ]; then
  echo "check-windows-leftovers: missing $BASELINE" >&2
  exit 1
fi

bad=0
while IFS="$(printf '\t')" read -r class n path; do
  [ -n "$path" ] || continue
  allowed=$(awk -F'\t' -v c="$class" -v p="$path" '$1 == c && $3 == p { print $2; exit }' "$base")
  if [ -z "$allowed" ]; then
    echo "check-windows-leftovers: $class: $path has $n line(s) and no baseline row" >&2
    bad=1
  elif [ "$n" -gt "$allowed" ]; then
    echo "check-windows-leftovers: $class: $path grew from $allowed to $n line(s)" >&2
    bad=1
  fi
done <<EOF
$current
EOF

if [ "$bad" -ne 0 ]; then
  echo "check-windows-leftovers: Windows-only code and the voice feature stay out of the live tree (archive/voice/ holds voice)." >&2
  exit 1
fi
echo "check-windows-leftovers: OK"
