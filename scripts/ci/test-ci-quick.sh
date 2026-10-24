#!/usr/bin/env bash
# scripts/ci/test-ci-quick.sh -- the ci-quick fold in .github/workflows/ci.yml.
# The short check jobs run as step groups of ONE job, ci-quick; each old job name
# stays a required-context sentinel: it fails when its group did not pass. A
# sentinel that carries a required name runs (a skipped job would report its raw
# name expression, never the required context) and fails in a step; the others
# are skipped (= success) when their group passed. Pure text + a model of the
# expressions, no network, no PyYAML.
#
#   Q1  every folded name is a sentinel: needs ci-quick, fails unless its group
#       output is 'pass' (in a step for a required-named sentinel, in the job
#       `if` for the others) and takes no runner when the run was cancelled, no
#       checkout, a job timeout
#   Q2  every ci-quick step but the shared ones belongs to a group (id
#       <group> or <group>__<x>) and runs under !cancelled()
#   Q3  each group output is the canonical expression: checkout and the closing
#       `finished` step succeeded, setup-node succeeded or was skipped (the CI
#       image has node), every group step succeeded or was skipped
#   Q4  the model over that expression: a timed-out ci-quick (whether a timeout
#       reports failure or cancelled), a skipped ci-quick, a failed checkout and
#       a failed group step all fail the sentinel; a cancelled run skips it; a
#       step failure fails only its own group; a plan-gated skip passes
#   Q5  the doc-invariants group (its orphan checkout is destructive) runs last
#   Q6  two recorded hosted runs (test-ci-quick-fixtures/): in the cancelled
#       run the sentinels took runners and went red; under the sentinel gate
#       they take none. On the green run only the required-named sentinels now
#       take a runner (and pass)
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
NAMED="secret-scan unchecked-mktemp-range commit-lint claude-startup guardrail-matrices doc-invariants"
SHARED="checkout setup-node"
STRICT="checkout"

job_block() { awk -v job="$1" '$0 == "  " job ":" { j = 1; print; next } j && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { exit } j { print }' "$CI_YML"; }

# A sentinel also skips on a label event that is not the go run.
CHEAP_ON="!(github.event_name == 'pull_request' && github.event.action == 'labeled') || (github.event.label.name == (vars.CI_GO_LABEL || 'ci:go') && vars.CI_GO_GATE == 'on')"

# Q1
for g in $GROUPS_FOLDED; do
  b="$(job_block "$g")"
  if [ -z "$b" ]; then bad "Q1 $g: no sentinel job"; continue; fi
  case " $NAMED " in
    *" $g "*) want_if="    if: \${{ !cancelled() && ($CHEAP_ON) }}"
              want_step="      - if: \${{ needs.ci-quick.outputs.$g != 'pass' }}
        run: exit 1" ;;
    *) want_if="    if: \${{ !cancelled() && ($CHEAP_ON) && needs.ci-quick.outputs.$g != 'pass' }}"
       want_step="      - run: exit 1" ;;
  esac
  if printf '%s\n' "$b" | grep -qxF "    needs: ci-quick" \
     && printf '%s\n' "$b" | grep -qxF "$want_if" \
     && printf '%s\n' "$b" | grep -qxF -- "$(printf '%s\n' "$want_step" | head -n 1)" \
     && printf '%s\n' "$b" | grep -qxF -- "$(printf '%s\n' "$want_step" | tail -n 1)" \
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
  for s in $SHARED; do
    case " $STRICT " in
      *" $s "*) e="$e && steps.$s.outcome == 'success'" ;;
      *) e="$e && contains(fromJSON('[\"success\",\"skipped\"]'), steps.$s.outcome)" ;;
    esac
  done
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
  for s in finished $STRICT; do [ "$(outcome_of "$s")" = success ] || { echo fail; return; }; done
  case "$(outcome_of setup-node)" in success|skipped) ;; *) echo fail; return ;; esac
  for s in $(printf '%s\n' "$steps" | cut -f1 | awk -v g="$1" '$0 == g || index($0, g "__") == 1'); do
    o="$(outcome_of "$s")"
    case "$o" in success|skipped) ;; *) echo fail; return ;; esac
  done
  echo pass
}
# A sentinel takes a runner when !cancelled() ($RUN_CANCELLED=1 when the run was cancelled); a required-named one always does, the others only when their group output is not 'pass'. It fails when the group output is not 'pass'.
sentinel_fails() { [ "${RUN_CANCELLED:-0}" != 1 ] && [ "$(group_output "$1")" != pass ]; }
sentinel_runs() { case " $NAMED " in *" $1 "*) [ "${RUN_CANCELLED:-0}" != 1 ] ;; *) sentinel_fails "$1" ;; esac; }
expect() { # expect <label> <want: pass|fail> <group>
  if sentinel_fails "$3"; then got=fail; else got=pass; fi
  if [ "$got" = "$2" ]; then ok "Q4 $1"; else bad "Q4 $1: sentinel $3 would $got"; fi
}
OUTCOMES="" JOB_RAN=1;                expect "all green: secret-scan sentinel skipped" pass secret-scan
OUTCOMES="" JOB_RAN=0;                  expect "a ci-quick that timed out or was skipped (no outputs, run not cancelled) fails the sentinel" fail commit-lint
OUTCOMES="" JOB_RAN=0 RUN_CANCELLED=1;  expect "a cancelled run takes no sentinel runner and shows no false red" pass commit-lint
RUN_CANCELLED=0
OUTCOMES="finished=skipped" JOB_RAN=1; expect "a timeout that skips the finished step fails every sentinel" fail claude-startup
OUTCOMES="checkout=failure" JOB_RAN=1; expect "a failed checkout fails the sentinel before its group ran" fail guardrail-matrices
OUTCOMES="setup-node=skipped" JOB_RAN=1; expect "setup-node skipped in the CI image passes" pass guardrail-matrices
OUTCOMES="setup-node=failure" JOB_RAN=1; expect "a failed setup-node fails the sentinel" fail guardrail-matrices
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

