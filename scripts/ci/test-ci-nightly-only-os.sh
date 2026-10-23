#!/usr/bin/env bash
# scripts/ci/test-ci-nightly-only-os.sh -- regression suite:
# ci.yml runs ubuntu only (Windows support is dropped, macOS has its
# own cadence workflow, macos-cadence.yml). ci.yml has no
# `force_all_os` dispatch input, so no manually dispatched run can occupy the
# paid Windows/macOS runner slots (2026-09-29: per-PR dispatches held 14 of the
# account's 20 concurrent job slots and queued ~287 jobs behind them).
#
# Pure text + evaluated-expression assertions over the workflow file (comments
# stripped, so a comment cannot satisfy a policy check). No network, no PyYAML.
#
# Usage: bash scripts/ci/test-ci-nightly-only-os.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# Whole file with full-line and trailing ` #` comments removed.
stripped="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$CI_YML")"

# 1. The input and every reference to it are gone.
if grep -q 'force_all_os' <<< "$stripped"; then
  bad "ci.yml still keys logic on force_all_os"
else
  ok "no force_all_os in the executable part of ci.yml"
fi
if grep -q 'force_all_os' "$CI_YML"; then
  bad "ci.yml still MENTIONS force_all_os (a comment telling someone to dispatch it)"
else
  ok "no force_all_os mention anywhere in ci.yml"
fi

# 2. workflow_dispatch stays a trigger but carries no inputs.
dispatch="$(awk '/^  workflow_dispatch:/ {f=1; next} f && /^  [a-z_]+:/ {f=0} f' <<< "$stripped")"
if grep -q 'inputs:' <<< "$dispatch"; then
  bad "workflow_dispatch still declares inputs"
else
  ok "workflow_dispatch declares no inputs"
fi
if grep -q '^  workflow_dispatch:' <<< "$stripped"; then
  ok "workflow_dispatch trigger is still present (plain dispatch stays ubuntu-only)"
else
  bad "workflow_dispatch trigger was removed (out of scope)"
fi
if grep -q 'inputs\.' <<< "$stripped"; then
  bad "ci.yml still reads an inputs.* context"
else
  ok "ci.yml reads no inputs.* context"
fi

# 3. Windows is gone from ci.yml -- no leg, no repo-variable
# switch, no nightly-issue step -- and the two matrix jobs run ubuntu only.
job_block() { awk -v j="$1" '$0 == "  " j ":" {f=1; next} f && /^  [a-zA-Z_-]+:/ {f=0} f' <<< "$stripped"; }

if grep -qiE 'windows|WINDOWS_NIGHTLY' <<< "$stripped"; then
  bad "ci.yml still runs or reads Windows: $(grep -iE -m1 'windows|WINDOWS_NIGHTLY' <<< "$stripped")"
else
  ok "no Windows leg, WINDOWS_NIGHTLY switch or windows-nightly-issue step in the executable part of ci.yml"
fi
for job in shell-unit-shard bun-suites; do
  if grep -qE '^        os: \[ubuntu-latest\]$' <<< "$(job_block "$job")"; then
    ok "$job: matrix os is ubuntu-latest only"
  else
    bad "$job: matrix os is not the single ubuntu-latest entry"
  fi
done

# 4. SUITE_TIER_MODE=all (the full corpus) on every run that is not a
# pull_request (the nightly, the main-sweep cron, a manual dispatch), fast on
# a PR. The aggregator recomputes the shards' tier, so both carry one expression.
tier="$(job_block shell-unit-shard | sed -n 's/^[[:space:]]*SUITE_TIER_MODE:[[:space:]]*//p')"
agg_tier="$(job_block shell-unit | sed -n 's/^[[:space:]]*SUITE_TIER_MODE:[[:space:]]*//p')"
case "$tier" in
  "\${{ github.event_name == 'pull_request' && 'fast' || 'all' }}")
    ok "SUITE_TIER_MODE is 'fast' on a pull_request, 'all' on every other run" ;;
  *) bad "SUITE_TIER_MODE expression is not 'fast' on a PR and 'all' elsewhere; got '$tier'" ;;
esac
if [ "$agg_tier" = "$tier" ]; then ok "the aggregator's SUITE_TIER_MODE matches the shards'"
else bad "the aggregator's SUITE_TIER_MODE '$agg_tier' differs from the shards' '$tier'"; fi

