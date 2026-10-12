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
# Platform guard (gitbash-only): bash 3.2+, grep, cmp, python3.
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

if grep -n -E 'HIMMEL-[0-9]+' "$README"; then
  bad "README.md carries internal ticket IDs (listed above)"
else
  ok "README.md carries no internal ticket IDs"
fi

if grep -n -E 'in v1\.0\.0|until v1\.0\.1' "$README"; then
  bad "README.md pins a support claim to a version (listed above)"
else
  ok "README.md support claims carry no version numbers"
fi

if grep -n -E 'github\.com/[^ )]*/actions/runs/[0-9]+' "$README"; then
  bad "README.md links a single Actions run as evidence (listed above)"
else
  ok "README.md evidence links are filtered run lists, not single runs"
fi

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