# Q6: replay recorded hosted runs. A row is <job> <conclusion> <started> <completed>, tab separated.
FIX="$ROOT/scripts/ci/test-ci-quick-fixtures"
cancelled_fx="$FIX/cancelled-run-39388709732.tsv"
green_fx="$FIX/green-run-39385449571.tsv"
fx_result() { awk -F'\t' '$1 == "ci-quick" { print $2 }' "$1"; }
fx_ran() { awk -F'\t' '$1 != "ci-quick" && $2 != "skipped" && $2 != "cancelled" { n++ } END { print n + 0 }' "$1"; }
would_run() { # would_run <result>: how many sentinels take a runner; a cancelled ci-quick in a recorded run is a cancelled run
  local g n=0 c=0
  [ "$1" = cancelled ] && c=1
  for g in $GROUPS_FOLDED; do RUN_CANCELLED="$c" sentinel_runs "$g" && n=$((n + 1)); done
  echo "$n"
}
if [ -r "$cancelled_fx" ] && [ -r "$green_fx" ]; then
  res="$(fx_result "$cancelled_fx")"; ran="$(fx_ran "$cancelled_fx")"
  if [ "$res" = cancelled ] && [ "$ran" -eq 8 ]; then ok "Q6 recorded cancelled run: ci-quick cancelled, $ran sentinels took a runner and went red"
  else bad "Q6 the cancelled fixture is not the recorded shape (ci-quick '$res', $ran sentinels ran)"; fi
  OUTCOMES="" JOB_RAN=0
  spent="$(would_run "$res")"
  if [ "$spent" -eq 0 ]; then ok "Q6 under the sentinel gate that cancelled run spends no sentinel runner"
  else bad "Q6 $spent sentinels would still take a runner on the recorded cancelled run"; fi
  res="$(fx_result "$green_fx")"; ran="$(fx_ran "$green_fx")"
  OUTCOMES="" JOB_RAN=1
  spent="$(would_run "$res")"
  want_spent=0; for g in $NAMED; do want_spent=$((want_spent + 1)); done
  if [ "$res" = success ] && [ "$ran" -eq 0 ] && [ "$spent" -eq "$want_spent" ]; then ok "Q6 recorded green run: every sentinel was skipped; now only the $spent required-named ones take a runner"
  else bad "Q6 green fixture: ci-quick '$res', $ran sentinels ran, $spent would run (want $want_spent)"; fi
else
  bad "Q6 missing fixtures under $FIX"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