# 5. The aggregator's nightly-only steps are keyed on schedule alone.
agg="$(job_block shell-unit)"
n_if="$(grep -c "github.event.schedule == '17 7 \* \* \*'" <<< "$agg")"
if [ "$n_if" -ge 2 ]; then ok "shell-unit's extended-tier issue steps are gated on schedule ($n_if if:s)"
else bad "shell-unit has only $n_if schedule-gated steps (expected >= 2)"; fi

# 5b. macOS is not in ci.yml at all -- no matrix leg, no health
# step -- it runs on macos-cadence.yml, so a macOS red can never redden `CI`.
if grep -qi 'macos' <<< "$stripped"; then
  bad "ci.yml still runs or reads a macOS job: $(grep -i -m1 'macos' <<< "$stripped")"
else
  ok "no macOS job or macOS health step remains in the executable part of ci.yml"
fi

# 6. With one OS left there is nothing to make non-gating.
for job in shell-unit-shard bun-suites; do
  if grep -q 'continue-on-error' <<< "$(job_block "$job")"; then
    bad "$job: still carries continue-on-error"
  else
    ok "$job: no continue-on-error (ubuntu is the only leg)"
  fi
done

# 7. the shard job and its apt/at install step are bounded (a hung
# apt lock once held a shard ~1.5 h; the 6 h default queued every later main run).
blk="$(job_block shell-unit-shard)"
# Windows shards (79-128 min) are gone, so the cap is flat: 1.7x the slowest
# nightly ubuntu shard (35-38 min).
tm_line="$(grep -E '^    timeout-minutes:' <<< "$blk")"
if [ "$tm_line" = "    timeout-minutes: 60" ]; then
  ok "shell-unit-shard: job-level timeout-minutes is a flat 60"
else
  bad "shell-unit-shard: job-level timeout-minutes is not a flat 60: $tm_line"
fi
# A timed-out shard is `cancelled`, so its failed-suite logs must upload then too.
if grep -Eq "^        if: failure\(\) \|\| cancelled\(\)$" <<< "$(awk '/name: Upload failed-suite logs/ {f=1; next} f {print; exit}' <<< "$blk")"; then
  ok "shell-unit-shard: failed-suite logs upload on failure() || cancelled()"
else
  bad "shell-unit-shard: failed-suite logs upload does not cover a cancelled (timed-out) shard"
fi
# The at/atd install step alone: from its `- name:` line to the next step.
step="$(awk '/^      - name: Install \+ enable at\/atd/ {f=1; print; next} f && /^      - / {f=0} f' <<< "$blk")"
if grep -Eq '^        timeout-minutes: [0-9]+$' <<< "$step"; then
  ok "shell-unit-shard: at/atd install step has its own timeout-minutes"
else
  bad "shell-unit-shard: at/atd install step has no step-level timeout-minutes"
fi
# The apt calls moved into .github/scripts/apt-install.sh; the step
# must call it for exactly at + bubblewrap + socat, and the helper carries the
# invariants this block used to pin inline.
HELPER_SH="$ROOT/.github/scripts/apt-install.sh"
if grep -Eq '^ +bash \.github/scripts/apt-install\.sh at bubblewrap socat$' <<< "$step" \
   && ! grep -q 'apt-get ' <<< "$step"; then
  ok "shell-unit-shard: at/atd install goes through apt-install.sh (at bubblewrap socat)"
else
  bad "shell-unit-shard: at/atd install does not call apt-install.sh for at bubblewrap socat"
fi
# A runner where atd never started must fail the step, not pass it and fail a
# later job with an unrelated symptom.
if grep -Eq '\|\|[[:space:]]*true[[:space:]]*$' <<< "$(grep -E 'atd' <<< "$step" | grep -v '^ *#')"; then
  bad "shell-unit-shard: at/atd start swallows a failure with || true"
else
  ok "shell-unit-shard: at/atd start is not swallowed with || true"
fi
if grep -Eq '^ +(sudo )?systemctl is-active --quiet atd \|\| \{ echo "[^"]+" >&2; exit 1; \}$' <<< "$step"; then
  ok "shell-unit-shard: at/atd step ends in an is-active check that exits 1"
else
  bad "shell-unit-shard: at/atd step has no 'systemctl is-active --quiet atd || { echo ...; exit 1; }' check"
