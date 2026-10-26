#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-recorded-run.sh — POC. The fixtures in recorded/ are the
# real transcripts of run-poc.sh on a test VM guest (Ubuntu 24.04, srt 0.0.79);
# this asserts the POC verdict still matches them: every battery row PASSes,
# origin main never moved, and srt refuses an invalid or missing settings file.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REC="$HERE/recorded"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# grep exits 0 on a match, 1 on none and >1 on an error: only 1 proves absence
has() { if grep -qE -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3"; fi; }
hasnt() {
    local rc=0
    grep -qE -- "$2" "$1" 2>/dev/null || rc=$?
    if [ "$rc" -eq 1 ]; then ok "$3"; else bad "$3"; fi
}

# positive control: the negative matcher must see a planted FAIL row and must
# not treat an unreadable file as "absent"
ctl="$(mktemp)" || exit 1
th="$(mktemp -d)" || exit 1
trap 'rm -rf "$ctl" "$th"' EXIT
printf 'ROW X FAIL\n' >"$ctl"
grep -qE '^ROW .* FAIL' "$ctl" && ok "control: matcher sees a planted FAIL row" || bad "control: matcher blind to a FAIL row"
ctl_rc=0
grep -qE x "$REC/does-not-exist.txt" 2>/dev/null || ctl_rc=$?
if [ "$ctl_rc" -eq 2 ]; then ok "control: unreadable file exits 2 (hasnt fails closed)"; else bad "control: unreadable file not an error"; fi

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
common_rows=(B0-worker-commit B1-benign-python B2-rm-rf-outside B3-write-outside B4-direct-force-push-outside
    B5-force-push-inside-root-passes B6-wrapper-own-branch B7-wrapper-refuses-force B8-wrapper-refuses-main
    B8b-wrapper-refuses-plus B9-credential-read B10-allowed-host B11-proxy-bypass B12-profile-domain B15-worktree-commit)
for r in "${common_rows[@]}"; do
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

# driver controls: run the real run-poc.sh against stub srt binaries in a throwaway HOME
poc() { # <srt> <mode> <home> -> rc of the driver, output in $th/poc.out
    HOME="$3" SRT="$1" bash "$HERE/run-poc.sh" "$2" >"$th/poc.out" 2>&1
}
mkdir -p "$th/h1/.ssh"
echo keep >"$th/h1/outside-write.txt"
echo keepkey >"$th/h1/.ssh/poc_dummy"
poc /bin/true failure-modes "$th/h1"
if [ "$(cat "$th/h1/outside-write.txt" 2>/dev/null)" = keep ]; then ok "cleanup keeps a pre-existing outside-write.txt"; else bad "cleanup deleted a pre-existing outside-write.txt"; fi
if [ "$(cat "$th/h1/.ssh/poc_dummy" 2>/dev/null)" = keepkey ]; then ok "cleanup keeps a pre-existing poc_dummy"; else bad "cleanup deleted or overwrote a pre-existing poc_dummy"; fi
mkdir -p "$th/h2"
poc no-such-srt-binary failure-modes "$th/h2"; f3_rc=$?
if [ "$f3_rc" -ne 0 ] && grep -q 'ASSERT FAIL F3 srt not resolvable' "$th/poc.out"; then ok "F3 fails when srt does not resolve"; else bad "F3 passed on command-not-found"; fi
{
    echo '#!/bin/bash'
    for r in "${common_rows[@]}" B13-domain-request-approved B14-domain-request-default-deny; do echo "echo 'ROW $r PASS'"; done
} >"$th/srt-all"
printf '#!/bin/bash\necho "ROW B0-worker-commit PASS"\n' >"$th/srt-one"
chmod +x "$th/srt-all" "$th/srt-one"
mkdir -p "$th/h3" "$th/h4"
poc "$th/srt-all" impl "$th/h3"; all_rc=$?
if [ "$all_rc" -eq 0 ]; then ok "control: every impl row present passes the verdict"; else bad "control: complete impl rows failed the verdict (rc=$all_rc)"; fi
poc "$th/srt-one" impl "$th/h4"; one_rc=$?
if [ "$one_rc" -ne 0 ] && grep -q 'ASSERT FAIL row B1-benign-python missing' "$th/poc.out"; then ok "verdict fails when profile rows are missing"; else bad "verdict passed with one row"; fi

echo "fails=$fails"
[ "$fails" -eq 0 ]
