#!/usr/bin/env bash
# scripts/ci/test-snyk-weekly-workflow.sh -- shape guard for
# .github/workflows/snyk-weekly.yml: the scheduled Snyk scan.
# Text assertions over the workflow with comments stripped; no network.
#
# It pins what keeps the scan inside the free quota and the secret out of reach:
# schedule + workflow_dispatch only (never per PR), read-only permissions, every
# `uses:` pinned by a 40-hex sha, the CLI installed at an exact version, the
# token gated so an empty SNYK_TOKEN skips with a notice, the scan and the forks
# scan run through scripts/security/snyk-scan.sh, and the JSON uploaded as an artifact.
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

# run the gate step's own script with an empty and a set token
gate="$(awk '
  /^      - name: Gate on the token/ { g=1; next }
  g && /^      - / { exit }
  g && /^        run: \|/ { r=1; next }
  g && r { sub(/^          /, ""); print }' <<< "$s" | sed 's/\${{ github.repository }}/o\/r/g')"
out="$(mktemp "${TMPDIR:-/tmp}/snyk-gate.XXXXXX")" || { bad "mktemp for the gate run failed"; out=""; }
if [ -n "$gate" ] && [ -n "$out" ]; then
  : > "$out"
  msg_empty="$(SNYK_TOKEN='' GITHUB_OUTPUT="$out" bash -c "$gate")"
  if [ "$(cat "$out")" = "enabled=false" ] && grep -q '^::notice.*SNYK_TOKEN' <<< "$msg_empty"; then ok "empty token: enabled=false and a notice"; else bad "empty token: enabled=false and a notice"; fi
  : > "$out"
  msg_set="$(SNYK_TOKEN='x' GITHUB_OUTPUT="$out" bash -c "$gate")"
  if [ "$(cat "$out")" = "enabled=true" ] && [ -z "$msg_set" ]; then ok "set token: enabled=true and no notice"; else bad "set token: enabled=true and no notice"; fi
else
  bad "gate step script not found in the workflow"
fi
[ -z "$out" ] || rm -f "$out"
# every step that does work (checkout, install, scan, upload) carries the gate
ungated="$(awk '
  function flush() { if (blk ~ /(actions\/checkout@|npm install -g snyk@|bash scripts\/security\/snyk-scan\.sh|actions\/upload-artifact@)/ && blk !~ /if:[^\n]*steps\.gate\.outputs\.enabled == .true./) n++ }
  /^[[:space:]]+- / { flush(); blk="" }
  { blk = blk "\n" $0 }
  END { flush(); print n+0 }' <<< "$s")"
if [ "$ungated" = 0 ]; then ok "every working step is gated on the token"; else bad "every working step is gated on the token ($ungated ungated)"; fi
check_not "token is not exposed at job level"       '^    env:'
tok_steps="$(awk '
  function flush() { if (blk ~ /secrets\.SNYK_TOKEN/) { if (blk ~ /id: gate/) g++; else if (blk ~ /bash scripts\/security\/snyk-scan\.sh/) sc++; else other++ } }
  /^[[:space:]]+- / { flush(); blk="" }
  { blk = blk "\n" $0 }
  END { flush(); print g+0, sc+0, other+0 }' <<< "$s")"
if [ "$tok_steps" = "1 2 0" ]; then ok "token reaches only the gate, scan and forks steps"; else bad "token reaches only the gate, scan and forks steps (gate/scan/other: $tok_steps)"; fi
check     "checkout does not persist credentials"   'persist-credentials: false'
check     "scan runs snyk-scan.sh"                 'bash scripts/security/snyk-scan\.sh'
check     "scan writes to a known out-dir"          'snyk-scan\.sh.*--out-dir'
# shellcheck disable=SC2016  # regex: a literal $RUNNER_TEMP
check     "forks scan runs snyk-scan.sh --forks"   'bash scripts/security/snyk-scan\.sh --forks --out-dir "\$RUNNER_TEMP/snyk"'
check     "uv installed at an exact version"        'pipx install uv==[0-9]+\.[0-9]+\.[0-9]+([[:space:]]|$)'
check     "curl is installed for the osv.dev lookup" 'apt-get install.* curl'
check     "forks scan still runs when the main scan finds issues" 'if: \$\{\{ !cancelled\(\) && steps\.gate\.outputs\.enabled == .true. \}\}'
check     "dispatch input probes a missing ref"     'missing_ref_probe:'
forks_step="$(awk '/^      - name: Run the forks scan/ {f=1; print; next} f && /^      - / {exit} f {print}' <<< "$s")"
probe_guard="$(awk '/if \[ "\$MISSING_REF_PROBE" = "true" \]; then/ {f=1; next} f && /^[[:space:]]+fi$/ {exit} f {print}' <<< "$forks_step")"
if grep -q 'inputs.missing_ref_probe' <<< "$forks_step" && grep -q 'export SNYK_SCAN_FORKS=' <<< "$probe_guard"; then ok "probe feeds one missing-ref fork row to the forks scan"; else bad "probe feeds one missing-ref fork row to the forks scan"; fi
check     "JSON uploaded as an artifact"            'actions/upload-artifact@'
check     "upload runs even when the scan finds issues" "if: always\(\) && steps\.gate\.outputs\.enabled == 'true'"

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed." >&2; exit 1; fi
echo "all checks passed"
