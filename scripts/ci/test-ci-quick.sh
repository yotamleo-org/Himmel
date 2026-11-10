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
#       `if` for the others) and takes no runner when the run was cancelled, a
#       job timeout, no checkout (the claude-startup sentinel alone has exactly
#       one, at ci-quick's pin, with persist-credentials: false), no success()
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
#   Q7  two recorded jobs of one merge sha (S1 passed on ubuntu-24.04, failed on
#       ubuntu-26.04 once ubuntu-latest moved): every runs-on in ci.yml names the
#       green job's image, none floats
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

job_block_f() { awk -v job="$2" '$0 == "  " job ":" { j = 1; print; next } j && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { exit } j { print }' "$1"; }
job_block() { job_block_f "$CI_YML" "$1"; }

# A sentinel also skips on a label event that is not the go run.
CHEAP_ON="!(github.event_name == 'pull_request' && github.event.action == 'labeled') || (github.event.label.name == (vars.CI_GO_LABEL || 'ci:go') && vars.CI_GO_GATE == 'on')"

q1_check() {
  local f="$1" g b want_if want_step co_sha n co_ok
  co_sha="$(job_block_f "$f" ci-quick | sed -n 's|^      - uses: actions/checkout@\([0-9a-f]\{40\}\)\( #.*\)\{0,1\}$|\1|p' | head -n 1)"
  for g in $GROUPS_FOLDED; do
    b="$(job_block_f "$f" "$g")"
    if [ -z "$b" ]; then echo "FAIL - Q1 $g: no sentinel job"; continue; fi
    case " $NAMED " in
      *" $g "*) want_if="    if: \${{ !cancelled() && ($CHEAP_ON) }}"
                want_step="      - if: \${{ needs.ci-quick.outputs.$g != 'pass' }}
        run: exit 1" ;;
      *) want_if="    if: \${{ !cancelled() && ($CHEAP_ON) && needs.ci-quick.outputs.$g != 'pass' }}"
         want_step="      - run: exit 1" ;;
    esac
    n="$(printf '%s\n' "$b" | grep -c 'actions/checkout')"
    co_ok=0
    if [ "$n" -eq 0 ]; then co_ok=1
    elif [ "$g" = claude-startup ] && [ "$n" -eq 1 ] && [ -n "$co_sha" ] \
         && printf '%s\n' "$b" | grep -qE "^        uses: actions/checkout@$co_sha( #.*)?$" \
         && printf '%s\n' "$b" | awk '/^      - / { s = 0 } /actions\/checkout/ { s = 1 } s && /^          persist-credentials: false$/ { ok = 1 } END { exit !ok }'; then co_ok=1; fi
    if printf '%s\n' "$b" | grep -qxF "    needs: ci-quick" \
       && printf '%s\n' "$b" | grep -qxF "$want_if" \
       && printf '%s\n' "$b" | grep -xF -A1 -- "$(printf '%s\n' "$want_step" | head -n 1)" | grep -qxF -- "$(printf '%s\n' "$want_step" | tail -n 1)" \
       && printf '%s\n' "$b" | grep -qE '^    timeout-minutes: [0-9]+' \
       && [ "$co_ok" -eq 1 ] \
       && ! printf '%s\n' "$b" | grep -qE 'success\(\)'; then
      echo "ok - Q1 $g is a fail-unless-pass sentinel on ci-quick"
    else
      echo "FAIL - Q1 $g is not the sentinel shape"
    fi
  done
}

# Q1
q1_out="$(q1_check "$CI_YML")"
while IFS= read -r l; do
  case "$l" in "FAIL - "*) bad "${l#FAIL - }" ;; *) echo "$l" ;; esac
done <<< "$q1_out"

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

