#!/usr/bin/env bash
# Test for scripts/ci/queue-latency.sh.
# A fake gh serves canned Actions API fixtures and applies the script's own
# --jq expression with real jq, so the filters are exercised, not stubbed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/queue-latency.sh"
TMP="$(mktemp -d "/tmp/himmel-test-queue-latency.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../lib/timeout-bin.sh
. "$ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null

fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
is()  { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1: want '$2' got '$3'"; fi; }

mkdir -p "$TMP/bin" "$TMP/fx"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: `gh api <path> --jq <expr>`; fixtures live in $FX.
[ -n "${FAKE_GH_FAIL:-}" ] && { echo "fake-gh: simulated API failure" >&2; exit 1; }
shift; path="$1"; shift
echo "$path $*" >> "$FX/calls.log"
expr=""
while [ $# -gt 0 ]; do case "$1" in --jq) expr="$2"; shift 2 ;; *) shift ;; esac; done
case "$path" in
  *status=in_progress*) f="$FX/runs-in_progress.json" ;;
  *status=queued*)      f="$FX/runs-queued.json" ;;
  *status=pending*)     f="$FX/runs-pending.json"; [ -f "$f" ] || echo '{"workflow_runs":[]}' > "$f" ;;
  */runs/*/jobs*)       id="${path#*/runs/}"; id="${id%%/*}"; f="$FX/jobs-$id.json" ;;
  *) echo "fake-gh: unsupported $path" >&2; exit 1 ;;
esac
[ -f "$f" ] || { echo "fake-gh: no fixture $f" >&2; exit 1; }
jq -r "$expr" < "$f"
EOF
chmod +x "$TMP/bin/gh"

now=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }  # GNU || BSD
t10=$(iso $((now - 600)))   # 10 minutes ago
t3=$(iso $((now - 180)))    # 3 minutes ago

# jobs fixture helper: jobs_json <n_ip_linux> <n_ip_macos> <n_queued> <queued_created>
jobs_json() {
  local out='{"jobs":[' sep='' i
  for ((i = 0; i < $1; i++)); do out+="$sep{\"status\":\"in_progress\",\"labels\":[\"ubuntu-latest\"],\"created_at\":\"$t10\"}"; sep=','; done
  for ((i = 0; i < $2; i++)); do out+="$sep{\"status\":\"in_progress\",\"labels\":[\"macos-latest\"],\"created_at\":\"$t10\"}"; sep=','; done
  for ((i = 0; i < $3; i++)); do out+="$sep{\"status\":\"queued\",\"labels\":[\"ubuntu-latest\"],\"created_at\":\"$4\"}"; sep=','; done
  echo "$out]}"
}
runs_json() { # runs_json <status> <id>...
  local st="$1" out='{"workflow_runs":[' sep=''; shift
  for id in "$@"; do out+="$sep{\"id\":$id,\"status\":\"$st\",\"created_at\":\"$t10\"}"; sep=','; done
  echo "$out]}"
}
reset() { rm -f "$TMP"/fx/*; }
run() { FX="$TMP/fx" PATH="$TMP/bin:$PATH" bash "$SCRIPT" -R owner/repo 2>&1; }

if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# idle
reset
runs_json in_progress > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
out="$(run)"
is "idle" "ci-queue: jobs_in_progress=0/60 macos=0/5 queued=0 oldest_wait=0m" "$out"

# saturated 20/60 across two runs, 2 queued jobs waiting 10m
reset
runs_json in_progress 1 2 > "$TMP/fx/runs-in_progress.json"; runs_json queued 3 > "$TMP/fx/runs-queued.json"
jobs_json 12 0 0 "$t10" > "$TMP/fx/jobs-1.json"
jobs_json 8 0 0 "$t10" > "$TMP/fx/jobs-2.json"
jobs_json 0 0 2 "$t10" > "$TMP/fx/jobs-3.json"
out="$(run)"
is "20 running, 2 queued" "ci-queue: jobs_in_progress=20/60 macos=0/5 queued=2 oldest_wait=10m" "$out"

# macOS 5/5 (counted inside the total)
reset
runs_json in_progress 1 > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
jobs_json 3 5 0 "$t3" > "$TMP/fx/jobs-1.json"
out="$(run)"
is "macOS 5/5" "ci-queue: jobs_in_progress=8/60 macos=5/5 queued=0 oldest_wait=0m" "$out"

# a run in BOTH lists is counted once
reset
runs_json in_progress 1 > "$TMP/fx/runs-in_progress.json"; runs_json queued 1 > "$TMP/fx/runs-queued.json"
jobs_json 2 0 0 "$t3" > "$TMP/fx/jobs-1.json"
out="$(run)"
case "$out" in *jobs_in_progress=2/60*) ok "dedupe run listed twice" ;; *) bad "dedupe: $out" ;; esac

# storm: queued runs with no jobs materialised still count as waiting
reset
runs_json in_progress > "$TMP/fx/runs-in_progress.json"; runs_json queued 7 8 > "$TMP/fx/runs-queued.json"
echo '{"jobs":[]}' > "$TMP/fx/jobs-7.json"; echo '{"jobs":[]}' > "$TMP/fx/jobs-8.json"
out="$(run)"
is "queued runs with 0 jobs" "ci-queue: jobs_in_progress=0/60 macos=0/5 queued=2 oldest_wait=10m" "$out"

# 75 live runs (3 in progress, 72 queued); every queued run is still running
# one job while another waits, so run-level status hides the running jobs.
# All 75 are counted: 3*5 + 72*1 running, 72 queued.
reset
ids=(); for ((i = 0; i < 72; i++)); do ids+=($((100 + i))); done
runs_json in_progress 1 2 3 > "$TMP/fx/runs-in_progress.json"; runs_json queued "${ids[@]}" > "$TMP/fx/runs-queued.json"
for i in 1 2 3; do jobs_json 5 0 0 "$t10" > "$TMP/fx/jobs-$i.json"; done
for id in "${ids[@]}"; do jobs_json 1 0 1 "$t10" > "$TMP/fx/jobs-$id.json"; done
out="$(run)"
is "75 runs: every running job counted" "ci-queue: jobs_in_progress=87/60 macos=0/5 queued=72 oldest_wait=10m" "$out"

# pending runs (no jobs yet) wait like queued ones
reset
runs_json in_progress > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
runs_json pending 5 6 7 > "$TMP/fx/runs-pending.json"
for id in 5 6 7; do echo '{"jobs":[]}' > "$TMP/fx/jobs-$id.json"; done
out="$(run)"
is "pending runs counted" "ci-queue: jobs_in_progress=0/60 macos=0/5 queued=3 oldest_wait=10m" "$out"

# the cap is overridable
reset
runs_json in_progress > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
out="$(CI_MAX_JOBS=20 run)"
is "CI_MAX_JOBS override" "ci-queue: jobs_in_progress=0/20 macos=0/5 queued=0 oldest_wait=0m" "$out"
out="$(CI_MAX_JOBS=abc run)"
is "non-numeric CI_MAX_JOBS -> default" "ci-queue: jobs_in_progress=0/60 macos=0/5 queued=0 oldest_wait=0m" "$out"

# a real jobs payload (verbatim from the Actions API, 2026-10-19) parses as one queued job
reset
runs_json in_progress > "$TMP/fx/runs-in_progress.json"; runs_json queued 39312674478 > "$TMP/fx/runs-queued.json"
cat > "$TMP/fx/jobs-39312674478.json" <<'EOF'
{"total_count":1,"jobs":[{"id":118267302169,"run_id":39312674478,"workflow_name":"PR Title Lint","head_branch":"fix/himmel-2053-hermes-cr-gate-parity","run_url":"https://api.github.com/repos/yotamleo-org/Himmel/actions/runs/39312674478","run_attempt":1,"node_id":"CR_kwDOS8WKNM8AAAAbiUfRGQ","head_sha":"965a4d4cf1aebd617f288d66f4fa5d284d34dc42","url":"https://api.github.com/repos/yotamleo-org/Himmel/actions/jobs/118267302169","html_url":"https://github.com/yotamleo-org/Himmel/actions/runs/39312674478/job/118267302169","status":"queued","conclusion":null,"created_at":"2026-10-19T19:41:11Z","started_at":"2026-10-19T19:41:11Z","completed_at":null,"name":"pr-title-lint","steps":[],"check_run_url":"https://api.github.com/repos/yotamleo-org/Himmel/check-runs/118267302169","labels":["ubuntu-latest"],"runner_id":0,"runner_name":"","runner_group_id":0,"runner_group_name":""}]}
EOF
out="$(run)"
case "$out" in "ci-queue: jobs_in_progress=0/60 macos=0/5 queued=1 oldest_wait="*) ok "real jobs payload" ;; *) bad "real jobs payload: $out" ;; esac

# an empty-body runs listing is not an empty queue
reset
runs_json in_progress > "$TMP/fx/runs-in_progress.json"; : > "$TMP/fx/runs-queued.json"
out="$(run)"
is "empty-body queued listing -> unknown" "ci-queue: unknown" "$out"
reset
: > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
out="$(run)"
is "empty-body in_progress listing -> unknown" "ci-queue: unknown" "$out"

# an empty-body jobs listing is not zero jobs
reset
runs_json in_progress 1 > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
: > "$TMP/fx/jobs-1.json"
out="$(run)"
is "empty-body jobs listing -> unknown" "ci-queue: unknown" "$out"

# every runs listing is paged, so a queue past 100 runs is not cut at page one
reset
runs_json in_progress > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
out="$(run)"
is "runs listings carry --paginate" "3" "$(grep -c 'actions/runs?status=.*--paginate' "$TMP/fx/calls.log")"

# a jobs page that is shorter than the run's total_count is not a full count
reset
runs_json in_progress 1 > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
echo '{"total_count":150,"jobs":[]}' > "$TMP/fx/jobs-1.json"
out="$(run)"
is "truncated jobs page -> unknown" "ci-queue: unknown" "$out"

# API error -> unknown, exit 0
reset
out="$(FAKE_GH_FAIL=1 run)"; rc=$?
is "API error -> unknown" "ci-queue: unknown" "$out"
is "API error -> rc 0" "0" "$rc"

# a per-run jobs failure (no fixture) also degrades to unknown
reset
runs_json in_progress 1 > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
out="$(run)"
is "per-run jobs failure -> unknown" "ci-queue: unknown" "$out"

# `-R` with no argument must fail fast, not spin (shift 2 fails on a lone arg)
if [ -n "$_TIMEOUT_BIN" ]; then
  "$_TIMEOUT_BIN" 5 bash "$SCRIPT" -R >/dev/null 2>&1; rc=$?
  is "-R without value exits 2" "2" "$rc"
else
  echo "skip - -R without value: no timeout binary"
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASSED"; exit 0; else echo "FAILED=$fails"; exit 1; fi
