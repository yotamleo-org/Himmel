#!/usr/bin/env bash
# selector: tree-scan
# test-docs-current-version.sh — the site pages describe only the current version.
#
# A site page (an entry of site/allowlist.txt) must not name a dropped platform
# (Windows, WSL, PowerShell, Git Bash, MSYS), an old model generation, or an
# internal workstream code (WS1..WS9). Release notes are history and exempt.
#
#   PENDING  pages not yet swept; the list only shrinks. A pending page that is
#            now clean fails too, so its entry is removed in the PR that
#            cleans it.
#   ALLOW    file<TAB>substring: one line a page keeps on purpose (a guard that
#            blocks `schtasks`, the one archive pointer, a measured eval row).
#
# Platform guard: bash 3.2+, grep.
# Usage: bash scripts/docs/test-docs-current-version.sh
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PATTERN='Windows|\bWSL2?\b|PowerShell|\.ps1\b|Git[- ]Bash|\bMSYS|%LOCALAPPDATA%|schtasks|gpt-5\.[0-5]\b|gpt-6-(sol|astra)\b|claude-(opus|sonnet|haiku)-4|\b(Haiku|Sonnet|Opus) 4\.[0-9]|\bWS[0-9]+\b'

PENDING='
why-himmel.md
getting-started.md
setup/install.md
setup/new-machine.md
daily-loop.md
commands-catalog.md
hermes-runbook.md
handover/afk-mode.md
handover/running-a-chief.md
glossary.md
internals/enforcement.md
internals/stuck-playbook.md
internals/egress-matrix.md
internals/harness-compat.md
internals/testing.md
internals/lane-calibration.md
evals/review-panel.md
'

# The backticks below are literal page text, not command substitution.
# shellcheck disable=SC2016
ALLOW='
internals/lane-parity.md	`TERMINAL_DESTRUCTIVE` blocks `schtasks`
evals/README.md	| `codex:gpt-6-astra` |
evals/README.md	| `codex:gpt-6-sol` |
'

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $*"; }
bad() { fail=$((fail + 1)); echo "not ok - $*"; }

for sample in 'runs on Windows' 'under WSL2' 'pinned gpt-5.5' 'gpt-6-sol' 'claude-haiku-4-5' 'Opus 4.8' 'the WS5 index'; do
  if ! grep -q -E "$PATTERN" <<< "$sample"; then
    bad "pattern misses its own sample '$sample'"
  fi
done

in_list() { grep -q -x -F "$1" <<< "$2"; }

# hits <page>: the page's matching lines minus its ALLOW lines.
hits() {
  local page=$1 line allowed rest
  grep -n -E "$PATTERN" "$ROOT/docs/$page" | while IFS= read -r line; do
    allowed=0
    while IFS= read -r rest; do
      [ -n "$rest" ] || continue
      [ "${rest%%	*}" = "$page" ] || continue
      case $line in *"${rest#*	}"*) allowed=1 ;; esac
    done <<EOF
$ALLOW
EOF
    [ "$allowed" -eq 1 ] || printf '%s\n' "$line"
  done
}

pages=$(grep -v -e '^#' -e '^$' "$ROOT/site/allowlist.txt")
for page in $pages; do
  case $page in release/*) continue ;; esac
  [ -f "$ROOT/docs/$page" ] || { bad "site/allowlist.txt names docs/$page, which does not exist"; continue; }
  [ -r "$ROOT/docs/$page" ] || { bad "docs/$page cannot be read"; continue; }
  found=$(hits "$page")
  if in_list "$page" "$PENDING"; then
    [ -n "$found" ] || bad "docs/$page is clean now: remove it from PENDING"
  elif [ -n "$found" ]; then
    printf '%s\n' "$found" | sed "s|^|docs/$page:|"
    bad "docs/$page names a dropped platform, an old model or a workstream code (listed above)"
  else
    ok "docs/$page"
  fi
done

for page in $PENDING; do
  in_list "$page" "$pages" || bad "PENDING names $page, which is not a site page"
done

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
