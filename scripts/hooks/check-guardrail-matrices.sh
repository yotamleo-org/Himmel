#!/usr/bin/env bash
# Run the guardrail matrix invariant suites.
#
# The suite existed as a standalone script that only ran when somebody
# remembered to type it. The egress matrix decides whether a corpus may leave
# the machine — an unenforced guard is exactly the one that regresses quietly,
# so it is wired into pre-commit AND the public-mirror CI.
#
# Pre-commit matters more than CI here: Actions is OFF on the private repo by
# design, so a private PR going green is not evidence the suite ran.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$repo_root"

if ! command -v node >/dev/null 2>&1; then
  echo "check-guardrail-matrices: node not found — cannot verify guardrail invariants" >&2
  exit 1
fi

suite=scripts/guardrails/test-egress-matrix.mjs
if [ ! -f "$suite" ]; then
  echo "check-guardrail-matrices: missing $suite" >&2
  exit 1
fi
if ! out=$(node "$suite" 2>&1); then
  echo "check-guardrail-matrices: FAILED $suite" >&2
  echo "$out" >&2
  exit 1
fi
echo "  ok  $suite"