# Q7: `ubuntu-latest` moved from ubuntu-24.04 to ubuntu-26.04 between two ci-quick jobs of the SAME merge sha
# (run 41812666688), and the consult sandbox row S1 failed on 26.04. The fixtures are the recorded runner-image lines and
# suite rows of those two jobs; every runs-on in ci.yml must name the image the green job ran on, never a floating label.
green7="$FIX/runner-image-green-job-126516044346.txt"
red7="$FIX/runner-image-red-job-126525191459.txt"
fx_image() { sed -n 's/^[^ ]* Image: //p' "$1"; }
if [ -r "$green7" ] && [ -r "$red7" ]; then
  gi="$(fx_image "$green7")"; ri="$(fx_image "$red7")"
  if [ -n "$gi" ] && [ -n "$ri" ] && [ "$gi" != "$ri" ] && grep -q 'PASS  S1 ' "$green7" && grep -q 'FAIL  S1 ' "$red7"; then ok "Q7 recorded jobs: S1 passed on $gi and failed on $ri"
  else bad "Q7 the recorded fixtures are not a green/red pair on two images (green '$gi', red '$ri')"; fi
  runs_on_all="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$CI_YML" | sed -n 's/^[[:space:]]*runs-on:[[:space:]]*//p')"
  total="$(printf '%s\n' "$runs_on_all" | grep -c .)"
  floating="$(printf '%s\n' "$runs_on_all" | awk -v pin="$gi" -v red="$ri" 'NF && (index($0, pin) == 0 || index($0, red) || index($0, "-latest") || index($0, "matrix.os")) { n++ } END { print n + 0 }')"
  if [ "$total" -gt 0 ] && [ "$floating" -eq 0 ]; then ok "Q7 all $total runs-on lines in ci.yml name $gi; none floats with ubuntu-latest"
  else bad "Q7 $floating of $total runs-on lines in ci.yml float (ubuntu-latest, matrix.os) or name an image other than $gi"; fi
else
  bad "Q7 missing runner-image fixtures under $FIX"
fi

# Q8: the claude-startup rows. Every executable line of ci-quick that names
# scripts/testing is the one recorder form, and the recorder paths equal the set
# the recorder's --expected reads from the SKIP_LIST, so a mock-Claude suite
# cannot run in ci-quick without a recorded row, and a SKIP_LIST entry with no
# recorder step is a red. A SKIP_LIST list parsed wrongly can only make the two
# sets differ (a red) or leave a suite unrecorded, which item 19 then refuses; it
# never produces a green. The published artifact name and file name sit inside
# the globs ready-check.sh and ci-fail-record.sh read, and the raw one outside.
RC_F="$ROOT/scripts/handover/chief-kit/ready-check.sh"
FR_F="$ROOT/scripts/cr/ci-fail-record.sh"
RST_F="$ROOT/scripts/ci/run-shell-tests.sh"
RECORDER_FORM='^        run: bash scripts/ci/claude-startup-row.sh (scripts/testing/test-[A-Za-z0-9._-]+\.sh)$'
VERIFY_FORM='^bash scripts/ci/claude-startup-row\.sh --verify ([^ ]+) ([^ ]+)$'

