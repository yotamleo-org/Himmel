# shellcheck shell=bash
# shellcheck disable=SC2034  # SUT is read by the suites that source this file
# launch-profile-ok-file: the claude words are fake /proc cmdline files for the tick's session census; nothing is launched
# tick-test-fixture.sh — the shared fixture of test-tick.sh and test-tick-fields.sh
# (one 490 s suite split in two so neither nears the runner's 600 s cap).
# SOURCED, never run: it makes the temp root $W and its EXIT trap, the pass/fail/contains
# helpers, the stub binaries and the hermetic env. $0 is the sourcing suite, so HERE is the
# chief-kit dir. It carries no `test-` prefix, so it is not a suite and has no tier row.
# No state outside $W: a suite that sources it never reaches the real ~/.himmel, queue or vault.
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/tick.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-test.XXXXXX")" || exit 1  # prim-ok: the suite's own private temp root, removed by the EXIT trap below
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac
}
not_contains() {
    case "$2" in *"$3"*) fail "$1 (found '$3' in '$2')" ;; *) pass "$1" ;; esac
}
skip() { printf 'skip - %s\n' "$1"; }
# shellcheck source=../../lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh"

# tmp= reads df on a tmp dir; a path that does not exist keeps the host's own /tmp out of every line.
export TICK_TMP_DIR="$W/no-such-tmp"

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/repo/scripts/lanes/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/proc" "$W/himmel-shell-suite-test.lock"

# mkcmdline <pid> <argv...> - a real NUL-separated cmdline file for a fake
# /proc/<pid>. printf writes the NULs straight to the file; a bash string
# variable cannot hold an embedded NUL, so this must not build the payload
# in a variable first.
mkcmdline() {
    local pid="$1"; shift
    mkdir -p "$W/proc/$pid"
    printf '%s\0' "$@" > "$W/proc/$pid/cmdline"
}

# mk_pgrep_x <dir> <pid...> - a `pgrep -x claude` stub returning these bare
# pids, written into <dir>/pgrep.
mk_pgrep_x() {
    local dir="$1"; shift
    mkdir -p "$dir"
    {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016  # single quotes are deliberate: $1 must
        # reach the generated stub file literally, not expand here.
        printf 'if [ "$1" = "-x" ]; then printf "%%s\\n" %s; exit 0; fi\n' "$*"
        printf 'exit 1\n'
    } > "$dir/pgrep"
    chmod +x "$dir/pgrep"
}

cat > "$W/repo/scripts/handover/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  heartbeat) exit 0 ;;
  status)
    # a held chief lock prints its owner.json (started = the shift start).
    case "$2" in *chief-fails*) printf '%s\n' '{"session":"s","host":"h","handover":"x","started":"2026-10-07T03:00:00Z","heartbeat":"2026-10-07T03:10:00Z"}' 'status: FRESH'; exit 11 ;; esac
    case "$2" in *N61*|*-N1-*|*-N2-*|*-N191-*|*-leg192-*|*-legN194-*|*odd-name*|*-N301-*|*-N302-*|*-N303-*|*-N4304b-*) printf '%s\n' 'status: FRESH'; exit 11 ;;
    *-N390-*) printf '%s\n' '{"session":"s","host":"h","handover":"x","started":"2026-10-01T00:00:00Z","heartbeat":"2026-10-01T00:00:00Z"}' 'status: STALE-DEAD (age 99999s >= ttl 21600s; owner pid gone, no live claude session names this doc)'; exit 12 ;;
    *-N380-*) printf '%s\n' 'held -- UNVERIFIED lock: /r/.locks/queue/x.lock is named for this doc but records /elsewhere/x.md, which does not resolve here'; exit 11 ;; *) printf '%s\n' free; exit 0 ;; esac ;;
