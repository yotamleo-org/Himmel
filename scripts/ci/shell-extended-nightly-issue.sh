#!/usr/bin/env bash
# scripts/ci/shell-extended-nightly-issue.sh — maintain ONE consolidated issue
# for a red `shell-unit` gate on the nightly-only extended tier.
#
# run-shell-tests.sh's SUITE_TIER_DEFAULT `extended` suites (currently
# test-check-ci.sh, test-arm-resume-identity.sh and
# test-arm-resume-1879.sh) only execute under SUITE_TIER_MODE=all, which
# ci.yml sets only on the schedule (nightly) leg of shell-unit-shard. A red
# extended suite therefore only ever reddens the `shell-unit` aggregating job
# on that nightly run — a run nobody is watching interactively — so
# without this script the failure is silent even though the job itself goes
# red. This script does not distinguish which suite failed; on a nightly
# run every fast-tier suite is already expected green (they gate
# every PR), so in practice a nightly-only red here points at the extended
# tier. macOS is not on this nightly any more (it runs on
# macos-cadence.yml, so a macOS red never reddens this run). A Windows shell
# shard stays masked by continue-on-error and is not filed here; see
# docs/internals/testing.md "A nightly OS red".
#
#   rc != 0 -> open the issue if absent, else refresh its body + add a "still
#              red" comment — unless the run is not a real red: no shard
#              failed and one was cancelled (inconclusive), or a newer
#              schedule run already went green (superseded). Both log a note
#              and leave the issue untouched.
#   rc == 0 -> if an issue is open, comment "green again" and close it.
#
# Usage:  shell-extended-nightly-issue.sh <shell-unit-outcome-rc> <run-url>
# Env:
#   GH_TOKEN / GITHUB_TOKEN  gh auth (issues:write) — supplied by the workflow.
#   SHELL_EXTENDED_NIGHTLY_ISSUE_LABEL  marker label (default: shell-extended-nightly-ci).
#   SHELL_EXTENDED_NIGHTLY_ISSUE_TITLE  issue title (default below) — stable across runs.
#   GITHUB_REPOSITORY / GITHUB_RUN_ID  the run being reported (workflow-supplied);
#                            used to classify a red. When unset or a lookup
#                            fails the red is reported as before.
#   DRY_RUN_JOBS_FILE / DRY_RUN_RUNS_FILE / DRY_RUN_CREATED_AT  (DRY_RUN only)
#                            the run's jobs JSON, the completed schedule runs
#                            JSON and this run's created_at.
#   DRY_RUN=1                print the gh commands instead of running them
#                            (used by the test harness; no network, no auth).
set -uo pipefail

RC="${1:-}"
RUN_URL="${2:-}"
LABEL="${SHELL_EXTENDED_NIGHTLY_ISSUE_LABEL:-shell-extended-nightly-ci}"
TITLE="${SHELL_EXTENDED_NIGHTLY_ISSUE_TITLE:-Shell extended-tier nightly CI is red (shell-unit)}"

if [ -z "$RC" ] || [ -z "$RUN_URL" ]; then
  echo "usage: shell-extended-nightly-issue.sh <shell-unit-outcome-rc> <run-url>" >&2
  exit 2
fi

run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  "$@"
}

now() { date -u +'%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "unknown-time"; }

# Newest open issue carrying the marker label. Prints the number (empty when
# there is none) on a successful lookup; returns nonzero when the lookup
# itself fails, so callers can tell "no issue" apart from "don't know" — a
# swallowed failure would let the red branch open a duplicate.
find_open_issue() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    [ "${DRY_RUN_LOOKUP_FAIL:-0}" = "1" ] && return 1
    printf '%s' "${DRY_RUN_OPEN_ISSUE:-}"
    return 0
  fi
  local out rc
  out="$(gh issue list --label "$LABEL" --state open --limit 1 \
    --json number --jq '.[0].number // empty' 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out"
}

