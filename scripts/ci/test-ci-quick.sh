#!/usr/bin/env bash
# scripts/ci/test-ci-quick.sh -- the ci-quick fold in .github/workflows/ci.yml.
# The short check jobs run as step groups of ONE job, ci-quick; each old job name
# stays a required-context sentinel that is skipped (= success) when its group
# passed and runs `exit 1` otherwise. Pure text + a model of the expressions, no
# network, no PyYAML.
#
#   Q1  every folded name is a sentinel: needs ci-quick, fails unless its group
#       output is 'pass', no checkout, a job timeout
#   Q2  every ci-quick step but the shared ones belongs to a group (id
#       <group> or <group>__<x>) and runs under !cancelled()
#   Q3  each group output is the canonical expression: the shared steps and the
#       closing `finished` step succeeded, every group step succeeded or was skipped
#   Q4  the model over that expression: a cancelled or timed-out ci-quick, a
#       skipped ci-quick, a failed checkout and a failed group step all fail the
#       sentinel; a step failure fails only its own group; a plan-gated skip passes
#   Q5  the doc-invariants group (its orphan checkout is destructive) runs last
#
# Usage: bash scripts/ci/test-ci-quick.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

GROUPS_FOLDED="secret-scan bwk-awk-mktemp-gate unchecked-mktemp-range commit-lint jira-cli-smoke claude-startup guardrail-matrices doc-invariants"
SHARED="checkout setup-node"

job_block() { awk -v job="$1" '$0 == "  " job ":" { j = 1; print; next } j && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { exit } j { print }' "$CI_YML"; }

# Q1
for g in $GROUPS_FOLDED; do
  b="$(job_block "$g")"
  if [ -z "$b" ]; then bad "Q1 $g: no sentinel job"; continue; fi
  want_if="    if: \${{ always() && needs.ci-quick.outputs.$g != 'pass' }}"
  if printf '%s\n' "$b" | grep -qxF "    needs: ci-quick" \
     && printf '%s\n' "$b" | grep -qxF "$want_if" \
     && printf '%s\n' "$b" | grep -qE '^      - run: exit 1$' \
     && printf '%s\n' "$b" | grep -qE '^    timeout-minutes: [0-9]+' \
     && ! printf '%s\n' "$b" | grep -qE 'actions/checkout|success\(\)'; then
    ok "Q1 $g is a fail-unless-pass sentinel on ci-quick"
  else
    bad "Q1 $g is not the sentinel shape"
  fi
done

quick="$(job_block ci-quick)"
if [ -z "$quick" ]; then
  bad "no ci-quick job"
  echo "$fails failed" >&2; exit 1
fi

# "<id>\t<if>" per step of ci-quick, in order.
steps="$(printf '%s\n' "$quick" | awk '
  function flush() { if (inst) print id "\t" cond; id = ""; cond = ""; inst = 0 }
  /^    steps:/ { s = 1; next }
  s && /^      - / { flush(); inst = 1 }
  s && inst && /^        id: / { id = $2 }
  s && inst && /^        if: / { cond = $0; sub(/^        if: /, "", cond) }
  s && inst && /^      - id: / { id = $3 }
  END { flush() }
')"

# Q2
order=""
while IFS=$'\t' read -r id cond; do
  case " $SHARED finished " in *" $id "*) order="$order $id"; continue ;; esac
  g="${id%%__*}"
  case " $GROUPS_FOLDED " in
    *" $g "*) ;;
    *) bad "Q2 ci-quick step '${id:-<no id>}' belongs to no group"; continue ;;
  esac
  case "$cond" in
    "\${{ !cancelled()"*) ;;
    *) bad "Q2 step $id runs without !cancelled(): '${cond:-<none>}'" ;;
  esac
  order="$order $id"
done <<< "$steps"
ok "Q2 checked the ci-quick steps:$order"
last_id="$(printf '%s\n' "$steps" | tail -n 1 | cut -f1)"
last_if="$(printf '%s\n' "$steps" | tail -n 1 | cut -f2)"
if [ "$last_id" = finished ] && [ "$last_if" = "\${{ !cancelled() }}" ]; then ok "Q2 ci-quick ends with the finished step"
else bad "Q2 the last ci-quick step is '$last_id' if '$last_if' (expected finished, \${{ !cancelled() }})"; fi
for s in $SHARED; do
  if printf '%s\n' "$steps" | cut -f1 | grep -qx "$s"; then ok "Q2 shared step $s present"; else bad "Q2 no shared step $s"; fi