esac
exit 2
STUB
cat > "$W/repo/scripts/context-fill.sh" <<'STUB'
#!/usr/bin/env bash
[ "${FILL_STALE:-0}" -eq 0 ] || exit 3
printf '%s\n' 28
STUB
# --burn shells out to the real worker-burn.sh. Stub it so the suite
# never touches ~/.claude/projects: N61 has a transcript, N66 does not.
cat > "$W/repo/scripts/lanes/worker-burn.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  HIMMEL-111-legN61)
    printf 'worker-burn x.jsonl: calls=4 avg-ctx=128.1k first-turn=74.3k out=185 compactions=2 text-only=2\n' ;;
  HIMMEL-555-N41-thing)
    printf 'worker-burn y.jsonl: calls=9 avg-ctx=90.0k first-turn=60.0k out=100 compactions=0 text-only=1\n' ;;
  HIMMEL-777-legN77)
    printf 'worker-burn s.jsonl: calls=90 avg-ctx=100.0k first-turn=32.3k out=900 compactions=2 text-only=0 cost-eq=3100.5k floor-share=9.0%%\n' ;;
  HIMMEL-888-legN88)
    printf 'worker-burn h.jsonl: calls=400 avg-ctx=106.0k first-turn=32.3k out=900 compactions=7 text-only=0 cost-eq=7689.4k floor-share=9.0%%\n' ;;
  *) printf 'worker-burn: no transcript found for session name: %s\n' "$1" >&2; exit 2 ;;
esac
STUB
cat > "$W/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in +%H:%M) printf '%s\n' 12:34 ;; *) /bin/date "$@" ;; esac
STUB

# Default primary-path table: pid 101 (a pinned sonnet worker, named in $WORKERS
# below), 102 (a pinned opus worker belonging to a DIFFERENT chief's --workers --
# procs=/models= now count only the sessions THIS chief
# dispatched, so 102 is live but must not appear in procs=/models=, only in
# ceiling= which scans every session regardless of --workers), 103 (the chief
# -- no --autocompact, exempt from drift).
# launch-guard-ok: test fixture (process cmdline stubs), nothing is launched
mkcmdline 101 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-111-legN61 work
mkcmdline 102 claude --model claude-opus-5 --autocompact 200000 -n LUNA-222-legN9 work
mkcmdline 103 claude --model claude-sonnet-5 -n HIMMEL-next-chief work
mk_pgrep_x "$W/bin" 101 102 103

cat > "$W/bin/atq" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '1 Tue job' '2 Wed job'
STUB
# `gh api -i graphql` is the gql= budget probe (ghb_read). The stub
# logs each call to STUB_GH_API_LOG, and prints STUB_GQL_OUT (a printf %b string,
# default = a healthy header set) then exits STUB_GQL_RC (default 0).
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
# `gh api rate_limit` is the rest main / rest read budget probe: not logged
# (it costs no budget), STUB_RATE_OUT for the main token, STUB_RATE_READ_OUT for the read
# token (GH_TOKEN set by gh-read.sh); empty by default, so a tick shows no rest fields.
if [ "${1:-}" = api ] && [ "${2:-}" = rate_limit ]; then
  if [ -n "${GH_TOKEN:-}" ]; then printf '%s\n' "${STUB_RATE_READ_OUT:-}"; else printf '%s\n' "${STUB_RATE_OUT:-}"; fi
  exit 0
fi
# cired= reads `gh issue list --label ci-red --state open`: STUB_CIRED_OUT (default empty = unknown), STUB_CIRED_RC exit.
# A query without the ci-red label or the open state fails the stub, so a mutated read reads unknown.
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
  case " $* " in *" --label ci-red "*) ;; *) exit 7 ;; esac
  case " $* " in *" --state open "*) ;; *) exit 7 ;; esac
  [ -z "${STUB_CIRED_RC:-}" ] || exit "$STUB_CIRED_RC"
  printf '%s\n' "${STUB_CIRED_OUT:-}"
  exit 0
