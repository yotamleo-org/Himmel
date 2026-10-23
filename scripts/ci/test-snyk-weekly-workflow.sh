#!/usr/bin/env bash
# scripts/ci/test-snyk-weekly-workflow.sh -- shape guard for
# .github/workflows/snyk-weekly.yml: the scheduled Snyk scan.
# Text assertions over the workflow with comments stripped; no network.
#
# It pins what keeps the scan inside the free quota and the secret out of reach:
# schedule + workflow_dispatch only (never per PR), read-only permissions, every
# `uses:` pinned by a 40-hex sha, the CLI installed at an exact version, the
# token gated so an empty SNYK_TOKEN skips with a notice, the scan run through
# scripts/security/snyk-scan.sh, and the JSON uploaded as an artifact.
#
# ponytail: line-oriented text checks, not a YAML parse, upgrade to a real parser
# if the repo ever vendors one for workflows (as test-main-sweep-red-workflow.sh).
#
# Usage: bash scripts/ci/test-snyk-weekly-workflow.sh
# Env:   SNYK_WEEKLY_YML  workflow under test (default: the tracked file).
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${SNYK_WEEKLY_YML:-$ROOT/.github/workflows/snyk-weekly.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

if [ ! -f "$WF" ]; then
  bad "workflow file missing: $WF"
  echo "$fails check(s) failed." >&2
  exit 1
fi

s="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$WF")"
has() { grep -Eq -- "$1" <<< "$s"; }
check() { # <label> <regex>
  if has "$2"; then ok "$1"; else bad "$1"; fi
}
check_not() { # <label> <regex>
  if has "$2"; then bad "$1"; else ok "$1"; fi
}

check     "triggers on schedule"                    '^[[:space:]]+schedule:'
check     "triggers on workflow_dispatch"           '^[[:space:]]+workflow_dispatch:'
check_not "never runs per PR or push"               '^[[:space:]]+(pull_request|pull_request_target|push|workflow_run):'
check     "permissions are contents: read"          '^[[:space:]]+contents: read[[:space:]]*$'
check_not "no write permission"                     ':[[:space:]]*write[[:space:]]*$'

unpinned="$(grep -E '^[[:space:]]*-?[[:space:]]*uses:' <<< "$s" | grep -Ev 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]*$' || true)"
if [ -z "$unpinned" ] && has 'uses:'; then ok "every uses: is pinned by a 40-hex sha"; else bad "every uses: is pinned by a 40-hex sha"; fi

check     "CLI installed at an exact version"       'npm install -g snyk@[0-9]+\.[0-9]+\.[0-9]+([[:space:]]|$)'
check     "token read from secrets.SNYK_TOKEN"      'SNYK_TOKEN: \$\{\{ secrets\.SNYK_TOKEN \}\}'
check     "empty token skips with a notice"         '::notice.*SNYK_TOKEN'
check     "install and scan steps gated on the token" "if: steps\.gate\.outputs\.enabled == 'true'"
check     "scan runs snyk-scan.sh"                  'bash scripts/security/snyk-scan\.sh'
check     "scan writes to a known out-dir"          'snyk-scan\.sh.*--out-dir'
check     "JSON uploaded as an artifact"            'actions/upload-artifact@'
check     "upload runs even when the scan finds issues" "if: always\(\) && steps\.gate\.outputs\.enabled == 'true'"

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed." >&2; exit 1; fi
echo "all checks passed"