step_of() {
  awk -v id="$1" '
    function flush() { if (hit) printf "%s", buf; buf = ""; hit = 0 }
    /^    steps:/ { s = 1; next }
    s && /^      - / { flush() }
    s { buf = buf $0 "\n" }
    s && ($0 == "      - id: " id || $0 == "        id: " id) { hit = 1 }
    END { flush() }'
}
skv() { sed -nE "s/^( {6}- | {8})$1: ?//p" | head -n 1; }
wkv() { sed -nE "s/^ {10}$1: ?//p" | head -n 1; }
dir_of() { case "$1" in */*) printf '%s' "${1%/*}" ;; *) printf '%s' "" ;; esac; }
idx_of() { printf '%s\n' "$2" | grep -nxF -- "$1" | head -n 1 | cut -d: -f1; }

q8_check() {
  local f="$1" rc_f="${2:-$RC_F}" fr_f="${3:-$FR_F}" rst_f="${4:-$RST_F}"
  local qb sb d l rec="" dups exp erc kind a c na nc u glob pglob="" nglob="" vs vrun raw_p="" out_p="" msrc
  local ms rs ds cs rr name raw_name ids last r i prev want got sids ord_bad
  qb="$(job_block_f "$f" ci-quick)"
  sb="$(job_block_f "$f" claude-startup)"
  d="$(mktemp -d "${TMPDIR:-/tmp}/q8.XXXXXX")" || { echo "FAIL - Q8a: no temp dir"; return 0; }

  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [[ "$l" =~ $RECORDER_FORM ]]; then rec="$rec${BASH_REMATCH[1]}
"; else echo "FAIL - Q8a: a ci-quick line names scripts/testing but is not the recorder form: $l"; fi
  done <<< "$(printf '%s\n' "$qb" | grep 'scripts/testing' | grep -vE '^[[:space:]]*#')"
  dups="$(printf '%s' "$rec" | LC_ALL=C sort | uniq -d)"
  [ -z "$dups" ] || echo "FAIL - Q8a: a suite has more than one recorder step: $(printf '%s' "$dups" | tr '\n' ' ')"
  mkdir "$d/exp" && cp "$ROOT/scripts/ci/claude-startup-row.sh" "$d/exp/claude-startup-row.sh" && cp "$rst_f" "$d/exp/run-shell-tests.sh"
  exp="$(bash "$d/exp/claude-startup-row.sh" --expected 2>/dev/null)"; erc=$?
  [ "$erc" -eq 0 ] || echo "FAIL - Q8a: --expected exited $erc over $rst_f"
  [ -n "$exp" ] || echo "FAIL - Q8a: the expected set is empty"
  [ -n "$rec" ] || echo "FAIL - Q8a: ci-quick has no recorder step"
  [ "$(printf '%s' "$rec" | LC_ALL=C sort)" = "$(printf '%s\n' "$exp" | LC_ALL=C sort)" ] || echo "FAIL - Q8a: the recorder steps ($(printf '%s' "$rec" | tr '\n' ' ')) are not the expected set ($(printf '%s' "$exp" | tr '\n' ' '))"

  for kind in p name; do
    a="$(grep -oE -- "-$kind '[^']*'" "$rc_f")"; c="$(grep -oE -- "-$kind '[^']*'" "$fr_f")"
    na="$(printf '%s\n' "$a" | grep -c .)"; nc="$(printf '%s\n' "$c" | grep -c .)"
    u="$(printf '%s\n%s\n' "$a" "$c" | grep . | LC_ALL=C sort -u | grep -c .)"
    if [ "$na" -ne 2 ] || [ "$nc" -ne 1 ] || [ "$u" -ne 1 ]; then echo "FAIL - Q8b: the -$kind literals: ready-check has $na (want 2), ci-fail-record $nc (want 1), $u distinct (want 1)"; fi
    glob="$(printf '%s\n' "$c" | sed "s/^-$kind '//; s/'\$//")"
    if [ "$kind" = p ]; then pglob="$glob"; else nglob="$glob"; fi
  done
  [ -n "$pglob" ] && [ -n "$nglob" ] || echo "FAIL - Q8b: no -p / -name glob read from ci-fail-record"
  vs="$(printf '%s\n' "$sb" | step_of claude-startup__verify)"
  vrun="$(printf '%s\n' "$vs" | skv run)"
  if [[ "$vrun" =~ $VERIFY_FORM ]]; then raw_p="${BASH_REMATCH[1]}"; out_p="${BASH_REMATCH[2]}"; else echo "FAIL - Q8b: cannot read the --verify arguments from '${vrun:-<no run>}'"; fi
  msrc="$(printf '%s\n' "$qb" | sed -n 's/^      CLAUDE_STARTUP_MANIFEST: //p' | head -n 1)"
  [ -n "$msrc" ] || echo "FAIL - Q8b: ci-quick env has no CLAUDE_STARTUP_MANIFEST"
  ms="$(printf '%s\n' "$sb" | step_of claude-startup__manifest)"
  rs="$(printf '%s\n' "$qb" | step_of claude-startup__raw)"
  ds="$(printf '%s\n' "$sb" | step_of claude-startup__download)"
  cs="$(printf '%s\n' "$qb" | step_of claude-startup__raw-clean)"
  rr="$(printf '%s\n' "$sb" | step_of claude-startup__raw-reset)"
  case "$(printf '%s\n' "$ms" | skv uses)" in actions/upload-artifact@*) ;; *) echo "FAIL - Q8b: the published step does not use actions/upload-artifact" ;; esac
  name="$(printf '%s\n' "$ms" | wkv name)"
  case "$name" in ''|*"\${{"*) echo "FAIL - Q8b: the published artifact name is not a literal: '$name'" ;; esac
  # shellcheck disable=SC2254
  case "$name" in $pglob) ;; *) echo "FAIL - Q8b: the published artifact name '$name' does not match the readers' -p glob '$pglob'" ;; esac
  [ "$(printf '%s\n' "$ms" | wkv path)" = "$(dir_of "$out_p")/" ] || echo "FAIL - Q8b: the published upload path is not the directory of <out> ($out_p)"
  # shellcheck disable=SC2254
  case "${out_p##*/}" in $nglob) ;; *) echo "FAIL - Q8b: the published file name '${out_p##*/}' does not match the readers' -name glob '$nglob'" ;; esac
  case "$(printf '%s\n' "$rs" | skv uses)" in actions/upload-artifact@*) ;; *) echo "FAIL - Q8b: the raw step does not use actions/upload-artifact" ;; esac
  raw_name="$(printf '%s\n' "$rs" | wkv name)"
  [ -n "$raw_name" ] || echo "FAIL - Q8b: the raw artifact has no name"
  # shellcheck disable=SC2254
  case "$raw_name" in $pglob) echo "FAIL - Q8b: the raw artifact name '$raw_name' matches the readers' -p glob" ;; esac
  [ "$(printf '%s\n' "$rs" | wkv path)" = "$(dir_of "$msrc")/" ] || echo "FAIL - Q8b: the raw upload path is not the directory of CLAUDE_STARTUP_MANIFEST ($msrc)"
  case "$(printf '%s\n' "$ds" | skv uses)" in actions/download-artifact@*) ;; *) echo "FAIL - Q8b: the download step does not use actions/download-artifact" ;; esac
  [ "$(printf '%s\n' "$ds" | wkv name)" = "$raw_name" ] || echo "FAIL - Q8b: the download name is not the raw artifact name '$raw_name'"
  [ "$(printf '%s\n' "$ds" | wkv path)" = "$(dir_of "$raw_p")/" ] || echo "FAIL - Q8b: the download path is not the directory of the raw file ($raw_p)"
  [ "$(printf '%s\n' "$cs" | skv run)" = "rm -rf $(dir_of "$msrc")" ] || echo "FAIL - Q8b: the raw clean step is not rm -rf of the directory of CLAUDE_STARTUP_MANIFEST"
  [ "$(printf '%s\n' "$rr" | skv run)" = "rm -rf $(dir_of "$raw_p")" ] || echo "FAIL - Q8b: the raw reset step is not rm -rf of the directory of the raw file"

  ids="$(printf '%s\n' "$qb" | awk '/^    steps:/ { s = 1; next } s && /^      - id: / { print $3; next } s && /^        id: / { print $2 }')"
  last=0; ord_bad=""
  for r in claude-startup claude-startup__mock-turn claude-startup__consult claude-startup__hook-smoke claude-startup__live-turn claude-startup__raw claude-startup__raw-clean; do
    i="$(idx_of "$r" "$ids")"
    if [ -z "$i" ] || [ "$i" -le "$last" ]; then ord_bad="$ord_bad $r"; else last="$i"; fi
  done
  [ -z "$ord_bad" ] || echo "FAIL - Q8d: ci-quick does not run the five recorder steps, then claude-startup__raw, then claude-startup__raw-clean; out of place:$ord_bad"
  sids="$(printf '%s\n' "$sb" | awk '/^    steps:/ { s = 1; next } s && /^      - / { if (n) print id; n = 1; id = "-"; if ($0 ~ /^      - id: /) id = $3 } s && /^        id: / { id = $2 } END { if (n) print id }' | paste -sd' ' -)"
  want="claude-startup__checkout claude-startup__raw-reset claude-startup__download claude-startup__verify claude-startup__manifest -"
  [ "$sids" = "$want" ] || echo "FAIL - Q8d: the claude-startup sentinel steps are '$sids', want exactly '$want'"
  prev=claude-startup__checkout
  for r in claude-startup__raw-reset claude-startup__download claude-startup__verify claude-startup__manifest; do
    want="\${{ !cancelled() && steps.$prev.outcome == 'success' }}"
    got="$(printf '%s\n' "$sb" | step_of "$r" | skv if)"
    [ "$got" = "$want" ] || echo "FAIL - Q8d: $r runs under '${got:-<none>}', want '$want'"
    prev="$r"
  done
  [[ "$vrun" =~ $VERIFY_FORM ]] || echo "FAIL - Q8d: the verify step run is '${vrun:-<none>}', not exactly the --verify call"
  if printf '%s\n' "$ds" | grep -qE '^ +(run-id|github-token):'; then echo "FAIL - Q8d: the download step takes a run-id or github-token"; fi
  if printf '%s\n' "$sb" | grep -q 'continue-on-error'; then echo "FAIL - Q8d: the claude-startup sentinel has a continue-on-error"; fi
  if printf '%s\n' "$sb" | grep -vE '^[[:space:]]*#' | grep -q 'scripts/testing'; then echo "FAIL - Q8d: the claude-startup sentinel names scripts/testing outside a comment"; fi
  [ "$(printf '%s\n' "$rs" | wkv if-no-files-found)" = error ] || echo "FAIL - Q8d: the raw upload does not set if-no-files-found: error"
  [ "$(printf '%s\n' "$ms" | wkv if-no-files-found)" = error ] || echo "FAIL - Q8d: the published upload does not set if-no-files-found: error"
  rm -rf "$d"
}