fi
# dispatch= reads the in-flight workflow_dispatch runs (one TSV row per run: id, workflow
# path, head branch, head sha, started) and, per run, one jobs row (job count, completed
# count, newest job timestamp). STUB_DISPATCH_RUNS / STUB_DISPATCH_JOBS are printf %b
# strings, empty by default; every call is logged to STUB_DISPATCH_LOG, never to the gql log.
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    repos/*/actions/runs/*/jobs*) [ -z "${STUB_DISPATCH_LOG:-}" ] || printf '%s\n' "jobs $2" >> "$STUB_DISPATCH_LOG"; printf '%b' "${STUB_DISPATCH_JOBS-}"; exit 0 ;;
    repos/*/actions/runs\?*) [ -z "${STUB_DISPATCH_LOG:-}" ] || printf '%s\n' "runs $2" >> "$STUB_DISPATCH_LOG"; printf '%b' "${STUB_DISPATCH_RUNS-}"; exit "${STUB_DISPATCH_RC:-0}" ;;
  esac
fi
if [ "${1:-}" = api ]; then
  [ -z "${STUB_GH_API_LOG:-}" ] || printf '%s\n' "$*" >> "$STUB_GH_API_LOG"
  printf '%b' "${STUB_GQL_OUT-HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 4321\r\nX-Ratelimit-Reset: 1790000000\r\n\r\n}"
  exit "${STUB_GQL_RC:-0}"
fi
if [ "$PWD" != "${GH_STUB_CWD:-$REPO}" ]; then
  printf 'gh stub: expected cwd=%s, got %s\n' "${GH_STUB_CWD:-$REPO}" "$PWD" >&2
  exit 9
fi
# gh pr list --json ... --jq emits one TSV row per PR: number, head branch, isDraft,
# author login, isCrossRepository, updatedAt. STUB_PR_ROWS (a printf %b string) replaces
# the default pair of drafts, which tick.sh lists in prs= but never flags as unowned.
[ -z "${STUB_PR_SLEEP:-}" ] || sleep "$STUB_PR_SLEEP"
[ -z "${STUB_PR_FAIL:-}" ] || exit 1
printf '%b' "${STUB_PR_ROWS-2247\\tfeat/x\\ttrue\\tme\\tfalse\\t2026-01-01T00:00:00Z\\n2250\\tfeat/y\\ttrue\\tme\\tfalse\\t2026-01-01T00:00:00Z\\n}"
STUB
# orphans= reads `ps -ww -eo pid=,ppid=,etime=,args=` (orphan-loops.sh).
# Answered from $PS_FIXTURE so the suite never reads the live process table;
# any other ps argv falls through to the real ps.
cat > "$W/bin/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-eo pid=,ppid=,etime=,args=" ] || [ "$*" = "-ww -eo pid=,ppid=,etime=,args=" ]; then
  cat "$PS_FIXTURE"
  exit 0
fi
exec /bin/ps "$@"
STUB
printf '%s\n' '    1     0 40-00:00:01 /sbin/init' > "$W/ps-none.txt"
cat > "$W/bin/bun" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_BANK_ROW-claudex funded measured 5h used=12% free=88%; weekly used=34% free=66%}"
STUB
# the real ceiling-conformance.sh, not a re-implemented stub --
# it reads the same claude_sessions() table this suite already builds, so a
# worker row here is one source of truth for procs=/models=/ceiling= alike.
cp "$HERE/../../lanes/ceiling-conformance.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh"
# the shared helper both ceiling-conformance.sh and tick.sh
# source by $REPO-relative path.
cp "$HERE/../../lanes/lib/claude-sessions.sh" "$W/repo/scripts/lanes/lib/claude-sessions.sh"

# fleet=/capacity= reuse usage-preflight.sh's FLEET line. This stub
# prints the same stderr line shape (STUB_FLEET_LINE overrides it) and records
# the env tick ran it under, so the suite can pin that tick never asks it for a
# ledger row or a launch refusal.
cat > "$W/repo/scripts/lib/usage-preflight.sh" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_PF_SEEN:-}" ] || printf 'ledger=%s launch=%s\n' "${CADENCE_USAGE_LEDGER:-unset}" "${CADENCE_USAGE_LAUNCH:-unset}" > "$STUB_PF_SEEN"
printf '%s\n' "${STUB_FLEET_LINE-bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/8}" >&2
printf '%s\n' "${STUB_PF_VERDICT:-PROCEED}"
STUB

chmod +x "$W/repo/scripts/handover/queue-lock.sh" "$W/repo/scripts/context-fill.sh" "$W/repo/scripts/lanes/worker-burn.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh" "$W/repo/scripts/lib/usage-preflight.sh" "$W/bin/"*

printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"
# N61 has no PR; its description field is what --verbose prints beside the label.
# worker_description reads the tracker and forge seams: pin both off so no row reaches Jira or GitHub.
export TRACKER=none FORGE=none
doc_n61="$W/handover/HIMMEL-111-legN61.md"
doc_n65="$W/handover/HIMMEL-222-legN65.md"
printf '%s\n' '---' 'description: Add a login form' '---' '# worker' '- LIVE — working' > "$doc_n61"
printf '%s\n' '# worker' '- READY — done' > "$doc_n65"
printf '123456789\n' > "$W/handover/inbox/N61.md"
printf '1234567\n' > "$W/handover/inbox/N65.md"
printf '%s\n' 4 > "$W/handover/inbox/.cursor/N61"
printf '%s\n' 8 > "$W/handover/inbox/.cursor/N65"
printf 'pid=%s\n' "$$" > "$W/himmel-shell-suite-test.lock/owner"

export PATH="$W/bin:$PATH"
# holds.py and next-dispatchable.sh keep the holds register under $HOME/.himmel; a tick over the stub forge must not reach the real one.
export HOME="$W/home"
mkdir -p "$HOME"
export DOC="$W/handover/chief.md"
export TOKEN=test-token
export WORKERS='HIMMEL-111-legN61 HIMMEL-222-legN65'
export HANDOVER_DIR="$W/handover"
# parked= reads the trust shadow ledger; never the real ~/.claude/himmel one.
export HIMMEL_TRUST_LEDGER_DIR="$W/trust-ledger"
export REPO="$W/repo"
export TICK_TMPDIR="$W"
# no stall probe by default: a real pr-stall.sh against the stub gh would add stall=? to every line
export TICK_STALL_PROBE="$W/no-stall-probe" TICK_STALL_CACHE="$W/stall.cache"
# doctor= runs this command; the default is a missing one, never the real doctor.
export TICK_DOCTOR_CMD="$W/no-doctor" TICK_DOCTOR_CACHE="$W/doctor.cache"
# station= reads this state file; never the real ~/.himmel one.
export TICK_STATION_STATE="$W/station-sync.state"
# alert-fail= reads this marker; never the real ~/.himmel one.
export CADENCE_ALERT_SEND_FAILED_MARK="$W/cadence-alert-send-failed"
export PS_FIXTURE="$W/ps-none.txt"
export TICK_BANK_CACHE_FILE="$W/bank.json"
export NEXT_DISPATCH_MIRROR="$W/no-default-mirror"
# ciq= keeps the last tick's waiting state under here; never the real ~/.himmel.
export TICK_STATE_DIR="$W/state"
# ciguard= runs this probe; the default is a missing one (ciguard=unknown), never a live fetch.
export TICK_CIGUARD_PROBE="$W/no-ciguard-probe"
# A fixture mirror must not send a tick to live Jira: versionless-done= reads this probe (a missing
# one reads skip) and leaks= this one (empty output reads 0). Rows on those fields set their own.
# A fixture tracker render reads its parity line unavailable through a missing CLI.
export TICK_VERSIONLESS_DONE_PROBE="$W/no-vd-probe" TICK_LEAKS_PROBE=/dev/null TRACKER_JIRA="$W/no-jira-cli"
# ciguard= and orphans-wip= read a cache a detached refresh fills. Rows here refresh on every
# tick and wait for the refresh, unless a row sets its own cadence or wait.
export TICK_CIGUARD_MIN_SECS=0 TICK_ORPHANS_MIN_SECS=0 TICK_SECTION_WAIT=60
export TICK_BUS_PEERS_DIR="$W/no-bus-peers"
# fails= reads these three ledgers; never the real ~/.himmel ones.
export HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$W/leg-failures.jsonl"
export HIMMEL_EVAL_RUNS_LEDGER="$W/eval-runs.jsonl"
export HIMMEL_FAILURE_ROUTES_LOG="$W/failure-routes.log.jsonl"
# fails= ~<k> reads the digest step's skips.jsonl under this dir.
export WORKER_SESSION_DIGEST_STATE_DIR="$W/worker-digest"
printf '#!/bin/sh\necho off\n' > "$W/vmrun-probe.sh"
export HIMMEL_VMRUN_PROBE="$W/vmrun-probe.sh"
mkdir -p "$WORKER_SESSION_DIGEST_STATE_DIR"
# flakes= reads the suite-flake ledger for this repo id; never the real ~/.himmel one.
export SUITE_FLAKE_LEDGER="$W/suite-flake.jsonl"
export SUITE_FLAKE_REPO_ID=tick-test-repo
export CLAUDE_SESSIONS_PROC="$W/proc"
# launch logs live in <work-dir>/<chain>/<name>.launch.log.
export TICK_LAUNCH_DIR="$W/chief-work"
mkdir -p "$W/chief-work/chain"

# cachettl must distinguish old idle transcripts from recent activity and
# still-armed waits. Keep the transcript root private even in the full suite.
export TICK_PROJECTS_DIR="$W/projects"
mkdir -p "$TICK_PROJECTS_DIR/p"