done

canon() { # canonical output expression for group $1
  local e="\${{ steps.finished.outcome == 'success'" s
  for s in $SHARED; do e="$e && steps.$s.outcome == 'success'"; done
  for s in $(printf '%s\n' "$steps" | cut -f1 | awk -v g="$1" '$0 == g || index($0, g "__") == 1'); do
    e="$e && contains(fromJSON('[\"success\",\"skipped\"]'), steps.$s.outcome)"
  done
  printf "%s && 'pass' || 'fail' }}" "$e"
}

# Q3
for g in $GROUPS_FOLDED; do
  n="$(printf '%s\n' "$steps" | cut -f1 | awk -v g="$g" '$0 == g || index($0, g "__") == 1' | wc -l)"
  if [ "$n" -eq 0 ]; then bad "Q3 group $g has no step"; continue; fi
  if printf '%s\n' "$quick" | grep -qxF "      $g: $(canon "$g")"; then ok "Q3 output $g is canonical over $n step(s)"
  else bad "Q3 output $g is not '$(canon "$g")'"; fi
done

# Q4: the model. outcome_of <id> reads $OUTCOMES ("id=outcome ..."); unlisted = success.
outcome_of() { local a; for a in $OUTCOMES; do [ "${a%%=*}" = "$1" ] && { echo "${a#*=}"; return; }; done; echo success; }
group_output() { # what ci-quick's output for group $1 evaluates to under $OUTCOMES; '' when $JOB_RAN=0
  [ "${JOB_RAN:-1}" = 1 ] || { echo ""; return; }
  local s o
  for s in finished $SHARED; do [ "$(outcome_of "$s")" = success ] || { echo fail; return; }; done
  for s in $(printf '%s\n' "$steps" | cut -f1 | awk -v g="$1" '$0 == g || index($0, g "__") == 1'); do
    o="$(outcome_of "$s")"
    case "$o" in success|skipped) ;; *) echo fail; return ;; esac
  done
  echo pass
}
sentinel_fails() { [ "$(group_output "$1")" != pass ]; } # the sentinel's `if`; its body is exit 1
expect() { # expect <label> <want: pass|fail> <group>
  if sentinel_fails "$3"; then got=fail; else got=pass; fi
  if [ "$got" = "$2" ]; then ok "Q4 $1"; else bad "Q4 $1: sentinel $3 would $got"; fi
}
OUTCOMES="" JOB_RAN=1;                expect "all green: secret-scan sentinel skipped" pass secret-scan
OUTCOMES="" JOB_RAN=0;                expect "ci-quick cancelled, timed out or skipped (no outputs) fails the sentinel" fail commit-lint
OUTCOMES="finished=skipped" JOB_RAN=1; expect "a timeout that skips the finished step fails every sentinel" fail claude-startup
OUTCOMES="checkout=failure" JOB_RAN=1; expect "a failed checkout fails the sentinel before its group ran" fail guardrail-matrices
OUTCOMES="jira-cli-smoke=skipped jira-cli-smoke__npm=skipped" JOB_RAN=1; expect "a plan-gated skip passes" pass jira-cli-smoke
OUTCOMES="secret-scan=failure" JOB_RAN=1; expect "a failed secret-scan step fails its sentinel" fail secret-scan
for g in $GROUPS_FOLDED; do
  [ "$g" = secret-scan ] && continue
  OUTCOMES="secret-scan=failure" JOB_RAN=1; expect "a failed secret-scan step leaves $g green" pass "$g"
done
OUTCOMES="secret-scan=cancelled" JOB_RAN=1; expect "a cancelled group step fails its sentinel" fail secret-scan

# Q5
first_doc="$(printf '%s\n' "$steps" | cut -f1 | grep -n -m1 -E '^doc-invariants(__|$)' | cut -d: -f1)"
last_other="$(printf '%s\n' "$steps" | cut -f1 | grep -n -vE '^(doc-invariants(__.*)?|finished)$' | tail -n 1 | cut -d: -f1)"
if [ -n "$first_doc" ] && [ -n "$last_other" ] && [ "$first_doc" -gt "$last_other" ]; then ok "Q5 the doc-invariants group runs last"
else bad "Q5 a step runs after the doc-invariants group starts (first doc step ${first_doc:-?}, last other ${last_other:-?})"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