q8_out="$(q8_check "$CI_YML")"
if [ -z "$q8_out" ]; then ok "Q8 the claude-startup recorder, artifacts and sentinel hold (a, b, d)"
else
  while IFS= read -r l; do bad "${l#FAIL - }"; done <<< "$q8_out"
fi

MT="$(mktemp -d "${TMPDIR:-/tmp}/q8m.XXXXXX")" || exit 1
trap 'rm -rf "$MT"' EXIT
m="$MT/m.yml"
newm() { cp "$CI_YML" "$m"; }

mut() {
  # shellcheck disable=SC2015
  OLD="$3" NEW="$4" awk -v job="$2" '
    BEGIN { old = ENVIRON["OLD"]; new = ENVIRON["NEW"] }
    $0 == "  " job ":" { inj = 1 }
    inj && $0 != "  " job ":" && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { inj = 0 }
    inj && !done && (i = index($0, old)) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); done = 1 }
    { print }
    END { exit !done }
  ' "$1" > "$1.n" && mv "$1.n" "$1" || { rm -f "$1.n"; bad "Q8m setup: '$3' not found in $2"; return 1; }
}
mut_ins() {
  # shellcheck disable=SC2015
  ANCHOR="$3" TEXT="$4" awk -v job="$2" '
    BEGIN { a = ENVIRON["ANCHOR"]; t = ENVIRON["TEXT"] }
    $0 == "  " job ":" { inj = 1 }
    inj && $0 != "  " job ":" && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { inj = 0 }
    inj && !done && $0 == a { print t; done = 1 }
    { print }
    END { exit !done }
  ' "$1" > "$1.n" && mv "$1.n" "$1" || { rm -f "$1.n"; bad "Q8m setup: no line '$3' in $2"; return 1; }
}
step_lines() {
  awk -v job="$2" -v id="$3" '
    function emit(e) { if (hit) { print st, e; done = 1; exit } }
    $0 == "  " job ":" { inj = 1; next }
    inj && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { emit(NR - 1); inj = 0 }
    inj && /^      - / { emit(NR - 1); st = NR; hit = ($0 == "      - id: " id); next }
    inj && $0 == "        id: " id { hit = 1 }
    END { if (!done) emit(NR) }
  ' "$1"
}
mut_del_step() {
  local r; r="$(step_lines "$1" "$2" "$3")"
  [ -n "$r" ] || { bad "Q8m setup: no step $3 in $2"; return 1; }
  sed "${r% *},${r#* }d" "$1" > "$1.n" && mv "$1.n" "$1"
}
mut_mv_step() {
  local r s e b
  r="$(step_lines "$1" "$2" "$3")"; [ -n "$r" ] || { bad "Q8m setup: no step $3 in $2"; return 1; }
  s="${r% *}"; e="${r#* }"
  sed -n "${s},${e}p" "$1" > "$1.chunk"; sed "${s},${e}d" "$1" > "$1.rest"
  r="$(step_lines "$1.rest" "$2" "$4")"; [ -n "$r" ] || { bad "Q8m setup: no step $4 in $2"; return 1; }
  b="${r% *}"
  { head -n $((b - 1)) "$1.rest"; cat "$1.chunk"; tail -n +"$b" "$1.rest"; } > "$1"
}
q8m() {
  local id="$1" tag="$2" f="$3" out; shift 3
  out="$(q8_check "$f" "$@")"
  if printf '%s\n' "$out" | grep -q "^FAIL - $tag"; then ok "Q8m $id -> $tag"; else bad "Q8m $id: no $tag line; got: ${out:-<none>}"; fi
}
q1m() {
  local out; out="$(q1_check "$2")"
  if printf '%s\n' "$out" | grep -q '^FAIL - Q1'; then ok "Q1m $1 -> Q1 FAIL"; else bad "Q1m $1: no Q1 FAIL line"; fi
}