# Prints "inconclusive", "superseded" or nothing (a real red) for this run.
# A lookup that fails prints nothing, so an unknown stays a reported red.
classify_red() {
  command -v jq >/dev/null 2>&1 || return 0
  local jobs="" runs="" created=""
  if [ "${DRY_RUN:-0}" = "1" ]; then
    [ -n "${DRY_RUN_JOBS_FILE:-}" ] && jobs="$(cat "$DRY_RUN_JOBS_FILE")"
    [ -n "${DRY_RUN_RUNS_FILE:-}" ] && runs="$(cat "$DRY_RUN_RUNS_FILE")"
    created="${DRY_RUN_CREATED_AT:-}"
  elif [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    jobs="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?per_page=100")" || jobs=""
    runs="$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs?event=schedule&status=completed&per_page=10")" || runs=""
    created="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" --jq .created_at)" || created=""
  fi
  local failed cancelled newer
  if [ -n "$jobs" ]; then
    failed="$(jq '[.jobs[]|select((.name|startswith("shell-unit-shard")) and .conclusion!=null and (.conclusion|IN("success","skipped","cancelled")|not))]|length' <<< "$jobs")"
    cancelled="$(jq '[.jobs[]|select((.name|startswith("shell-unit-shard")) and .conclusion=="cancelled")]|length' <<< "$jobs")"
    if [ "${failed:-1}" = 0 ] && [ "${cancelled:-0}" -gt 0 ] 2>/dev/null; then
      echo inconclusive
      return 0
    fi
  fi
  if [ -n "$runs" ] && [ -n "$created" ]; then
    newer="$(jq --arg c "$created" '[.workflow_runs[]|select(.conclusion=="success" and .created_at>$c)]|length' <<< "$runs")"
    if [ "${newer:-0}" -gt 0 ] 2>/dev/null; then
      echo superseded
    fi
  fi
}

build_body() {
  local body_file="$1"
  {
    echo "**Automated shell extended-tier nightly report** — maintained in"
    echo "place by the \`shell-unit\` aggregating gate job's schedule"
    echo "(nightly) leg. Do not open duplicates; this issue is refreshed"
    echo "each run and auto-closed once the leg goes green again."
    echo ""
    echo "The SUITE_TIER_DEFAULT \`extended\` suites (run-shell-tests.sh) only"
    echo "run under SUITE_TIER_MODE=all, i.e. only on this nightly"
    echo "leg — never per-PR — so this issue is the only signal that one of"
    echo "them broke."
    echo ""
    echo "_Last red run: $(now)._"
    echo ""
    echo "Run: $RUN_URL"
  } > "$body_file"
}

if [ "$RC" != 0 ]; then
  case "$(classify_red)" in
    inconclusive)
      echo "shell-extended-nightly-issue: no shard failed and one was cancelled — inconclusive, not reporting red: $RUN_URL"
      exit 0 ;;
    superseded)
      echo "shell-extended-nightly-issue: a newer schedule run already went green — red superseded, not reporting: $RUN_URL"
      exit 0 ;;
  esac
  if ! num="$(find_open_issue)"; then
    echo "shell-extended-nightly-issue: could not query existing issues (gh lookup failed) — not creating/refreshing to avoid a duplicate. Retrying next run." >&2
    exit 1
  fi
  mut=0
  run gh label create "$LABEL" --color FBCA04 \
      --description "Nightly shell extended-tier CI tracking" --force || mut=1
  body_file="$(mktemp "${TMPDIR:-/tmp}/shell-extended-nightly-issue.XXXXXX")" || {
    echo "shell-extended-nightly-issue: mktemp failed" >&2
    exit 1
  }
  build_body "$body_file"
  if [ -n "$num" ]; then
    echo "shell-extended-nightly-issue: refreshing existing issue #$num"
    run gh issue edit "$num" --body-file "$body_file" || mut=1
    run gh issue comment "$num" --body "Still red as of $(now): $RUN_URL" || mut=1
  else
    echo "shell-extended-nightly-issue: opening new consolidated issue"
    run gh issue create --title "$TITLE" --label "$LABEL" --body-file "$body_file" || mut=1
  fi
  rm -f "$body_file"
  if [ "$mut" -ne 0 ]; then
    echo "shell-extended-nightly-issue: an issue mutation failed (see above) — failing so the red run is not silently green." >&2
    exit 1
  fi
else
  if ! num="$(find_open_issue)"; then
    echo "shell-extended-nightly-issue: green, but could not query existing issues (gh lookup failed) — failing so the unresolved reconciliation is visible. Retries next run." >&2
    exit 1
  fi
  if [ -n "$num" ]; then
    echo "shell-extended-nightly-issue: green again — closing issue #$num"
    mut=0
    run gh issue comment "$num" --body "Green again as of $(now): $RUN_URL. Closing." || mut=1
    run gh issue close "$num" || mut=1
    if [ "$mut" -ne 0 ]; then
      echo "shell-extended-nightly-issue: failed to close the issue (see above) — it will retry next run." >&2
      exit 1
    fi
  else
    echo "shell-extended-nightly-issue: green, no open issue — nothing to do."
  fi
fi
