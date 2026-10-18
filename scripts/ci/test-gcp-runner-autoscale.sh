#!/usr/bin/env bash
# scripts/ci/test-gcp-runner-autoscale.sh -- regression suite for scripts/ci/gcp-runner-autoscale.sh
# gh is a stub that serves fixtures shaped like the real REST responses and applies the
# caller's --jq with real jq; gcp-runners.sh is a stub that logs its argv. No live call.
# Pins: nothing happens while CI_GCP is off or no gcp job is queued, `up` gets the queued
# gcp depth capped at 4, only status=queued jobs count, a failed read never reaches `up`,
# and the systemd timer + service units point at the script.
#
# Usage: bash scripts/ci/test-gcp-runner-autoscale.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$ROOT/scripts/ci/gcp-runner-autoscale.sh"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

T="$(mktemp -d -t gcp-autoscale-test.XXXXXX)" || exit 1
trap 'rm -rf "$T"' EXIT

cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
# Serves fixtures by URL; applies the --jq expression with real jq.
printf 'GH %s\n' "$*" >> "$STUB_LOG"
q=""; url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --jq) q="$2"; shift ;;
        repos/*) url="$1" ;;
        variable) url="variable" ;;
    esac
    shift
done
case "$url" in
    variable) [ "${STUB_FAIL:-}" = var ] && exit 1; cat "$STUB_VAR"; exit 0 ;;
    repos/*/actions/runs\?status=queued*) [ "${STUB_FAIL:-}" = runs ] && exit 1; f="$STUB_DIR/runs.json" ;;
    repos/*/actions/runs\?status=in_progress*) f="$STUB_DIR/runs-ip.json" ;;
    repos/*/actions/runs/*/jobs*) id="${url#*/runs/}"; id="${id%%/*}"; f="$STUB_DIR/jobs-$id.json" ;;
    *) exit 1 ;;
esac
jq -r "$q" < "$f"
STUB
cat > "$T/runners" <<'STUB'
#!/usr/bin/env bash
printf 'RUNNERS %s\n' "$*" >> "$STUB_LOG"
STUB
chmod +x "$T/gh" "$T/runners"
export GH="$T/gh" GCP_AUTOSCALE_RUNNERS="$T/runners" STUB_LOG="$T/log" STUB_VAR="$T/civar" STUB_DIR="$T"

# Fixture shapes copied from the real `gh api repos/yotamleo/Himmel/actions/runs?status=queued`
# and `.../actions/runs/<id>/jobs` responses.
mkruns() { # ids... -> queued runs (in-progress runs: mkruns_ip)
    local first=1 id out='{"total_count":'"$#"',"workflow_runs":['
    for id in "$@"; do [ "$first" -eq 1 ] || out="$out,"; first=0; out="$out{\"id\":$id,\"status\":\"queued\",\"head_repository\":{\"full_name\":\"${RUN_HEAD_REPO:-yotamleo/Himmel}\",\"fork\":${RUN_HEAD_FORK:-false}}}"; done
    printf '%s]}\n' "$out" > "$T/runs.json"
    printf '{"total_count":0,"workflow_runs":[]}\n' > "$T/runs-ip.json"
}
mkruns_ip() { # ids... -> in-progress runs on top of the queued set
    local first=1 id out='{"total_count":'"$#"',"workflow_runs":['
    for id in "$@"; do [ "$first" -eq 1 ] || out="$out,"; first=0; out="$out{\"id\":$id,\"status\":\"in_progress\",\"head_repository\":{\"full_name\":\"${RUN_HEAD_REPO:-yotamleo/Himmel}\",\"fork\":${RUN_HEAD_FORK:-false}}}"; done
    printf '%s]}\n' "$out" > "$T/runs-ip.json"
}
mkjobs() { # run-id status label... one job per status:label pair
    local id="$1" first=1 j out='{"total_count":0,"jobs":[' n=100
    shift
    for j in "$@"; do
        [ "$first" -eq 1 ] || out="$out,"; first=0; n=$((n + 1))
        out="$out{\"id\":$id$n,\"run_id\":$id,\"status\":\"${j%%:*}\",\"conclusion\":null,\"labels\":[\"self-hosted\",\"${j#*:}\"],\"name\":\"job-$n\"}"
    done
    printf '%s]}\n' "$out" > "$T/jobs-$id.json"
}
run() { : > "$STUB_LOG"; bash "$SUT" > "$T/out" 2>&1; echo $?; }
ups() { grep -c '^RUNNERS up' "$STUB_LOG"; }

echo on > "$STUB_VAR"

# 1. CI_GCP off: nothing is created, nothing is read beyond the variable.
echo off > "$STUB_VAR"; mkruns 1; mkjobs 1 queued:gcp
rc="$(run)"; if [ "$rc" -eq 0 ] && [ "$(ups)" -eq 0 ] && ! grep -q 'actions/runs' "$STUB_LOG"; then ok "CI_GCP off: no scale-up"; else bad "CI_GCP off: rc=$rc ups=$(ups)"; fi
echo on > "$STUB_VAR"

# 2. nothing queued at all, and queued runs without a queued gcp job: no scale-up.
mkruns
rc="$(run)"; if [ "$rc" -eq 0 ] && [ "$(ups)" -eq 0 ]; then ok "no queued run: no scale-up"; else bad "empty queue: rc=$rc ups=$(ups)"; fi
mkruns 1 2; mkjobs 1 queued:ubuntu-latest; mkjobs 2 in_progress:gcp completed:gcp
rc="$(run)"; if [ "$rc" -eq 0 ] && [ "$(ups)" -eq 0 ]; then ok "only queued gcp jobs count"; else bad "non-gcp / non-queued: rc=$rc ups=$(ups)"; fi

# 3. queue depth 3 across two runs: up 3.
mkruns 10 20; mkjobs 10 queued:gcp queued:gcp queued:ubuntu-latest; mkjobs 20 queued:gcp
rc="$(run)"; if [ "$rc" -eq 0 ] && grep -qx 'RUNNERS up 3' "$STUB_LOG"; then ok "up gets the queued gcp depth"; else bad "depth 3: rc=$rc log=$(grep RUNNERS "$STUB_LOG")"; fi

# 3b. a queued gcp job inside an in-progress run (other jobs already running) counts too.
mkruns 10; mkjobs 10 queued:gcp; mkruns_ip 40; mkjobs 40 in_progress:ubuntu-latest queued:gcp
rc="$(run)"; if [ "$rc" -eq 0 ] && grep -qx 'RUNNERS up 2' "$STUB_LOG"; then ok "queued gcp jobs of in-progress runs count"; else bad "in-progress run: rc=$rc log=$(grep RUNNERS "$STUB_LOG")"; fi

# 3c. a run seen in both listings (it moved between the reads) counts once.
mkruns 10; mkjobs 10 queued:gcp; mkruns_ip 10
rc="$(run)"; if [ "$rc" -eq 0 ] && grep -qx 'RUNNERS up 1' "$STUB_LOG"; then ok "a run in both listings counts once"; else bad "dup run: rc=$rc log=$(grep RUNNERS "$STUB_LOG")"; fi

# 3d. fork-PR runs (head_repository is the fork) never count, queued or in progress.
RUN_HEAD_REPO=evil/Himmel RUN_HEAD_FORK=true mkruns 50; mkjobs 50 queued:gcp queued:gcp queued:gcp
rc="$(run)"; if [ "$rc" -eq 0 ] && [ "$(ups)" -eq 0 ]; then ok "a fork run's queued gcp jobs create no VM"; else bad "fork run: rc=$rc log=$(grep RUNNERS "$STUB_LOG")"; fi
mkruns 10; mkjobs 10 queued:gcp; RUN_HEAD_REPO=evil/Himmel RUN_HEAD_FORK=true mkruns_ip 51; mkjobs 51 queued:gcp queued:gcp
rc="$(run)"; if [ "$rc" -eq 0 ] && grep -qx 'RUNNERS up 1' "$STUB_LOG"; then ok "a fork run in progress does not add to the depth"; else bad "fork in-progress: rc=$rc log=$(grep RUNNERS "$STUB_LOG")"; fi

# 4. queue depth 7: capped at 4.
mkruns 30; mkjobs 30 queued:gcp queued:gcp queued:gcp queued:gcp queued:gcp queued:gcp queued:gcp
rc="$(run)"; if [ "$rc" -eq 0 ] && grep -qx 'RUNNERS up 4' "$STUB_LOG" && [ "$(ups)" -eq 1 ]; then ok "up is capped at 4"; else bad "depth 7: rc=$rc log=$(grep RUNNERS "$STUB_LOG")"; fi

# 5. a failed read never reaches up.
export STUB_FAIL=runs
rc="$(run)"; if [ "$rc" -ne 0 ] && [ "$(ups)" -eq 0 ]; then ok "a failed queue listing creates nothing"; else bad "runs fail: rc=$rc ups=$(ups)"; fi
export STUB_FAIL=var
rc="$(run)"; if [ "$rc" -ne 0 ] && [ "$(ups)" -eq 0 ]; then ok "an unreadable CI_GCP creates nothing"; else bad "var fail: rc=$rc ups=$(ups)"; fi
unset STUB_FAIL

# 6. a failing up fails the tick.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/runners"
rc="$(run)"; if [ "$rc" -ne 0 ]; then ok "a failed up fails the tick"; else bad "failed up swallowed"; fi

# 7. the systemd user units run the script on a timer.
SVC="$ROOT/scripts/ci/himmel-gcp-autoscale.service"; TMR="$ROOT/scripts/ci/himmel-gcp-autoscale.timer"
if [ -f "$SVC" ] && grep -q '^Type=oneshot$' "$SVC" && grep -q '^ExecStart=.*gcp-runner-autoscale\.sh' "$SVC"; then ok "service unit runs the autoscale script once"; else bad "service unit missing or wrong"; fi
if [ -f "$TMR" ] && grep -q '^OnUnitActiveSec=' "$TMR" && grep -q '^OnBootSec=' "$TMR" && grep -q '^WantedBy=timers.target$' "$TMR"; then ok "timer unit fires on boot and on an interval"; else bad "timer unit missing or wrong"; fi

if [ "$fails" -eq 0 ]; then echo "PASS: $0"; exit 0; fi
echo "FAILED: $fails case(s)" >&2
exit 1
