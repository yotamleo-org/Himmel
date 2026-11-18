#!/usr/bin/env bash
# shellcheck disable=SC2154  # SEED and the run state are set by the sourced testlib
# test-adopt-sequences-b.sh — seeded install/uninstall SEQUENCE driver, part 2 of 2: the
# uninstall-on-clean row, the two known-red rows, the strict-residue row and the three generated
# sequences. The verbs, the fixture, the stub and the options live in tests/testlib-adopt-sequences.sh;
# part 1 (test-adopt-sequences.sh) documents them and owns the --break-restore control row.
# Usage: bash scripts/test-adopt-sequences-b.sh [--seed N] [--only ID] [--seq "A U ..."] [--keep DIR]
# selector: names adopt.sh uninstall.sh himmel-doctor.sh bin.js settings-template.json
set -u
# shellcheck source=tests/testlib-adopt-sequences.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tests/testlib-adopt-sequences.sh"

# id|xfail-ticket|verbs
SEQS=(
  "uninstall-on-clean||U A U"
  "declined-restore-HIMMEL-6110|HIMMEL-6110|N A T U"
  "strict-residue-HIMMEL-6729||A P S W"
  "reinstall-reuninstall-HIMMEL-3767|HIMMEL-3767|A U D A W"
)
for g in 1 2 3; do
  SEQS+=("generated-seed-${SEED}-${g}||$(gen_seq $(( SEED + g )))")
done

run_sequences
