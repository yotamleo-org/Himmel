#!/usr/bin/env bash
# scripts/handover/chief-kit/chain-plan.sh: the merge planner.
# Reads a chain graph (chain-graph.py --json) and prints the order the chain's PRs should merge in.
#
#   chain-graph.py --open --json > graph.json
#   chain-plan.sh --graph graph.json [--ready 3971,3972]      (--ready: PRs green and GO-able now)
#   chain-plan.sh --evidence --graph graph.json [--ready ...]  only the MERGE-FORWARD lines, whatever the flag
#   chain-plan.sh --go-check <pr> --graph graph.json          the pre-GO check, whatever the flag
#
# Output, one line each (nothing else on stdout):
#   chain-plan: chain_merge_plan on
#   ORDER <pr> <pr> ...                      every node, in merge order
#   HOLD <pr> for <pr> (<kind> <det>)        an H1 or H2 successor waits for its predecessor
#   MERGE-FORWARD <pr> after <pr> (S2 <det>) the later node of an S2 pair merges main forward once, after
#                                            the last of its S2 predecessors, then re-runs its impacted
#                                            suites; merge-forward-check.sh --chain-s2 derives the line itself
# S1 and independent edges order nothing: those nodes merge as they go green.
# The planner is chain-plan-core.sh (flag-free; the order rules and --go-check are documented there). This wrapper
# only reads the flag chain_merge_plan (scripts/lib/flags.tsv, default off) for the default plan: off prints one
# notice line and no plan. --evidence and --go-check skip the flag. The flag is read here, never in a gate:
# merge-forward-check.sh execs the core, not this file.
#
# Exit: 0 plan (or flag off)  1 cycle among the hard edges, or a --go-check REFUSE  2 usage, unreadable graph or flag registry
# Platform guard: bash, jq, awk.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for a in "$@"; do case "$a" in --evidence|--go-check) exec bash "$SCRIPT_DIR/chain-plan-core.sh" "$@" ;; esac; done
# shellcheck source=../../lib/flags.sh
. "$SCRIPT_DIR/../../lib/flags.sh" || exit 2

himmel_flag chain_merge_plan; rc=$?
case "$rc" in
  0) exec bash "$SCRIPT_DIR/chain-plan-core.sh" --flag-state on "$@" ;;
  1) exec bash "$SCRIPT_DIR/chain-plan-core.sh" --flag-state off "$@" ;;
  *) exit 2 ;;
esac
