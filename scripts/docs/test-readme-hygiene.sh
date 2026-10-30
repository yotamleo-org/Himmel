#!/usr/bin/env bash
# test-readme-hygiene.sh — the public README reads cleanly for a new visitor.
#
#   1. No internal ticket IDs (HIMMEL-<n>) in README.md.
#   2. No version-pinned support claims ("in v1.0.0", "until v1.0.1").
#   3. No evidence link pinned to one Actions run (/actions/runs/<id>): platform
#      evidence links to a filtered run list, which stays current.
#   4. The README shows the flow graph, and docs/assets/flows.svg is exactly
#      what scripts/docs/render-flows.py renders (no hand-edited or stale SVG).
#
# Platform guard: bash 3.2+, grep, cmp, python3.
# Usage: bash scripts/docs/test-readme-hygiene.sh
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
README="$ROOT/README.md"
SVG="$ROOT/docs/assets/flows.svg"
GEN="$ROOT/scripts/docs/render-flows.py"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $*"; }
bad() { fail=$((fail + 1)); echo "not ok - $*"; }

# forbid <pattern> <sample> <ok-msg> <bad-msg>: README.md must not match the
# pattern. The sample is a line the pattern must match, so a broken pattern
# fails here instead of passing silently; a grep error (status 2) fails too.
forbid() {
  if ! printf '%s\n' "$2" | grep -q -E "$1"; then
    bad "pattern '$1' does not match its own sample"
    return
  fi
  grep -n -E "$1" "$README"
  case $? in
    0) bad "$4 (listed above)" ;;
    1) ok "$3" ;;
    *) bad "grep failed on $README" ;;
  esac
}

forbid 'HIMMEL-[0-9]+' 'see HIMMEL-123' \
  "README.md carries no internal ticket IDs" \
  "README.md carries internal ticket IDs"
forbid 'in v1\.0\.0|until v1\.0\.1' 'not supported in v1.0.0' \
  "README.md support claims carry no version numbers" \
  "README.md pins a support claim to a version"
forbid 'github\.com/[^ )]*/actions/runs/[0-9]+' 'https://github.com/o/r/actions/runs/42' \
  "README.md evidence links are filtered run lists, not single runs" \
  "README.md links a single Actions run as evidence"

if grep -q -F 'docs/assets/flows.svg' "$README"; then
  ok "README.md shows the flow graph"
else
  bad "README.md must embed docs/assets/flows.svg"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/readme-hygiene.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
if [ ! -f "$GEN" ]; then
  bad "generator $GEN is missing"
elif ! python3 "$GEN" --out "$TMP/flows.svg"; then
  bad "render-flows.py failed"
elif [ ! -f "$SVG" ]; then
  bad "docs/assets/flows.svg is missing (run: python3 scripts/docs/render-flows.py)"
elif cmp -s "$TMP/flows.svg" "$SVG"; then
  ok "docs/assets/flows.svg matches its generator"
else
  bad "docs/assets/flows.svg is stale (run: python3 scripts/docs/render-flows.py)"
fi

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