RPFX='run: bash scripts/ci/claude-startup-row.sh'
PUB='shell-unit-manifest-ubuntu-latest-shard-claude-startup'
VERIFY_RUN="$RPFX --verify claude-startup-raw/rows.txt claude-startup-manifest/manifest-shard-claude-startup.txt"
SENT_EXIT="      - if: \${{ needs.ci-quick.outputs.claude-startup != 'pass' }}"
CO_SHA="$(job_block_f "$CI_YML" ci-quick | sed -n 's|^      - uses: actions/checkout@\([0-9a-f]\{40\}\)\( #.*\)\{0,1\}$|\1|p' | head -n 1)"

newm; mut "$m" ci-quick "$RPFX scripts/testing/test-mock-hook-smoke.sh" "run: bash scripts/testing/test-mock-hook-smoke.sh" && q8m a1 Q8a "$m"
newm; mut_ins "$m" ci-quick "      - id: doc-invariants__dev" $'      - run: |\n          bash scripts/testing/test-x.sh' && q8m a2 Q8a "$m"
newm; mut "$m" ci-quick "$RPFX scripts/testing/test-claude-mock-turn.sh" "$RPFX scripts/testing/test-claude-mock-turn.sh"$'\n'"        $RPFX scripts/testing/test-claude-mock-turn.sh" && q8m "a3 (a duplicated line)" Q8a "$m"
newm; mut_del_step "$m" ci-quick claude-startup__consult && q8m "a3 (a deleted step)" Q8a "$m"
awk '{ print } /^scripts\/testing\/test-mock-hook-live-turn\.sh/ { print "scripts/testing/test-sixth.sh  # extra" }' "$RST_F" > "$MT/rst-six.sh"
q8m a4 Q8a "$CI_YML" "$RC_F" "$FR_F" "$MT/rst-six.sh"
sed -E 's|^( +)run: bash scripts/ci/claude-startup-row.sh scripts/testing/.*$|\1run: true|' "$CI_YML" > "$m"
awk '$0 !~ /^scripts\/testing\//' "$RST_F" > "$MT/rst-none.sh"
q8m a5 Q8a "$m" "$RC_F" "$FR_F" "$MT/rst-none.sh"

