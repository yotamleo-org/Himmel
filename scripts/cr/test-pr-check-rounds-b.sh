#!/usr/bin/env bash
# Part b of test-pr-check-rounds.sh: the signed judge-record, delta-scope,
# clean-merge and merge-resolution rows. It runs that file with --part b; the
# cases live there.
# selector: names panel-first-pass.sh anchor-handoff.sh base-resolver.sh review-round.sh note-polish.sh ledger-append.sh write-verdicts.sh clear-review-marker.sh blast-scope.cjs ledger-amend-auth.js known-findings.sh known-findings.json critic-pre-existing-tag.py
# selector: names chokepoint-seam-guard.sh lib.sh load-dotenv.sh shared-branch-lock.sh go-gate.sh gh-read.sh project-mode.sh ticket-status.sh required-checks.sh prim.sh status-marker.sh fixture-tempdir.sh write-verdict.sh
set -uo pipefail
exec bash "$(dirname "$0")/test-pr-check-rounds.sh" --part b