fi
# shellcheck disable=SC2016  # the patterns match helper source text literally
if [ ! -f "$HELPER_SH" ]; then
  bad "shell-unit-shard: apt-install.sh helper missing"
else
  # every apt call runs under `timeout`, with a dpkg-lock wait
  if grep -Fq 'apt() { $SUDO timeout -k 10 "$1" "$APT_GET"' "$HELPER_SH" \
     && [ "$(grep -c '"\$APT_GET"' "$HELPER_SH")" -eq 1 ] \
     && [ "$(grep -c 'DPkg::Lock::Timeout=' "$HELPER_SH")" -ge 2 ]; then
    ok "shell-unit-shard: every helper apt call is timeout-bounded and carries DPkg::Lock::Timeout"
  else
    bad "shell-unit-shard: helper has an unbounded apt call or lacks DPkg::Lock::Timeout"
  fi
  # Plain install first, index refresh only after it fails
  plain_ln="$(grep -n 'apt "\$T_PLAIN" install' "$HELPER_SH" | head -1 | cut -d: -f1)"
  upd_ln="$(grep -n 'apt "\$T_ALT" update' "$HELPER_SH" | head -1 | cut -d: -f1)"
  alt_ln="$(grep -n 'apt "\$T_ALT" install' "$HELPER_SH" | head -1 | cut -d: -f1)"
  if [ -n "$plain_ln" ] && [ -n "$upd_ln" ] && [ -n "$alt_ln" ] \
     && [ "$plain_ln" -lt "$upd_ln" ] && [ "$upd_ln" -lt "$alt_ln" ]; then
    ok "shell-unit-shard: helper tries plain install first, then update, then the retry install"
  else
    bad "shell-unit-shard: helper order is not plain install, update, retry install"
  fi
  # A swallowed install failure would let `at` stay absent
  if grep -Eq 'install .*\|\|[[:space:]]*true([[:space:];]|$)' "$HELPER_SH"; then
    bad "shell-unit-shard: helper swallows an apt-get install failure with || true"
  else
    ok "shell-unit-shard: no apt-get install failure is swallowed with || true"
  fi
  # worst case (cached + plain + update + retry install) fits the step cap
  t_c="$(sed -n 's/^T_CACHED="${APT_T_CACHED:-\([0-9]*\)}"$/\1/p' "$HELPER_SH")"
  t_p="$(sed -n 's/^T_PLAIN="${APT_T_PLAIN:-\([0-9]*\)}"$/\1/p' "$HELPER_SH")"
  t_a="$(sed -n 's/^T_ALT="${APT_T_ALT:-\([0-9]*\)}"$/\1/p' "$HELPER_SH")"
  apt_sum=$(( ${t_c:-0} + ${t_p:-0} + 2 * ${t_a:-0} ))
  cap_min="$(grep -Eo '^        timeout-minutes: [0-9]+$' <<< "$step" | grep -Eo '[0-9]+$')"
  if [ -n "$cap_min" ] && [ "$apt_sum" -gt 0 ] && [ "$apt_sum" -le $((cap_min * 60)) ]; then
    ok "shell-unit-shard: at/atd install worst-case apt time (${apt_sum}s) fits the step cap (${cap_min}m)"
  else
    bad "shell-unit-shard: at/atd install worst-case apt time (${apt_sum}s) exceeds the step cap (${cap_min:-none}m)"
  fi
  if grep -q 'echo "apt-install: installed from' "$HELPER_SH" && grep -q 'echo "apt-install: .*switching to' "$HELPER_SH"; then
    ok "shell-unit-shard: helper logs which path ran"
  else
    bad "shell-unit-shard: helper does not log which path ran"
  fi
fi

# 8. The plan job now sits behind the 180 s PR debounce, so its cap
# is 13 minutes (the p95 comment is kept on the raw file, comments stripped above).
plan_tm="$(awk '$0 == "  plan:" {f=1; next} f && /^  [a-zA-Z_-]+:/ {f=0} f && /^    timeout-minutes:/ {print; exit}' "$CI_YML")"
if [[ "$plan_tm" =~ ^"    timeout-minutes: 13 # p95 " ]]; then
  ok "plan: timeout-minutes is 13 with a p95 comment"
else
  bad "plan: timeout-minutes is not '13 # p95 ...': $plan_tm"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