newm; mut "$m" claude-startup "name: $PUB" "name: \${{ github.head_ref }}" && q8m b1 Q8b "$m"
newm; mut "$m" claude-startup "name: $PUB" "name: claude-startup-manifest" && q8m b2 Q8b "$m"
newm; mut "$m" ci-quick "name: claude-startup-raw" "name: shell-unit-manifest-ubuntu-latest-shard-raw" && q8m b3 Q8b "$m"
newm; mut "$m" claude-startup "path: claude-startup-raw/" "path: other/" && q8m b4 Q8b "$m"
newm; mut "$m" claude-startup "actions/upload-artifact@" "actions/cache@" && q8m b5 Q8b "$m"
newm; mut "$m" claude-startup "path: claude-startup-manifest/" "path: other/" && q8m b6 Q8b "$m"
newm; mut "$m" claude-startup "claude-startup-manifest/manifest-shard-claude-startup.txt" "claude-startup-manifest/claude-startup.txt" && q8m b7 Q8b "$m"
newm; mut "$m" ci-quick "path: claude-startup-raw/" "path: other/" && q8m b8 Q8b "$m"
newm; mut "$m" claude-startup "name: claude-startup-raw" "name: x" && q8m b9 Q8b "$m"
newm; mut "$m" ci-quick "run: rm -rf claude-startup-raw" "run: rm -rf other" && q8m b10 Q8b "$m"
{ cat "$RC_F"; printf '%s\n' "# -p 'shell-unit-manifest-ubuntu-latest-shard*'"; } > "$MT/rc-p.sh"
q8m b11 Q8b "$CI_YML" "$MT/rc-p.sh"
newm; mut "$m" ci-quick "actions/upload-artifact@" "actions/cache@" && q8m b12 Q8b "$m"
newm; mut "$m" claude-startup "actions/download-artifact@" "actions/cache@" && q8m b13 Q8b "$m"
sed "s|-p 'shell-unit-manifest-ubuntu-latest-shard\*'|-p 'other*'|" "$FR_F" > "$MT/fr-p.sh"
q8m b14 Q8b "$CI_YML" "$RC_F" "$MT/fr-p.sh"
{ cat "$RC_F"; printf '%s\n' "# -name 'manifest-shard*.txt'"; } > "$MT/rc-n.sh"
q8m b15 Q8b "$CI_YML" "$MT/rc-n.sh"
newm; mut "$m" claude-startup "run: rm -rf claude-startup-raw" "run: rm -rf other" && q8m b16 Q8b "$m"

