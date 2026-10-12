#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-recorded-run.sh — HIMMEL-5287 POC. The fixtures in recorded/ are the
# real transcripts of run-poc.sh on a test VM guest (Ubuntu 24.04, srt 0.0.79);
# this asserts the POC verdict still matches them: every battery row PASSes,
# origin main never moved, and srt refuses an invalid or missing settings file.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REC="$HERE/recorded"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

has() { grep -qE -- "$2" "$1" && ok "$3" || bad "$3"; }
hasnt() { grep -qE -- "$2" "$1" && bad "$3" || ok "$3"; }

for m in impl research; do
    f="$REC/vm-run-$m.txt"
    [ -s "$f" ] || { bad "$m transcript present"; continue; }
    hasnt "$f" '^ROW .* FAIL' "$m: no battery row failed"
    has "$f" '^ROW B4-direct-force-push-outside PASS' "$m: direct force push outside the roots blocked"
    has "$f" '^ROW B5-force-push-inside-root-passes PASS' "$m: boundary honesty row recorded"
    has "$f" '^ROW B7-wrapper-refuses-force PASS rc=20' "$m: wrapper refused force"
    has "$f" '^ASSERT origin main untouched' "$m: origin main untouched"
    has "$f" '^ASSERT settings-loaded' "$m: launch-time settings assertion ran"
done
for r in B0-leg-commit B1-benign-python B2-rm-rf-outside B3-write-outside B4-direct-force-push-outside \
    B5-force-push-inside-root-passes B6-wrapper-own-branch B7-wrapper-refuses-force B8-wrapper-refuses-main \
    B8b-wrapper-refuses-plus B9-credential-read B10-allowed-host B11-proxy-bypass B12-profile-domain B15-worktree-commit; do
    for m in impl research; do
        has "$REC/vm-run-$m.txt" "^ROW $r PASS" "$m: row $r present and PASS"
    done
done
has "$REC/vm-run-impl.txt" '^ROW B13-domain-request-approved PASS' "impl: approved domain request round trip"
has "$REC/vm-run-impl.txt" '^ROW B14-domain-request-default-deny PASS' "impl: unanswered request denied"
has "$REC/vm-run-research.txt" '^ROW B12b-research-not-unlimited PASS' "research: not unlimited"
has "$REC/vm-run-failure-modes.txt" 'is empty\. Delete it' "failure: zero-byte settings refused"
has "$REC/vm-run-failure-modes.txt" 'does not exist' "failure: missing settings refused"
has "$REC/vm-run-failure-modes.txt" 'Sandbox dependencies not available' "failure: missing bwrap refused"

echo "fails=$fails"
[ "$fails" -eq 0 ]
