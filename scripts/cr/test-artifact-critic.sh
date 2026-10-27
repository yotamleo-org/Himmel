#!/usr/bin/env bash
# scripts/cr/test-artifact-critic.sh — TDD for artifact-critic.sh.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HERE="$(cd "$(dirname "$0")" && pwd)"; AC="$HERE/artifact-critic.sh"
tmp="$(mktemp -d -t artifact-critic-test.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT
fails=0

# artifact-critic.sh runs the REAL critic-first-pass.sh, which
# spawns the REAL scripts/hermes/invoke.sh -- HERMES_PY stubs the model, not
# the wrapper, so its flow-run rows went to the PRODUCTION ledger. Redirect
# into this test's own scratch dir.
export HIMMEL_FLOW_RUNS_LEDGER="$tmp/flow-runs.jsonl"
# the real critic-first-pass.sh now writes a `score` row and a
# raw response beside the CR ledger on every completed run; without an
# explicit CR_LEDGER that is the PRODUCTION ledger (git common dir).
export CR_LEDGER="$tmp/cr-ledger.jsonl"
check(){ if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: got [$2] want [$3]"; fails=$((fails+1)); fi; }
check_contains(){ if grepq "$2" -F -- "$3"; then echo "ok - $1"; else echo "FAIL - $1: missing [$3]"; fails=$((fails+1)); fi; }

ART="$tmp/spec.md"
cat > "$ART" <<'MD'
# Dashboard rollout plan

## Context

The dashboard currently labels the surface inconsistently.
Operators need one stable term across the related views.
This plan keeps the change limited to visible copy.

## Proposed patch

The fenced patch below documents the intended implementation.

```diff
diff --git a/quoted b/quoted
--- a/quoted
+++ b/quoted
@@ -1 +1 @@
-old
+new
```

## Validation

Run the focused surface-label tests after applying the patch.
Confirm that the legacy label no longer appears in the dashboard.
MD
CH="$tmp/charter.md"; printf 'charter role text\n' > "$CH"

# Stub CFP: record argv + stdin-first-line so we can assert the delegation.
STUB="$tmp/cfp-stub.sh"
cat > "$STUB" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$tmp/argv"
head -1 > "$tmp/stdin1"
echo "# s First-Pass Review"
EOS
chmod +x "$STUB"

# --help remains available without the required runtime arguments.
bash "$AC" --help >/dev/null 2>&1
check "--help exits 0" "$?" "0"

# (f) wrapper delegates with --artifact-mode --charter-file and pipes the prose
# artifact (a fenced diff quotation is ordinary artifact content).
out="$(CRITIC_FIRST_PASS="$STUB" bash "$AC" --artifact "$ART" --charter "$CH" --model x/y --slug s 2>/dev/null)"
argv="$(cat "$tmp/argv")"
check_contains "f: returns CFP output" "$out" "# s First-Pass Review"
check_contains "f: delegates --artifact-mode" "$argv" "--artifact-mode"
check_contains "f: delegates --charter-file" "$argv" "--charter-file $CH"
check_contains "f: passes model" "$argv" "--model x/y"
check "f: artifact piped on stdin (first line)" "$(cat "$tmp/stdin1")" "# Dashboard rollout plan"

# missing artifact file -> exit 2
CRITIC_FIRST_PASS="$STUB" bash "$AC" --artifact "$tmp/nope.md" --charter "$CH" --model x/y >/dev/null 2>&1
check "missing artifact -> exit 2" "$?" "2"

# the plan-artifact path shares critic-first-pass's citation guard.
# When every plan finding cites a missing heading, preserve the content on stdout
# instead of returning the same 0/0/0 shape as a genuinely clean plan.
PLAN="$tmp/plan.md"; printf '# Plan\n## Implementation\nsteps\n' > "$PLAN"
PLAN_STUB_PY="$tmp/plan-all-dropped.py"
cat > "$PLAN_STUB_PY" <<'PY'
print("## Critical Issues (0 found)")
print("## Important Issues (1 found)")
print("- [CRITIC-1]: migration ordering can lose state [plan.md#Rollback]")
print("## Suggestions (0 found)")
PY
PLAN_PY="$tmp/plan-py.sh"
cat > "$PLAN_PY" <<PY
#!/usr/bin/env bash
exec python3 "$PLAN_STUB_PY"
PY
chmod +x "$PLAN_PY"
plan_rc=0
plan_out="$(CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" HERMES_PY="$PLAN_PY" bash "$AC" --artifact "$PLAN" --charter "$CH" --model x/y --slug plancritic 2>/dev/null)" || plan_rc=$?
# all-dropped now exits the DISTINCT code 4 (not
# clean), while the evidence stays on stdout for guard-aware callers.
check "HIMMEL-1871: all-dropped plan review exits 4 with evidence on stdout" "$plan_rc" "4"
check_contains "HIMMEL-1871: plan review surfaces Dropped Citations" "$plan_out" "## Dropped Citations (1 dropped)"
check_contains "HIMMEL-1871: plan review preserves rejected finding" "$plan_out" "migration ordering can lose state"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