newm; mut_mv_step "$m" ci-quick claude-startup__raw claude-startup__live-turn && q8m d1 Q8d "$m"
newm; mut_mv_step "$m" claude-startup claude-startup__manifest claude-startup__verify && q8m d2 Q8d "$m"
newm; mut_del_step "$m" claude-startup claude-startup__verify && q8m d3 Q8d "$m"
newm; mut_ins "$m" claude-startup "$SENT_EXIT" "      - run: bash scripts/testing/test-x.sh" && q8m d4 Q8d "$m"
newm; mut_ins "$m" claude-startup "$SENT_EXIT" "      - run: bash scripts/hooks/check-guardrail-matrices.sh" && q8m d5 Q8d "$m"
newm; mut "$m" ci-quick "if-no-files-found: error" "if-no-files-found: warn" && q8m "d6 (raw upload)" Q8d "$m"
newm; mut "$m" claude-startup "if-no-files-found: error" "if-no-files-found: warn" && q8m "d6 (published upload)" Q8d "$m"
newm; mut "$m" claude-startup "if: \${{ !cancelled() && steps.claude-startup__verify.outcome == 'success' }}" "if: \${{ !cancelled() }}" && q8m d7 Q8d "$m"
newm; mut "$m" claude-startup "$VERIFY_RUN" "run: cp claude-startup-raw/rows.txt claude-startup-manifest/manifest-shard-claude-startup.txt" && q8m d8 Q8d "$m"
newm; mut "$m" claude-startup "run: exit 1" "run: exit 1; bash scripts/testing/test-x.sh" && q8m d9 Q8d "$m"
newm; mut "$m" claude-startup "$VERIFY_RUN" "$VERIFY_RUN"$'\n'"        continue-on-error: true" && q8m d10 Q8d "$m"
newm; mut "$m" claude-startup "name: claude-startup-raw" "name: claude-startup-raw"$'\n'"          run-id: 1" && q8m d11 Q8d "$m"
newm; mut_del_step "$m" claude-startup claude-startup__raw-reset && mut "$m" claude-startup "steps.claude-startup__raw-reset.outcome" "steps.claude-startup__checkout.outcome" && q8m d12 Q8d "$m"
newm; mut "$m" claude-startup "name: claude-startup-raw" "name: claude-startup-raw"$'\n'"          github-token: x" && q8m d13 Q8d "$m"
newm
if mut_ins "$m" ci-quick "      - id: claude-startup__live-turn" "      # scripts/testing/mock-anthropic"; then
  out="$(q8_check "$m")"
  if [ -z "$out" ]; then ok "Q8m control: a whole-line comment naming scripts/testing raises no Q8 line"; else bad "Q8m control: a comment line raised: $out"; fi
fi

newm; mut_ins "$m" commit-lint "      - if: \${{ needs.ci-quick.outputs.commit-lint != 'pass' }}" "      - uses: actions/checkout@$CO_SHA # v7.0.1" && q1m 1 "$m"
newm; mut_ins "$m" claude-startup "$SENT_EXIT" "      - uses: actions/checkout@$CO_SHA # v7.0.1" && q1m 2 "$m"
newm; mut "$m" claude-startup "persist-credentials: false" "" && q1m 3 "$m"
newm; mut "$m" claude-startup "actions/checkout@$CO_SHA" "actions/checkout@0123456789012345678901234567890123456789" && q1m 4 "$m"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
