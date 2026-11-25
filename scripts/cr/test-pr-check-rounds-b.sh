#!/usr/bin/env bash
# selector: names panel-first-pass.sh anchor-handoff.sh base-resolver.sh review-round.sh note-polish.sh ledger-append.sh write-verdicts.sh clear-review-marker.sh blast-scope.cjs ledger-amend-auth.js known-findings.sh known-findings.json critic-pre-existing-tag.py
# selector: names chokepoint-seam-guard.sh lib.sh load-dotenv.sh shared-branch-lock.sh go-gate.sh gh-read.sh project-mode.sh ticket-status.sh required-checks.sh prim.sh status-marker.sh fixture-tempdir.sh write-verdict.sh
# selector: names forge.sh forge-github.sh forge-bitbucket.sh gate-repo-resolver.sh git-clean.sh handover-path.sh user-slug.sh
set -uo pipefail
exec bash "$(dirname "$0")/test-pr-check-rounds.sh" --part b
