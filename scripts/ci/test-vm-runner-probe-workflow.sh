#!/usr/bin/env bash
# scripts/ci/test-vm-runner-probe-workflow.sh -- static suite for the VM runner
# probe workflow, the one dispatch target the live proof runs on the himmel-vm
# self-hosted runner. The repo is public, so the probe must stay inert:
#   1. the only trigger is workflow_dispatch (no pull_request, push, schedule);
#   2. top-level permissions are empty, no write scope anywhere;
#   3. no `uses:` (no checkout, no third-party action) and no secrets;
#   4. it runs on [self-hosted, himmel-vm] with timeout-minutes <= 5;
#   5. a concurrency group that never cancels a running probe.
# Mutation controls prove each check can fail; no network.
#
# Usage: bash scripts/ci/test-vm-runner-probe-workflow.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${PROBE_YML:-$ROOT/.github/workflows/vm-runner-probe.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

strip_comments() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }

# check_file <file> -- print one "name" line per violated property.
check_file() {
    local f="$1" s events mins
    [ -f "$f" ] || { echo "workflow-missing"; return; }
    s=$(strip_comments "$f")
    events=$(awk '/^on:/{f=1;next} /^[^[:space:]]/{f=0} f && /^  [a-z_]+:/{sub(/:.*/,"");gsub(/ /,"");print}' <<< "$s" | sort | tr '\n' ' ') # pipefail-ok: small input
    [ "$events" = "workflow_dispatch " ] || echo "extra-trigger"
    grep -qE '^permissions:[[:space:]]*\{\}[[:space:]]*$' <<< "$s" || echo "permissions-not-empty"
    grep -qE '^[[:space:]]+[a-z-]+:[[:space:]]*write[[:space:]]*$' <<< "$s" && echo "write-permission"
    grep -qE '(^|[[:space:]])uses:' <<< "$s" && echo "uses-action"
    grep -qE 'secrets\.|GITHUB_TOKEN' <<< "$s" && echo "references-secret"
    grep -qE '^[[:space:]]+runs-on:[[:space:]]*\[self-hosted,[[:space:]]*himmel-vm\][[:space:]]*$' <<< "$s" || echo "not-vm-runner"
    mins=$(sed -n 's/^[[:space:]]*timeout-minutes:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' <<< "$s" | head -n1)
    if [ -z "$mins" ]; then echo "no-timeout"; elif [ "$mins" -gt 5 ]; then echo "timeout-over-5"; fi
    grep -qE '^[[:space:]]+group:[[:space:]]*vm-runner-probe[[:space:]]*$' <<< "$s" || echo "no-concurrency-group"
    grep -qE '^[[:space:]]+cancel-in-progress:[[:space:]]*false' <<< "$s" || echo "cancels-running-probe"
}

got=$(check_file "$WF")
if [ -z "$got" ]; then ok "vm-runner-probe.yml satisfies every property"; else bad "vm-runner-probe.yml violates: ${got//$'\n'/ }"; fi

# Mutation controls: each rewrite of the real workflow must trip its check.
if [ -f "$WF" ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/probe-wf.XXXXXX") || exit 1; trap 'rm -rf "$tmp"' EXIT
    mutate() { # <name> <sed-expr>
        sed -e "$2" "$WF" > "$tmp/m.yml"
        out=$(check_file "$tmp/m.yml")
        if grep -qx "$1" <<< "$out"; then ok "control: $1 detected"; else bad "control: $1 NOT detected"; fi
    }
    mutate extra-trigger "s#^  workflow_dispatch:#  pull_request:\n  workflow_dispatch:#"
    mutate extra-trigger "s#^  workflow_dispatch:#  schedule:\n  workflow_dispatch:#"
    mutate permissions-not-empty "s#^permissions: {}#permissions: read-all#"
    mutate write-permission "s#^permissions: {}#permissions: {}\n  contents: write#"
    mutate uses-action "s#^    steps:#    steps:\n      - uses: actions/checkout@v4#"
    mutate references-secret "s#^    steps:#    steps:\n      - run: echo \${{ secrets.X }}#"
    mutate not-vm-runner "s#himmel-vm#ubuntu-latest#"
    mutate timeout-over-5 "s#timeout-minutes: [0-9]*#timeout-minutes: 30#"
    mutate no-timeout "s#timeout-minutes:#timeout:#"
    mutate cancels-running-probe "s#cancel-in-progress: false#cancel-in-progress: true#"
    mutate no-concurrency-group "s#group: vm-runner-probe#group: other#"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2; exit 1
