#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # SEQS is read and SEED set by the sourced testlib
# The per-step suites (test-adopt.sh, test-uninstall*.sh) prove
# each step alone; install-sequence bugs only show when steps are chained. This suite chains adopt / adopt --scope project /
# uninstall / uninstall --purge-state / adopt-with-failure-at-step-k on a
# fixture HOME + project and asserts, after EVERY step:
#   - after an uninstall the fixture equals its pre-install snapshot (the
#     ALLOWLIST aside) and the rc is non-zero iff something remains;
#   - after a (non-injected) adopt, `himmelctl status` has no red row and
#     the doctor install checks are green.
#
# Verbs in a sequence:  A  adopt --scope user      P  adopt --scope project
#   U  uninstall       X  uninstall --purge-state   W  uninstall that must
#   exit 0   N  (first verb) seed an explicit-null hooks container   T  corrupt
#   the backups of that null   S  strict mode (no known-residue tolerance)
#   D  claude stub stops declaring marketplaces in settings   B  stray file
#   (control row)   F<k>  adopt --scope user with the kth `claude` call failing.
#
# KNOWN-RED rows (xfail): a sequence tagged with a ticket key pins a defect
# that is live at head. It must FAIL the contract (that is the expected
# result); if it PASSES (XPASS) the suite fails and names the ticket — the fix
# PR promotes the row by deleting its tag.
#
# Fixture HOME only: every sequence runs under its own mktemp HOME with a
# hermetic PATH (only the fixture bin: no host tool such as qmd, node, pre-commit, at or crontab, so the result is the same on a workstation and a CI runner) and
# a stateful pure-bash `claude` stub. Sequences run in parallel (<=8 at once).
#
# Usage: bash scripts/test-adopt-sequences.sh [--seed N] [--break-restore]
#   --seed N         seed for the generated sequences (default 6626)
#   --only ID        run just that sequence
#   --seq "A U ..."  run one ad-hoc sequence of verbs
#   --keep DIR      build the fixtures in DIR and leave them (debugging)
#   --break-restore  RED control: sabotage the restore in the control row so
#                    it must fail a green row (not part of the normal run)
#   SEQ_BUDGET_SECS  wall-clock budget in seconds (default 120, 640 when CI is set)
#   --check-budget E  exit 0 iff elapsed E seconds is within the budget
# selector: names adopt.sh uninstall.sh himmel-doctor.sh bin.js settings-template.json
set -u
# shellcheck source=tests/testlib-adopt-sequences.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tests/testlib-adopt-sequences.sh"

# id|xfail-ticket|verbs
SEQS=(
  "install-uninstall-user||A U"
  "install-uninstall-project||P U"
  "reinstall-reuninstall-user||A U A U"
  "both-scopes-one-uninstall||A P U"
  "project-then-user||P A U U"
  "purge-state||A X"
  "fail-inject-3-then-uninstall||F3 S W"
  "fail-inject-9-then-uninstall||F9 U"
  "control-broken-restore||A B U"
)

run_sequences
