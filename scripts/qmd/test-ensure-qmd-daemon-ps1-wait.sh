#!/usr/bin/env bash
# selector: tree-scan
# test-ensure-qmd-daemon-ps1-wait.sh - structural guard for the PowerShell
# ensure twin (no pwsh needed): after `qmd mcp --http --daemon` returns, the
# post-start alive wait must be bounded by $QmdStartTimeout, not a literal
# few-second loop. The qmd-mcp-daemon ONLOGON task runs this script, so a
# daemon that is merely slow to bind at boot made the task exit 1 and report
# Last Result=1 while the daemon came up healthy moments later.
# shellcheck disable=SC2016 # literal PowerShell text, not shell expansion
set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ps1="$repo_root/scripts/qmd/ensure-qmd-daemon.ps1"
[ -f "$ps1" ] || { echo "FAIL: $ps1 not found" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# The alive-wait loop is the one whose body probes Test-QmdAlive and sleeps.
loop="$(grep -n 'for (\$i = 0; \$i -lt ' "$ps1")"
[ -n "$loop" ] || fail "no 'for (\$i = 0; \$i -lt ...)' wait loop found in ensure-qmd-daemon.ps1"
[ "$(printf '%s\n' "$loop" | wc -l)" -eq 1 ] || fail "expected exactly one wait loop, got: $loop"
case "$loop" in
  *'-lt $QmdStartTimeout'*) : ;;
  *) fail "post-start wait loop is not bounded by \$QmdStartTimeout (got: $loop)" ;;
esac

echo "PASS: ensure-qmd-daemon.ps1 post-start wait is bounded by QmdStartTimeout"
