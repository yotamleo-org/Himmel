#!/usr/bin/env bash
# scripts/ci/suite-ledger.sh — append one row per local suite run to the ledger.
#
# Sourced, never executed. suite_ledger_append <suite> <rc> <sec> adds
#   {"ts":"<UTC>","suite":"<suite>","head":"<sha>","rc":<n>,"sec":<n>,"station":"<host>"}
# to $HIMMEL_SUITE_LEDGER, default $HOME/.himmel/state/suite-runs.jsonl (the
# directory is created on demand). Read by suite-runs-summary.sh.
#
# It can never change a suite's verdict: every failure is swallowed and the
# function returns 0. A fixture-marked run (HIMMEL_TEST_FIXTURE=1, set by
# run-shell-tests.sh around every suite) and a GitHub Actions run record
# nothing unless HIMMEL_SUITE_LEDGER names a file explicitly, so a suite that
# drives quiet-run.sh or the runner never writes the operator's real ledger.

suite_ledger_append() {
  local suite="$1" rc="$2" sec="$3" ledger head station ts esc
  if [ -z "${HIMMEL_SUITE_LEDGER:-}" ]; then
    [ "${HIMMEL_TEST_FIXTURE:-}" = "1" ] && return 0
    [ "${GITHUB_ACTIONS:-}" = "true" ] && return 0
  fi
  ledger="${HIMMEL_SUITE_LEDGER:-${HOME:-}/.himmel/state/suite-runs.jsonl}"
  case "$rc$sec" in *[!0-9]*|'') return 0 ;; esac
  {
    mkdir -p "${ledger%/*}" || return 0
    head=$(git rev-parse HEAD 2>/dev/null) || head='' # swallow-ok: the ledger must never fail a suite; an empty head is a row without a sha
    station=$(hostname 2>/dev/null) || station='' # swallow-ok: the ledger must never fail a suite; falls back to "unknown" below
    [ -n "$station" ] || station=unknown
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    esc=$(printf '%s' "$suite" | sed 's/\\/\\\\/g; s/"/\\"/g')
    station=$(printf '%s' "$station" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"ts":"%s","suite":"%s","head":"%s","rc":%s,"sec":%s,"station":"%s"}\n' \
      "$ts" "$esc" "$head" "$rc" "$sec" "$station" >> "$ledger"
  } 2>/dev/null || true
  return 0
}
