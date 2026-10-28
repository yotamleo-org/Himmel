#!/usr/bin/env bash
# Smoke / invariant tests for scripts/handover/arm-resume.sh
#
# Covers cwd resolution (--cwd flag, resume_cwd frontmatter, legacy
# fallback + discoverability warning). Uses --dry-run throughout so no
# real scheduler jobs are created.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# ---------------------------------------------------------------------------
# --only <section> / --list: a targeted-section filter so
# verifying one change doesn't cost the full 35-50 minute / ~380-assertion
# run. Every named section below (T1, V4, 1329, ...) is individually gated
# by `if _sec_selected "<alias>" ...; then ... fi`. Default (no flag): every
# gate sees an empty $ONLY_FILTERS and _sec_selected returns true
# unconditionally, so the full run's output/exit-code semantics are
# BYTE-IDENTICAL to before this flag existed — CI and the pre-push gate
# (which invoke this script with no args) are unaffected.
#
# --list matches the run-shell-tests.sh --list convention: print the plan,
# execute nothing. It exits before $TMP/$ARM are even touched.
#
# Some sections share setup fixtures that live outside any single section's
# gate (e.g. the multislot STATEFUL_STUB scheduler, the ARMED_STUB/STUB_BIN telemetry stubs) — those helpers are
# deliberately left UNGATED so a filtered run of a downstream section stays
# self-contained; see the ticket for the list of sections with this coupling.
# ---------------------------------------------------------------------------
ONLY_FILTERS=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --only)
            # Empty is refused like absent (panel glm-2, PR CR): "" would make
            # ONLY_FILTERS a bare newline — non-empty, so every section gate
            # deselects and the run exits 0 having tested NOTHING, the exact
            # vacuous-green shape the unknown-section validation fails closed on.
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "test-arm-resume.sh: --only requires a non-empty argument" >&2
                exit 1
            fi
            ONLY_FILTERS="${ONLY_FILTERS}${2}
"
            shift 2
            ;;
        --list)
            LIST_ONLY=1
            shift
            ;;
        *)
            echo "test-arm-resume.sh: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Canonical section plan: <listed name>|<accepted aliases>. Both --list and
# --only validation consume this table so a displayed family name cannot drift
# into a silently vacuous filter again. Keep aliases whitespace-free.
SECTION_DEFINITIONS='T1|T1
T2|T2
T3|T3
T4|T4
T5|T5
T6|T6
T7|T7
T8|T8 T8b
T9|T9 T9b T9b2 T9c T9d
T10|T10
T11|T11
T12|T12
T13|T13
T14|T14
T15|T15
T16|T16
T17|T17
T18|T18
T19|T19
T20|T20
T21|T21
T22|T22
T23|T23
T23b|T23b
T24|T24 T24c
T25|T25
T26|T26
T27|T27
T28|T28 T28d T28e
T29|T29
T30|T30
T31|T31
T32|T32
T33|T33
T33c|T33c
T38|T38
W1-W8|W1-W8 W1 W2 W3 W4 W5 W6 W7 W8 W9 W10 W11 W12 W13 W14 W15 W16 W17
T33-collision|T33-collision
T34|T34
T35|T35
T36|T36
T37|T37
N1-N8|N1-N8 N1 N2 N3 N4 N5 N6 N7 N8
S1-S5|S1-S5 S1 S2 S3 S4 S5
N9-N13|N9-N13 N9 N10 N11 N12 N13 S6 S7 S8 S9 S10 S11 S12
macOS|macOS
T-awkfail|T-awkfail
1365|1365 HIMMEL-1365
1331|1331 HIMMEL-1331
1331b|1331b
1329|1329 HIMMEL-1329
1330|1330 HIMMEL-1330
1603|1603 HIMMEL-1603
1640|1640 HIMMEL-1640
1719|1719 HIMMEL-1719
1674|1674 HIMMEL-1674
1879|1879 HIMMEL-1879 1999 HIMMEL-1999
1879-1365|1879-1365 1998 HIMMEL-1998
812|812 HIMMEL-812
2973|2973 HIMMEL-2973
1830|1830 HIMMEL-1830
1636|1636 HIMMEL-1636
2113c|2113c HIMMEL-2113
2113d|2113d HIMMEL-2113
2113e|2113e HIMMEL-2113
2113f|2113f HIMMEL-2113
2113g|2113g HIMMEL-2113
2128|2128 HIMMEL-2128
2147|2147 HIMMEL-2147
2192|2192 HIMMEL-2192
2199|2199 HIMMEL-2199
2545|2545 HIMMEL-2545
3118|3118 HIMMEL-3118'

_section_alias_known() {
    local _candidate="$1" _label _aliases _alias
    while IFS='|' read -r _label _aliases; do
        for _alias in $_aliases; do
            [ "$_candidate" = "$_alias" ] && return 0
        done
    done <<EOF
$SECTION_DEFINITIONS
EOF
    return 1
}

_list_sections() {
    local _label _aliases
    while IFS='|' read -r _label _aliases; do
        printf '%s\n' "$_label"
    done <<EOF
$SECTION_DEFINITIONS
EOF
}

if [ -n "$ONLY_FILTERS" ]; then
    while IFS= read -r _filter; do
        [ -n "$_filter" ] || continue
        if ! _section_alias_known "$_filter"; then
            echo "test-arm-resume.sh: unknown --only section: $_filter (see --list)" >&2
            exit 1
        fi
    done <<EOF
$ONLY_FILTERS
EOF
fi

# _sec_selected <alias> [<alias> ...] — true (rc 0) when this section should
# run this pass: no --only filter was given (default full run), or at least
# one of the section's own aliases exact-matches a requested --only value.
_sec_selected() {
    [ -z "$ONLY_FILTERS" ] && return 0
    local _want _f
    for _want in "$@"; do
        while IFS= read -r _f; do
            [ -n "$_f" ] || continue
            [ "$_f" = "$_want" ] && return 0
        done <<EOF
$ONLY_FILTERS
EOF
    done
    return 1
}

if [ "$LIST_ONLY" -eq 1 ]; then
    _list_sections
    exit 0
fi

ARM="$(cd "$(dirname "$0")" && pwd)/arm-resume.sh"
[ -x "$ARM" ] || chmod +x "$ARM"

# Under TMPDIR, never a template-less mktemp -d: macOS puts that in /var/folders,
# outside the suite temp root, so the flow-run ledger quarantines its rows.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/arm-resume.XXXXXX") || exit 1
# macOS: mktemp yields /var/folders/... but arm-resume resolves the real path
# (/private/var/...); canonicalise so path assertions compare like with like.
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
# No .git under it, so the default worktree isolation never fires outside W9-W17.
mkdir -p "$TMP/no-primary"
export ARM_ISOLATION_ROOT="$TMP/no-primary"
# The policy dir comes from the account entry; this seam points it back at HOME.
export HIMMEL_POLICY_FOLLOWS_HOME=1
# any case below that fails to stub crontab/at must not be able
# to silently touch the operator's REAL scheduler. Snapshot now, before any
# case runs, and diff again right before the summary -- a change either way
# fails the suite outright, regardless of --only. Under run-shell-tests.sh the
# snapshot reads past the runner's recording shim (HIMMEL_SUITE_SHIM_DIR): the
# shim sees only PATH lookups, this diff also sees an absolute or reset-PATH one.
SCHED_REAL_PATH=":$PATH:"
[ -z "${HIMMEL_SUITE_SHIM_DIR:-}" ] || SCHED_REAL_PATH="${SCHED_REAL_PATH//":$HIMMEL_SUITE_SHIM_DIR:"/:}"
SCHED_REAL_PATH="${SCHED_REAL_PATH#:}"
SCHED_REAL_PATH="${SCHED_REAL_PATH%:}"
CRONTAB_SNAPSHOT_BEFORE=$(PATH="$SCHED_REAL_PATH" crontab -l 2>/dev/null || true)
ATQ_SNAPSHOT_BEFORE=$(PATH="$SCHED_REAL_PATH" atq 2>/dev/null || true)
# A dry-run arm lists already-armed jobs with `atq`; an empty queue keeps cases
# without their own scheduler stub off the operator's real one.
mkdir -p "$TMP/empty-atq-bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/empty-atq-bin/atq"
chmod +x "$TMP/empty-atq-bin/atq"
export PATH="$TMP/empty-atq-bin:$PATH"
# every non-dry-run arm reserves a FLEET_CAP slot; redirect it off
# the production dir the live fleet counts, and fail the suite if it could leak.
# This file is also the body of test-arm-resume-fast.sh / -1879.sh (`--only`).
. "$(dirname "$ARM")/../lib/fleet-slots-shield.sh"
fleet_slots_shield "$TMP" || exit 1
# real crontab arms create the arm log dir and probe the log
# FILE for append; keep that under the suite's TMP, not the operator's
# real ~/.himmel/arm-resume. Real crontab/macOS arms also now write a
# generated runner file (fold of Goomal's fix/arm-resume-macos-cron) under
# ARM_RUNNER_DIR -- default that under $TMP too, for the same reason.
export ARM_RESUME_LOG_DIR="$TMP/arm-logs"
export ARM_RUNNER_DIR="$TMP/arm-runners"
# a non-dry-run arm runs the REAL bank-preflight, whose producer
# refresh writes the usage cache; keep both cache knobs off the live
# /tmp/claude/statusline-usage-cache.json (checked again before the summary).
export CADENCE_USAGE_CACHE="$TMP/bank-cache.json" CLAUDE_USAGE_CACHE="$TMP/bank-cache.json"
# the real producer only writes the cache when a live OAuth fetch
# succeeds, so "the scratch cache file exists" was host- and network-dependent.
# A stub producer records the cache path each refresh was handed instead: the
# end-of-run row asserts a real refresh ran AND none was aimed at the live cache.
BANK_PRODUCER_LOG="$TMP/bank-producer.log"
: > "$BANK_PRODUCER_LOG"
export CADENCE_USAGE_PRODUCER="$TMP/bank-producer-stub.sh"
# shellcheck disable=SC2016 # $CLAUDE_USAGE_CACHE must expand in the stub, not here
printf '#!/bin/bash\nprintf "%%s\\n" "$CLAUDE_USAGE_CACHE" >> "%s"\n' "$BANK_PRODUCER_LOG" > "$CADENCE_USAGE_PRODUCER"
# Default: no other HIMMEL-* scheduled task, so the operator's real crontab
# entries (same-minute fixtures -> rc=6) cannot decide a case. Cases testing the
# collision path set the seam inline, which overrides this.
export ARM_COLLISION_CANDIDATES=""

# hermetic identity so every raw usage-cache fixture below can
# stamp a matching account hash — resume-slot.sh now refuses (rc=2) a cache
# whose .account doesn't match the current session, and CLAUDE_ACCOUNT_CONFIG
# overrides current_account_hash's HOME lookup regardless of which g_env/
# mac_env/posix_env HOME override a given section below applies.
export CLAUDE_ACCOUNT_CONFIG="$TMP/claude-account.json"
printf '%s' '{"oauthAccount":{"accountUuid":"uuid-arm-resume-test"}}' > "$CLAUDE_ACCOUNT_CONFIG"
# shellcheck source=../lib/usage-cache-identity.sh
. "$(dirname "$ARM")/../lib/usage-cache-identity.sh"
ACCT="$(current_account_hash)"

# macOS (crontab) arms REFUSE rc=2 when `claude`
# does not resolve on PATH at arm time, and the nightly macOS runners
# have no claude installed -- so nearly every section below fails there. When
# the host has none, put a no-op stub first on PATH for the whole suite (a
# section that builds its own stub PATH still prepends to this one). A host
# that has claude is left untouched, so dev machines run exactly as before.
if ! command -v claude >/dev/null 2>&1; then
    mkdir -p "$TMP/no-claude-host-stub"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TMP/no-claude-host-stub/claude"
    chmod +x "$TMP/no-claude-host-stub/claude"
    export PATH="$TMP/no-claude-host-stub:$PATH"
fi
# the sections below drive the at/atq backend with stubs (`at -t`
# stamps, atq dedup, at job bodies). arm-resume.sh dispatches on OSTYPE, and on
# macOS that is the crontab backend -- so every at-shaped assertion fails there.
# Pin the linux (at) branch for this suite on a darwin host; the macOS crontab
# branch has its own suite (test-arm-resume-cron.sh). A section that passes
# OSTYPE per invocation still overrides this.
case "${OSTYPE:-}" in
    darwin*) export OSTYPE=linux-gnu ;;
esac

# Fleet-census shield: all real arms use scheduler stubs, so
# the host's live session count must not refuse them at the fleet preflight.
# Match test-arm-resume-queue-lock.sh's empty process-table fixture.
FLEET_PS_STUB="$TMP/no-fleet-ps.sh"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FLEET_PS_STUB"
chmod +x "$FLEET_PS_STUB"
export FLEET_PS_CMD="$FLEET_PS_STUB"

# Global telemetry shield: arm-resume emits to
# ~/.claude/telemetry/skill-usage.jsonl by default, so without a
# suite-level override every invocation below individually relies on
# --dry-run / a per-test SKILL_TELEMETRY_DIR / the kill switch / stubs
# to avoid polluting the operator's real sink. Default the sink to a
# throwaway under $TMP; telemetry tests (T21-T24) override per-call
# with their own sinks as before.
export SKILL_TELEMETRY_DIR="$TMP/telemetry-default"
# Unset the kill switch so T21/T23 (which assert a record IS written) are
# not spuriously broken by an operator shell that exports it.
unset SKILL_TELEMETRY_DISABLE 2>/dev/null || true
# Naming-template shield: an operator shell exporting a custom
# ARM_NAME_TEMPLATE would skew every derived-name assertion below (N/S cases);
# S8/S9 set it per-call.
unset ARM_NAME_TEMPLATE 2>/dev/null || true
# Slot-threshold shield: the --time smart cases assert against
# the SHIPPED default wall, and an operator shell exporting
# RESUME_SLOT_THRESHOLD reaches resume-slot.sh through this script. T9c sets
# it per-call.
unset RESUME_SLOT_THRESHOLD 2>/dev/null || true
# CR-floor-fallback advisory shield: 2128b/2128b2 assert on
# whether the pre-arm WARN fires for CR_REQUIRE_CROSS_MODEL/CR_FLOOR_FALLBACK;
# an operator shell exporting either would make those assertions depend on
# ambient state instead of the per-call value each case sets.
unset CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK 2>/dev/null || true
# Worker-census shield: arm-resume's live-lane-worker guard
# (rc=10) censuses reconcile-workers.sh's bridge root — default
# ~/.claude/handover/bridge — so a REAL live or unprobeable GLM/claudex worker
# meta on the MACHINE turns every non-dry-run arm below into a spurious rc=10
# (observed 2026-08-08: 27 FAILs across T25b–W8 in a gate run that overlapped
# live lane dispatches; the window closed mid-run and later sections passed).
# Point the census at an isolated, empty root under $TMP. Scope note: the
# telegram-bridge tests (T13–T19) drive supervisor.pid detection via per-call
# BRIDGE_ROOT / BRIDGE_PIDFILE, which the census does NOT read when
# WORKER_BRIDGE_ROOT is set (reconcile-workers.sh resolution:
# WORKER_BRIDGE_ROOT > BRIDGE_ROOT > default), so this shield cannot leak
# into their bridge-detection assertions.
export WORKER_BRIDGE_ROOT="$TMP/worker-bridge-shield"
# Global workspace-trust shield: arm-resume now pre-trusts the
# resolved cwd in ~/.claude.json. The non-dry-run arm cases below (T14-T20
# bridge/channel checks, dedup-any) would otherwise write the operator's real
# config — redirect the pre-seed at a throwaway file for the whole suite.
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
# Temp-target shield: every fixture in this suite lives under
# $TMP (WORK_REPO="$TMP/work-repo"), which is precisely the shape arm-resume
# now refuses — a real scheduled task pointing at a throwaway directory. This
# suite means it: its scheduler is PATH-stubbed, so no real task is ever
# created. Declaring the opt-out here, alongside the other shields, keeps that
# intent explicit rather than letting a heuristic silently exempt us. The
# refusal itself is exercised below with the variable unset.
export ARM_TEMP_CWD_OK=1

# Dotenv-read shield. arm-resume load_dotenv's ARMAUTOMERGE /
# CR_REQUIRE_CROSS_MODEL / CR_FLOOR_FALLBACK out of a `.env` FILE, falling back
# to the PRIMARY checkout when the candidate root has none -- so the `unset`s
# above are NOT enough on their own: a host whose own .env carries the
# ARMAUTOMERGE=1 default re-fills the key from disk, and every
# "a default arm does not GRANT ARMAUTOMERGE" assertion below (T33b, T33c, and
# CR_MERGE_GATE_OK=1 ` prefix the moment the default applies) fails on exactly
# the hosts that adopted the feature and passes everywhere else. The shield
# must therefore defeat a FILE READ, not an env var. ARM_RESUME_DOTENV_ROOT
# points that read at a suite-owned directory: EMPTY by default, so every key
# is genuinely absent; the 2128/2147 cases below write a `.env` into it to
# drive the value they are actually testing.
export ARM_RESUME_DOTENV_ROOT="$TMP/dotenv-shield"
mkdir -p "$ARM_RESUME_DOTENV_ROOT"
# Defense-in-depth against ambient PROCESS env, which wins over any .env via
# load_dotenv's non-clobber contract before the file is ever consulted.
unset ARMAUTOMERGE CR_MERGE_GATE_OK 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label — output unexpectedly contains: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

FAILED=0

# ---------------------------------------------------------------------------
# Fixture setup
# ---------------------------------------------------------------------------
# A directory to use as a "valid work repo" that is a git repo (so
# the legacy fallback also has something to resolve to).
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

# A separate directory for handover files (simulates the state repo).
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"

# A NEAR future time (HH:MM, <=60 min out) so the long-gap guard
# stays silent for every fixture below that just needs a valid future HH:MM.
# Tests that deliberately arm FAR — T8 tomorrow-roll, T28d seeds, T33-T36/N6
# collision probes, the macOS multislot sibling — carry their own far times
# + --long-gap.
#
# (suite shelf life): this used to be computed ONCE, justified by
# "a hermetic shell suite finishes well inside the 30-min window". That is no
# longer true — the suite takes 35-50 minutes on the overlord8 box. Every test
# reached after minute 30 therefore asked for a time already in the PAST,
# arm-resume rolled it to TOMORROW (~23.5h out), and the long-gap guard
# refused with rc=9. Observed 2026-08-06: 14 failures across V3/V4/V4b/V5/V6/V6c,
# all "expected rc=N, got rc=9", none of them a real defect. The suite had
# outlived its own fixture.
#
# So: recompute on demand, but CACHE. The naive fix (a fresh timestamp at every
# one of the 118 call sites) would break the identity/verify tests, which arm
# and then re-arm or post-verify and compare the requested time against the
# scheduler's NextRunTime inside a 120s tolerance -- a minute rolling over
# between those two calls is exactly the mismatch they are written to detect.
# Caching keeps the value STABLE across the calls within a test and refreshes
# only when the target is about to go stale.
#
# The cache lives in a FILE, not in shell variables (panel r3 codex-1). Every
# one of the 118 call sites spells this `$(future_time)`, and a command
# substitution runs in a SUBSHELL: variables the function assigns die with it,
# so a variable-backed cache was write-only and each call silently recomputed
# from scratch. That is not cosmetic — V4b feeds one call's HH:MM into the
# expected epoch and another's into the arm, so a minute rolling between them
# shifted the requested target 60s and turned its deliberate 121s mistime into
# a 61s one, inside the tolerance: the case would have gone red for a fixture
# reason, intermittently, on exactly the boundary is settling. A
# file survives the subshell, so the cache the comment above describes is now
# the cache that actually runs.
_FT_FILE="$TMP/future-time.cache"      # "<target-epoch> <HH:MM>"
_FT_STALE_FILE="$TMP/future-time.stale"
future_time() {
    local _now _target _value
    _now=$(date +%s)
    _target=0; _value=""
    [ -s "$_FT_FILE" ] && read -r _target _value < "$_FT_FILE"
    # Refresh when unset, or when fewer than 10 minutes remain before the
    # cached target -- comfortably before it can expire mid-test, and far
    # enough from the 60-min long-gap ceiling to stay silent.
    if [ -z "$_value" ] || [ "$(( _target - _now ))" -lt 600 ]; then
        # Latch BEFORE overwriting: a target found already past is the only
        # evidence the run outlived its fixture, and the refresh erases it.
        # The teardown WARN reads this marker.
        if [ -n "$_value" ] && [ "$_now" -ge "$_target" ]; then : > "$_FT_STALE_FILE"; fi
        _target=$(( _now + 1800 ))
        _value=$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).strftime('%H:%M'))" "$_target")
        printf '%s %s\n' "$_target" "$_value" > "$_FT_FILE"
    fi
    printf '%s' "$_value"
}
# Crossing midnight needs no special case: at 23:45 this yields "00:15", which
# arm-resume reads as past-for-today and rolls to the next calendar day --
# 30 minutes out from 23:45, the intended lead, not a 24h one.

# ---------------------------------------------------------------------------
# Helper: write a minimal handover file and return its path via stdout.
# Usage: make_handover [resume_cwd_value_or_empty]
# ---------------------------------------------------------------------------
make_handover() {
    local cwd_val="${1:-}"
    local path="$HANDOVER_DIR/handover-$RANDOM.md"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        [ -n "$cwd_val" ] && printf 'resume_cwd: %s\n' "$cwd_val"
        printf -- '---\n'
        printf '# Test handover\n'
    } > "$path"
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# _freeze_now <Y> <M> <D> <H> <Mi> <S>: writes a sitecustomize.py
# that pins python3's datetime.datetime.now()/.now(tz) to exactly this local
# instant, and echoes a dir to put on PYTHONPATH. `site` auto-imports
# sitecustomize at interpreter start, even under `python3 -c`, so putting this
# dir on PYTHONPATH for BOTH this suite's own "past"/"tomorrow" one-liners AND
# the `bash "$ARM"` invocation they bracket makes every datetime.now() read in
# between see the SAME instant. Without it, each is an independent real-clock
# read: the suite computes an input (or an expected date) at one instant,
# arm-resume computes its own --time roll at a slightly later one, and a real
# clock tick between them (near-guaranteed if the pair straddles UTC
# midnight) makes the two disagree on which day it is -- class,
# for the T8/T_1674 fixtures instead of the 2177 one. A caller that never sets
# PYTHONPATH (production, or any other test) sees the real clock; arm-resume.sh
# itself never sets or reads PYTHONPATH, so this changes no shipped behaviour.
# ---------------------------------------------------------------------------
_freeze_now() {
    local y="$1" mo="$2" d="$3" h="$4" mi="$5" s="$6" dir
    dir=$(mktemp -d "$TMP/freeze-clock.XXXXXX") || {
        echo "_freeze_now: mktemp -d failed -- refusing to silently fall back to the real clock" >&2
        exit 1
    }
    cat > "$dir/sitecustomize.py" <<EOF || { echo "_freeze_now: failed to write $dir/sitecustomize.py" >&2; exit 1; }
import datetime as _dt
_real = _dt.datetime
class _Frozen(_real):
    @classmethod
    def now(cls, tz=None):
        fixed = _real($y, $mo, $d, $h, $mi, $s)
        return fixed.astimezone(tz) if tz is not None else fixed
_dt.datetime = _Frozen
EOF
    printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# Helper: a TICKET-BEARING handover, dedicated + separate from
# make_handover so the dedup/collision/multislot suite stays ticketless.
#   $1 = H1 title text, $2 = optional 'ticket:' frontmatter value,
#   $3 = optional body line (printed AFTER the closing --- and H1 — i.e. body,
#        not frontmatter — so N5 can mention a ticket key OUTSIDE the H1 scan).
# ---------------------------------------------------------------------------
make_handover_titled() {
    local path="$HANDOVER_DIR/ho-titled-$RANDOM.md"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        [ -n "${2:-}" ] && printf 'ticket: %s\n' "$2"
        printf -- '---\n'
        printf '# %s\n' "$1"
        [ -n "${3:-}" ] && printf '%s\n' "$3"
    } > "$path"
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Scheduler stub for T1-T7: these tests use --dry-run to probe
# cwd-resolution logic and never intend to touch the real scheduler. Without
# a stub, list_existing() calls the real atq on a machine that may
# have a live HIMMEL-Resume job, causing rc=3 (dedup block) and spurious
# failures. Reuse the same empty-scheduler stub pattern as T23.
# ---------------------------------------------------------------------------
SCHED_STUB_T17="$TMP/sched-stub-t17"
mkdir -p "$SCHED_STUB_T17"
# /create REGISTERS what it was given, /query reports it back. The
# old stateless "always exit 0, never list anything" fake is internally
# inconsistent, and the post-arm EXISTENCE verify reads it (correctly) as a
# create that armed nothing -> rc 2 on every non-dry-run arm through this stub
# (W5, W8). Same treatment ARMED_STUB gets below; own state file so the two
# cannot see each other's tasks, and it still starts EMPTY.
# the POSIX backend must also report the jobs it accepted.
# Match ARMED_STUB's stateful at pair; an empty atq after create correctly
# refuses at arm-resume.sh's post-arm existence verify (W5/W8 on Linux).
cat > "$SCHED_STUB_T17/atq" <<EOF
#!/usr/bin/env bash
d="$TMP/sched-stub-t17.atdir"; [ -d "\$d" ] || exit 0
for f in "\$d"/job-*; do
    [ -f "\$f" ] || continue
    printf '%s\\tThu Jun 11 09:00:00 2026 a user\\n' "\${f##*/job-}"
done
exit 0
EOF
cat > "$SCHED_STUB_T17/at" <<EOF
#!/usr/bin/env bash
d="$TMP/sched-stub-t17.atdir"; mkdir -p "\$d"
case "\${1:-}" in
    -c) cat "\$d/job-\${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=\$(cat "\$d/.counter" 2>/dev/null || echo 0); n=\$((n + 1))
        printf '%s' "\$n" > "\$d/.counter"
        cat > "\$d/job-\$n"
        exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
cat > "$SCHED_STUB_T17/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe "unavailable" -> arm-resume's verify fail-opens (WARN, arm stands).
# Faking a NextRunTime here would need the requested TARGET_EPOCH, which the
# stub can't know; the fail-open path is the honest fake for tests that
# exercise dedup/worktree/naming, not the verify feature itself.
exit 1
EOF
chmod +x "$SCHED_STUB_T17/atq" "$SCHED_STUB_T17/at" "$SCHED_STUB_T17/powershell"

# ---------------------------------------------------------------------------
# T1: --cwd <dir> overrides everything, even when resume_cwd is set
# ---------------------------------------------------------------------------
if _sec_selected "T1"; then
out=$(bash "$ARM" --wsl-distro ubuntu --dry-run 2>&1)
rc=$?
assert_rc "T1 removed WSL flag is refused" 1 "$rc"
assert_contains "T1 removed WSL flag is unknown" "unknown arg: --wsl-distro" "$out"
out=$(OSTYPE=msys PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --list-temp-arms 2>&1)
rc=$?
assert_rc "T1 temp-arm sweep refuses an unsupported platform" 2 "$rc"
assert_contains "T1 temp-arm sweep names unsupported platform" "unsupported platform" "$out"
assert_not_contains "T1 unsupported sweep never reports clean" "none — no armed resume entry" "$out"
HO=$(make_handover "$HANDOVER_DIR")   # resume_cwd set to $HANDOVER_DIR itself
# $WORK_REPO is the explicit --cwd; it should win.
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --cwd "$WORK_REPO" --dry-run 2>&1)
rc=$?
assert_rc "T1 --cwd flag exits 0" 0 "$rc"
assert_contains "T1 RESUME_CWD matches --cwd arg" "RESUME_CWD=$WORK_REPO" "$out"
assert_not_contains "T1 --cwd does not resolve to statedocs" "RESUME_CWD=$HANDOVER_DIR" "$out"
# the arm pre-trusts the resolved cwd (dry-run reports, doesn't mutate).
assert_contains "T1 dry-run pre-trusts resolved cwd" "would pre-trust workspace '$WORK_REPO'" "$out"
fi

# ---------------------------------------------------------------------------
# T2: handover WITH resume_cwd pointing to a valid dir, NO --cwd
#     → resolved cwd is that dir
# ---------------------------------------------------------------------------
if _sec_selected "T2"; then
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T2 resume_cwd frontmatter exits 0" 0 "$rc"
assert_contains "T2 RESUME_CWD matches frontmatter value" "RESUME_CWD=$WORK_REPO" "$out"
# Must NOT emit the discoverability warning (resume_cwd was found).
assert_not_contains "T2 no discoverability warning when resume_cwd set" "no --cwd and no 'resume_cwd:'" "$out"
fi

# ---------------------------------------------------------------------------
# T3: handover with resume_cwd pointing to a NON-EXISTENT dir, no --cwd
#     → emits WARN and falls back (cwd != the bogus path)
# ---------------------------------------------------------------------------
if _sec_selected "T3"; then
BOGUS="$TMP/does-not-exist-$(date +%s)"
HO=$(make_handover "$BOGUS")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T3 bad resume_cwd still exits 0 (warn+fallback)" 0 "$rc"
assert_contains "T3 emits WARN for bad resume_cwd" "WARN arm-resume: handover resume_cwd:" "$out"
assert_not_contains "T3 RESUME_CWD is not the bogus path" "RESUME_CWD=$BOGUS" "$out"
# resume_cwd was present (just invalid) — must NOT emit the "no resume_cwd" discoverability WARN.
assert_not_contains "T3 no spurious discoverability warning when key was present" "no --cwd and no 'resume_cwd:'" "$out"
fi

# ---------------------------------------------------------------------------
# T4: handover with NO resume_cwd, no --cwd
#     → falls back to git-toplevel / handover dir AND emits discoverability warning
# ---------------------------------------------------------------------------
if _sec_selected "T4"; then
HO=$(make_handover "")   # no resume_cwd line
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T4 no-cwd fallback exits 0" 0 "$rc"
assert_contains "T4 emits discoverability warning" "no --cwd and no 'resume_cwd:' in handover frontmatter" "$out"
# RESUME_CWD should resolve to the git toplevel of $TMP/statedocs.
# Compute the expected value the same way arm-resume does (git rev-parse).
EXPECTED_T4=$(git -C "$TMP/statedocs" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$TMP/statedocs")
assert_contains "T4 RESUME_CWD resolves to statedocs git-toplevel" "RESUME_CWD=$EXPECTED_T4" "$out"
fi

# ---------------------------------------------------------------------------
# T5: resume_cwd value with surrounding double quotes is handled correctly
# ---------------------------------------------------------------------------
if _sec_selected "T5"; then
HO_QUOTED="$HANDOVER_DIR/handover-quoted-$RANDOM.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf 'resume_cwd: "%s"\n' "$WORK_REPO"
    printf -- '---\n'
    printf '# Test handover\n'
} > "$HO_QUOTED"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_QUOTED" --dry-run 2>&1)
rc=$?
assert_rc "T5 double-quoted resume_cwd exits 0" 0 "$rc"
assert_contains "T5 double-quoted resume_cwd resolves correctly" "RESUME_CWD=$WORK_REPO" "$out"
fi

# ---------------------------------------------------------------------------
# T6: resume_cwd value with surrounding single quotes is handled correctly
# ---------------------------------------------------------------------------
if _sec_selected "T6"; then
HO_SQ="$HANDOVER_DIR/handover-sq-$RANDOM.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf "resume_cwd: '%s'\n" "$WORK_REPO"
    printf -- '---\n'
    printf '# Test handover\n'
} > "$HO_SQ"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_SQ" --dry-run 2>&1)
rc=$?
assert_rc "T6 single-quoted resume_cwd exits 0" 0 "$rc"
assert_contains "T6 single-quoted resume_cwd resolves correctly" "RESUME_CWD=$WORK_REPO" "$out"
fi

# ---------------------------------------------------------------------------
# T7: CRLF + double-quoted resume_cwd regression guard
#     Fixture uses \r\n line endings and `resume_cwd: "<validdir>"`.
#     Old code: quote-strip before rtrim → `\r` prevents `%\"` match →
#     rtrim leaves trailing quote → `[ -d ]` fails → wrong-repo fallback.
#     New code: rtrim first → \r gone → quote-strip works → resolves correctly.
# ---------------------------------------------------------------------------
if _sec_selected "T7"; then
HO_CRLF="$HANDOVER_DIR/handover-crlf-$RANDOM.md"
# Write every line with explicit CRLF (\r\n) to simulate Windows-authored YAML.
printf -- '---\r\nsession_kind: test\r\nresume_cwd: "%s"\r\n---\r\n# CRLF test handover\r\n' \
    "$WORK_REPO" > "$HO_CRLF"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_CRLF" --dry-run 2>&1)
rc=$?
assert_rc "T7 CRLF+quoted resume_cwd exits 0" 0 "$rc"
assert_contains "T7 CRLF+quoted resume_cwd resolves correctly" "RESUME_CWD=$WORK_REPO" "$out"
# Must NOT contain a trailing quote in the resolved path.
assert_not_contains "T7 no trailing quote in RESUME_CWD" "RESUME_CWD=${WORK_REPO}\"" "$out"
# Must NOT fall back to the discoverability warning (resume_cwd WAS present).
assert_not_contains "T7 no discoverability warning for CRLF handover" "no --cwd and no 'resume_cwd:'" "$out"
fi

# ---------------------------------------------------------------------------
# T8: a past --time HH:MM rolls the scheduled DATE to tomorrow.
#     --force --dry-run
#     isolates from the live-scheduler dedup so this is deterministic.
# ---------------------------------------------------------------------------
if _sec_selected "T8"; then
HO=$(make_handover "$WORK_REPO")
# freeze ONE instant deliberately at 23:59:59 and feed it to
# every datetime.now() read below (ours and arm-resume's own via PYTHONPATH),
# so PAST_HHMM's "2 minutes ago" and the arm's own roll-to-tomorrow decision
# always land on the SAME day the assertions expect -- regardless of the real
# wall clock, and regression-testing the exact midnight boundary every run.
T8_FREEZE=$(_freeze_now 2026 9 22 23 59 59) || exit 1
PAST_HHMM=$(PYTHONPATH="$T8_FREEZE" python3 -c 'import datetime; print((datetime.datetime.now()-datetime.timedelta(minutes=2)).strftime("%H:%M"))')
# host `at` must not be a dependency; pin the posix backend with the stub.
out=$(PYTHONPATH="$T8_FREEZE" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$PAST_HHMM" --handover "$HO" --long-gap --force --dry-run 2>&1)
rc=$?
assert_rc "T8 past --time exits 0 (force+dry)" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)
        TOM=$(PYTHONPATH="$T8_FREEZE" python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(days=1)).strftime("%Y%m%d"))')
        assert_contains "T8 at -t stamp is tomorrow" "at -t $TOM" "$out"
        ;;
esac
fi

# ---------------------------------------------------------------------------
# T9: --time smart end-to-end through arm-resume. A bank-free
#     fixture cache (injected via RESUME_SLOT_CACHE) must resolve to an ASAP
#     slot and flow a concrete date into the scheduler line. SLOT_MAX_AGE=0
#     skips the freshness guard; --force --dry-run isolates from the live
#     scheduler dedup and touches nothing.
#
# ARM_COLLISION_CANDIDATES="" on every call in this section
# pins check_collision's exact-minute check to an empty set.
# Without it, check_collision shells out to the REAL `crontab -l` on Linux
# (its only fail-safe test seam), so the "smart" slot -- whose HH:MM tracks
# this station's real wall clock via SEVEN_RESET -- can exact-match one of
# this station's own scheduled HIMMEL-* cadence jobs (several cluster in the
# UTC 00:00-06:40 band) and HARD-REFUSE (rc=6). T9b2 is the only case here
# that asserts rc=0 without --force, so it was the only one able to surface
# the flake; the others silently demoted an exact hit to a WARN via --force.
if _sec_selected "T9" "T9b" "T9b2" "T9c" "T9d"; then
HO=$(make_handover "$WORK_REPO")
SLOT_CACHE="$TMP/usage-free.json"
FIVE_RESET=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')
SEVEN_RESET=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')
printf '{"five_hour":{"utilization":0.0,"resets_at":"%s"},"seven_day":{"utilization":15.0,"resets_at":"%s"},"account":"%s"}' \
    "$FIVE_RESET" "$SEVEN_RESET" "$ACCT" > "$SLOT_CACHE"
# host `at` must not be a dependency; pin the posix backend with the stub.
out=$(ARM_COLLISION_CANDIDATES="" RESUME_SLOT_CACHE="$SLOT_CACHE" SLOT_MAX_AGE=0 PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T9 --time smart exits 0 (force+dry)" 0 "$rc"
assert_contains "T9 smart banner shows bank-free ASAP" "smart -> " "$out"
assert_contains "T9 smart reason is bank free" "bank free" "$out"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)
        assert_contains "T9 smart flows an at -t stamp" "at -t " "$out" ;;
esac

# ---------------------------------------------------------------------------
# T9b/T9c: RESUME_SLOT_THRESHOLD reaches resume-slot.sh THROUGH arm-resume
# arm-resume deliberately does not forward a --threshold
#     flag — the child process inherits the environment — so this is the
#     end-to-end proof of that contract. One 95% seven_day fixture: EXHAUSTED
#     under the shipped 90 default (park at the reset), HEADROOM under an
#     operator-set 97 (ASAP).
#
# a 6-day-out seven-day-reset park now refuses FAST
# (rc=19) instead of silently arming into it -- exactly the incident shape
# (a multi-hour/day park chosen silently deep inside a slow script). --force
# alone does NOT override this (it only sanctions the shipped-work preflight);
# --long-gap is the dedicated override, reusing the explicit-HH:MM long-gap
# guard's own flag/semantics.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
BUSY_CACHE="$TMP/usage-95.json"
printf '{"five_hour":{"utilization":10.0,"resets_at":"%s"},"seven_day":{"utilization":95.0,"resets_at":"%s"},"account":"%s"}' \
    "$FIVE_RESET" "$SEVEN_RESET" "$ACCT" > "$BUSY_CACHE"
out=$(ARM_COLLISION_CANDIDATES="" RESUME_SLOT_CACHE="$BUSY_CACHE" SLOT_MAX_AGE=0 PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T9b default-wall park refuses fast (rc=19, HIMMEL-2113)" 19 "$rc"
assert_contains "T9b ERR names the park time + reason" "wait for seven-day reset" "$out"
assert_contains "T9b ERR names the --long-gap override" "--long-gap" "$out"

HO=$(make_handover "$WORK_REPO")
out=$(ARM_COLLISION_CANDIDATES="" RESUME_SLOT_CACHE="$BUSY_CACHE" SLOT_MAX_AGE=0 PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO" --force --long-gap --dry-run 2>&1)
rc=$?
assert_rc "T9b1 --long-gap overrides the park refusal (rc=0)" 0 "$rc"
assert_contains "T9b1 95% is exhausted under the shipped 90 default" "wait for seven-day reset" "$out"

# T9b2 (review fix): the OTHER rc=19 exemption -- ARM_RESUME_SAFETY_ARM=1 alone,
# with NEITHER --long-gap NOR --force, must also arm cleanly. This is the
# auto-arm-on-cap.sh/spawn-glm cap-respawn shape: those automated
# callers set ARM_RESUME_SAFETY_ARM=1 in their child env and cannot pass
# --long-gap, so a future edit that dropped this exemption from the rc=19
# guard (while keeping it on rc=9) would silently strand them parked.
HO=$(make_handover "$WORK_REPO")
out=$(ARM_COLLISION_CANDIDATES="" ARM_RESUME_SAFETY_ARM=1 RESUME_SLOT_CACHE="$BUSY_CACHE" SLOT_MAX_AGE=0 PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T9b2 ARM_RESUME_SAFETY_ARM=1 exempts the park refusal, no --long-gap/--force (rc=0)" 0 "$rc"
assert_contains "T9b2 95% is exhausted under the shipped 90 default" "wait for seven-day reset" "$out"

HO=$(make_handover "$WORK_REPO")
out=$(ARM_COLLISION_CANDIDATES="" RESUME_SLOT_THRESHOLD=97 RESUME_SLOT_CACHE="$BUSY_CACHE" SLOT_MAX_AGE=0 PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T9c env-97 wall exits 0" 0 "$rc"
assert_contains "T9c RESUME_SLOT_THRESHOLD=97 reaches the child -> ASAP" "bank free" "$out"
assert_contains "T9c child applied the env threshold, not 90" "< 97%" "$out"

# T9d: the 2026-08-19 19:37 shape — 96% weekly under an
# operator-raised 97 threshold resolves ASAP (correct by the rule), but the
# child's near-wall WARN must REACH the operator through arm-resume. A
# successful resolve used to discard the child's stderr, so the warning was
# silent exactly when it mattered.
HO=$(make_handover "$WORK_REPO")
NEAR_CACHE="$TMP/usage-96.json"
printf '{"five_hour":{"utilization":6.0,"resets_at":"%s"},"seven_day":{"utilization":96.0,"resets_at":"%s"},"account":"%s"}'     "$FIVE_RESET" "$SEVEN_RESET" "$ACCT" > "$NEAR_CACHE"
out=$(ARM_COLLISION_CANDIDATES="" RESUME_SLOT_THRESHOLD=97 RESUME_SLOT_CACHE="$NEAR_CACHE" SLOT_MAX_AGE=0 PATH="$SCHED_STUB_T17:$PATH"     bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T9d 96% under env-97 still arms ASAP (rc 0)" 0 "$rc"
assert_contains "T9d slot is ASAP by the rule" "bank free" "$out"
assert_contains "T9d the child's near-wall WARN is relayed by arm-resume" "WARN resume-slot: seven-day=96%" "$out"
fi

# ---------------------------------------------------------------------------
# T10: --time smart with an exhausted-but-null-reset cache fails loud (rc 1
#      from arm-resume, surfacing resume-slot's rc 2) — never arms a bad job.
# ---------------------------------------------------------------------------
if _sec_selected "T10"; then
HO=$(make_handover "$WORK_REPO")
BAD_CACHE="$TMP/usage-nullreset.json"
printf '{"five_hour":{"utilization":99.0,"resets_at":null},"seven_day":{"utilization":10.0,"resets_at":"%s"}}' \
    "$SEVEN_RESET" > "$BAD_CACHE"
out=$(RESUME_SLOT_CACHE="$BAD_CACHE" SLOT_MAX_AGE=0 bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T10 smart with unsafe cache exits 1 (no arm)" 1 "$rc"
assert_contains "T10 surfaces the slot error" "could not resolve a slot" "$out"
fi

# ---------------------------------------------------------------------------
# T_1674_STALE: --time smart with a STRUCTURALLY-VALID
#     cache whose mtime is STALE must fail CLOSED. This is the operator's
#     exact 2026-08-10 scenario (cache 13058s old against a 3600s max): a stale
#     cache is a NORMAL expected state (idle machine / statusline not run
#     recently), NOT malformed data. resume-slot.sh exits 2 on a stale cache and
#     arm-resume relays that as rc 1 -- never rc 0 with no task. This locks the
#     closed behaviour; a regression that re-opens the fail-open (rc 0, no task)
#     fails this assertion. Distinct from T10 (a structurally-bad cache: null
#     reset, also rc 2 -> rc 1).
# ---------------------------------------------------------------------------
if _sec_selected "1674"; then
HO=$(make_handover "$WORK_REPO")
STALE_CACHE="$TMP/usage-stale.json"
# Self-contained resets_at (staleness is checked BEFORE the cache is parsed, so
# the values do not matter -- but keep them valid so a future reorder of
# resume-slot's checks does not make this test pass for the wrong reason).
printf '{"five_hour":{"utilization":10.0,"resets_at":"1785000000"},"seven_day":{"utilization":20.0,"resets_at":"1785000000"}}' > "$STALE_CACHE"
# Age the fixture far past the 3600s freshness ceiling (operator saw 13058s).
# `touch -d` runs as a child of this harness, so it is NOT subject to the
# caller's command-shape allow-list the way a direct tool invocation is.
touch -d "2020-01-01 00:00:00" "$STALE_CACHE"
out=$(RESUME_SLOT_CACHE="$STALE_CACHE" SLOT_MAX_AGE=3600 bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T_1674 stale cache -> smart fails CLOSED (rc 1, no arm)" 1 "$rc"
assert_contains "T_1674 stale surfaces the arm-resume relay error" "could not resolve a slot" "$out"
assert_contains "T_1674 stale names the staleness reason" "stale" "$out"

# ---------------------------------------------------------------------------
# T_1674_TOMORROW: an explicit --time HH:MM already past
#     for today rolls to TOMORROW. The roll must be reported LOUDLY when it is a
#     FAR park (the "resume in 10 min silently became resume in 24h" class), not
#     land on tomorrow with no mention. A 2-minutes-ago HH:MM rolls ~24h out, so
#     the WARN must fire. --long-gap sanctions the far park (else the long-gap
#     guard refuses rc=9); --force --dry-run isolate from the live scheduler.
#     Distinct from T8, which asserts the /sd-is-tomorrow mechanics; this
#     asserts the operator-facing roll WARN.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
# same freeze as T8 -- PAST_HHMM's "2 minutes ago" and
# arm-resume's own roll decision must see the SAME now, or a real clock tick
# between the two reads (near-guaranteed at real midnight) can make arm-resume
# see "23:57" as still LATER today instead of past, and never roll at all.
T1674_TOMORROW_FREEZE=$(_freeze_now 2026 9 22 23 59 59) || exit 1
PAST_HHMM=$(PYTHONPATH="$T1674_TOMORROW_FREEZE" python3 -c 'import datetime; print((datetime.datetime.now()-datetime.timedelta(minutes=2)).strftime("%H:%M"))')
out=$(PYTHONPATH="$T1674_TOMORROW_FREEZE" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$PAST_HHMM" --handover "$HO" --long-gap --force --dry-run 2>&1)
rc=$?
assert_rc "T_1674 past-time far roll still arms (force+long-gap+dry)" 0 "$rc"
assert_contains "T_1674 past-time roll warns LOUDLY about tomorrow" "rolled the arm to TOMORROW" "$out"
assert_contains "T_1674 past-time roll names the rolled time" "$PAST_HHMM" "$out"

# ---------------------------------------------------------------------------
# T_1674_NEAR: a NEAR arm must NOT trip the
#     far-roll WARN. A ~25-minutes-out HH:MM is either a same-day future arm
#     (no roll at all) or, across midnight, a near roll whose gap is < 3600s --
#     either way the WARN stays silent. Guards against the WARN being over-broad
#     and noising up every ordinary / midnight-crossing arm.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
# same freeze technique as above, pinned right at the midnight
# boundary so this test always exercises the "near roll across midnight" arm
# the comment above describes, instead of leaving it to chance whether the
# suite happens to run near real midnight.
T1674_NEAR_FREEZE=$(_freeze_now 2026 9 22 23 59 59) || exit 1
NEAR_HHMM=$(PYTHONPATH="$T1674_NEAR_FREEZE" python3 -c 'import datetime; n=datetime.datetime.now(); t=n.replace(second=0,microsecond=0)+datetime.timedelta(minutes=25); print(t.strftime("%H:%M"))')
out=$(PYTHONPATH="$T1674_NEAR_FREEZE" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$NEAR_HHMM" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T_1674 near arm arms cleanly (rc 0, no long-gap refusal)" 0 "$rc"
assert_not_contains "T_1674 near arm emits no spurious roll WARN" "rolled the arm to TOMORROW" "$out"
fi

# ---------------------------------------------------------------------------
# T11: --channels while the bun bridge is LIVE is REFUSED (rc 5)..
#      ARM_BRIDGE_LIVE=1 forces the liveness check true without a real process.
#      --force --dry-run isolates from the live scheduler; the guard fires
#      before any scheduler touch, so nothing is created.
# ---------------------------------------------------------------------------
if _sec_selected "T11"; then
HO=$(make_handover "$WORK_REPO")
out=$(ARM_BRIDGE_LIVE=1 bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T11 --channels + live bridge refused (rc 5)" 5 "$rc"
assert_contains "T11 explains the refusal" "refusing --channels" "$out"
assert_contains "T11 names the 409 hazard" "409 Conflict" "$out"
fi

# ---------------------------------------------------------------------------
# T12: ARM_CHANNELS_OK=1 overrides the guard even with a live bridge → the arm
#      proceeds (rc 0) and the --channels passthrough flows into the dry-run.
# ---------------------------------------------------------------------------
if _sec_selected "T12"; then
HO=$(make_handover "$WORK_REPO")
out=$(ARM_CHANNELS_OK=1 ARM_BRIDGE_LIVE=1 bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T12 ARM_CHANNELS_OK override exits 0" 0 "$rc"
assert_contains "T12 channels passthrough survives override" "--channels" "$out"
assert_not_contains "T12 no refusal under override" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T13: real detection path — BRIDGE_ROOT points at a dir with NO supervisor.pid
#      (bridge not running), ARM_BRIDGE_LIVE unset → the guard does NOT fire and
#      a --channels arm proceeds (rc 0), passthrough intact.
# ---------------------------------------------------------------------------
if _sec_selected "T13"; then
NO_BRIDGE="$TMP/no-bridge"
mkdir -p "$NO_BRIDGE"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$NO_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T13 --channels + no live bridge proceeds (rc 0)" 0 "$rc"
assert_contains "T13 channels passthrough flows into dry-run" "--channels" "$out"
assert_not_contains "T13 no spurious refusal when bridge absent" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T14: the guard is --channels-only — a PLAIN arm with a live bridge is
#      UNAFFECTED (rc 0). Confirms the default relaunch path never regresses.
# ---------------------------------------------------------------------------
if _sec_selected "T14"; then
HO=$(make_handover "$WORK_REPO")
out=$(ARM_BRIDGE_LIVE=1 bash "$ARM" --time "$(future_time)" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T14 plain arm + live bridge unaffected (rc 0)" 0 "$rc"
assert_not_contains "T14 no refusal on a plain arm" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T15: REAL detection — pidfile names a LIVE pid → guard fires (rc 5). Exercises
#      the actual pidfile-read + JSON-parse + _pid_alive path that the
#      ARM_BRIDGE_LIVE seam (T11/T12/T14) bypasses. This shell's own pid
#      ($$, `kill -0` true) provides a live process. Requires python3 + kill —
#      a failure here is env,
#      not guard logic.
# ---------------------------------------------------------------------------
if _sec_selected "T15"; then
LIVE_BRIDGE="$TMP/live-bridge"
mkdir -p "$LIVE_BRIDGE"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)                           LIVE_PID=$$ ;;
esac
printf '{"supervisor": %d, "poller": 0}\n' "$LIVE_PID" > "$LIVE_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$LIVE_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T15 real pidfile + live pid refuses (rc 5)" 5 "$rc"
assert_contains "T15 explains the refusal" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T16: stale pidfile names a DEAD pid → guard does NOT fire (rc 0). A crashed
#      bridge leaves a pidfile; a legit --channels arm must still proceed.
#      999999 is absent on every platform (`kill -0` fails / tasklist "No tasks").
# ---------------------------------------------------------------------------
if _sec_selected "T16"; then
STALE_BRIDGE="$TMP/stale-bridge"
mkdir -p "$STALE_BRIDGE"
printf '{"supervisor": 999999, "poller": 0}\n' > "$STALE_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$STALE_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T16 stale (dead-pid) pidfile proceeds (rc 0)" 0 "$rc"
assert_not_contains "T16 no refusal on a dead-pid pidfile" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T17: malformed pidfile (present but unparseable) → FAIL CLOSED: treat the
#      bridge as live and refuse (rc 5) + warn. A present-but-torn pidfile most
#      likely means the bridge is up, so refusing is the safe direction (the
#      ARM_CHANNELS_OK=1 escape covers a genuinely corrupt file).
# ---------------------------------------------------------------------------
if _sec_selected "T17"; then
BAD_BRIDGE="$TMP/bad-bridge"
mkdir -p "$BAD_BRIDGE"
printf 'not json at all {{{\n' > "$BAD_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$BAD_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T17 malformed pidfile fails closed (rc 5)" 5 "$rc"
assert_contains "T17 warns about the unreadable pidfile" "present but unreadable/empty" "$out"
assert_contains "T17 still refuses --channels" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T18: REAL detection via the POLLER key — pidfile is {"supervisor":0,"poller":<live>}
#      so the supervisor key is dead/absent and ONLY the poller key carries a live
#      pid. Proves the JSON loop's poller branch decides liveness (T15 puts the
#      live pid under supervisor, so this is the complementary key). Guard fires
#      (rc 5). Live pid is platform-honest (see T15).
# ---------------------------------------------------------------------------
if _sec_selected "T18"; then
POLLER_BRIDGE="$TMP/poller-bridge"
mkdir -p "$POLLER_BRIDGE"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)                           POLLER_PID=$$ ;;
esac
printf '{"supervisor": 0, "poller": %d}\n' "$POLLER_PID" > "$POLLER_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$POLLER_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T18 live pid under poller key refuses (rc 5)" 5 "$rc"
assert_contains "T18 explains the refusal" "refusing --channels" "$out"
# Negative assertion: the fail-closed path (empty $pids) ALSO yields rc 5 +
# "refusing --channels", so the asserts above would stay green even if the
# poller key were ignored. T17's fail-closed branch is the one that emits
# "present but unreadable/empty" — its ABSENCE here proves liveness was decided
# by the parsed poller pid, not by the unreadable-pidfile fallback.
assert_not_contains "T18 did NOT take the fail-closed path" "present but unreadable/empty" "$out"
fi

# ---------------------------------------------------------------------------
# T19: BRIDGE_PIDFILE direct override WINS over BRIDGE_ROOT/supervisor.pid. The
#      resolver prefers $BRIDGE_PIDFILE; all other tests drive BRIDGE_ROOT only.
#      Point BRIDGE_PIDFILE at a live-pid file while BRIDGE_ROOT points at a dir
#      whose supervisor.pid is DEAD — if the override wins the guard fires (rc 5),
#      proving BRIDGE_PIDFILE took precedence over the (dead) BRIDGE_ROOT file.
# ---------------------------------------------------------------------------
if _sec_selected "T19"; then
OVERRIDE_LIVE="$TMP/override-live.pid"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)                           OVERRIDE_PID=$$ ;;
esac
printf '{"supervisor": %d, "poller": 0}\n' "$OVERRIDE_PID" > "$OVERRIDE_LIVE"
OVERRIDE_ROOT="$TMP/override-root"        # BRIDGE_ROOT with a DEAD supervisor.pid
mkdir -p "$OVERRIDE_ROOT"
printf '{"supervisor": 999999, "poller": 0}\n' > "$OVERRIDE_ROOT/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_PIDFILE="$OVERRIDE_LIVE" BRIDGE_ROOT="$OVERRIDE_ROOT" bash "$ARM" \
        --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T19 BRIDGE_PIDFILE override (live) wins over dead BRIDGE_ROOT (rc 5)" 5 "$rc"
assert_contains "T19 explains the refusal" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T20: wedged python3 stub — the --time HH:MM epoch resolution
#      must fail BOUNDED + visible (rc 2 + ERR), never hang the arm. The
#      watchdog (auto-arm-on-cap) calls this script, so a hang here would
#      wedge the whole armor chain.
# ---------------------------------------------------------------------------
if _sec_selected "T20"; then
if timeout --version 2>/dev/null | grep -qi coreutils; then
    mkdir -p "$TMP/wedged-bin"
    cat > "$TMP/wedged-bin/python3" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30
EOF
    chmod +x "$TMP/wedged-bin/python3"
    HO=$(make_handover "$WORK_REPO")
    start=$(date +%s)
    out=$(PATH="$TMP/wedged-bin:$PATH" PY_ARMOR_TIMEOUT=1 PY_ARMOR_KILL_AFTER=1 \
        bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    assert_rc "T20 wedged stub fails the arm visibly (rc 2)" 2 "$rc"
    assert_contains "T20 surfaces a clean ERR line" "ERR arm-resume: could not resolve --time" "$out"
    if [ "$elapsed" -lt 15 ]; then
        echo "PASS T20 bounded (${elapsed}s)"
    else
        echo "FAIL T20 bounded — took ${elapsed}s"
        FAILED=$((FAILED + 1))
    fi
else
    echo "SKIP T20 (no GNU coreutils timeout on this runner)"
fi
fi

# ---------------------------------------------------------------------------
# T21: telemetry seam — the dedup block (rc 3) emits ONE
#      measure-during record to the side-channel sink, nothing to stdout
#      beyond the existing ERR text. Scheduler is PATH-stubbed so the
#      test fabricates an existing HIMMEL-Resume job on any platform.
# ---------------------------------------------------------------------------
STUB_BIN="$TMP/sched-stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/atq" <<'EOF'
#!/usr/bin/env bash
printf '1\tThu Jun 11 09:00:00 2026 a user\n'
EOF
cat > "$STUB_BIN/at" <<'EOF'
#!/usr/bin/env bash
printf '# HIMMEL-Resume-stub\n'
EOF
chmod +x "$STUB_BIN/atq" "$STUB_BIN/at"

if _sec_selected "T21"; then
# --dedup-any: STUB_BIN fabricates a job named HIMMEL-Resume-stub
# whose name will not match this random handover's $TASK_NAME under the new
# per-handover dedup. --dedup-any restores the broad "any slot blocks" match
# so this test keeps exercising the shared dedup-block path (telemetry + rc 3).
TELEMETRY_T21="$TMP/telemetry-t21"
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T21" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T21 dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T21 ERR text preserved" "already scheduled" "$out"
TLOG="$TELEMETRY_T21/skill-usage.jsonl"
if [ -f "$TLOG" ]; then
    echo "PASS T21 telemetry record written"
else
    echo "FAIL T21 telemetry record missing ($TLOG)"
    FAILED=$((FAILED + 1))
fi
tline=$(tail -1 "$TLOG" 2>/dev/null || true)
assert_contains "T21 record names the skill" '"skill":"handover-arm-resume"' "$tline"
assert_contains "T21 record names the event" '"event":"dedup-block"' "$tline"
if [ "$(wc -l < "$TLOG" 2>/dev/null | tr -d ' ')" = "1" ]; then
    echo "PASS T21 exactly one append"
else
    echo "FAIL T21 expected exactly one telemetry line"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T22: telemetry honors --dry-run's "touch nothing" contract AND the
#      kill switch — neither run may append a record.
# ---------------------------------------------------------------------------
if _sec_selected "T22"; then
TELEMETRY_T22="$TMP/telemetry-t22"
HO=$(make_handover "$WORK_REPO")
out=$(SKILL_TELEMETRY_DIR="$TELEMETRY_T22" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T22 dry-run exits 0" 0 "$rc"
if [ -f "$TELEMETRY_T22/skill-usage.jsonl" ]; then
    echo "FAIL T22 dry-run appended telemetry (touch-nothing violated)"
    FAILED=$((FAILED + 1))
else
    echo "PASS T22 dry-run appends no telemetry"
fi
out=$(PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T22" SKILL_TELEMETRY_DISABLE=1 \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T22 kill-switched dedup still blocks (rc 3)" 3 "$rc"
if [ -f "$TELEMETRY_T22/skill-usage.jsonl" ]; then
    echo "FAIL T22 kill switch did not suppress the append"
    FAILED=$((FAILED + 1))
fi
# --dry-run WITHOUT --force hitting the dedup block (the no---force
# else-branch — the path the --force --dry-run case above bypasses):
# must still block rc 3 AND must not emit (touch-nothing contract).
out=$(PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T22" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "T22 dry-run (no --force) dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T22 dry-run dedup ERR text preserved" "already scheduled" "$out"
if [ -f "$TELEMETRY_T22/skill-usage.jsonl" ]; then
    echo "FAIL T22 dry-run dedup-block appended telemetry (touch-nothing violated)"
    FAILED=$((FAILED + 1))
else
    echo "PASS T22 no run appended telemetry (dry-run x2 + kill switch)"
fi

fi
# ---------------------------------------------------------------------------
# T23: telemetry seam — a SUCCESSFUL arm (the primary
#      measure-during signal) emits exactly ONE "armed" record with the
#      time=/force= fields. Scheduler is PATH-stubbed: /query (and atq)
#      report an empty scheduler, /create (and at) succeed, so the arm
#      completes on any platform without touching the real scheduler.
# ---------------------------------------------------------------------------
ARMED_STUB="$TMP/armed-stub-bin"
mkdir -p "$ARMED_STUB"
# this stub used to answer EVERY /query with an empty scheduler
# while reporting /create success -- internally inconsistent, and the arm's new
# post-arm existence verify (correctly) reads that as "the create armed
# nothing" and refuses rc=2. Same class the note below already
# handled for `powershell`. State is a per-$TMP file (no SCHED_DB env needed,
# unlike make_stateful_sched), with real `/create /f` overwrite-in-place
# semantics, so the scheduler still starts EMPTY for every section and only
# ever holds what this suite actually armed.
cat > "$ARMED_STUB/atq" <<EOF
#!/usr/bin/env bash
d="$TMP/armed-stub.atdir"; [ -d "\$d" ] || exit 0
for f in "\$d"/job-*; do
    [ -f "\$f" ] || continue
    printf '%s\\tThu Jun 11 09:00:00 2026 a user\\n' "\${f##*/job-}"
done
exit 0
EOF
cat > "$ARMED_STUB/at" <<EOF
#!/usr/bin/env bash
d="$TMP/armed-stub.atdir"; mkdir -p "\$d"
case "\${1:-}" in
    -c) cat "\$d/job-\${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=\$(cat "\$d/.counter" 2>/dev/null || echo 0); n=\$((n + 1))
        printf '%s' "\$n" > "\$d/.counter"
        cat > "\$d/job-\$n"
        exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
cat > "$ARMED_STUB/atrm" <<EOF
#!/usr/bin/env bash
rm -f "$TMP/armed-stub.atdir/job-\${1:-}" 2>/dev/null || true
exit 0
EOF
# file-backed, like the mac cron suite's stub -- never touches
# the real crontab, even on a Linux host where arm-resume.sh would otherwise
# prefer `at` but a case still lists/reads via `crontab -l` first.
cat > "$ARMED_STUB/crontab" <<EOF
#!/usr/bin/env bash
store="$TMP/armed-stub.crontab"
case "\${1:-}" in
    -l) [ -s "\$store" ] && cat "\$store" || exit 1 ;;
    -)  cat > "\$store" ;;
    *)  exit 0 ;;
esac
EOF
cat > "$ARMED_STUB/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$ARMED_STUB/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe "unavailable" -> verify fail-opens (see SCHED_STUB_T17 note).
exit 1
EOF
chmod +x "$ARMED_STUB/atq" "$ARMED_STUB/at" "$ARMED_STUB/atrm" "$ARMED_STUB/crontab" "$ARMED_STUB/claude" "$ARMED_STUB/powershell"

if _sec_selected "T23"; then
TELEMETRY_T23="$TMP/telemetry-t23"
HO=$(make_handover "$WORK_REPO")
# capture ONCE. This is the only test that arms at a time and then
# asserts that same time appears in the output, so it is the only place where
# two future_time() calls must agree. The helper refreshes when its cached
# target is close to expiring, and a refresh landing between the arm and the
# assertion would fail this test for a reason that has nothing to do with the
# telemetry record it is checking.
T23_TIME=$(future_time)
out=$(TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T23" \
    bash "$ARM" --time "$T23_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T23 stubbed arm succeeds (rc 0)" 0 "$rc"
assert_contains "T23 arm banner printed" "RESUME ARMED" "$out"
TLOG23="$TELEMETRY_T23/skill-usage.jsonl"
if [ -f "$TLOG23" ] && [ "$(wc -l < "$TLOG23" | tr -d ' ')" = "1" ]; then
    echo "PASS T23 exactly one telemetry record"
else
    echo "FAIL T23 expected exactly one telemetry line ($TLOG23)"
    FAILED=$((FAILED + 1))
fi
tline=$(tail -1 "$TLOG23" 2>/dev/null || true)
assert_contains "T23 record names the skill" '"skill":"handover-arm-resume"' "$tline"
assert_contains "T23 record names the event" '"event":"armed"' "$tline"
assert_contains "T23 record carries time" "\"time\":\"$T23_TIME\"" "$tline"
assert_contains "T23 record carries force" '"force":"0"' "$tline"
# the measured gap (raw seconds) is emitted alongside the
# long_gap flag. FUTURE_TIME is now+30m, so a real positive integer (<3600)
# is expected — present AND numeric, not an exact value (timing-dependent).
assert_contains "T23 record carries gap_sec field" '"gap_sec":"' "$tline"
_t23_gap=${tline#*\"gap_sec\":\"}; _t23_gap=${_t23_gap%%\"*}
case "$_t23_gap" in
    ''|0|*[!0-9]*)
        # '0' is rejected too: an explicit arm 30m out MUST measure a nonzero
        # gap — 0 is the unset-_GAP_SEC default and would mask that regression.
        echo "FAIL T23 gap_sec not a strictly positive integer (got '$_t23_gap')"
        FAILED=$((FAILED + 1))
        ;;
    *)
        echo "PASS T23 gap_sec is a strictly positive integer ($_t23_gap)"
        ;;
esac
unset _t23_gap
fi

# ---------------------------------------------------------------------------
# T23b: scheduler-create FAILURE emits NO record — the
#       'armed' emit sits AFTER schedule_arm, so a failed create (rc 4)
#       must leave the sink absent/empty: a failed arm is not a
#       re-launch signal. Arg-discriminating stub: /query (and atq)
#       report an empty scheduler so the arm proceeds past dedup,
#       /create (and at) fail.
# ---------------------------------------------------------------------------
if _sec_selected "T23b"; then
CREATEFAIL_STUB="$TMP/createfail-stub-bin"
mkdir -p "$CREATEFAIL_STUB"
cat > "$CREATEFAIL_STUB/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$CREATEFAIL_STUB/at" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null   # consume the heredoc job body
echo "stub: at refused" >&2
exit 1
EOF
cat > "$CREATEFAIL_STUB/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$CREATEFAIL_STUB/atq" "$CREATEFAIL_STUB/at" "$CREATEFAIL_STUB/claude"

TELEMETRY_T23B="$TMP/telemetry-t23b"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" PATH="$CREATEFAIL_STUB:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T23B" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
assert_rc "T23b failed scheduler create exits 4" 4 "$rc"
assert_contains "T23b ERR text surfaced" "ERR arm-resume:" "$out"
if [ -s "$TELEMETRY_T23B/skill-usage.jsonl" ]; then
    echo "FAIL T23b failed create appended telemetry (no-emit invariant violated)"
    FAILED=$((FAILED + 1))
else
    echo "PASS T23b failed create appends no telemetry"
fi

# the one case that guarantees a non-dry arm reaches the
# bank-preflight producer refresh (--time auto never skips it), so the
# end-of-run cache-redirect row cannot pass vacuously. Only the refresh is
# under test: the arm's own outcome is T23b's business, not asserted here.
_refresh_before=$(wc -l < "$BANK_PRODUCER_LOG" 2>/dev/null || echo 0)
HO=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" PATH="$CREATEFAIL_STUB:$PATH" SKILL_TELEMETRY_DIR="$TMP/telemetry-t23b-3911" \
    bash "$ARM" --time auto --handover "$HO" >/dev/null 2>&1 || true
_refresh_after=$(wc -l < "$BANK_PRODUCER_LOG" 2>/dev/null || echo 0)
assert_rc "T23b-3911 a non-dry auto arm reached the producer refresh" 1 "$([ "$_refresh_after" -gt "$_refresh_before" ] && echo 1 || echo 0)"
fi

# ---------------------------------------------------------------------------
# T24: caller-side fail-open — arm-resume must behave
#      identically when scripts/lib/telemetry.sh is ABSENT or
#      syntactically BROKEN (the `|| true` source + no-op fallback at
#      the call site). The script is copied into an isolated tree so
#      the real lib is never touched.
# ---------------------------------------------------------------------------
if _sec_selected "T24"; then
FAILOPEN="$TMP/failopen"
mkdir -p "$FAILOPEN/handover" "$FAILOPEN/lib"
# copy the WHOLE handover + lib pair, not just arm-resume.sh.
# The original copied arm-resume.sh plus py-armor.sh alone, which was complete
# when T24 was written and silently rotted as arm-resume grew dependencies. It
# now reaches for four siblings via $SCRIPT_DIR (cap-reset-time, queue-lock,
# reconcile-workers, resume-slot), and reconcile-workers is FAIL-CLOSED:
# arm-resume.sh:315 refuses rc=2 when it is absent, because live-worker state
# that cannot be checked must not be papered over. Every T24 case therefore died
# at rc=2 before reaching the dedup path it is actually about, while reporting
# as "the fail-open contract is broken". Copying the directories
# wholesale means the next fail-closed sibling does not repeat this.
cp "$(dirname "$ARM")"/*.sh "$FAILOPEN/handover/" 2>/dev/null || true
cp "$(dirname "$ARM")/../lib"/*.sh "$(dirname "$ARM")/../lib"/*.mjs "$FAILOPEN/lib/" 2>/dev/null || true
# arm-resume resolves its plugin profile through ../lanes (fail-closed).
mkdir -p "$FAILOPEN/lanes"
cp "$(dirname "$ARM")/../lanes"/* "$FAILOPEN/lanes/" 2>/dev/null || true
# telemetry.sh is the SUBJECT of this test — it must be the only thing missing.
rm -f "$FAILOPEN/lib/telemetry.sh"
# (a) lib ABSENT — dedup must still block rc 3 with the ERR text intact.
#     --dedup-any: STUB_BIN's fabricated HIMMEL-Resume-stub won't match this
#     random handover's $TASK_NAME under per-handover dedup, so
#     the broad scope is what reproduces the dedup-block path under test here.
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$STUB_BIN:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T24 absent lib: dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T24 absent lib: ERR text intact" "already scheduled" "$out"
# (b) lib BROKEN (bash syntax error) — same dedup invariants, AND a
#     successful arm still completes end-to-end (rc 0, banner printed)
printf 'if [ broken\nthen (\n' > "$FAILOPEN/lib/telemetry.sh"
out=$(PATH="$STUB_BIN:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T24 broken lib: dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T24 broken lib: ERR text intact" "already scheduled" "$out"
out=$(TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
assert_rc "T24 broken lib: successful arm still completes (rc 0)" 0 "$rc"
assert_contains "T24 broken lib: arm banner printed" "RESUME ARMED" "$out"
# The fail-open is `. lib 2>/dev/null || true` — BOTH halves. Nothing pinned
# the redirect, so bash's parse error from the broken lib could start leaking
# into the operator's arm output with every rc assertion still green.
assert_not_contains "T24 broken lib: the parse error is not leaked to the operator" "syntax error" "$out"

# T24c: the NEGATIVE CONTROL. Turning six FAILs into six PASSes
# does not demonstrate the test works — T24 spent months exiting 2 on a missing
# sibling while reporting as "the fail-open contract is broken", and
# a repaired fixture that still cannot fail for its intended reason is the same
# defect wearing green. So: break the fail-open deliberately, in a SECOND copy
# tree, and assert the arm dies. If this passes while T24(b) also passes, the
# `|| true` is genuinely what is holding the arm up.
FAILOPEN_NEG="$TMP/failopen-neg"
rm -rf "$FAILOPEN_NEG"
mkdir -p "$FAILOPEN_NEG"
cp -R "$FAILOPEN/handover" "$FAILOPEN/lib" "$FAILOPEN/lanes" "$FAILOPEN_NEG/"
sed -e '\#bash -n .*lib/telemetry\.sh#d' -e '\#lib/telemetry\.sh#s# 2>/dev/null || true##' "$FAILOPEN/handover/arm-resume.sh" \
    > "$FAILOPEN_NEG/handover/arm-resume.sh"
# A no-op sed would make this control vacuous — the exact class of bug the
# ticket is about — so prove the edit landed before trusting the result.
if grep -qF 'lib/telemetry.sh" 2>/dev/null || true' "$FAILOPEN_NEG/handover/arm-resume.sh"; then
    echo "FAIL T24c negative control did not strip the fail-open (sed matched nothing) — the control below is vacuous"
    FAILED=$((FAILED + 1))
else
    echo "PASS T24c negative control stripped the caller-side fail-open"
fi
# A FRESH handover, not the $HO that T24(b) just armed: if the fail-open were
# ever restored, a second arm of the same handover could return rc=3 (dedup)
# instead of rc=0, and the "rc != 0" below would read as PASS for a reason that
# has nothing to do with the fail-open — a control whose green can come from a
# second cause is the vacuous shape this whole case exists to remove.
# bash 3.2 (macOS) does not abort on a `.` of a syntax-broken file: it returns
# nonzero and carries on, so there is no nonzero rc or leaked parse error to
# assert and the control cannot fail for its cause there. T24(b)
# above still proves the guard on bash 3.2; the control needs bash >= 4.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "SKIP T24c bash ${BASH_VERSION%%[^0-9.]*} continues after a failed source — the removed-fail-open control needs bash >= 4"
else
HO_T24C=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" \
    bash "$FAILOPEN_NEG/handover/arm-resume.sh" --time "$(future_time)" --handover "$HO_T24C" 2>&1)
rc=$?
# "Nonzero" alone is not proof of CAUSE (panel r3 codex-2): an unrelated
# fixture or scheduler error would satisfy it and the control would pass
# without testing anything. So require the positive evidence too — with the
# 2>/dev/null gone, bash's own parse error from the broken lib must now reach
# the output, which is the same string T24(b) asserts is ABSENT while the
# fail-open stands. The pair is the control: same input, opposite verdicts.
if [ "$rc" != "0" ] && grepq "$out" -F 'syntax error'; then
    echo "PASS T24c without the fail-open the broken telemetry.sh breaks the arm and surfaces its parse error (rc=$rc) — T24 can still fail for its intended reason"
else
    echo "FAIL T24c expected a nonzero rc AND a leaked parse error with the fail-open REMOVED (got rc=$rc) — the control is not proving its cause"
    FAILED=$((FAILED + 1))
fi
fi
fi

# ---------------------------------------------------------------------------
# Multislot: per-handover dedup lets N distinct handovers each
# arm their own slot, while the SAME handover still dedups. These need a
# STATEFUL scheduler stub (the empty/always-one stubs above can't model a
# growing set of jobs): /create records the task, /query lists what was
# recorded, /delete removes one. Selected by platform exactly as arm-resume
# selects it (at/atq/atrm on Linux, crontab on macOS), sharing one state
# location so dedup is actually exercised.
# ---------------------------------------------------------------------------
make_stateful_sched() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/at" <<'EOF'
#!/usr/bin/env bash
# Stateful at stub. State = $SCHED_DB_DIR (job-<id> files + .counter).
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"
case "${1:-}" in
    -c) cat "$d/job-${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=$(cat "$d/.counter" 2>/dev/null || echo 0); n=$((n + 1))
        printf '%s' "$n" > "$d/.counter"
        cat > "$d/job-$n"
        exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
    cat > "$dir/atq" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; [ -d "$d" ] || exit 0
for f in "$d"/job-*; do
    [ -f "$f" ] || continue
    printf '%s\tThu Jun 11 09:00:00 2026 a user\n' "${f##*/job-}"
done
exit 0
EOF
    cat > "$dir/atrm" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; rm -f "$d/job-${1:-}" 2>/dev/null || true
exit 0
EOF
    cat > "$dir/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$dir/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe "unavailable" -> verify fail-opens (see SCHED_STUB_T17 note).
exit 1
EOF
    cat > "$dir/crontab" <<'EOF'
#!/usr/bin/env bash
# Stateful crontab stub (lifted from test-arm-resume-identity.sh's
# stub). arm-resume.sh routes macOS (Darwin) through crontab ONLY:
# list_existing()'s macos arm calls _crontab_list (`crontab -l | grep`), and
# _crontab_schedule/_crontab_delete rewrite via `| crontab -`. Without a stub
# here a Darwin run of the multislot section resolves the REAL crontab binary
# and reads -- and through _crontab_delete's rewrite, WRITES -- the operator's
# machine-wide crontab outside this suite's fixture. State lives in a fixture
# file inside $SCHED_DB_DIR; `:?` so an unset var is a LOUD failure rather than
# a silent fall-through to the real binary (mirrors the at/atq/atrm guard).
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"
db="$d/crontab.fixture"
case "${1:-}" in
    -l)
        # Real `crontab -l` exits 1 ("no crontab for user") with no output when
        # the crontab is empty; the arm-resume callers all guard that, so model
        # it honestly rather than always exiting 0.
        if [ -s "$db" ]; then cat "$db"; exit 0; else exit 1; fi ;;
    -)
        cat > "$db"; exit 0 ;;
    -r)
        : > "$db"; exit 0 ;;
    "")
        # Piped stdin with no flag = replace.
        cat > "$db"; exit 0 ;;
    -*)
        # Unknown flag (-e editor, -u user): NEVER touch real state. Drain any
        # piped stdin so the writer sees no spurious SIGPIPE; exit 0 so a
        # probe-by-existence sees a present binary.
        cat > /dev/null 2>&1 || true; exit 0 ;;
    *)
        # A bare file arg = install from that file (real `crontab <file>`).
        if [ -f "$1" ]; then cat "$1" > "$db"; exit 0; fi
        cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
    chmod +x "$dir/at" "$dir/atq" "$dir/atrm" "$dir/claude" "$dir/powershell" "$dir/crontab"
}

# Count armed slots in the platform's state location.
#   $1 = legacy SCHED_DB argument; $2 = SCHED_DB_DIR directory
count_slots() {
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        darwin*)
            # macOS uses crontab ONLY (arm-resume.sh PLATFORM=macos), whose stub
            # store is $dir/crontab.fixture -- NOT $db or job-* (at).
            # Counting either of those here would always read 0 on Darwin and
            # make every slot assertion below vacuously pass.
            if [ -f "$2/crontab.fixture" ]; then grep -c . "$2/crontab.fixture" 2>/dev/null || true; else echo 0; fi ;;
        *)
            find "$2" -maxdepth 1 -name 'job-*' 2>/dev/null | wc -l | tr -d ' ' ;;
    esac
}

STATEFUL_STUB="$TMP/stateful-sched"
make_stateful_sched "$STATEFUL_STUB"

# ---------------------------------------------------------------------------
# T25: two DISTINCT handovers both arm — the multislot core. Under the old
#      HIMMEL-Resume-* wildcard dedup the second arm was refused (rc 3); with
#      per-$TASK_NAME dedup both succeed and TWO distinct jobs exist.
# ---------------------------------------------------------------------------
if _sec_selected "T25"; then
DB25="$TMP/db25.tasks"; DB25D="$TMP/db25.atdir"; : > "$DB25"; mkdir -p "$DB25D"
HO_A=$(make_handover "$WORK_REPO")
HO_B=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB25" SCHED_DB_DIR="$DB25D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_A" 2>&1)
rc=$?
assert_rc "T25a first distinct handover arms (rc 0)" 0 "$rc"
assert_contains "T25a arm banner printed" "RESUME ARMED" "$out"
out=$(TMPDIR="$TMP" SCHED_DB="$DB25" SCHED_DB_DIR="$DB25D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_B" 2>&1)
rc=$?
assert_rc "T25b second DISTINCT handover ALSO arms (rc 0, multislot)" 0 "$rc"
assert_contains "T25b arm banner printed" "RESUME ARMED" "$out"
assert_not_contains "T25b second distinct arm is NOT a dedup block" "already scheduled" "$out"
if [ "$(count_slots "$DB25" "$DB25D")" = "2" ]; then
    echo "PASS T25c two distinct slots coexist"
else
    echo "FAIL T25c expected 2 slots, got $(count_slots "$DB25" "$DB25D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T26: the SAME handover armed twice still dedups — second arm refused (rc 3),
#      one slot only. Preserves the "never two sessions for one handover"
#      invariant the original wildcard dedup enforced too broadly.
# ---------------------------------------------------------------------------
if _sec_selected "T26"; then
DB26="$TMP/db26.tasks"; DB26D="$TMP/db26.atdir"; : > "$DB26"; mkdir -p "$DB26D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB26" SCHED_DB_DIR="$DB26D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
assert_rc "T26a same handover first arm (rc 0)" 0 "$rc"
out=$(TMPDIR="$TMP" SCHED_DB="$DB26" SCHED_DB_DIR="$DB26D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
assert_rc "T26b same handover re-arm still blocks (rc 3)" 3 "$rc"
assert_contains "T26b dedup ERR text preserved" "already scheduled" "$out"
# the refusal must state the scope it actually enforces. A blurb
# that reads prefix-wide taught the operator to serialise independent tickets.
assert_contains "T26b refusal names the SAME-handover scope" "for the SAME handover" "$out"
assert_contains "T26b refusal says a different handover needs no flag" "arms concurrently with" "$out"
if [ "$(count_slots "$DB26" "$DB26D")" = "1" ]; then
    echo "PASS T26c same-handover dedup keeps exactly one slot"
else
    echo "FAIL T26c expected 1 slot, got $(count_slots "$DB26" "$DB26D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T27: --force replaces ONLY the same-handover job — one slot before, one
#      after (delete + recreate), never a duplicate.
# ---------------------------------------------------------------------------
if _sec_selected "T27"; then
DB27="$TMP/db27.tasks"; DB27D="$TMP/db27.atdir"; : > "$DB27"; mkdir -p "$DB27D"
HO=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" SCHED_DB="$DB27" SCHED_DB_DIR="$DB27D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" >/dev/null 2>&1
out=$(TMPDIR="$TMP" SCHED_DB="$DB27" SCHED_DB_DIR="$DB27D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --force 2>&1)
rc=$?
assert_rc "T27a same handover --force re-arms (rc 0)" 0 "$rc"
if [ "$(count_slots "$DB27" "$DB27D")" = "1" ]; then
    echo "PASS T27b --force replaces in place (still one slot)"
else
    echo "FAIL T27b expected 1 slot after --force, got $(count_slots "$DB27" "$DB27D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T28: --dedup-any restores the broad "defer to ANY existing slot" semantics
#      the auto-arm watchdogs rely on — a DISTINCT handover is refused (rc 3)
#      when any HIMMEL-Resume job already exists, so safety arms never fan out.
# ---------------------------------------------------------------------------
if _sec_selected "T28"; then
DB28="$TMP/db28.tasks"; DB28D="$TMP/db28.atdir"; : > "$DB28"; mkdir -p "$DB28D"
HO_A=$(make_handover "$WORK_REPO")
HO_B=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" SCHED_DB="$DB28" SCHED_DB_DIR="$DB28D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_A" >/dev/null 2>&1
out=$(TMPDIR="$TMP" SCHED_DB="$DB28" SCHED_DB_DIR="$DB28D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_B" --dedup-any 2>&1)
rc=$?
assert_rc "T28a --dedup-any distinct handover blocks when any slot exists (rc 3)" 3 "$rc"
assert_contains "T28a dedup ERR text preserved" "already scheduled" "$out"
# the broad scope refuses for a DIFFERENT reason than the default
# per-handover scope, so it must not claim the slot is the same handover's.
assert_contains "T28a refusal names the --dedup-any scope" "--dedup-any safety-arm semantics" "$out"
assert_not_contains "T28a refusal does not claim same-handover" "for the SAME handover" "$out"
# --force in THIS scope is NO LONGER multi-delete — it replaces
# only THIS handover's own job(s), so the refusal must say so rather than warn
# of a sibling-endangering wipe. (T28d proves the foreign siblings in fact
# survive.)
assert_contains "T28a refusal says --force is own-only (HIMMEL-1563)" "replaces only THIS" "$out"
# Sanity: WITHOUT --dedup-any the same distinct arm would succeed (T25 proves
# this), so the rc 3 here is the flag's doing, not a stuck scheduler.
if [ "$(count_slots "$DB28" "$DB28D")" = "1" ]; then
    echo "PASS T28b --dedup-any left the single slot untouched"
else
    echo "FAIL T28b expected 1 slot, got $(count_slots "$DB28" "$DB28D")"
    FAILED=$((FAILED + 1))
fi
# --dedup-any against an EMPTY scheduler still arms (rc 0).
DB28E="$TMP/db28e.tasks"; DB28ED="$TMP/db28e.atdir"; : > "$DB28E"; mkdir -p "$DB28ED"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB28E" SCHED_DB_DIR="$DB28ED" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T28c --dedup-any on empty scheduler arms (rc 0)" 0 "$rc"

# T28d (re-pointed): --dedup-any --force is NO
# LONGER destructive to foreign chains. Pre-1563 its broad dedup scope matched
# EVERY resume job, so the --force replace loop reaped every HIMMEL-Resume-*
# task on the box — two queued FOREIGN sibling arms (distinct handovers, not
# this one) collapsed into the single new arm, and on a multi-chain box that
# collateral-deleted another chain's armed resume (worker 44 deleted
# HIMMEL-Resume-trust-envelope-chain-06). narrows the --force reap
# to THIS invocation's own identity only, so a cancel/replace can never touch a
# task it did not create. The broad scope still governs the rc=3 refusal
# (T28a/T28c) — read-only — but the DELETE is own-identity.
#
# So under --dedup-any --force the two foreign sibling arms SURVIVE alongside
# the new arm (3 slots). Contrast T30: WITHOUT --dedup-any, --force was always
# scoped to the arming handover and siblings survived; makes the
# --dedup-any path agree.
#
# The TRANSACTIONAL contract (the replace runs only AFTER the new
# job is registered + verified, so the FAILURE half — slots survive when the
# arm refuses rc 7 / rc 8 or fails inside schedule_arm — holds for the
# own-identity markers) is covered by G3.1-G3.4 in test-arm-resume-identity.sh,
# which carries the create-failure injection seam this suite's stub lacks.
DB28F="$TMP/db28f.tasks"; DB28FD="$TMP/db28f.atdir"; : > "$DB28F"; mkdir -p "$DB28FD"
HO_F1=$(make_handover "$WORK_REPO")
HO_F2=$(make_handover "$WORK_REPO")
HO_F3=$(make_handover "$WORK_REPO")
# Seed the two siblings at DISTINCT minutes. They only need to coexist, not to
# share a minute, and giving them their own slots keeps this test independent of
# whether the backend under test implements exact-minute collision detection;
# on one that does, same-minute seeds would refuse rc=6 and the
# test would fail during setup, before it ever exercised --dedup-any --force.
TMPDIR="$TMP" SCHED_DB="$DB28F" SCHED_DB_DIR="$DB28FD" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "23:57" --handover "$HO_F1" --long-gap >/dev/null 2>&1
TMPDIR="$TMP" SCHED_DB="$DB28F" SCHED_DB_DIR="$DB28FD" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "23:58" --handover "$HO_F2" --long-gap >/dev/null 2>&1
if [ "$(count_slots "$DB28F" "$DB28FD")" = "2" ]; then
    echo "PASS T28d two sibling slots queued before the --dedup-any --force arm"
else
    echo "FAIL T28d expected 2 slots before force, got $(count_slots "$DB28F" "$DB28FD")"
    FAILED=$((FAILED + 1))
fi
_slot_ids() {   # echo one HIMMEL-Resume-* identity per recorded slot
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        darwin*) grep -ho 'HIMMEL-Resume-[^[:space:]"]*' "$DB28FD/crontab.fixture" 2>/dev/null || true ;;
        *) grep -rho 'HIMMEL-Resume-[^[:space:]"]*' "$DB28FD" 2>/dev/null || true ;;
    esac
}
# Snapshot the two siblings' identities BEFORE the force, so the post-check can
# prove the survivor is the new arm rather than one of them.
_ids_before=$(_slot_ids | sort -u)
out=$(TMPDIR="$TMP" SCHED_DB="$DB28F" SCHED_DB_DIR="$DB28FD" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_F3" --dedup-any --force 2>&1)
rc=$?
assert_rc "T28d --dedup-any --force arms (rc 0)" 0 "$rc"
# the foreign sibling arms SURVIVE. Pre-1563 the broad scope made
# --force reap every HIMMEL-Resume-* job, collapsing both siblings into the one
# new arm (1 slot). Now the force replace is scoped to THIS handover's own
# job(s), so the two FOREIGN siblings are untouched and coexist with the new
# arm: 3 slots. (On main this is 1 → FAIL; the headline 1563 regression.)
if [ "$(count_slots "$DB28F" "$DB28FD")" = "3" ]; then
    echo "PASS T28d --dedup-any --force leaves both foreign siblings + the new arm (3 slots, HIMMEL-1563)"
else
    echo "FAIL T28d expected 3 slots after --dedup-any --force (2 siblings + new arm), got $(count_slots "$DB28F" "$DB28FD")"
    FAILED=$((FAILED + 1))
fi
# Cardinality alone is not enough: assert every sibling identity captured
# BEFORE the force is STILL present (foreign arms survived), AND exactly one
# NEW identity (the HO_F3 arm) joined them. Compares recorded HIMMEL-Resume-*
# identities rather than re-deriving the task name here, so this stays correct
# if the name composition ever changes.
_ids_after=$(_slot_ids | sort -u)
_missing=0
while IFS= read -r _id; do
    [ -z "$_id" ] && continue
    grepq "$_ids_after" -xF "$_id" || _missing=$((_missing + 1))
done <<< "$_ids_before"
_new=0
while IFS= read -r _id; do
    [ -z "$_id" ] && continue
    grepq "$_ids_before" -xF "$_id" || _new=$((_new + 1))
done <<< "$_ids_after"
if [ "$_missing" = "0" ] && [ "$_new" = "1" ]; then
    echo "PASS T28d both sibling identities survived + 1 new arm identity (HIMMEL-1563)"
else
    echo "FAIL T28d identity check: missing=$_missing new=$_new (before='$(printf '%s' "$_ids_before" | tr '\n' ',')' after='$(printf '%s' "$_ids_after" | tr '\n' ',')')"
    FAILED=$((FAILED + 1))
fi

# T28e: a Darwin CANARY for the two helpers above, not a Darwin
# run of T28d. On macOS arm-resume schedules through crontab ONLY, so before
# this ticket count_slots/_slot_ids — which knew about the schtasks db and the
# `at` job-* store and nothing else — read 0/empty there and every slot
# assertion in this section passed VACUOUSLY. The real acceptance test is a
# macOS run, which this box cannot perform; what CAN be proven here is that the
# darwin* branches read the crontab fixture the stub actually writes. OSTYPE is
# set per-call (bash restores it after), and DB28F/DB28FD are re-pointed at
# throwaway paths — safe because every T28 assertion above is already done.
DB28F="$TMP/db28e.tasks"; DB28FD="$TMP/db28e.atdir"; mkdir -p "$DB28FD"
printf '%s\n%s\n' \
    '57 23 * * * cmd HIMMEL-Resume-canary-one' \
    '58 23 * * * cmd HIMMEL-Resume-canary-two' > "$DB28FD/crontab.fixture"
_darwin_slots=$(OSTYPE=darwin23 count_slots "$DB28F" "$DB28FD")
if [ "$_darwin_slots" = "2" ]; then
    echo "PASS T28e count_slots reads the crontab fixture on Darwin (2 slots)"
else
    echo "FAIL T28e count_slots on Darwin: expected 2 slots, got '$_darwin_slots' (vacuous-pass gap)"
    FAILED=$((FAILED + 1))
fi
_darwin_ids=$(OSTYPE=darwin23 _slot_ids | sort -u | tr '\n' ' ')
if [ "$_darwin_ids" = "HIMMEL-Resume-canary-one HIMMEL-Resume-canary-two " ]; then
    echo "PASS T28e _slot_ids reads the crontab fixture on Darwin"
else
    echo "FAIL T28e _slot_ids on Darwin: got '$_darwin_ids'"
    FAILED=$((FAILED + 1))
fi
# The stub itself must exist, or a Darwin run escapes the fixture into the
# operator's machine-wide crontab (the hazard, in this suite).
if [ -x "$STATEFUL_STUB/crontab" ]; then
    echo "PASS T28e make_stateful_sched installs a crontab stub"
else
    echo "FAIL T28e make_stateful_sched has no executable crontab stub — a Darwin run would touch the real crontab"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T29: soft slot cap (decision: WARN, never block). With
#      ARM_MAX_SLOTS=2, arming a third distinct handover still succeeds
#      (rc 0) but emits a soft-cap WARN naming the count; arms below the cap
#      stay silent.
# ---------------------------------------------------------------------------
if _sec_selected "T29"; then
DB29="$TMP/db29.tasks"; DB29D="$TMP/db29.atdir"; : > "$DB29"; mkdir -p "$DB29D"
HO1=$(make_handover "$WORK_REPO")
HO2=$(make_handover "$WORK_REPO")
HO3=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" ARM_MAX_SLOTS=2 SCHED_DB="$DB29" SCHED_DB_DIR="$DB29D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO1" 2>&1)
assert_not_contains "T29a first arm below cap — no soft-cap warn" "soft cap" "$out"
out=$(TMPDIR="$TMP" ARM_MAX_SLOTS=2 SCHED_DB="$DB29" SCHED_DB_DIR="$DB29D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO2" 2>&1)
assert_not_contains "T29b arm reaching cap (2/2) — no soft-cap warn" "soft cap" "$out"
out=$(TMPDIR="$TMP" ARM_MAX_SLOTS=2 SCHED_DB="$DB29" SCHED_DB_DIR="$DB29D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO3" 2>&1)
rc=$?
assert_rc "T29c arm exceeding soft cap still succeeds (rc 0)" 0 "$rc"
assert_contains "T29c arm exceeding soft cap WARNs" "soft cap" "$out"
# The over-cap arm WARNs but must still create the slot (warn ≠ block).
if [ "$(count_slots "$DB29" "$DB29D")" = "3" ]; then
    echo "PASS T29d over-cap arm still created the slot (3 total)"
else
    echo "FAIL T29d expected 3 slots after over-cap arm, got $(count_slots "$DB29" "$DB29D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T30: --force on a GENUINE multislot scenario replaces ONLY the targeted
#      handover — two distinct slots, --force re-arm one, still TWO slots. A
#      regression to the legacy broad-scope delete (wiping siblings) would
#      pass T27 (single slot) but fail here — the precise wipe kills.
# ---------------------------------------------------------------------------
if _sec_selected "T30"; then
DB30="$TMP/db30.tasks"; DB30D="$TMP/db30.atdir"; : > "$DB30"; mkdir -p "$DB30D"
HO_A=$(make_handover "$WORK_REPO")
HO_B=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" SCHED_DB="$DB30" SCHED_DB_DIR="$DB30D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_A" >/dev/null 2>&1
TMPDIR="$TMP" SCHED_DB="$DB30" SCHED_DB_DIR="$DB30D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_B" >/dev/null 2>&1
out=$(TMPDIR="$TMP" SCHED_DB="$DB30" SCHED_DB_DIR="$DB30D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_A" --force 2>&1)
rc=$?
assert_rc "T30a --force re-arm of one of two distinct slots (rc 0)" 0 "$rc"
if [ "$(count_slots "$DB30" "$DB30D")" = "2" ]; then
    echo "PASS T30b --force replaced ONLY the targeted handover (sibling survived, 2 slots)"
else
    echo "FAIL T30b expected 2 slots (sibling preserved), got $(count_slots "$DB30" "$DB30D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T31: prefix-named task collision — the dedup match is whole-line/exact, so a
#      handover whose sanitized $TASK_NAME is a strict PREFIX of another's must
#      not cross-match. The discriminating order is LONGER-first: arm the
#      superset name, then arm the prefix name — under a regression from the
#      exact `grep -Fx` to substring `grep -F`, the prefix name's marker would
#      be found *inside* the superset's marker and falsely deduped (rc 3). With
#      the exact match it must arm (rc 0). Names are EXTENSIONLESS so the
#      sanitizer (tr -cd '[:alnum:]_-', which strips '.') can't insert a char
#      that breaks the prefix relationship (e.g. job.md→jobmd vs jobx.md→jobxmd
#      is NOT a prefix pair — the spurious-green trap a prior version fell into).
# ---------------------------------------------------------------------------
if _sec_selected "T31"; then
DB31="$TMP/db31.tasks"; DB31D="$TMP/db31.atdir"; : > "$DB31"; mkdir -p "$DB31D"
# Sanitized task names: ...pfxcollide_jobcollide  (prefix)
#                       ...pfxcollide_jobcollidex (strict superset — extra 'x')
PFX_DIR="$HANDOVER_DIR/pfxcollide"; mkdir -p "$PFX_DIR"
HO_SHORT="$PFX_DIR/jobcollide"; HO_LONG="$PFX_DIR/jobcollidex"
for _f in "$HO_SHORT" "$HO_LONG"; do
    printf -- '---\nsession_kind: test\n---\n# prefix collision handover\n' > "$_f"
done
# Arm the LONGER (superset) name first so the prefix arm below is the one a
# substring regression would falsely match.
out=$(TMPDIR="$TMP" SCHED_DB="$DB31" SCHED_DB_DIR="$DB31D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_LONG" 2>&1)
assert_rc "T31a superset handover 'jobcollidex' arms (rc 0)" 0 "$?"
# The PREFIX name must ALSO arm — exact match means it does not collide with the
# superset already present. (Substring grep -F regression → false rc 3 here.)
out=$(TMPDIR="$TMP" SCHED_DB="$DB31" SCHED_DB_DIR="$DB31D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_SHORT" 2>&1)
assert_rc "T31b prefix handover 'jobcollide' also arms — no substring cross-match (rc 0)" 0 "$?"
if [ "$(count_slots "$DB31" "$DB31D")" = "2" ]; then
    echo "PASS T31c both prefix-related handovers coexist (2 slots)"
else
    echo "FAIL T31c expected 2 slots, got $(count_slots "$DB31" "$DB31D")"
    FAILED=$((FAILED + 1))
fi
# Re-arming the prefix name must dedup ONLY itself (rc 3), proving exact match.
out=$(TMPDIR="$TMP" SCHED_DB="$DB31" SCHED_DB_DIR="$DB31D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_SHORT" 2>&1)
assert_rc "T31d re-arm 'jobcollide' dedups exactly itself (rc 3)" 3 "$?"
fi

# ---------------------------------------------------------------------------
# T32: the relaunch is SELF-CLEANING — the spawned launcher deletes its own
#      scheduler entry as its first action so a fired /sc ONCE task (or a
#      recurring crontab entry) never lingers to block a same-handover re-arm
#      or fire twice. --force --dry-run isolates from the live scheduler and
#      prints the launcher body. Platform-branched: schtasks .bat carries a
#      self-/delete; the crontab fallback entry self-removes its marker line;
#      the at path needs nothing (atd auto-removes one-shot jobs).
# ---------------------------------------------------------------------------
if _sec_selected "T32"; then
HO=$(make_handover "$WORK_REPO")
out=$(bash "$ARM" --time "$(future_time)" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T32 self-clean dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)
        if command -v at >/dev/null 2>&1; then
            # at queue auto-removes the job after it runs, so the body must
            # carry NO self-delete line — adding one would be wrong.
            assert_contains "T32 at body emitted" "would at -t" "$out"
            assert_not_contains "T32 at body has no spurious self-delete" "schtasks /delete" "$out"
        else
            # crontab fallback: the entry self-removes its own marker line
            # first, ANCHORED (grep -vE …$) so a prefix-related sibling
            # survives — must NOT regress to the unanchored grep -vF.
            assert_contains "T32 crontab entry self-removes its marker (anchored)" "grep -vE '# HIMMEL-Resume-" "$out"
            assert_not_contains "T32 crontab self-clean is not unanchored grep -vF" "grep -vF '# HIMMEL-Resume-" "$out"
            assert_contains "T32 crontab note says one-shot" "self-removes on first fire" "$out"
        fi
        ;;
esac
fi

# ---------------------------------------------------------------------------
# T33: --automerge wires ARMAUTOMERGE=1 + CR_MERGE_GATE_OK=1 into
#      the relaunched session's environment BEFORE invoking claude — opt-in
#      only. Fix round: every generated launch body ALWAYS clears both vars
#      first (defense against ambient-env carryover, e.g. `at` snapshotting
#      the submitting shell's env), then conditionally re-grants them ONLY
#      when --automerge was explicit on THIS arm. So the default (no
#      --automerge) body now contains the CLEAR form but never the GRANT
#      ("=1") form.
# ---------------------------------------------------------------------------
if _sec_selected "T33"; then
HO=$(make_handover "$WORK_REPO")
out=$(bash "$ARM" --time "$(future_time)" --handover "$HO" --automerge --force --dry-run 2>&1)
rc=$?
assert_rc "T33a --automerge dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)
        assert_contains "T33a launch command carries ARMAUTOMERGE=1" "ARMAUTOMERGE=1" "$out"
        assert_contains "T33a launch command carries CR_MERGE_GATE_OK=1" "CR_MERGE_GATE_OK=1" "$out"
        ;;
esac

HO=$(make_handover "$WORK_REPO")
out=$(bash "$ARM" --time "$(future_time)" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T33b default (no --automerge) dry-run exits 0" 0 "$rc"
# assert the GRANT FORM, not the bare substring. The
# advisory WARN ("will NOT set ARMAUTOMERGE=1") is printed on
# stderr on exactly this path and 2>&1 folds it into "$out", so a bare
# not-contains on "ARMAUTOMERGE=1" fails on the very behaviour it is
# supposed to confirm. What must be absent is the grant the ARMED SESSION
# would receive.
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)
        assert_not_contains "T33b default does not GRANT ARMAUTOMERGE/CR_MERGE_GATE_OK" "ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1 claude" "$out"
        assert_contains "T33b default still CLEARS both vars (defense-in-depth)" "unset ARMAUTOMERGE CR_MERGE_GATE_OK" "$out"
        ;;
esac
fi

# ---------------------------------------------------------------------------
# T33c: two-hop cap re-arm. Hop 1 arms WITH
#       --automerge. Hop 2 mirrors auto-arm-on-cap.sh's own invocation shape
#       (--dedup-any, NO --automerge, a DIFFERENT handover — a cap re-arm is
#       never the arm that asked) using the SCHED_STUB_T17 empty-scheduler
#       stub so the query sees no existing job and proceeds instead of
#       dedup-blocking. The hop-2 job body must explicitly CLEAR both vars
#       and must NOT set either to "1" — the grant must not leak across the
#       automatic re-arm, regardless of what hop 1's ambient env carried.
# ---------------------------------------------------------------------------
if _sec_selected "T33c"; then
HO1=$(make_handover "$WORK_REPO")
out=$(bash "$ARM" --time "$(future_time)" --handover "$HO1" --automerge --force --dry-run 2>&1)
rc=$?
assert_rc "T33c hop-1 (--automerge) dry-run exits 0" 0 "$rc"

HO2=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --dedup-any --time "$(future_time)" --handover "$HO2" --dry-run 2>&1)
rc=$?
assert_rc "T33c hop-2 (simulated auto-arm-on-cap re-arm, no --automerge) dry-run exits 0" 0 "$rc"
# grant-form assertions, not bare substrings — see the T33b
# comment above for why.
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)
        assert_not_contains "T33c hop-2 does not GRANT ARMAUTOMERGE/CR_MERGE_GATE_OK" "ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1 claude" "$out"
        assert_contains "T33c hop-2 CLEARS both vars" "unset ARMAUTOMERGE CR_MERGE_GATE_OK" "$out"
        ;;
esac
fi

# ---------------------------------------------------------------------------
# T38: ARM_RESUME_SAFETY_ARM sticky-exemption clear. The
#      automated safety callers (auto-arm-on-cap.sh, spawn-glm) set
#      ARM_RESUME_SAFETY_ARM=1 in their child env so the long-gap guard exempts
#      their multi-hour cap-reset arm. On Linux `at` snapshots the submitter
#      env, so WITHOUT a clear in the launch body the RESUMED claude session
#      inherits =1 and every later far HH:MM arm it makes silently bypasses the
#      guard. Every generated launch body must CLEAR ARM_RESUME_SAFETY_ARM
#      alongside ARMAUTOMERGE/CR_MERGE_GATE_OK — the exemption is for THIS
#      safety arm only, never a property the resumed session keeps. Mirrors how
#      the ARMAUTOMERGE unset is tested (T33b/c).
# ---------------------------------------------------------------------------
if _sec_selected "T38"; then
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_RESUME_SAFETY_ARM=1 \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "T38 safety-arm dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)
        assert_contains "T38 launch body unsets ARM_RESUME_SAFETY_ARM (sticky-exemption)" "unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM" "$out"
        ;;
esac
# The exemption VALUE is never granted to the resumed session — only cleared.
assert_not_contains "T38 body does not grant ARM_RESUME_SAFETY_ARM=1" "ARM_RESUME_SAFETY_ARM=1" "$out"
fi

# ---------------------------------------------------------------------------
# W1-W5: --worktree isolation for code arms
# ---------------------------------------------------------------------------
if _sec_selected "W1-W8" "W1" "W2" "W3" "W4" "W5" "W6" "W7" "W8" "W9" "W10" "W11" "W12" "W13" "W14" "W15" "W16" "W17"; then
# W1: --worktree dry-run computes the type+slug path, resumes there, pre-trusts it.
HO=$(make_handover "")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-test --dry-run 2>&1)
rc=$?
assert_rc "W1 --worktree dry-run exits 0" 0 "$rc"
assert_contains "W1 announces worktree create" "would create worktree 'feat/wt-test'" "$out"
assert_contains "W1 path uses type+slug dir" ".claude/worktrees/feat+wt-test" "$out"
assert_contains "W1 RESUME_CWD set to worktree" "RESUME_CWD=" "$out"
assert_contains "W1 pre-trusts the worktree (HIMMEL-386 wiring)" "would pre-trust workspace" "$out"

# W2: invalid branch (no type/slug) → loud rc 1, no scheduler touched.
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree not-valid --dry-run 2>&1)
rc=$?
assert_rc "W2 invalid worktree branch exits 1" 1 "$rc"
assert_contains "W2 explains type/slug requirement" "must be type/slug" "$out"

# W3: --cwd and --worktree together → rc 1 (the worktree IS the cwd).
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-test --cwd "$WORK_REPO" --dry-run 2>&1)
rc=$?
assert_rc "W3 --cwd + --worktree exits 1" 1 "$rc"
assert_contains "W3 says mutually exclusive" "mutually exclusive" "$out"

# W4: resume_worktree frontmatter used when the flag is omitted.
HO_WT="$HANDOVER_DIR/handover-wt-fm.md"
{ printf -- '---\n'; printf 'resume_worktree: fix/wt-fm\n'; printf -- '---\n'; printf '# fm worktree\n'; } > "$HO_WT"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_WT" --dry-run 2>&1)
rc=$?
assert_rc "W4 resume_worktree frontmatter exits 0" 0 "$rc"
assert_contains "W4 frontmatter worktree used" ".claude/worktrees/fix+wt-fm" "$out"

# W5: non-dry-run — a stub worktree cmd creates the dir; the arm resumes there
# and pre-trusts the worktree path in the (shielded) config.
WT_STUB="$TMP/wt-stub.sh"
# The literal $ARM_WORKTREE_PATH is intentional — the stub expands it at runtime.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nmkdir -p "$ARM_WORKTREE_PATH"\n' > "$WT_STUB"
chmod +x "$WT_STUB"
HO=$(make_handover "")
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_STUB" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-real 2>&1)
rc=$?
assert_rc "W5 non-dry worktree arm exits 0" 0 "$rc"
# The non-dry arm doesn't echo RESUME_CWD (that's dry-run only); proof the
# worktree path was used as cwd is that it got pre-trusted in the config below.
if command -v node >/dev/null 2>&1; then
    trust=$(WT_F="$WORKSPACE_TRUST_CONFIG" node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.env.WT_F,"utf8"));const hit=Object.entries(j.projects||{}).some(([k,v])=>k.includes("feat+wt-real")&&v&&v.hasTrustDialogAccepted===true);process.stdout.write(String(hit))}catch(e){process.stdout.write("ERR")}')
    assert_contains "W5 worktree pre-trusted in config" "true" "$trust"
fi
# Tidy the empty stub-created worktree dir (gitignored, but don't leave litter).
rm -rf "$(cd "$(dirname "$ARM")/../.." && pwd)/.claude/worktrees/feat+wt-real" 2>/dev/null || true

# Stub worktree commands (real scripts — an inline `bash -c '...'` would be
# word-split by the seam's intentional cmd+args split, mangling the quotes).
WT_FAIL_STUB="$TMP/wt-fail-stub.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$WT_FAIL_STUB"; chmod +x "$WT_FAIL_STUB"
WT_NODIR_STUB="$TMP/wt-nodir-stub.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WT_NODIR_STUB"; chmod +x "$WT_NODIR_STUB"

# W6: worktree cmd fails → arm aborts loudly with rc 4 (no silent half-arm).
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_FAIL_STUB" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-fail 2>&1)
rc=$?
assert_rc "W6 worktree create failure exits 4" 4 "$rc"
assert_contains "W6 reports create failure" "worktree create failed" "$out"

# W7: worktree cmd returns 0 but creates no dir → post-create check exits 4.
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_NODIR_STUB" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-nodir 2>&1)
rc=$?
assert_rc "W7 create-but-no-dir exits 4" 4 "$rc"
assert_contains "W7 reports missing worktree dir" "expected worktree dir not found" "$out"

# W8: existing worktree dir → reused (create cmd NOT invoked), arm still succeeds.
# The stub would exit 1 IF called; rc 0 proves the reuse branch skipped it.
W8_DIR="$(cd "$(dirname "$ARM")/../.." && pwd)/.claude/worktrees/feat+wt-reuse"
mkdir -p "$W8_DIR"
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_FAIL_STUB" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-reuse 2>&1)
rc=$?
assert_rc "W8 reuse existing worktree exits 0 (cmd not called)" 0 "$rc"
assert_contains "W8 announces reuse" "reusing existing worktree" "$out"
rm -rf "$W8_DIR"

# W9-W12: himmel code arms default to worktree isolation.
W9_ROOT="$TMP/w9-primary"; mkdir -p "$W9_ROOT/.git" "$TMP/w9-other"
_w9_ho() { # <file-name> <resume_cwd> [extra frontmatter line]
    local f="$HANDOVER_DIR/$1"
    { printf -- '---\nsession_kind: test\nresume_cwd: %s\n' "$2"; [ -n "${3:-}" ] && printf '%s\n' "$3"; printf -- '---\n# t\n'; } > "$f"
    printf '%s' "$f"
}
_w9_run() { PATH="$SCHED_STUB_T17:$PATH" ARM_ISOLATION_ROOT="$W9_ROOT" bash "$ARM" --time "$(future_time)" --handover "$1" --dry-run "${@:2}" 2>&1; echo "arm-rc=$?"; }
out=$(_w9_run "$(_w9_ho HIMMEL-1332-w9.md "$W9_ROOT")")
assert_contains "W9 himmel code arm defaults to a worktree" "would create worktree 'fix/himmel-1332-arm'" "$out"
out=$(_w9_run "$(_w9_ho HIMMEL-1332-w10.md "$W9_ROOT" "resume_isolation: primary")")
assert_not_contains "W10 resume_isolation: primary opts out" "would create worktree" "$out"
assert_contains "W10 exits 0" "arm-rc=0" "$out"
assert_contains "W10 opt-out is logged loudly" "resume_isolation: primary honoured" "$out"
out=$(_w9_run "$(_w9_ho HIMMEL-1332-w11.md "$TMP/w9-other")")
assert_not_contains "W11 a non-himmel resume_cwd (vault arm) is untouched" "would create worktree" "$out"
assert_contains "W11 exits 0" "arm-rc=0" "$out"
out=$(_w9_run "$(_w9_ho luna-note-w12.md "$W9_ROOT")")
assert_not_contains "W12 no HIMMEL ticket in the handover name is untouched" "would create worktree" "$out"
assert_contains "W12 exits 0" "arm-rc=0" "$out"
assert_contains "W12 the primary-without-isolation decline names its reason" "WARN arm-resume: himmel code arm resolves to the primary checkout WITHOUT worktree isolation: no HIMMEL ticket" "$out"
# W13: --cwd resolving to the primary (the hop.sh path) isolates too.
out=$(_w9_run "$(_w9_ho HIMMEL-1332-w13.md "$TMP/w9-other")" --cwd "$W9_ROOT")
assert_contains "W13 --cwd naming the primary checkout defaults to a worktree" "would create worktree 'fix/himmel-1332-arm'" "$out"
assert_contains "W13 exits 0" "arm-rc=0" "$out"
# W14: no resume_cwd: and no ticket in the file name, ticket: in the frontmatter.
W14_HO="$HANDOVER_DIR/luna-note-w14.md"
printf -- '---\nsession_kind: test\nticket: HIMMEL-1332\n---\n# t\n' > "$W14_HO"
out=$(_w9_run "$W14_HO")
assert_contains "W14 missing resume_cwd plus a frontmatter ticket isolates" "would create worktree 'fix/himmel-1332-arm'" "$out"
assert_contains "W14 exits 0" "arm-rc=0" "$out"
# W15: a failed create under the default is a hard exit 4, not a silent primary arm.
W15_HO="$(_w9_ho HIMMEL-9915-w15.md "$W9_ROOT")"
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_ISOLATION_ROOT="$W9_ROOT" ARM_WORKTREE_CMD="bash $WT_FAIL_STUB" bash "$ARM" --time "$(future_time)" --handover "$W15_HO" 2>&1)
rc=$?
assert_rc "W15 failed default worktree create exits 4" 4 "$rc"
assert_contains "W15 names the failed branch" "worktree create failed for branch 'fix/himmel-9915-arm'" "$out"
# W16: a chief doc is excluded from the default.
out=$(_w9_run "$(_w9_ho HIMMEL-1332-w16-chief.md "$W9_ROOT")")
assert_not_contains "W16 a chief doc is untouched" "would create worktree" "$out"
assert_not_contains "W16 a chief doc prints no isolation WARN" "WITHOUT worktree isolation" "$out"
# W17: no seam, the script may sit in a linked worktree; the primary comes from the git common dir.
W17_PRIMARY=$(git -C "$(dirname "$ARM")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
W17_PRIMARY="${W17_PRIMARY%/.git}"
out=$(env -u ARM_ISOLATION_ROOT PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$(_w9_ho HIMMEL-1332-w17.md "$TMP/w9-other")" --cwd "$W17_PRIMARY" --dry-run 2>&1)
assert_contains "W17 primary resolved via the git common dir isolates from a linked worktree" "would create worktree 'fix/himmel-1332-arm'" "$out"
rm -rf "$W9_ROOT" "$TMP/w9-other" "$W14_HO"
fi

# ---------------------------------------------------------------------------
# T33-T37: time-collision check
#
# These tests use the ARM_COLLISION_CANDIDATES seam (set to "<name>\t<HH:MM>"
# lines, empty string = no candidates) so they never touch the real scheduler
# and run on every platform. The stateful stub from T25-T31 is reused for the
# database (so the dedup block doesn't interfere with the collision check).
#
# make_stateful_sched already ran above; STATEFUL_STUB is set.
# ---------------------------------------------------------------------------

# Helper: build a stub HIMMEL-Pipeline-Harvest candidate at a given HH:MM.
# We need a fresh stateful DB per test so dedup doesn't bleed.
_collision_db() { printf '%s' "$TMP/coll-db-$RANDOM"; }
_collision_dbdir() { printf '%s' "$TMP/coll-dbdir-$RANDOM"; }

# ---------------------------------------------------------------------------
# T33: EXACT collision → rc=6 + ERR text + free-slot suggestion.
#      The stateful scheduler has an EMPTY db so the dedup block doesn't fire.
# ---------------------------------------------------------------------------
if _sec_selected "T33" "T33-collision"; then
DB33=$(_collision_db); DB33D=$(_collision_dbdir); : > "$DB33"; mkdir -p "$DB33D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB33" SCHED_DB_DIR="$DB33D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "T33 exact collision refuses (rc 6)" 6 "$rc"
assert_contains "T33 ERR names the collision" "time collision" "$out"
assert_contains "T33 ERR names the colliding task" "HIMMEL-Pipeline-Harvest" "$out"
assert_contains "T33 ERR mentions concurrent claude sessions" "claude sessions" "$out"
assert_contains "T33 free-slot suggestion printed" "Suggested free slots:" "$out"
assert_contains "T33 --force note printed" "--force" "$out"
fi

# ---------------------------------------------------------------------------
# T34: NEAR collision (within window, not exact) → rc=0 + WARN.
#      Request 02:03, candidate at 02:00 (3 min away, within default 5-min window).
# ---------------------------------------------------------------------------
if _sec_selected "T34"; then
DB34=$(_collision_db); DB34D=$(_collision_dbdir); : > "$DB34"; mkdir -p "$DB34D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB34" SCHED_DB_DIR="$DB34D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:03" --handover "$HO" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "T34 near collision still exits 0 (warn-only)" 0 "$rc"
assert_contains "T34 WARN printed for near collision" "WARN arm-resume: near time collision" "$out"
assert_contains "T34 WARN names the colliding task" "HIMMEL-Pipeline-Harvest" "$out"
assert_not_contains "T34 no ERR text on near collision" "ERR arm-resume: time collision" "$out"
fi

# ---------------------------------------------------------------------------
# T35: OUTSIDE window → rc=0, no warn, no ERR.
#      Request 02:10, candidate at 02:00 (10 min away, outside default 5-min window).
# ---------------------------------------------------------------------------
if _sec_selected "T35"; then
DB35=$(_collision_db); DB35D=$(_collision_dbdir); : > "$DB35"; mkdir -p "$DB35D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB35" SCHED_DB_DIR="$DB35D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:10" --handover "$HO" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "T35 outside window exits 0 silently" 0 "$rc"
assert_not_contains "T35 no collision warn outside window" "collision" "$out"
fi

# ---------------------------------------------------------------------------
# T36: --force bypasses EXACT collision → rc=0 + override WARN (not ERR).
# ---------------------------------------------------------------------------
if _sec_selected "T36"; then
DB36=$(_collision_db); DB36D=$(_collision_dbdir); : > "$DB36"; mkdir -p "$DB36D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB36" SCHED_DB_DIR="$DB36D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --long-gap --force --dry-run 2>&1)
rc=$?
assert_rc "T36 --force bypasses exact collision (rc 0)" 0 "$rc"
assert_not_contains "T36 no ERR on --force collision bypass" "ERR arm-resume: time collision" "$out"
assert_contains "T36 --force emits override WARN" "WARN arm-resume: --force: ignoring exact time collision" "$out"
fi

# ---------------------------------------------------------------------------
# T37: --dedup-any (unattended watchdog) exact collision → WARN-ONLY (rc=0),
#      never refuses. Ensures unattended watchdog arms always succeed even when
#      another HIMMEL-* task fires at the same time. ARM_RESUME_SAFETY_ARM=1 is
#      the watchdog's guard-exemption signal (--dedup-any
#      is dedup-scope only and no longer bypasses the long-gap guard, so a real
#      safety arm — auto-arm-on-cap.sh — sets this env var; this simulation
#      mirrors it). The collision check's own --dedup-any warn-only behavior is
#      what T37 actually asserts; the env var just gets it past the guard.
# ---------------------------------------------------------------------------
if _sec_selected "T37"; then
DB37=$(_collision_db); DB37D=$(_collision_dbdir); : > "$DB37"; mkdir -p "$DB37D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB37" SCHED_DB_DIR="$DB37D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_RESUME_SAFETY_ARM=1 \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "T37 --dedup-any exact collision is warn-only (rc 0)" 0 "$rc"
assert_not_contains "T37 no ERR on --dedup-any collision" "ERR arm-resume: time collision" "$out"
assert_contains "T37 --dedup-any emits WARN for exact collision" "WARN arm-resume: exact time collision" "$out"
fi

# ---------------------------------------------------------------------------
# N1-N6: ticket-in-name + ticket-aware dedup/collision
#
# The scheduler task name now carries the inferred ticket ID:
#   HIMMEL-Resume-<TICKET>-<path-suffix>     (ticket inferable)
#   HIMMEL-Resume-[<slug>-]<path-suffix>     (no ticket; also welds
#                                            the handover slug when derivable)
# Every dry-run name check runs with PATH="$SCHED_STUB_T17:$PATH" so
# list_existing hits the empty stub, not the real scheduler (a live armed job
# would otherwise spuriously rc 3). The asserted substring HIMMEL-Resume-KEY-540-
# is interpolated whole into the dry-run scheduler line on every platform.
# make_handover STAYS ticketless — these positive cases use make_handover_titled.
# ---------------------------------------------------------------------------
if _sec_selected "N1-N8" "N1" "N2" "N3" "N4" "N5" "N6" "N7" "N8"; then

# N1: ticket: front-matter (src-1) → exact HIMMEL-Resume-KEY-540- segment.
HO=$(make_handover_titled "Test handover" "HIMMEL-540")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N1 ticket: frontmatter arm exits 0" 0 "$rc"
assert_contains "N1 name carries the front-matter ticket" "HIMMEL-Resume-HIMMEL-540-" "$out"

# N2: H1-title-derived (src-3), no front-matter → exact ticket segment.
HO=$(make_handover_titled "Resume: foo HIMMEL-540 (bar)")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N2 H1-title-derived arm exits 0" 0 "$rc"
assert_contains "N2 name carries the H1-title ticket" "HIMMEL-Resume-HIMMEL-540-" "$out"

# N3: worktree branch (src-2), REAL LOWERCASE form feat/himmel-540-x →
# uppercased in the name. Proves src-2 normalizes AND that inference
# runs after the relocated TASK_NAME build (the F3 ordering guard: at the old
# line 491, the frontmatter/CLI worktree branch was resolved but the name was
# built before it). Asserts the portable substring (not a Windows-only line).
HO=$(make_handover "")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/himmel-540-x --dry-run 2>&1)
rc=$?
assert_rc "N3 worktree-branch arm exits 0" 0 "$rc"
assert_contains "N3 lowercase branch ticket is uppercased into the name" "HIMMEL-Resume-HIMMEL-540-" "$out"

# N4: ticketless fallback → current HIMMEL-Resume-<path-suffix> form, NO doubled
# HIMMEL-...HIMMEL- segment (no regression for arms with no inferable ticket).
HO=$(make_handover_titled "Test handover")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N4 ticketless arm exits 0" 0 "$rc"
assert_contains "N4 name keeps the HIMMEL-Resume- prefix" "HIMMEL-Resume-" "$out"
assert_not_contains "N4 no ticket segment for a ticketless handover" "HIMMEL-Resume-HIMMEL-" "$out"

# N5: body-mention-not-title — H1 has no key, a body line mentions LUNA-9. The
# H1-only scan must NOT pick up the body key (a stray reference can't be welded
# into the scheduler name). Falls back to the path-only name.
HO=$(make_handover_titled "No ticket title" "" "see LUNA-9 for context")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N5 body-mention arm exits 0" 0 "$rc"
assert_not_contains "N5 body LUNA-9 is NOT welded into the name" "HIMMEL-Resume-LUNA-9-" "$out"
assert_not_contains "N5 no ticket segment at all (H1 had no key)" "HIMMEL-Resume-HIMMEL-" "$out"

# N6: collision is unbroken by the doubled-HIMMEL- name. A
# ticket-bearing handover whose TASK_NAME is HIMMEL-Resume-KEY-540-... still
# HARD-REFUSES (rc 6) on an exact-minute collision with a DIFFERENT HIMMEL task.
# Stateful stub + fresh empty DB so the dedup block doesn't fire first; the
# ARM_COLLISION_CANDIDATES seam supplies a different task at the same minute.
# (Self-exclusion is NOT asserted: the seam returns verbatim BEFORE the real
# name-parse/self-exclude, so it is unreachable here by construction.)
DBN6=$(_collision_db); DBN6D=$(_collision_dbdir); : > "$DBN6"; mkdir -p "$DBN6D"
HO=$(make_handover_titled "Resume: HIMMEL-540 collision case")
out=$(TMPDIR="$TMP" SCHED_DB="$DBN6" SCHED_DB_DIR="$DBN6D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "N6 collision still HARD-REFUSES with a ticket-prefixed name (rc 6)" 6 "$rc"
assert_contains "N6 ERR names the collision" "time collision" "$out"

# N7: ticket: front-matter with surrounding quotes AND CRLF line endings — src-1
# reuses the exact rtrim-then-unquote idiom T5/T6/T7 prove fragile for resume_cwd:
# on Windows-authored YAML. A `ticket: "KEY-540"\r` must still resolve.
HO_N7="$HANDOVER_DIR/ho-n7-crlf-$RANDOM.md"
printf -- '---\r\nsession_kind: test\r\nticket: "HIMMEL-540"\r\n---\r\n# No key in title\r\n' > "$HO_N7"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_N7" --dry-run 2>&1)
rc=$?
assert_rc "N7 quoted+CRLF ticket: arm exits 0" 0 "$rc"
assert_contains "N7 quoted+CRLF ticket: resolves into the name" "HIMMEL-Resume-HIMMEL-540-" "$out"
# The needle targets the task-NAME context (Resume-KEY-540") — a bare
# 'KEY-540"' now legitimately appears as the closing quote of the
# `-n "KEY-540"` session-title arg on the Windows .bat launch line, so a
# whole-output match would false-fail. A leaked YAML quote would weld INTO the
# task name (HIMMEL-Resume-KEY-540"…), which this still catches.
assert_not_contains "N7 no stray quote/CR welded into the task name" 'Resume-HIMMEL-540"' "$out"

# N8: malformed multi-dash ticket: value is REJECTED by _validate_key (anchored
# ^<KEY>-<NUM>$) — falls back to the path-only name, no junk segment.
HO_N8=$(make_handover_titled "No key title" "ABC-123-456")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_N8" --dry-run 2>&1)
rc=$?
assert_rc "N8 malformed multi-dash ticket: arm exits 0" 0 "$rc"
assert_not_contains "N8 malformed key is not welded into the name" "HIMMEL-Resume-ABC-123" "$out"
assert_contains "N8 falls back to the HIMMEL-Resume- path-only prefix" "HIMMEL-Resume-" "$out"
fi

# ---------------------------------------------------------------------------
# S1-S3: the relaunch bakes `claude -n "<TICKET> <name>"` so an
# armed session is self-titled (scannable /resume name + terminal tab). The
# name is the canonical retitle form: the inferred ticket plus the
# worktree-slug name-half. Platform-branched like T32 — the dry-run prints the
# crontab/at line; -n is printf %q-escaped (space -> '\ ') for /bin/sh.
# ---------------------------------------------------------------------------
if _sec_selected "S1-S5" "S1" "S2" "S3" "S5"; then

# S1: worktree arm -> ticket (src-2, uppercased) + name-half from the slug.
HO=$(make_handover "")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/himmel-702-demo --dry-run 2>&1)
rc=$?
assert_rc "S1 worktree arm exits 0" 0 "$rc"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S1 win .bat bakes -n <ticket> <name>" '-n "HIMMEL-702 demo"' "$out" ;;
    *)
        assert_contains "S1 cron/at bakes -n <ticket> <name>" '-n HIMMEL-702\ demo' "$out" ;;
esac

# S2 (semantics extended): ticketless handover, no worktree ->
# the handover-slug fallback names the session from the file stem (the
# no-Jira adopter path). Pre-716 this case was fail-open (no -n); the truly
# nothing-derivable fail-open now lives in S9 (empty template render).
HO=$(make_handover_titled "Test handover")
S2_STEM=$(basename "$HO" .md)
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "S2 ticketless arm exits 0" 0 "$rc"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S2 win .bat bakes -n <handover slug>" "-n \"$S2_STEM\"" "$out" ;;
    *)
        assert_contains "S2 cron/at bakes -n <handover slug>" "-n $S2_STEM " "$out" ;;
esac
assert_contains "S2 slug also welds into the task name" "HIMMEL-Resume-$S2_STEM-" "$out"

# S3: ticket but no name-half (frontmatter ticket, no worktree slug) -> -n with
# the bare ticket key.
HO=$(make_handover_titled "Test handover" "HIMMEL-702")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "S3 ticket-only arm exits 0" 0 "$rc"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S3 win .bat bakes -n <ticket>" '-n "HIMMEL-702"' "$out" ;;
    *)
        assert_contains "S3 cron/at bakes -n <ticket>" '-n HIMMEL-702 ' "$out" ;;
esac

# S5: name-half but NO inferable ticket (worktree slug carries no
# `<key>-<N>` token, e.g. feat/cleanup) -> -n with the bare slug name. Exercises
# the token-less worktree-slug branch of _compose_arm_name; a branch slug is a
# meaningful title, so this is NOT the fail-open empty case (contrast S2).
HO=$(make_handover "")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/cleanup --dry-run 2>&1)
rc=$?
assert_rc "S5 name-only (ticketless slug) arm exits 0" 0 "$rc"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S5 win .bat bakes -n <name>" '-n "cleanup"' "$out" ;;
    *)
        assert_contains "S5 cron/at bakes -n <name>" '-n cleanup ' "$out" ;;
esac
fi

# ---------------------------------------------------------------------------
# N9-N10 / S6-S10: derived naming - chain position, slug
# fallback, ARM_NAME_TEMPLATE. Chained fixtures are next-session-<N>.md files
# inside a <TICKET>-<slug>/ epic dir (the handover skill's chain layout),
# which the existing helpers don't produce - make_handover_chained supplies
# them. Same stub/dry-run discipline as N1-N8 / S1-S5.
# ---------------------------------------------------------------------------
if _sec_selected "N9-N13" "N9" "N10" "S6" "S7" "S8" "S9" "S10" "S11" "N11" "N12" "S12" "N13"; then
# Helper: a CHAINED handover. $1 = epic dir name, $2 = session number,
# $3 = optional ticket: frontmatter value (empty = key-less chain file).
make_handover_chained() {
    local dir="$HANDOVER_DIR/$1" path
    mkdir -p "$dir"
    path="$dir/next-session-$2.md"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        [ -n "${3:-}" ] && printf 'ticket: %s\n' "$3"
        printf -- '---\n'
        printf '# Chained test handover\n'
    } > "$path"
    printf '%s' "$path"
}

# N9/S6: chained ticketed (frontmatter ticket) -> the identity carries the
# epic slug AND the chain position on BOTH surfaces: the scheduler row gets
# ...<ticket>-ws7-gates-s32... and the -n title "<ticket> ws7-gates s32".
HO=$(make_handover_chained "HIMMEL-654-ws7-gates" 32 "HIMMEL-654")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N9 chained ticketed arm exits 0" 0 "$rc"
assert_contains "N9 task name carries epic slug + chain position" "HIMMEL-Resume-HIMMEL-654-ws7-gates-s32-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S6 win .bat bakes -n <ticket> <slug> s<N>" '-n "HIMMEL-654 ws7-gates s32"' "$out" ;;
    *)
        assert_contains "S6 cron/at bakes -n <ticket> <slug> s<N>" '-n HIMMEL-654\ ws7-gates\ s32' "$out" ;;
esac

# N10: chained with NO key in frontmatter/H1 -> _infer_ticket src-4 takes the
# epic dir's leading key, so the chain identity survives a key-less chain file.
HO=$(make_handover_chained "HIMMEL-654-ws7-gates" 7 "")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N10 chained key-less arm exits 0" 0 "$rc"
assert_contains "N10 epic-dir key + slug + chain position welded" "HIMMEL-Resume-HIMMEL-654-ws7-gates-s7-" "$out"

# S7: no-ticket slug fallback (OSS adopter, no Jira at all) - a meaningfully
# named flat handover names the session and the scheduler row from its stem.
HO_S7="$HANDOVER_DIR/nightly-refactor-notes.md"
printf -- '---\nsession_kind: test\n---\n# Adopter handover, no ticket\n' > "$HO_S7"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_S7" --dry-run 2>&1)
rc=$?
assert_rc "S7 no-ticket slug arm exits 0" 0 "$rc"
assert_contains "S7 task name carries the slug" "HIMMEL-Resume-nightly-refactor-notes-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S7 win .bat bakes -n <slug>" '-n "nightly-refactor-notes"' "$out" ;;
    *)
        assert_contains "S7 cron/at bakes -n <slug>" '-n nightly-refactor-notes ' "$out" ;;
esac

# S8: ARM_NAME_TEMPLATE override (slug-only) - the ticket IS inferable but the
# operator's template drops it from BOTH surfaces; the ticket-KEYED file stem
# renders as the bare name-half (leading <ticket>- token stripped).
HO_S8="$HANDOVER_DIR/HIMMEL-716-arm-naming.md"
printf -- '---\nsession_kind: test\nticket: HIMMEL-716\n---\n# Template case\n' > "$HO_S8"
out=$(ARM_NAME_TEMPLATE='{slug}' PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_S8" --dry-run 2>&1)
rc=$?
assert_rc "S8 template arm exits 0" 0 "$rc"
assert_contains "S8 slug-only template drives the task name" "HIMMEL-Resume-arm-naming-" "$out"
assert_not_contains "S8 template drops the ticket segment" "HIMMEL-Resume-HIMMEL-716-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S8 win .bat bakes the template title" '-n "arm-naming"' "$out" ;;
    *)
        assert_contains "S8 cron/at bakes the template title" '-n arm-naming ' "$out" ;;
esac

# S9: template renders EMPTY ({session} on a non-chained handover) -> fail-open:
# no -n (claude auto-titles) and the task name falls back to the plain
# path-only form. This is the fail-open contract S2 used to pin pre-716.
# Keep the 72-character readable tail alphanumeric: a random path can clip at
# a legal leading hyphen and make the doubled-separator assertion lie.
HO="$HANDOVER_DIR/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz.md"
printf -- '---\nsession_kind: test\n---\n# Test handover\n' > "$HO"
out=$(ARM_NAME_TEMPLATE='{session}' PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "S9 empty-render template arm exits 0" 0 "$rc"
assert_not_contains "S9 no -n when the template renders empty" " -n " "$out"
# The task-name half of fail-open: an empty render must fall back to the plain
# path-only name, NOT leave a stray-separator segment (HIMMEL-Resume--<suffix>).
assert_not_contains "S9 empty template yields path-only task name" "HIMMEL-Resume--" "$out"

# S10: bare chain file in a GENERIC bucket (handovers/ itself, no epic dir,
# no ticket) -> the generic parent must NOT become the slug (it would name
# every slot alike); the chain position alone remains as the identity.
HO_S10="$HANDOVER_DIR/next-session-3.md"
printf -- '---\nsession_kind: test\n---\n# Bare chain file\n' > "$HO_S10"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_S10" --dry-run 2>&1)
rc=$?
assert_rc "S10 generic-bucket chain arm exits 0" 0 "$rc"
assert_not_contains "S10 generic parent dir is not welded as slug" "HIMMEL-Resume-handovers-" "$out"
assert_contains "S10 chain position alone is the identity" "HIMMEL-Resume-s3-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S10 win .bat bakes -n s<N>" '-n "s3"' "$out" ;;
    *)
        assert_contains "S10 cron/at bakes -n s<N>" '-n s3 ' "$out" ;;
esac

# S11/N11 (gap 1): worktree name-half AND chain session number
# COMBINED - the one branch where `_name` is worktree-derived (priority 1) AND
# `_sess` is non-empty. All other S/N cases exercise only ONE of the two. The
# worktree slug (feat/himmel-654-demo -> name-half "demo") WINS over the epic-dir
# slug ("x"), so the identity is + demo + s5, NOT ...ws7-gates...
HO=$(make_handover_chained "HIMMEL-654-x" 5 "HIMMEL-654")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/himmel-654-demo --dry-run 2>&1)
rc=$?
assert_rc "N11 worktree+chain arm exits 0" 0 "$rc"
assert_contains "N11 task name carries worktree name-half + chain position" "HIMMEL-Resume-HIMMEL-654-demo-s5-" "$out"
assert_not_contains "N11 epic-dir slug is NOT used (worktree half wins)" "HIMMEL-Resume-HIMMEL-654-x-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S11 win .bat bakes -n <ticket> <wt-name> s<N>" '-n "HIMMEL-654 demo s5"' "$out" ;;
    *)
        assert_contains "S11 cron/at bakes -n <ticket> <wt-name> s<N>" '-n HIMMEL-654\ demo\ s5' "$out" ;;
esac


# S12/N13 (gap 4): non-empty MIXED template on an actually-chained
# ticketed file - {session} renders sN (non-empty) and the task-surface sanitizer
# folds the '-' literal. ARM_NAME_TEMPLATE='{ticket}-{session}' -> KEY-654-s5
# on BOTH surfaces.
HO=$(make_handover_chained "HIMMEL-654-x" 5 "HIMMEL-654")
out=$(ARM_NAME_TEMPLATE='{ticket}-{session}' PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N13 mixed-template chained arm exits 0" 0 "$rc"
assert_contains "N13 template renders ticket+session into the task name" "HIMMEL-Resume-HIMMEL-654-s5-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S12 win .bat bakes the mixed template title" '-n "HIMMEL-654-s5"' "$out" ;;
    *)
        assert_contains "S12 cron/at bakes the mixed template title" '-n HIMMEL-654-s5 ' "$out" ;;
esac
fi

# ---------------------------------------------------------------------------
# macOS backend: crontab for schedule + dedup + --force
# ---------------------------------------------------------------------------
if _sec_selected "macOS" "S1-S5" "S4"; then
# at/atq present but must NOT be used on macOS — arm-resume picks crontab there
# (atrun is off-by-default / SIP-fragile). Shim at/atq present so the
# at-vs-crontab mismatch is actually exercised, plus a file-backed crontab.
MACBIN="$TMP/macbin"; mkdir -p "$MACBIN"
# the crontab renderer resolves claude ABSOLUTELY at arm time and
# refuses (rc 2) when it cannot -- CI has no claude, so every cron stub dir in
# this suite carries one (same line below for each sibling dir).
printf '#!/bin/sh\nexit 0\n' > "$MACBIN/claude"; chmod +x "$MACBIN/claude"
CRON_STORE="$TMP/cron.store"; : > "$CRON_STORE"
printf '#!/bin/sh\necho "at MUST NOT be called on macOS" >&2; exit 1\n' > "$MACBIN/at";  chmod +x "$MACBIN/at"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN/atq"; chmod +x "$MACBIN/atq"
cat > "$MACBIN/crontab" <<CRONEOF
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE" 2>/dev/null ;;
  -) cat > "$CRON_STORE" ;;
  *) exit 0 ;;
esac
CRONEOF
chmod +x "$MACBIN/crontab"

MAC_HO="$(make_handover "$WORK_REPO")"
mac_env() { env PATH="$MACBIN:$PATH" OSTYPE="darwin23" "$@"; }

# (a) schedule emits a crontab entry, not at -t
out="$(mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" --dry-run 2>&1)"; rc=$?
assert_rc "macOS schedule dry-run" 0 "$rc"
assert_contains "macOS uses crontab entry" "crontab entry" "$out"
assert_not_contains "macOS avoids at -t" "at -t" "$out"

# S4: the crontab/POSIX launch line also bakes -n, printf %q-escaped
# so the space in "<TICKET> <name>" survives the /bin/sh re-parse at fire time.
# Exercised on ANY host via mac_env's forced OSTYPE=darwin -> _crontab_schedule,
# so the POSIX injection is covered even when the suite runs on Windows.
S4_HO="$(make_handover "$WORK_REPO")"
out="$(mac_env bash "$ARM" --time "$(future_time)" --handover "$S4_HO" --worktree feat/himmel-702-demo --dry-run 2>&1)"; rc=$?
assert_rc "S4 macOS/cron worktree arm exits 0" 0 "$rc"
assert_contains "S4 crontab entry bakes -n <ticket> <name> (%q-escaped)" '-n HIMMEL-702\ demo' "$out"

# (b) real arm then a 2nd arm is deduped (proves list_existing reads crontab)
mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" >/dev/null 2>&1
out="$(mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" 2>&1)"; rc=$?
assert_rc "macOS 2nd arm deduped (rc=3)" 3 "$rc"

# (c) --force removes + replaces the crontab entry (one entry remains)
mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" --force >/dev/null 2>&1
n="$(grep -c 'HIMMEL-Resume-' "$CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 1 ]; then echo "PASS macOS --force keeps single entry"; else echo "FAIL macOS --force entries=$n"; FAILED=$((FAILED+1)); fi

# (d) scoped --force on macOS leaves a SIBLING handover's crontab line intact
# (invariant on the crontab path: the full-line grep -vxF delete must
# remove ONLY handover A's marker, never B's). B uses a distinct time so the
# advisory collision check has nothing to flag.
a_line="$(grep 'HIMMEL-Resume-' "$CRON_STORE" | head -1)"
MAC_HO2="$(make_handover "$WORK_REPO")"
mac_env bash "$ARM" --time "23:58" --handover "$MAC_HO2" --long-gap >/dev/null 2>&1   # arm sibling B
n="$(grep -c 'HIMMEL-Resume-' "$CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 2 ]; then echo "PASS macOS two distinct handovers coexist"; else echo "FAIL macOS expected 2 slots, got $n"; FAILED=$((FAILED+1)); fi
b_line="$(grep -vF "$a_line" "$CRON_STORE" | grep 'HIMMEL-Resume-' | head -1)"
mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" --force >/dev/null 2>&1   # force A
n="$(grep -c 'HIMMEL-Resume-' "$CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 2 ]; then echo "PASS macOS --force on A leaves sibling B (2 slots)"; else echo "FAIL macOS sibling preserve entries=$n"; FAILED=$((FAILED+1)); fi
if [ -n "$b_line" ] && grep -qF "$b_line" "$CRON_STORE" 2>/dev/null; then echo "PASS macOS sibling B line survived --force on A"; else echo "FAIL macOS sibling B line wiped"; FAILED=$((FAILED+1)); fi
fi

# ---------------------------------------------------------------------------
# T-awkfail: _crontab_delete must never fall through to
# `crontab -` with empty input just because its OWN awk filter failed
# (missing binary, runtime error, unreadable snapshot). Pre-fix, an unchecked
# awk rc left $filtered empty on ANY awk failure, `[ -z "$filtered" ]` read
# that as "the crontab is now correctly empty", and installed an EMPTY
# crontab -- wiping every entry, himmel's and the operator's unrelated ones
# alike -- and because that write "succeeded", the $snap backup made for
# exactly this recovery case was then deleted too. A legitimately-empty
# $filtered (the removed line was the only one queued) must stay a valid,
# non-fatal outcome -- only awk itself failing is the abort condition.
#
# Forces the failure with an `awk` shim that intercepts ONLY the specific
# one-shot-delete program `_crontab_delete` runs (matched on its
# `ENVIRON["MARKER"]` literal) and delegates every other awk invocation
# (frontmatter parsing, etc.) to the real binary, so nothing upstream of the
# delete step is disturbed by the injected failure.
#
# The --force below reaps the superseded slot through the post-commit sweep
# (delete_existing ... soft — see :1714-1722 / :1424-1430), which is SOFT
# mode: the new arm is already registered and verified by the time this awk
# failure hits, so  finding 1 it must WARN + keep the arm
# (rc=0), never exit 2 -- pre-fix, both crontab call sites in delete_existing
# ignored the soft flag and always hard-exited here, which is what this case
# used to assert (rc=2) before the fix landed.
# ---------------------------------------------------------------------------
if _sec_selected "T-awkfail"; then
AWKFAIL_REAL_AWK="$(command -v awk)"
AWKFAIL_DIR="$TMP/awkfail-bin"; mkdir -p "$AWKFAIL_DIR"
cat > "$AWKFAIL_DIR/awk" <<AWKEOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in
        *'ENVIRON["MARKER"]'*) echo "stub: awk forced failure (test)" >&2; exit 2 ;;
    esac
done
exec "$AWKFAIL_REAL_AWK" "\$@"
AWKEOF
chmod +x "$AWKFAIL_DIR/awk"
AWKFAIL_MACBIN="$TMP/awkfail-macbin"; mkdir -p "$AWKFAIL_MACBIN"
printf '#!/bin/sh\nexit 0\n' > "$AWKFAIL_MACBIN/claude"; chmod +x "$AWKFAIL_MACBIN/claude"   # HIMMEL-3074
AWKFAIL_CRON_STORE="$TMP/awkfail-cron.store"; : > "$AWKFAIL_CRON_STORE"
printf '#!/bin/sh\nexit 1\n' > "$AWKFAIL_MACBIN/at"; chmod +x "$AWKFAIL_MACBIN/at"
printf '#!/bin/sh\nexit 0\n' > "$AWKFAIL_MACBIN/atq"; chmod +x "$AWKFAIL_MACBIN/atq"
cat > "$AWKFAIL_MACBIN/crontab" <<CRONEOF3
#!/bin/sh
case "\$1" in
  -l) cat "$AWKFAIL_CRON_STORE" 2>/dev/null ;;
  -) cat > "$AWKFAIL_CRON_STORE" ;;
  *) exit 0 ;;
esac
CRONEOF3
chmod +x "$AWKFAIL_MACBIN/crontab"
awkfail_env() { env PATH="$AWKFAIL_DIR:$AWKFAIL_MACBIN:$PATH" OSTYPE="darwin23" "$@"; }

AWKFAIL_HO="$(make_handover "$WORK_REPO")"
awkfail_env bash "$ARM" --time "$(future_time)" --handover "$AWKFAIL_HO" >/dev/null 2>&1   # seed (real awk; no ENVIRON["MARKER"] call yet)
seed_n="$(grep -c 'HIMMEL-Resume-' "$AWKFAIL_CRON_STORE" 2>/dev/null)" || seed_n=0
if [ "$seed_n" -eq 1 ]; then echo "PASS T-awkfail seed: pre-existing slot armed"; else echo "FAIL T-awkfail seed left $seed_n slot(s) (expected 1)"; FAILED=$((FAILED+1)); fi

out=$(awkfail_env bash "$ARM" --time "$(future_time)" --handover "$AWKFAIL_HO" --force 2>&1)
rc=$?
assert_rc "T-awkfail soft-mode awk failure does NOT kill the script (rc=0)" 0 "$rc"
assert_contains "T-awkfail WARN names the awk failure" "could NOT be removed (awk rc=" "$out"
assert_contains "T-awkfail WARN says the sibling is still queued" "STILL QUEUED" "$out"
assert_contains "T-awkfail WARN surfaces the un-reaped count" "superseded job(s) could not be reaped" "$out"
assert_contains "T-awkfail the new arm still stands" "RESUME ARMED" "$out"
assert_not_contains "T-awkfail does NOT print the misleading success line" "removed crontab entry" "$out"
n="$(grep -c 'HIMMEL-Resume-' "$AWKFAIL_CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 2 ]; then echo "PASS T-awkfail both the un-reaped old entry and the new arm remain (2 entries)"; else echo "FAIL T-awkfail expected 2 entries (old un-reaped + new), got $n"; FAILED=$((FAILED+1)); fi
snap_path=$(printf '%s' "$out" | grep -oE '/[^ ]*crontab\.snap\.[A-Za-z0-9]+(\.[A-Za-z0-9]+)?' | head -1)  # BSD mktemp -t appends ".<rand>" after XXXXXX
if [ -n "$snap_path" ] && [ -s "$snap_path" ]; then
    echo "PASS T-awkfail snapshot preserved ($snap_path)"
    rm -f "$snap_path"   # HIMMEL-1370: it lives under the real tmp, not $TMP
else
    echo "FAIL T-awkfail snapshot missing or empty (path='$snap_path')"
    FAILED=$((FAILED+1))
fi

fi
posix_env() {
    local _dir="$1"; shift
    env PATH="$_dir:$PATH" OSTYPE=linux-gnu "$@"
}

# ---------------------------------------------------------------------------
# refuse to arm a REAL task against a TEMP/scratch target.
#
# The 2026-07 incident: a hand-run repro created a real schtasks entry pointing
# at a scratchpad fixture, firing at 23:59 into an unattended session. The whole
# suite arms $TMP fixtures deliberately (see the ARM_TEMP_CWD_OK shield above),
# so these cases unset it to exercise the guard itself.
# ---------------------------------------------------------------------------
if _sec_selected "1365" "HIMMEL-1365"; then
R1365="$TMP/h1365"
mkdir -p "$R1365/handovers"
printf -- '---\nresume_cwd: %s\n---\n\n# temp target\n' "$WORK_REPO" \
    > "$R1365/handovers/temp-target.md"

out=$(env -u ARM_TEMP_CWD_OK TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$R1365/handovers/temp-target.md" 2>&1)
assert_rc "1365 temp work dir refuses (rc=12)" 12 "$?"
assert_contains "1365 ERR names the temp path" "TEMP/scratch path" "$out"
assert_contains "1365 ERR names the override" "ARM_TEMP_CWD_OK=1" "$out"

# The declared opt-out lets a harness arm its own fixture.
out=$(ARM_TEMP_CWD_OK=1 TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$R1365/handovers/temp-target.md" 2>&1)
rc=$?
if [ "$rc" -eq 12 ]; then
    echo "FAIL 1365 ARM_TEMP_CWD_OK=1 did not override the temp refusal"
    FAILED=$((FAILED + 1))
else
    echo "PASS 1365 ARM_TEMP_CWD_OK=1 overrides the temp refusal (rc=$rc)"
fi

# --dry-run is exempt: it creates no scheduled task, so there is nothing to
# protect against, and the suite's own dry-run cases must keep working.
out=$(env -u ARM_TEMP_CWD_OK TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$R1365/handovers/temp-target.md" --dry-run 2>&1)
rc=$?
if [ "$rc" -eq 12 ]; then
    echo "FAIL 1365 --dry-run must be exempt from the temp refusal"
    FAILED=$((FAILED + 1))
else
    echo "PASS 1365 --dry-run is exempt from the temp refusal (rc=$rc)"
fi

# A NON-temp target must be unaffected — the guard keys on the target path, so
# this is what proves it is not simply refusing everything.
R1365_REAL="$TMP/h1365-real"   # under $TMP, but the RESUME_CWD below is not
mkdir -p "$R1365_REAL"
printf -- '---\nresume_cwd: %s\n---\n\n# real target\n' "$PWD" \
    > "$R1365_REAL/real-target.md"
out=$(env -u ARM_TEMP_CWD_OK -u ARM_FIXTURE_OK TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$R1365_REAL/real-target.md" 2>&1)
rc=$?
# widened the guard from cwd-only to BOTH halves of the fired
# session's identity, so this fixture (temp HANDOVER, real cwd) now refuses --
# and it should: arming a REAL unattended session that loads throwaway
# instructions INTO a real repo is the worse half of the 2026-07 incident
# shape, not the safe half. What still has to hold is that the guard stays
# DISCRIMINATING rather than blanket, which the ERR proves by naming which half
# tripped: the handover file, and NOT the (real) work directory.
assert_rc "1365 a temp HANDOVER refuses even with a real work dir (rc=12)" 12 "$rc"
assert_contains "1365 the ERR names the handover half" "handover file:" "$out"
assert_not_contains "1365 the ERR does NOT blame the real work dir" "target work directory:" "$out"
fi

# ---------------------------------------------------------------------------
# refuse to re-arm work that already shipped.
#
# Two real instances on 2026-07-28: re-armed at 23:40 after merging
# at 21:25; re-armed while PR #1428 was open and mergeable. Each
# burns a full autonomous session and produces rework.
#
# Hermetic: gh is a PATH stub whose output is scripted per case, so nothing
# reaches the network. The stub also stands in for "gh is present" — its
# ABSENCE is what the fail-open case exercises.
# ---------------------------------------------------------------------------
# assert_not_11 <label> <rc> -- the invariant for every non-refusing case.
# Downstream codes vary (0/1/3) as scheduler + registry state accumulates
# across these reruns; what each case pins is that the SHIPPED preflight did
# not fire.
assert_not_11() {
    if [ "$2" -eq 11 ]; then
        echo "FAIL $1 — shipped preflight fired (rc=11)"; FAILED=$((FAILED + 1))
    else
        echo "PASS $1 (rc=$2)"
    fi
}

if _sec_selected "1331" "HIMMEL-1331"; then
R1331="$TMP/h1331"
mkdir -p "$R1331/bin" "$R1331/repo" "$R1331/state/handovers"
( cd "$R1331/repo" && git init -q -b feat/shipped-thing . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
printf -- '---\nresume_cwd: %s\n---\n\n# HIMMEL-9001 shipped thing\n' "$R1331/repo" \
    > "$R1331/state/handovers/shipped.md"

# The stub is reached through GH_CMD, NOT through PATH. On Windows a PATH
# stub does not work here: an extensionless `gh` script loses to gh.exe even
# when its directory comes first, so a PATH-stubbed test silently exercises the
# REAL gh (verified while writing these). GH_CMD is the house seam for exactly
# this -- see scripts/graphify/graph-publish.sh and scripts/cr/*.
GH_FAKE="$R1331/bin/ghfake"
mk_gh_stub() { # <tsv-payload: number \t state \t mergeable>
    {
        printf '#!/usr/bin/env bash\n'
        printf 'case "$*" in *"pr list"*) printf "%%s\\n" "%s";; *) exit 0;; esac\n' "$1"
    } > "$GH_FAKE"
    chmod +x "$GH_FAKE"
}

# Sets $out and RETURNS the rc. Deliberately NOT `rc=$(_a1331)`: command
# substitution runs the function in a SUBSHELL, so $out is assigned there and
# lost here -- which leaves every message assertion comparing against an EMPTY
# string while the rc assertions still pass. That is exactly how the first cut
# of these tests reported "ERR names the merged PR: output missing" for a
# refusal that had in fact printed it.
_a1331() {
    out=$(TMPDIR="$TMP" GH_CMD="${GHC_1331:-$GH_FAKE}" PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" \
        --handover "$R1331/state/handovers/shipped.md" "$@" 2>&1)
}

# (a) MERGED PR on the branch -> refuse rc=11, naming the PR.
mk_gh_stub '1428	MERGED	UNKNOWN'
_a1331; rc=$?
assert_rc "1331 merged PR refuses (rc=11)" 11 "$rc"
assert_contains "1331 ERR names the merged PR" "PR #1428" "$out"
assert_contains "1331 ERR names the branch" "feat/shipped-thing" "$out"
assert_contains "1331 ERR points at the override" "ARM_SHIPPED_OK=1" "$out"

# (b) OPEN + MERGEABLE -> the shape (work finished, waiting on a
# human), also refuses.
mk_gh_stub '1428	OPEN	MERGEABLE'
_a1331; rc=$?
assert_rc "1331 open+mergeable PR refuses (rc=11)" 11 "$rc"
assert_contains "1331 ERR says OPEN and MERGEABLE" "OPEN and MERGEABLE" "$out"

# (c) OPEN but CONFLICTING -> real unfinished work, must NOT refuse.
mk_gh_stub '1428	OPEN	CONFLICTING'
_a1331; assert_not_11 "1331 conflicting PR does not trip the preflight" "$?"

# (d) CLOSED unmerged -> abandoned, not shipped; must NOT refuse.
mk_gh_stub '1428	CLOSED	UNKNOWN'
_a1331; assert_not_11 "1331 closed-unmerged PR does not trip the preflight" "$?"

# (e) --force overrides a MERGED PR (the ticket's documented escape hatch).
mk_gh_stub '1428	MERGED	UNKNOWN'
_a1331 --force; assert_not_11 "1331 --force overrides the shipped refusal" "$?"

# (f) ARM_SHIPPED_OK=1 is the env twin of --force.
ARM_SHIPPED_OK=1 _a1331
assert_not_11 "1331 ARM_SHIPPED_OK=1 overrides the shipped refusal" "$?"

# (g) FAIL-OPEN: gh unavailable. A machine that cannot answer the question must
# still arm -- refusing because the box is offline would be a worse failure than
# the one this check prevents.
GHC_1331=/nonexistent/gh _a1331
assert_not_11 "1331 fails open when gh is unavailable" "$?"

# (h) --dry-run must stay side-effect-free: it skips the network probes.
mk_gh_stub '1428	MERGED	UNKNOWN'
_a1331 --dry-run; assert_not_11 "1331 --dry-run skips the shipped preflight" "$?"
fi

# ---------------------------------------------------------------------------
# (bug fix, part of the 1329/1330/1331 trio) — the TICKET-STATUS
# half of the shipped preflight ((a) in _arm_shipped_preflight) was dead code:
# _ho_ticket was `unset` right after TASK_NAME derivation but read again later
# via `${_ho_ticket:-}`, so it was always empty and the Done/Closed/wont-do/
# wont-fix check never ran. Confirmed before this fix: none of the (a)-(h)
# cases above exercise it — every one only drives the PR/branch half. Fixed
# by keeping _ho_ticket alive. ARM_JIRA_CLI is a new test seam (added
# alongside the fix, same shape as GH_CMD) pointing the probe at
# a fixture CLI — this worktree has no built scripts/jira/dist/index.js to
# test against otherwise.
# ---------------------------------------------------------------------------
if _sec_selected "1331b" "1331" "HIMMEL-1331"; then
if command -v node >/dev/null 2>&1; then
    R1331B="$TMP/h1331b"
    mkdir -p "$R1331B/repo"
    ( cd "$R1331B/repo" && git init -q -b feat/ticket-status-thing . \
        && git config user.email t@t.t && git config user.name t \
        && git config commit.gpgsign false \
        && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
    JIRA_FAKE="$TMP/h1331b/jira-fake.js"
    cat > "$JIRA_FAKE" <<'EOF'
#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'get') {
    console.log(args[1] + '\tsome summary\t' + (process.env.FAKE_JIRA_STATUS || 'Open'));
}
EOF
    HO_1331B="$R1331B/repo-handover.md"
    printf -- '---\nticket: HIMMEL-9002\nresume_cwd: %s\n---\n\n# HIMMEL-9002 ticket-status thing\n' \
        "$R1331B/repo" > "$HO_1331B"

    _a1331b() {
        local status="$1"; shift
        out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE" \
            FAKE_JIRA_STATUS="$status" PATH="$ARMED_STUB:$PATH" \
            bash "$ARM" --time "$(future_time)" --handover "$HO_1331B" "$@" 2>&1)
    }

    _a1331b Done; rc=$?
    assert_rc "1331b Done ticket status refuses (rc=11)" 11 "$rc"
    assert_contains "1331b ERR names the ticket" "HIMMEL-9002" "$out"

    _a1331b "In Progress"; assert_not_11 "1331b In-Progress ticket does not trip the preflight" "$?"

    _a1331b Done --force; assert_not_11 "1331b --force overrides the ticket-status refusal" "$?"

    ARM_SHIPPED_OK=1 _a1331b Done; assert_not_11 "1331b ARM_SHIPPED_OK=1 overrides the ticket-status refusal" "$?"
else
    echo "PASS 1331b skipped — node not available on this host"
fi
fi

# ---------------------------------------------------------------------------
# worker-header false positive: a chained handover's H1 follows
# the epic's own "# Next Session — <worker-header>" convention (see
# make_handover_chained / N9-N13 above), and when a project happens to have
# an unrelated Done ticket numbered like the worker, _infer_ticket's src-3 (H1
# scan) used to weld THAT ticket into $_ho_ticket, false-tripping the
# shipped-work preflight (rc=11) against a handover that never
# referenced the real ticket at all. Fix: (1) the preflight now reads
# $_ho_ticket_strict (frontmatter-only), never the loose $_ho_ticket; (2)
# src-3 itself now skips H1 scanning for chain files (basename
# next-session-<N>.md) as defense-in-depth, so the loose ticket inference
# doesn't carry the worker-header key either. Both effects are asserted below.
# ---------------------------------------------------------------------------
if _sec_selected "2113c" "HIMMEL-2113"; then
if command -v node >/dev/null 2>&1; then
    R2113C="$TMP/h2113c"
    mkdir -p "$R2113C/repo"
    ( cd "$R2113C/repo" && git init -q -b feat/worker-header-thing . \
        && git config user.email t@t.t && git config user.name t \
        && git config commit.gpgsign false \
        && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
    JIRA_FAKE_2113C="$R2113C/jira-fake.js"
    cat > "$JIRA_FAKE_2113C" <<'EOF'
#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'get') {
    console.log(args[1] + '\tsome summary\tDone');
}
EOF
    # Chain file whose H1 is a worker header, NOT a ticket reference -- no
    # frontmatter ticket, generic (non-ticket-prefixed) epic dir so src-4
    # cannot supply a key either. LUNA-64 here stands in for the incident's
    # unrelated Done ticket that happens to share the worker number.
    mkdir -p "$R2113C/epic-notes"
    HO_2113C="$R2113C/epic-notes/next-session-64.md"
    printf -- '---\nresume_cwd: %s\n---\n\n# Next Session — LUNA-64\n' "$R2113C/repo" > "$HO_2113C"

    # ARM_PROFILE=1 (seam, reused here): this
    # fixture's ticket resolves to EMPTY (that's the whole point -- the
    # worker-header must NOT supply one), so the preflight's own Jira-status
    # branch never prints anything either way, refusal or not. Without an
    # independent "the preflight code path actually ran" signal, a rc=10
    # live-worker-census refusal upstream of the preflight would still read
    # as rc!=11 and pass VACUOUSLY. The "shipped-work-preflight=" phase-timing
    # line is emitted unconditionally the instant _arm_shipped_preflight
    # returns (see the call site), regardless of what it found -- exactly the
    # deterministic-under-these-stubs marker this needs.
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE_2113C" ARM_PROFILE=1 \
        PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$HO_2113C" 2>&1)
    rc=$?
    if grep -q "shipped-work-preflight=" <<<"$out"; then
        # codex-3: deliberately not tightened to `assert_rc 0` -- this is a
        # REAL (non-dry-run) arm, so it runs the UNSTUBBED live worker census
        # (reconcile-workers.sh against this actual host's real lane workers,
        # same as the sibling 1331/1331b real-arm cases above). A live/
        # unprobeable worker on the box would legitimately rc=10 BEFORE
        # reaching the preflight -- caught by the branch below, not here. The
        # one invariant this case actually pins, now that we KNOW the
        # preflight ran, is "never rc=11" (the worker-header false positive).
        assert_not_11 "2113c worker-header false positive no longer refuses (rc!=11)" "$rc"
        assert_not_contains "2113c worker-header key not welded into the task name" "LUNA-64" "$out"
    else
        echo "PASS 2113c skipped — shipped-work preflight never ran (blocked upstream, e.g. a live/unprobeable worker on this host, rc=$rc); host state, not a fixture bug"
    fi
else
    echo "PASS 2113c skipped — node not available on this host"
fi
fi

# ---------------------------------------------------------------------------
# explicit-time outrun WARN, printed at PARSE time (right
# after the --time HH:MM python resolve, before any slow phase runs) instead
# of only being discoverable via the end-of-script rollover guard. Purely
# advisory: rc stays 0 either way; --dry-run is fine since the check is one
# arithmetic compare against already-computed values.
# ---------------------------------------------------------------------------
if _sec_selected "2113d" "HIMMEL-2113"; then
NEAR_2113D=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=2)).strftime("%H:%M"))')
HO_2113D=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$NEAR_2113D" --handover "$HO_2113D" --dry-run 2>&1)
rc=$?
assert_rc "2113d near --time still arms (rc=0, advisory only)" 0 "$rc"
assert_contains "2113d WARN fires early for a near --time" "outrun that lead" "$out"

HO_2113D2=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2113D2" --dry-run 2>&1)
rc=$?
assert_rc "2113d far --time arms (rc=0)" 0 "$rc"
assert_not_contains "2113d no outrun WARN for a far --time" "outrun that lead" "$out"
fi

# ---------------------------------------------------------------------------
# ARM_PROFILE=1 emits a "PROFILE arm-resume: ..." line naming a
# known phase, on a plain success/dry-run exit AND on a REFUSAL exit. The
# refusal case pins the review-round EXIT-trap fix: the profile reporter is
# registered on a `trap ... EXIT` at the top of the script (not a hand-picked
# print before each success exit), so a mid-script refusal (rc=19 here, the
# Ask A quota-park guard) must still print it. Without that fix a refusal
# printed no PROFILE line at all.
# ---------------------------------------------------------------------------
if _sec_selected "2113e" "HIMMEL-2113"; then
HO_2113E=$(make_handover "$WORK_REPO")
out=$(ARM_PROFILE=1 PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2113E" --dry-run 2>&1)
rc=$?
assert_rc "2113e ARM_PROFILE dry-run still arms (rc=0)" 0 "$rc"
assert_contains "2113e PROFILE line names a known phase" "PROFILE arm-resume: queue-lock-probe" "$out"

FIVE_RESET_2113E=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')
SEVEN_RESET_2113E=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')
BUSY_CACHE_2113E="$TMP/usage-95-2113e.json"
printf '{"five_hour":{"utilization":10.0,"resets_at":"%s"},"seven_day":{"utilization":95.0,"resets_at":"%s"},"account":"%s"}' \
    "$FIVE_RESET_2113E" "$SEVEN_RESET_2113E" "$ACCT" > "$BUSY_CACHE_2113E"
HO_2113E2=$(make_handover "$WORK_REPO")
out=$(ARM_PROFILE=1 RESUME_SLOT_CACHE="$BUSY_CACHE_2113E" SLOT_MAX_AGE=0 PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO_2113E2" --force --dry-run 2>&1)
rc=$?
assert_rc "2113e refusal path still exits 19" 19 "$rc"
assert_contains "2113e PROFILE line fires on the EXIT-trap refusal path too" "PROFILE arm-resume: usage-cache-slot-resolve" "$out"
fi

# ---------------------------------------------------------------------------
# — a chain handover with NO frontmatter
# `ticket:` must still resolve its ticket from the PARENT DIR name (src-4) for
# the shipped-work preflight. The strict frontmatter-only narrowing (2113c)
# over-corrected: it closed the H1 worker-header false positive but also dropped
# this UNAMBIGUOUS signal, silently disabling the Jira-status half of the
# preflight for every no-frontmatter chain handover. Parent dir here IS
# ticket-shaped (KEY-9004-slug) -- the opposite of 2113c's deliberately
# generic "epic-notes" dir -- so this pins the fallback without reopening the
# worker-header false positive (2113c already pins that H1 stays ignored).
# ---------------------------------------------------------------------------
if _sec_selected "2113f" "HIMMEL-2113"; then
if command -v node >/dev/null 2>&1; then
    R2113F="$TMP/h2113f"
    mkdir -p "$R2113F/repo"
    ( cd "$R2113F/repo" && git init -q -b feat/parent-dir-ticket-thing . \
        && git config user.email t@t.t && git config user.name t \
        && git config commit.gpgsign false \
        && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
    JIRA_FAKE_2113F="$R2113F/jira-fake.js"
    cat > "$JIRA_FAKE_2113F" <<'EOF'
#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'get') {
    console.log(args[1] + '\tsome summary\tDone');
}
EOF
    # No `ticket:` frontmatter -- only the ticket-shaped parent dir name
    # (src-4) names. H1 is a plain worker header, same convention as
    # 2113c, to prove this is the parent-dir fallback firing, not a stray H1
    # match (src-3 already skips H1 for chain files regardless).
    mkdir -p "$R2113F/HIMMEL-9004-parent-dir-thing"
    HO_2113F="$R2113F/HIMMEL-9004-parent-dir-thing/next-session-1.md"
    printf -- '---\nresume_cwd: %s\n---\n\n# Next Session — worker 1\n' "$R2113F/repo" > "$HO_2113F"

    # ARM_PROFILE=1 + a marker check (codex-1, same guard 2113c got): closes
    # the vacuous-pass hole where a live/unprobeable host worker rc=10s the
    # UNSTUBBED census before the preflight ever runs, and "rc=11" (or "not
    # 11") would otherwise be asserted against a run that never reached it.
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE_2113F" ARM_PROFILE=1 \
        PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$HO_2113F" 2>&1)
    rc=$?
    if grep -q "shipped-work-preflight=" <<<"$out"; then
        assert_rc "2113f parent-dir ticket (no frontmatter) still trips the Done refusal (rc=11)" 11 "$rc"
        assert_contains "2113f ERR names the parent-dir ticket" "HIMMEL-9004" "$out"
    else
        echo "PASS 2113f skipped — shipped-work preflight never ran (blocked upstream, e.g. a live/unprobeable worker on this host, rc=$rc); host state, not a fixture bug"
    fi

    # Second case: ARM_SHIPPED_OK=1 takes arm-resume's FIRST if-branch (a
    # no-op ":"), so _arm_shipped_preflight is NEVER called here even on a
    # correctly-working override -- "shipped-work-preflight=" would never
    # appear and would wrongly skip every run. The marker that instead proves
    # this run reached that decision point (regardless of which branch fires)
    # is "arms-registry-cross-host=", the phase immediately BEFORE it and
    # common to every branch.
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE_2113F" ARM_SHIPPED_OK=1 ARM_PROFILE=1 \
        PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$HO_2113F" 2>&1)
    rc=$?
    if grep -q "arms-registry-cross-host=" <<<"$out"; then
        assert_not_11 "2113f ARM_SHIPPED_OK=1 overrides the parent-dir ticket-status refusal" "$rc"
    else
        echo "PASS 2113f (ARM_SHIPPED_OK case) skipped — run never reached the shipped-work decision point (blocked upstream, e.g. a live/unprobeable worker on this host, rc=$rc); host state, not a fixture bug"
    fi
else
    echo "PASS 2113f skipped — node not available on this host"
fi
fi

# ---------------------------------------------------------------------------
# — the parent-dir fallback must NOT prefix-match: a
# dir named KEY-9004foo is NOT the ticket (no delimiter after
# the digit run), even though a fake Jira would report as Done.
# The old bare `grep -oiE '^KEY-[0-9]+'` welded the prefix out regardless of
# what followed; this must resolve to NO ticket at all, so the preflight has
# nothing to check and the arm proceeds (rc != 11).
# ---------------------------------------------------------------------------
if _sec_selected "2113g" "HIMMEL-2113"; then
if command -v node >/dev/null 2>&1; then
    R2113G="$TMP/h2113g"
    mkdir -p "$R2113G/repo"
    ( cd "$R2113G/repo" && git init -q -b feat/parent-dir-prefix-thing . \
        && git config user.email t@t.t && git config user.name t \
        && git config commit.gpgsign false \
        && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
    JIRA_FAKE_2113G="$R2113G/jira-fake.js"
    cat > "$JIRA_FAKE_2113G" <<'EOF'
#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'get') {
    console.log(args[1] + '\tsome summary\tDone');
}
EOF
    # Parent dir is KEY-9004foo -- NOT delimited after the digits, so this
    # must NOT resolve to ticket even though the fake Jira would
    # report it Done.
    mkdir -p "$R2113G/HIMMEL-9004foo"
    HO_2113G="$R2113G/HIMMEL-9004foo/next-session-1.md"
    printf -- '---\nresume_cwd: %s\n---\n\n# Next Session — worker 1\n' "$R2113G/repo" > "$HO_2113G"

    # ARM_PROFILE=1 + marker check (codex-1, same guard 2113c/2113f got): no
    # --force/ARM_SHIPPED_OK here, so this always takes the preflight-calling
    # branch on a clean run -- but a live/unprobeable host worker still rc=10s
    # the UNSTUBBED census first, which would make "rc!=11" pass vacuously.
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE_2113G" ARM_PROFILE=1 \
        PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$HO_2113G" 2>&1)
    rc=$?
    if grep -q "shipped-work-preflight=" <<<"$out"; then
        assert_not_11 "2113g undelimited parent-dir prefix does not false-trip the preflight (rc!=11)" "$rc"
        assert_not_contains "2113g HIMMEL-9004 never gets welded out of HIMMEL-9004foo" "HIMMEL-9004 is 'Done'" "$out"
    else
        echo "PASS 2113g skipped — shipped-work preflight never ran (blocked upstream, e.g. a live/unprobeable worker on this host, rc=$rc); host state, not a fixture bug"
    fi
else
    echo "PASS 2113g skipped — node not available on this host"
fi
fi

# ---------------------------------------------------------------------------
# two ADVISORY pre-arm WARNs, printed at PARSE time (same
# "before any slow phase" placement as the 2113d outrun WARN above). Purely
# advisory: rc stays 0 (or whatever it already was) either way, so --dry-run
# is fine — the cheapest honest pin, same shape as 2113d.
# ---------------------------------------------------------------------------
if _sec_selected "2128" "HIMMEL-2128"; then
# (a) --automerge NOT passed -> WARN that the chain stops at green PRs.
# ambient ARMAUTOMERGE=1 (e.g. an armed himmel session's own
# exported env) would otherwise win over the absent .env value via
# load_dotenv's non-clobber contract and suppress the WARN. `env -u` alone
# handles the ambient-PROCESS-env case; the .env FILE half is handled by the
# top-of-suite ARM_RESUME_DOTENV_ROOT shield -- on a host whose
# own .env sets ARMAUTOMERGE=1 (the default) `env -u` alone is
# NOT enough, because the key is re-read from disk.
#
# (a2) --automerge passed -> no WARN. Explicit --automerge always wins over
# both ambient env and .env (arm-resume.sh:955), so this case needs no
# shield.
HO_2128A2=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128A2" --dry-run --automerge 2>&1)
rc=$?
assert_rc "2128a2 --automerge passed still arms (rc=0)" 0 "$rc"
assert_not_contains "2128a2 no WARN when --automerge is passed" "will NOT set ARMAUTOMERGE" "$out"

# (b) CR_REQUIRE_CROSS_MODEL truthy + CR_FLOOR_FALLBACK unset -> WARN that a
# mid-chain bank exhaustion parks the whole armed chain. Process env is
# authoritative over any .env for CR_REQUIRE_CROSS_MODEL=1 here — but
# CR_FLOOR_FALLBACK is NOT: load_dotenv treats an empty value as absent and
# reloads it from .env (its own documented contract), so a bare
# `CR_FLOOR_FALLBACK=` on the invocation does NOT force genuine absence when
# the PRIMARY checkout's own .env already sets this key (this host's does).
# the previous version of this test SKIPPED the
# assertion whenever ambient .env set the key, which would let the WARN path
# regress unnoticed on exactly such a host and never exercised the typo case
# at all. So this suite controls CR_FLOOR_FALLBACK itself (and, per
# above, ARMAUTOMERGE for case (a)).
# ARM_RESUME_DOTENV_ROOT (top-of-suite shield) already points the
# dotenv READ at an EMPTY suite-owned dir, so ARMAUTOMERGE and CR_FLOOR_FALLBACK
# are genuinely absent here with no repo write and no skip branch -- the old
# worktree-`.env` trick skipped this whole group whenever the checkout it ran
# from already had a `.env`, i.e. always on a primary checkout.

# `env -u` is defense-in-depth against ambient PROCESS env on top of the
# .env shield above (load_dotenv's non-clobber contract would otherwise
# let a live ambient ARMAUTOMERGE win before .env is ever consulted).
HO_2128A=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128A" --dry-run 2>&1)
rc=$?
assert_rc "2128a no --automerge still arms (rc=0, advisory only)" 0 "$rc"
assert_contains "2128a WARN fires when --automerge is not passed" "will NOT set ARMAUTOMERGE" "$out"

# Policy keys are read by load_policy, which ignores the process env, so
# every 2128b case drives them through the suite-owned .env seam.
printf 'CR_REQUIRE_CROSS_MODEL=1\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2128B=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128B" --dry-run 2>&1)
rc=$?
assert_rc "2128b cross-model + no fallback still arms (rc=0, advisory only)" 0 "$rc"
assert_contains "2128b WARN fires when CR_REQUIRE_CROSS_MODEL is on and CR_FLOOR_FALLBACK is unset" "PARKING the whole armed chain" "$out"

# (b3) CR_FLOOR_FALLBACK set to an UNRECOGNIZED value ("claude_only" typo,
# underscore not hyphen) -> WARN still fires. It never actually enables the
# fallback (clear-review-marker.sh only recognizes the exact "claude-only"
# string), so production SHOULD warn here too.
printf 'CR_REQUIRE_CROSS_MODEL=1\nCR_FLOOR_FALLBACK=claude_only\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2128B3=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128B3" --dry-run 2>&1)
rc=$?
assert_rc "2128b3 cross-model + typo'd fallback value still arms (rc=0)" 0 "$rc"
assert_contains "2128b3 WARN fires when CR_FLOOR_FALLBACK does not match the recognized claude-only value" "PARKING the whole armed chain" "$out"

# (b2) CR_FLOOR_FALLBACK set to the recognized value -> no WARN.
printf 'CR_REQUIRE_CROSS_MODEL=1\nCR_FLOOR_FALLBACK=claude-only\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2128B2=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128B2" --dry-run 2>&1)
rc=$?
assert_rc "2128b2 cross-model + fallback set still arms (rc=0)" 0 "$rc"
assert_not_contains "2128b2 no WARN when CR_FLOOR_FALLBACK is set" "PARKING the whole armed chain" "$out"
rm -f "$ARM_RESUME_DOTENV_ROOT/.env"
fi

# ---------------------------------------------------------------------------
# ARMAUTOMERGE .env default. When --automerge is not passed on
# this invocation, arm-resume.sh reads ARMAUTOMERGE from the PRIMARY
# checkout's .env (accepted truthy values: 1/true/on/yes, case-insensitive,
# arm-resume.sh:965) and treats it as if --automerge had been passed. An
# explicit --automerge on the invocation always wins regardless of .env
# (arm-resume.sh:955). Same worktree-local `.env` trick as 2128b above, so
# this suite controls the value with no change to the actual resolution code.
# ---------------------------------------------------------------------------
if _sec_selected "2147" "HIMMEL-2147"; then
# this section drives the .env value through the suite-owned
# ARM_RESUME_DOTENV_ROOT dir (declared with the other shields at the top),
# not through a throwaway `.env` written at the repo root. The old trick
# short-circuited `_load_dotenv_primary_for` on the FIRST dir that has a
# `.env` -- which meant it SKIPPED itself entirely whenever the checkout it
# ran from already had one (always, on a primary checkout), so the whole
# section was a vacuous PASS on exactly the hosts running it. The seam needs
# no repo write, no EXIT-trap backstop, and no skip branch.

# Ambient ARMAUTOMERGE (e.g. an operator shell that exports it for its own
# overnight-arm convenience) would otherwise win over the .env value under
# test via load_dotenv's own non-clobber contract (a live non-empty value
# is never overwritten) -- `env -u` makes every sub-case below
# hermetic to that ambient state, matching what it is actually testing.

# (a) .env ARMAUTOMERGE=1, no --automerge flag -> default applies: no WARN,
# launch text carries the grant.
printf 'ARMAUTOMERGE=1\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2147A=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147A" --dry-run 2>&1)
rc=$?
assert_rc "2147a .env ARMAUTOMERGE=1 (no --automerge flag) still arms (rc=0)" 0 "$rc"
assert_not_contains "2147a no WARN -- .env default applied" "will NOT set ARMAUTOMERGE" "$out"
assert_contains "2147a launch carries ARMAUTOMERGE=1 from the .env default" "ARMAUTOMERGE=1" "$out"

# (b) .env ARMAUTOMERGE=TRUE (mixed-case truthy) -> same as (a).
printf 'ARMAUTOMERGE=TRUE\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2147B=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147B" --dry-run 2>&1)
rc=$?
assert_rc "2147b .env ARMAUTOMERGE=TRUE still arms (rc=0)" 0 "$rc"
assert_not_contains "2147b no WARN -- truthy .env value is case-insensitive" "will NOT set ARMAUTOMERGE" "$out"

# (c) .env ARMAUTOMERGE=nope (unrecognized value) -> WARN still fires, no
# default applied.
printf 'ARMAUTOMERGE=nope\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2147C=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147C" --dry-run 2>&1)
rc=$?
assert_rc "2147c .env ARMAUTOMERGE=nope still arms (rc=0)" 0 "$rc"
assert_contains "2147c WARN fires -- unrecognized .env value is not truthy" "will NOT set ARMAUTOMERGE" "$out"

# (d) explicit --automerge flag wins even when .env holds a falsy value.
printf 'ARMAUTOMERGE=0\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2147D=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147D" --dry-run --automerge 2>&1)
rc=$?
assert_rc "2147d --automerge flag wins over a falsy .env value (rc=0)" 0 "$rc"
assert_not_contains "2147d no WARN when --automerge is explicit" "will NOT set ARMAUTOMERGE" "$out"
assert_contains "2147d launch carries ARMAUTOMERGE=1 from the explicit flag" "ARMAUTOMERGE=1" "$out"

# Restore the shield dir to its EMPTY default for any later section.
rm -f "$ARM_RESUME_DOTENV_ROOT/.env"
fi

# ---------------------------------------------------------------------------
# --no-automerge decline flag + merge-gate/ARMAUTOMERGE grant
# decoupling. --automerge raises the dotenv-derived ARMAUTOMERGE opt-in above;
# until now there was no way to lower it back down for a single arm, so a worker
# armed specifically to park on every green PR silently inherited the
# station's on-disk default instead. Separately (item 4, operator ruling): the
# dotenv default used to grant CR_MERGE_GATE_OK=1 alongside ARMAUTOMERGE=1 --
# the merge gate's OWN bypass, which a bare `.env` setting never had explicit
# consent to flip. Only an explicit --automerge on THIS invocation may grant
# CR_MERGE_GATE_OK=1 now.
# ---------------------------------------------------------------------------
if _sec_selected "3118" "HIMMEL-3118"; then

# (a) --automerge and --no-automerge together are refused before any arming
# work happens.
HO_3118A=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_3118A" --dry-run --automerge --no-automerge 2>&1)
rc=$?
assert_rc "3118a --automerge + --no-automerge refused (rc=2)" 2 "$rc"
assert_contains "3118a ERR names the conflict" "mutually exclusive" "$out"

# (b) RED control: dotenv opt-in ON, no --no-automerge -> the .env default
# still applies (ARMAUTOMERGE=1 in the launch text). Proves the shield below
# is live before (c) proves --no-automerge overrides it.
printf 'ARMAUTOMERGE=1\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_3118B=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_3118B" --dry-run 2>&1)
rc=$?
assert_rc "3118b RED control: dotenv default alone still arms (rc=0)" 0 "$rc"
assert_contains "3118b RED control: dotenv default grants ARMAUTOMERGE=1" "ARMAUTOMERGE=1" "$out"

# (c) --no-automerge forces AUTOMERGE=0 even though the SAME .env opt-in from
# (b) is still in place -- the flag must win over the on-disk default.
HO_3118C=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_3118C" --dry-run --no-automerge 2>&1)
rc=$?
assert_rc "3118c --no-automerge still arms (rc=0)" 0 "$rc"
assert_contains "3118c resolved state shows automerge=0 sourced from the flag" "automerge=0 merge_gate_bypass=0 (source: --no-automerge flag)" "$out"
assert_not_contains "3118c --no-automerge overrides the dotenv default -- no ARMAUTOMERGE=1 grant" "ARMAUTOMERGE=1 " "$out"
assert_not_contains "3118c --no-automerge overrides the dotenv default -- no CR_MERGE_GATE_OK=1 grant" "CR_MERGE_GATE_OK=1" "$out"

# (d) item 4, the chief's second RED-control arm: the dotenv default (no
# flags at all) grants ARMAUTOMERGE=1 ONLY -- CR_MERGE_GATE_OK=1 is no longer
# bundled into a bare .env opt-in. Pre-fix code emits BOTH here (that is
# exactly what item 4 rules out), so this assertion fails on the pre-fix
# arm-resume.sh and passes only after the decoupling fix.
HO_3118D=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_3118D" --dry-run 2>&1)
rc=$?
assert_rc "3118d dotenv default alone still arms (rc=0)" 0 "$rc"
assert_contains "3118d resolved state: automerge=1, merge_gate_bypass=0, dotenv source" "automerge=1 merge_gate_bypass=0 (source: dotenv default (ARMAUTOMERGE=1 in the policy config or .env))" "$out"
assert_contains "3118d launch text carries ARMAUTOMERGE=1 from the dotenv default" "ARMAUTOMERGE=1" "$out"
assert_not_contains "3118d launch text does NOT carry CR_MERGE_GATE_OK=1 from a bare dotenv default" "ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1" "$out"

# (e) fenced-off unchanged path: an explicit --automerge on THIS invocation
# still grants BOTH vars, dotenv opt-in or not.
HO_3118E=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_3118E" --dry-run --automerge 2>&1)
rc=$?
assert_rc "3118e explicit --automerge still arms (rc=0)" 0 "$rc"
assert_contains "3118e resolved state: automerge=1, merge_gate_bypass=1, flag source" "automerge=1 merge_gate_bypass=1 (source: --automerge flag)" "$out"
assert_contains "3118e launch text carries BOTH grants from the explicit flag" "ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1" "$out"

# (f) ambient-env-leak fix: an ambient ARMAUTOMERGE exported into THIS shell
# (e.g. an operator shell, or a parent armed session's own env) must NOT
# affect resolution -- only the on-disk .env value matters once --automerge
# was not passed. Ambient ARMAUTOMERGE=0 must not suppress a truthy .env
# default -- pre-fix, load_dotenv's non-clobber contract let this ambient
# value win over the file read, contradicting the code's own comment that an
# ambient value is irrelevant here.
HO_3118F=$(make_handover "$WORK_REPO")
out=$(ARMAUTOMERGE=0 PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_3118F" --dry-run 2>&1)
rc=$?
assert_rc "3118f ambient ARMAUTOMERGE=0 + dotenv default still arms (rc=0)" 0 "$rc"
assert_contains "3118f ambient value is ignored -- resolution reads the .env file, not the process env" "automerge=1 merge_gate_bypass=0 (source: dotenv default (ARMAUTOMERGE=1 in the policy config or .env))" "$out"

# (g) same assertion with the ambient var genuinely unset -- must resolve
# IDENTICALLY to (f), proving a set-but-ignored ambient and a genuinely unset
# ambient are no longer distinguishable outcomes.
HO_3118G=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_3118G" --dry-run 2>&1)
rc=$?
assert_rc "3118g env -u ARMAUTOMERGE + dotenv default still arms (rc=0)" 0 "$rc"
assert_contains "3118g unset ambient resolves the same as a set-but-ignored ambient (f)" "automerge=1 merge_gate_bypass=0 (source: dotenv default (ARMAUTOMERGE=1 in the policy config or .env))" "$out"

# Restore the shield dir to its EMPTY default for any later section.
rm -f "$ARM_RESUME_DOTENV_ROOT/.env"
fi

# ---------------------------------------------------------------------------
# ticket-level mutex: the SAME ticket armed twice via TWO
# DIFFERENT handover files must be refused, even though each handover's own
# derived TASK_NAME differs (so the per-handover dedup above, rc 3, never
# sees it).
# ---------------------------------------------------------------------------
if _sec_selected "1329" "HIMMEL-1329"; then
R1329="$TMP/h1329"
mkdir -p "$R1329/repo"
( cd "$R1329/repo" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
SCHED_DB_1329="$TMP/h1329-sched.db"; SCHED_DB_DIR_1329="$TMP/h1329-sched.atdir"
: > "$SCHED_DB_1329"; mkdir -p "$SCHED_DB_DIR_1329"
# Each sub-case below gets its OWN handover file for the SAME ticket: re-
# arming the SAME file would hit the per-handover dedup (rc 3) first and
# never reach the ticket-level check this section is testing.
HO_1329_A="$R1329/worker-a.md"
HO_1329_B="$R1329/worker-b.md"
HO_1329_D="$R1329/worker-d-force.md"
HO_1329_E="$R1329/worker-e-env-override.md"
HO_1329_C="$R1329/worker-c-unrelated.md"
printf -- '---\nticket: HIMMEL-9003\nresume_cwd: %s\n---\n\n# HIMMEL-9003 worker A\n' "$R1329/repo" > "$HO_1329_A"
printf -- '---\nticket: HIMMEL-9003\nresume_cwd: %s\n---\n\n# HIMMEL-9003 worker B\n' "$R1329/repo" > "$HO_1329_B"
printf -- '---\nticket: HIMMEL-9003\nresume_cwd: %s\n---\n\n# HIMMEL-9003 worker D\n' "$R1329/repo" > "$HO_1329_D"
printf -- '---\nticket: HIMMEL-9003\nresume_cwd: %s\n---\n\n# HIMMEL-9003 worker E\n' "$R1329/repo" > "$HO_1329_E"
printf -- '---\nticket: HIMMEL-9004\nresume_cwd: %s\n---\n\n# HIMMEL-9004 unrelated\n' "$R1329/repo" > "$HO_1329_C"

_a1329() {
    local ho="$1"; shift
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh SCHED_DB="$SCHED_DB_1329" SCHED_DB_DIR="$SCHED_DB_DIR_1329" \
        PATH="$STATEFUL_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$ho" "$@" 2>&1)
}

_a1329 "$HO_1329_A"; rc=$?
assert_rc "1329 first worker (handover A) arms cleanly (rc=0)" 0 "$rc"

_a1329 "$HO_1329_B"; rc=$?
assert_rc "1329 second worker (handover B, SAME ticket) refuses (rc=13)" 13 "$rc"
assert_contains "1329 ERR names the ticket" "HIMMEL-9003" "$out"
assert_contains "1329 ERR points at the override" "ARM_TICKET_DUP_OK=1" "$out"

_a1329 "$HO_1329_D" --force; rc=$?
assert_rc "1329 --force overrides the ticket-dup refusal" 0 "$rc"

out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh SCHED_DB="$SCHED_DB_1329" SCHED_DB_DIR="$SCHED_DB_DIR_1329" \
    ARM_TICKET_DUP_OK=1 PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1329_E" 2>&1)
rc=$?
assert_rc "1329 ARM_TICKET_DUP_OK=1 overrides the ticket-dup refusal" 0 "$rc"

_a1329 "$HO_1329_C"; rc=$?
assert_rc "1329 leaves an unrelated ticket alone" 0 "$rc"
fi

# ---------------------------------------------------------------------------
# (item 2) — inferticketstrict frontmatter window must CLOSE. A
# handover whose YAML frontmatter never closes (only the opening `---`, no
# trailing `---`) must yield NO frontmatter ticket, so a `ticket:` line that
# lives in the BODY of that file is not parsed as frontmatter. Under the old
# one-pass `c==1` filter the unclosed block swallowed the whole body as
# frontmatter, so a body `ticket:` keyed the ticket mutex and
# could spuriously refuse (rc 13) an unrelated handover that armed the same
# ticket for real. Failure direction is spurious refusal only; --force /
# ARM_TICKET_DUP_OK override still exists. This fix removes the noise.
# Worker C (codex-adv r2): OPENED-but-UNTERMINATED frontmatter is a hard parse
# error (rc 1, no arm) — silently yielding no ticket would let a REAL
# frontmatter ticket whose closing `---` was lost bypass the mutex (fail-open),
# the exact duplicate-resume race the mutex prevents.
# ---------------------------------------------------------------------------
if _sec_selected "1640" "HIMMEL-1640"; then
R1640="$TMP/h1640"
mkdir -p "$R1640/repo"
( cd "$R1640/repo" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
SCHED_DB_1640="$TMP/h1640-sched.db"; SCHED_DB_DIR_1640="$TMP/h1640-sched.atdir"
: > "$SCHED_DB_1640"; mkdir -p "$SCHED_DB_DIR_1640"
# Worker A: a WELL-FORMED (closed) frontmatter that really carries the ticket —
# arms for real, so the ticket mutex records an armed slot for it.
HO_1640_A="$R1640/worker-a-closed.md"
printf -- '---\nticket: HIMMEL-9999\nresume_cwd: %s\n---\n\n# HIMMEL-9999 worker A (closed frontmatter)\n' \
    "$R1640/repo" > "$HO_1640_A"
# Worker B: an UNCLOSED frontmatter block (only the opening `---`) whose BODY —
# not frontmatter — mentions the SAME ticket. With the bug this body line was
# treated as frontmatter and the mutex keyed onto worker B too (rc 13).
# --cwd is passed because an unclosed frontmatter also defeats resume_cwd:
# parsing (out of scope for item 2); it isolates this test to ticket inference.
HO_1640_B="$R1640/worker-b-unclosed.md"
printf -- '---\nsession_kind: test\nresume_cwd: %s\n\n# worker B (frontmatter never closes)\n\nticket: HIMMEL-9999\nsome unrelated body line\n' \
    "$R1640/repo" > "$HO_1640_B"

_a1640() {
    local ho="$1"; shift
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh SCHED_DB="$SCHED_DB_1640" SCHED_DB_DIR="$SCHED_DB_DIR_1640" \
        PATH="$STATEFUL_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$ho" "$@" 2>&1)
}

_a1640 "$HO_1640_A"; rc=$?
assert_rc "1640 worker A (closed frontmatter, real ticket) arms cleanly (rc=0)" 0 "$rc"
assert_contains "1640 worker A arm banner printed" "RESUME ARMED" "$out"

_a1640 "$HO_1640_B" --cwd "$R1640/repo"; rc=$?
assert_rc "1640 worker B (unclosed frontmatter) refuses with a parse error (rc=1), not a ticket-dup" 1 "$rc"
assert_contains "1640 worker B names the unclosed frontmatter" "unclosed YAML frontmatter" "$out"
assert_not_contains "1640 worker B is not refused as a ticket dup" "already has another armed resume slot" "$out"
assert_not_contains "1640 worker B did not arm" "RESUME ARMED" "$out"

# Worker C (codex-adv r2): a REAL frontmatter ticket whose closing `---` was
# truncated. Silently yielding no strict ticket here would bypass the
# mutex (worker A already holds an armed slot) and
# schedule a duplicate resume — the fail-open direction. Must hard-refuse
# (rc 1) with the parse error, before any scheduler mutation.
HO_1640_C="$R1640/worker-c-truncated.md"
printf -- '---\nticket: HIMMEL-9999\nresume_cwd: %s\n\n# HIMMEL-9999 worker C (closer lost)\n' \
    "$R1640/repo" > "$HO_1640_C"
_a1640 "$HO_1640_C" --cwd "$R1640/repo"; rc=$?
assert_rc "1640 worker C (truncated REAL frontmatter ticket) hard-refuses (rc=1), never silently bypasses the mutex" 1 "$rc"
assert_contains "1640 worker C names the unclosed frontmatter" "unclosed YAML frontmatter" "$out"
assert_not_contains "1640 worker C did not arm" "RESUME ARMED" "$out"

# Worker D (codex-adv r3): a frontmatter-LESS handover (first line is a `#`
# heading, not a `---` opener) whose BODY contains exactly ONE `---`
# horizontal rule. Under the pre-r3 code the unanchored opener entered
# frontmatter mode at that lone body rule and, never closing, tripped the
# round-2 unclosed-frontmatter hard error (rc 1) -- a REGRESSION that blocked
# perfectly valid plain-markdown handovers. With the line-1 anchor the body
# rule is ordinary text: no frontmatter is entered, so no parse error.
HO_1640_D="$R1640/worker-d-no-frontmatter-one-rule.md"
printf -- '# worker D (no frontmatter, one body rule)\n\nIntro before the rule.\n\n---\n\nBody after the rule.\n' \
    > "$HO_1640_D"
_a1640 "$HO_1640_D" --cwd "$R1640/repo"; rc=$?
assert_rc "1640 worker D (no frontmatter, one body --- rule) arms cleanly (rc=0), no false unclosed-block error" 0 "$rc"
assert_contains "1640 worker D arm banner printed" "RESUME ARMED" "$out"
assert_not_contains "1640 worker D not refused as unclosed frontmatter" "unclosed YAML frontmatter" "$out"

# Worker E (codex-adv r3): a frontmatter-LESS handover whose BODY carries TWO
# `---` horizontal rules surrounding `ticket: KEY-9999` -- the SAME ticket
# worker A armed for real. Under the pre-r3 code the unanchored opener parsed
# these two body rules as a CLOSED frontmatter, inferred as a
# STRICT ticket, and the mutex refused worker E as a duplicate of
# worker A's slot (rc 13). With the line-1 anchor no frontmatter is inferred,
# _ho_ticket_strict stays empty, the mutex gate is skipped, and worker E arms its
# own slot. --cwd isolates cwd resolution (there is no resume_cwd: to parse).
HO_1640_E="$R1640/worker-e-no-frontmatter-two-rules.md"
printf -- '# worker E (no frontmatter, two body rules)\n\nIntro.\n\n---\n\nticket: HIMMEL-9999\n\n---\n\nTrailer.\n' \
    > "$HO_1640_E"
_a1640 "$HO_1640_E" --cwd "$R1640/repo"; rc=$?
assert_rc "1640 worker E (no frontmatter, two body --- rules around a ticket) arms cleanly (rc=0), not a ticket dup" 0 "$rc"
assert_contains "1640 worker E arm banner printed" "RESUME ARMED" "$out"
assert_not_contains "1640 worker E not refused as a ticket dup" "already has another armed resume slot" "$out"
assert_not_contains "1640 worker E not refused as unclosed frontmatter" "unclosed YAML frontmatter" "$out"

# Worker F: a UTF-8 BOM before the line-1 `---` opener. The BOM strip
# must work in mawk too (an `\xHH` awk escape is a gawk extension and silently
# skips there). The BOM'd frontmatter carries, the ticket worker A
# armed, so it must parse as a STRICT ticket and the mutex refuse it (rc 13).
# A skipped strip leaves line 1 as `<BOM>---`, no frontmatter is entered, no
# ticket is inferred and the handover arms (rc 0) past the mutex.
HO_1640_F="$R1640/worker-f-bom.md"
printf -- '\357\273\277---\nticket: HIMMEL-9999\nresume_cwd: %s\n---\n\n# HIMMEL-9999 worker F (BOM frontmatter)\n' \
    "$R1640/repo" > "$HO_1640_F"
_a1640 "$HO_1640_F" --cwd "$R1640/repo"; rc=$?
assert_rc "1654 worker F (BOM before frontmatter) parses the ticket and is refused as a dup (rc=13)" 13 "$rc"
assert_contains "1654 worker F refused by the ticket mutex" "already has another armed resume slot" "$out"
assert_not_contains "1654 worker F did not arm" "RESUME ARMED" "$out"
fi

# ---------------------------------------------------------------------------
# refuse to auto-detect a SINGLE-WRITER repo as the launch cwd.
# A handover with no --cwd/--worktree/resume_cwd:, sitting inside a repo
# marked `.single-writer` (the luna vault shape), must not silently arm
# INSIDE that repo.
# ---------------------------------------------------------------------------
if _sec_selected "1330" "HIMMEL-1330"; then
R1330="$TMP/h1330"
mkdir -p "$R1330/vault/handovers"
git init -q "$R1330/vault" >/dev/null 2>&1
touch "$R1330/vault/.single-writer"
HO_1330="$R1330/vault/handovers/no-resume-cwd.md"
printf -- '---\nsession_kind: test\n---\n\n# no resume_cwd handover\n' > "$HO_1330"

out=$(PATH="$ARMED_STUB:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_1330" --dry-run 2>&1)
rc=$?
assert_rc "1330 dry-run does not hard-fail (preview only)" 0 "$rc"
assert_contains "1330 dry-run warns about the vault refusal" "would REFUSE to arm" "$out"

out=$(PATH="$ARMED_STUB:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_1330" 2>&1)
rc=$?
assert_rc "1330 real arm refuses into a single-writer repo (rc=14)" 14 "$rc"
# The ERR text names the cwd as the script resolved it, which on Git-Bash is
# the Windows form (C:/Users/.../AppData/Local/Temp/tmp.X/h1330/vault) while
# $R1330 holds the MSYS form (/tmp/tmp.X/h1330/vault) -- and `realpath -m`
# here converts NEITHER into the other, so reconstructing the expected string
# is host-specific either way. Assert the distinctive tail instead: it is
# present verbatim in both spellings, on any host.
assert_contains "1330 ERR names the vault path" "h1330/vault" "$out"
assert_contains "1330 ERR points at the override" "ARM_VAULT_CWD_OK=1" "$out"

out=$(ARM_VAULT_CWD_OK=1 GH_CMD=/nonexistent/gh TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1330" 2>&1)
rc=$?
assert_rc "1330 ARM_VAULT_CWD_OK=1 overrides the vault refusal" 0 "$rc"

# The arm above registered THIS handover's task in the (now stateful)
# stub scheduler, and --cwd does not change the derived task name,
# so without a reset the next arm of the SAME handover is a legitimate rc 3
# dedup hit rather than the vault-guard bypass under test. Clear the stub's
# scheduler, which is what "a fresh box" meant back when /create registered
# nothing.
: > "$TMP/armed-stub.tasks"
rm -f "$TMP/armed-stub.atdir"/job-*
out=$(GH_CMD=/nonexistent/gh TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1330" --cwd "$WORK_REPO" 2>&1)
rc=$?
assert_rc "1330 explicit --cwd bypasses the vault guard" 0 "$rc"

HO_1330B="$R1330/vault/handovers/with-resume-cwd.md"
printf -- '---\nsession_kind: test\nresume_cwd: %s\n---\n\n# has resume_cwd\n' "$WORK_REPO" > "$HO_1330B"
out=$(GH_CMD=/nonexistent/gh TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1330B" 2>&1)
rc=$?
assert_rc "1330 resume_cwd: frontmatter bypasses the vault guard" 0 "$rc"

NORMAL_HO_1330=$(make_handover)
out=$(GH_CMD=/nonexistent/gh TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$NORMAL_HO_1330" 2>&1)
rc=$?
assert_rc "1330 leaves a normal auto-detected cwd alone" 0 "$rc"
fi

# ---------------------------------------------------------------------------
# registry-bucket cwd fallback (arm-resume.sh ~2048), a
# pre-refusal fallback inside the same single-writer guard above
# (own section gate so `--only 2147` and `--only 1330` each pull exactly what
# they name). A handover parked under the bucket layout
# (handovers/<user>/<repo-bucket>/...) with no --cwd/--worktree/resume_cwd:,
# sitting inside a single-writer repo, looks up <repo-bucket> in the handover
# registry BEFORE refusing. Fail-closed by construction: no match, no
# registry file, or the resolved repo is ITSELF single-writer all fall
# through to the unchanged refusal.
# ---------------------------------------------------------------------------
if _sec_selected "2147" "HIMMEL-2147"; then
R2147="$TMP/h2147"
mkdir -p "$R2147/vault/handovers/testuser/myrepo-bucket"
git init -q "$R2147/vault" >/dev/null 2>&1
touch "$R2147/vault/.single-writer"
HO_2147_FB="$R2147/vault/handovers/testuser/myrepo-bucket/worker.md"
printf -- '---\nsession_kind: test\n---\n\n# bucket-shaped handover, no resume_cwd\n' > "$HO_2147_FB"

mkdir -p "$R2147/regwork"
git init -q "$R2147/regwork" >/dev/null 2>&1

REG_2147="$TMP/registry-2147.json"
printf '{"repos":{"himmel":{"bucket_name":"myrepo-bucket","path":"%s"}}}\n' "$R2147/regwork" > "$REG_2147"

# (e) success: bucket matches a registry entry whose path is NOT single-writer
# -> WARN names the fallback, real arm succeeds (rc=0) using that cwd.
out=$(HANDOVER_REGISTRY="$REG_2147" GH_CMD=/nonexistent/gh TMPDIR="$TMP" \
    PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147_FB" 2>&1)
rc=$?
assert_rc "2147e registry-bucket fallback resolves and arms (rc=0)" 0 "$rc"
assert_contains "2147e WARN names the bucket fallback" "falling back to the handover registry" "$out"
assert_contains "2147e WARN names the matched bucket" "myrepo-bucket" "$out"
: > "$TMP/armed-stub.tasks"

# (f) fail-closed: the registry-resolved path is ITSELF single-writer -> never
# resolves into it, falls through to the unchanged refusal (rc=14).
touch "$R2147/regwork/.single-writer"
out=$(HANDOVER_REGISTRY="$REG_2147" GH_CMD=/nonexistent/gh TMPDIR="$TMP" \
    PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147_FB" 2>&1)
rc=$?
assert_rc "2147f resolved-but-single-writer bucket falls through to refusal (rc=14)" 14 "$rc"
rm -f "$R2147/regwork/.single-writer"

# (g) fail-closed: registry file exists but has no matching bucket entry.
REG_2147_NOMATCH="$TMP/registry-2147-nomatch.json"
printf '{"repos":{"other":{"bucket_name":"unrelated-bucket","path":"%s"}}}\n' "$R2147/regwork" > "$REG_2147_NOMATCH"
out=$(HANDOVER_REGISTRY="$REG_2147_NOMATCH" GH_CMD=/nonexistent/gh TMPDIR="$TMP" \
    PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147_FB" 2>&1)
rc=$?
assert_rc "2147g no matching bucket in registry falls through to refusal (rc=14)" 14 "$rc"

# (h) fail-closed: no registry file at the resolved HANDOVER_REGISTRY path.
out=$(HANDOVER_REGISTRY="$TMP/registry-2147-missing.json" GH_CMD=/nonexistent/gh TMPDIR="$TMP" \
    PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147_FB" 2>&1)
rc=$?
assert_rc "2147h missing registry file falls through to refusal (rc=14)" 14 "$rc"
fi


# ---------------------------------------------------------------------------
# an arm must never be created without a registry record just
# because the CWD does not map to a handover root.
#
# handover_root() answers from HANDOVER_DIR or <cwd's git root>/handovers, i.e.
# from where we ARE, never from what we are ARMING. Arming from a cwd that maps
# to neither used to skip the queue-lock check, the cross-host dedup AND the
# registry write in one silent branch. Caught live 2026-08-06: an arm fired at
# 08:12 with no arms.jsonl record, ever.
#
# All three cases run --dry-run (no scheduler job) from a NON-git cwd with
# HANDOVER_DIR unset — the exact shape that used to fail open.
# ---------------------------------------------------------------------------
if _sec_selected "1603" "HIMMEL-1603"; then
R1603="$TMP/h1603"
mkdir -p "$R1603/state/handovers/yotamleo/himmel" "$R1603/notgit" "$R1603/loose"
printf -- '---\nresume_cwd: %s\n---\n\n# t\n' "$R1603/notgit" \
    > "$R1603/state/handovers/yotamleo/himmel/x.md"
# A handover deliberately NOT under any `handovers/` dir — the supported
# repo-root HANDOVER.md shape, which has no fallback to find.
printf -- '---\nresume_cwd: %s\n---\n\n# t\n' "$R1603/notgit" > "$R1603/loose/HANDOVER.md"

out=$(cd "$R1603/notgit" && env -u HANDOVER_DIR bash "$ARM" --time 23:58 --long-gap \
    --handover "$R1603/state/handovers/yotamleo/himmel/x.md" --dry-run 2>&1)
assert_contains "1603 derives the root from the handover path when the cwd cannot" \
    "using the root derived from the handover path instead" "$out"
assert_contains "1603 names the derived root" "$R1603/state/handovers" "$out"
assert_not_contains "1603 does not fall through to the unregistered-arm branch" \
    "invisible to the census" "$out"
# The whole point of deriving the root: queue-lock must now resolve, so its
# own "could not resolve" degradation must be gone.
assert_not_contains "1603 queue-lock receives the derived root" \
    "queue-lock: could not resolve handover root" "$out"

# Residual case: no `handovers/` ancestor exists, so there is genuinely nothing
# to derive. That still arms (fail-open is deliberate — an arm that already
# succeeded must not be undone), but it must say so LOUDLY and durably rather
# than emitting the old bland WARN that nobody could act on after the fact.
T1603="$R1603/tele"
out=$(cd "$R1603/notgit" && env -u HANDOVER_DIR SKILL_TELEMETRY_DIR="$T1603" bash "$ARM" \
    --time 23:58 --long-gap --handover "$R1603/loose/HANDOVER.md" --dry-run 2>&1)
assert_contains "1603 unresolvable root warns that the arm is unregistered" \
    "invisible to the census" "$out"
assert_contains "1603 unresolvable root names the remedy" "set HANDOVER_DIR" "$out"
fi







if _sec_selected "1719" "HIMMEL-1719"; then
echo "--- 1719 ---"
HO=$(make_handover "$WORK_REPO")
EXPECTED_1719="load $HO overnight mode. Apply the Launch preamble standing instructions in docs/handover/afk-mode.md before Phase 1."

# Single-line + charset invariants on the fixture itself (pins the contract
# any future rewording must keep).
case "$EXPECTED_1719" in
    *$'\n'*) echo "FAIL 1719a expected prompt contains a newline"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS 1719a expected prompt is a single line" ;;
esac
case "$EXPECTED_1719" in
    *[\"\'%\&^\<\>\|\$\`]*) echo "FAIL 1719b expected prompt carries a quoting-hostile character"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS 1719b expected prompt is quoting-safe (no \" ' % & ^ < > | \$ \`)" ;;
esac

# printf %q round-trip (the cron/at path re-quotes the prompt exactly so).
q_1719=$(printf '%q' "$EXPECTED_1719")
rt_1719=""
eval "rt_1719=$q_1719"
if [ "$rt_1719" = "$EXPECTED_1719" ]; then
    echo "PASS 1719c prompt survives printf %q round-trip"
else
    echo "FAIL 1719c printf %q round-trip mangled the prompt"
    FAILED=$((FAILED + 1))
fi

out=$(posix_env "$SCHED_STUB_T17" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --cwd "$WORK_REPO" --force --dry-run 2>&1)
rc=$?
assert_rc "1719d pointer-clause dry-run exits 0" 0 "$rc"
assert_contains "1719d at body carries the full prompt incl. pointer clause" "$q_1719" "$out"
if grepq "$out" -E 'overnight.*mode.*Apply.*Launch.*preamble.*before.*Phase.*1'; then
    echo "PASS 1719e trigger phrase and pointer clause share one line"
else
    echo "FAIL 1719e pointer clause split from the trigger phrase (embedded newline?)"
    FAILED=$((FAILED + 1))
fi

# Parity: both prompt builders (arm-resume.sh + schedule-resume.sh) carry
# the identical clause — a divergent pair is the drift class this retires.
# Count each builder SEPARATELY: a summed count over both files passes when
# one file carries both matches and the other carries none — the exact
# divergence this check exists to catch. Per-file also sidesteps `grep -c`'s
# `file:count` prefix, which an `awk -F:` split mis-parses on a Windows
# `C:/...` path. -F keeps the literal dots literal.
_clause_1719="overnight mode. Apply the Launch preamble standing instructions in docs/handover/afk-mode.md before Phase 1."
# `|| true`, NOT `|| echo 0`: grep -c ALREADY prints its count (0) and exits 1
# on no-match, so an `echo 0` fallback appends a SECOND line and the numeric
# test below dies with "integer expected" instead of failing cleanly. The
# empty-guard covers a missing file (grep prints nothing, exits 2).
n_arm_1719=$(grep -cF "$_clause_1719" "$ARM" 2>/dev/null || true)
[ -n "$n_arm_1719" ] || n_arm_1719=0
n_sched_1719=$(grep -cF "$_clause_1719" "$(dirname "$ARM")/schedule-resume.sh" 2>/dev/null || true)
[ -n "$n_sched_1719" ] || n_sched_1719=0
if [ "$n_arm_1719" -ge 1 ] && [ "$n_sched_1719" -ge 1 ]; then
    echo "PASS 1719f arm-resume.sh and schedule-resume.sh build the identical clause"
else
    echo "FAIL 1719f prompt-builder parity broken (arm-resume=$n_arm_1719 schedule-resume=$n_sched_1719; each must be >=1)"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# 1879: the SUCCESS line must be EARNED.
#
# Three failures the ticket measured, each with its own case below:
#   a/b  --time smart picks ASAP (+4 min) but ARMING ITSELF can take longer than
#        that, so the task registers already-expired and the past-fire guard
#        deletes it -- net zero arms after an encouraging trail. Fixed by an
#        elapsed-aware lead floor applied just before scheduler registration.
#   c    scheduler create rc=0 is not proof anything is scheduled. The arm is
#        queried BACK before the banner; nothing there = FAILURE, never SUCCESS.
#   d    a FIRED arm deletes its own registration, so the scheduler-based dedup
#        reads clean and a second invocation double-fires. The flow-run ledger
#        remembers the fire; it is consulted before arming.
#
# NOT covered here, deliberately: the "target lapsed mid-arm" branch of the
# post-arm verify. Reaching it needs wall-clock to cross a target during the
# run, and the only honest seam for that would be a fake `date` on PATH -- which
# every other helper in this suite also calls. It shares its refusal block (and
# its assertions) with case c; the elapsed-aware floor in a/b is what actually
# prevents it.
# ---------------------------------------------------------------------------
if _sec_selected "1879" "HIMMEL-1879" "1999" "HIMMEL-1999"; then
echo "--- 1879 ---"

# --- 1879a/b: elapsed-aware lead floor on a SENTINEL slot -------------------
# The bank-free fixture resolves --time smart to ASAP = now + 4 min (240s).
# ARM_MIN_LEAD_SEC=900 > 240 forces the bump deterministically without having to
# make the arm genuinely slow; =60 < 240 proves a comfortable lead is untouched.
S1879="$TMP/s1879-stub-bin"
make_stateful_sched "$S1879"
DB_1879="$TMP/s1879.tasks"; DBD_1879="$TMP/s1879.atdir"
SLOT_FREE_1879="$TMP/usage-free-1879.json"
printf '{"five_hour":{"utilization":0.0,"resets_at":"%s"},"seven_day":{"utilization":5.0,"resets_at":"%s"},"account":"%s"}' \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')" \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')" \
    "$ACCT" \
    > "$SLOT_FREE_1879"

: > "$DB_1879"; rm -f "$DBD_1879"/job-*; mkdir -p "$DBD_1879"
HO_1879A="$(make_handover "$WORK_REPO")"
out=$(ARM_MIN_LEAD_SEC=900 RESUME_SLOT_CACHE="$SLOT_FREE_1879" SLOT_MAX_AGE=0 \
    HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879a.jsonl" TMPDIR="$TMP" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time smart --handover "$HO_1879A" 2>&1)
rc=$?
assert_rc "1879a smart arm under a raised lead floor still succeeds (rc=0)" 0 "$rc"
assert_contains "1879a the sentinel target was pushed past the floor" "pushed the target forward" "$out"
assert_contains "1879a the WARN names the never-fires consequence" "never fires" "$out"
assert_contains "1879a it still reports an armed slot" "RESUME ARMED" "$out"

# The negative twin. Deliberately NOT the bank-free (ASAP, +4 min) cache: an arm
# on a loaded box can eat most of a 4-minute lead, so "no push happened" would be
# asserting about this machine's speed rather than about the guard. An EXHAUSTED
# seven_day window makes smart resolve to that window's RESET instead -- days
# out, still a SENTINEL, and far beyond any floor however slow the run.
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
SLOT_BUSY_1879="$TMP/usage-busy-1879.json"
printf '{"five_hour":{"utilization":10.0,"resets_at":"%s"},"seven_day":{"utilization":95.0,"resets_at":"%s"},"account":"%s"}' \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')" \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')" \
    "$ACCT" \
    > "$SLOT_BUSY_1879"
# --long-gap is REQUIRED here, and says nothing about the lead
# floor this case is pinning. The exhausted-seven_day fixture above is what
# makes the target far out; later taught the `--time smart`
# branch to refuse a >1h park up front (rc=19) unless the operator accepts it
# with --long-gap. Without the flag this case died at that refusal and never
# reached the "no needless push" assertion it exists for -- a stale fixture,
# not a live-cap-state flake: TARGET_EPOCH comes from RESUME_SLOT_CACHE, so
# the ~6-day park is deterministic on every host.
HO_1879B="$(make_handover "$WORK_REPO")"
out=$(ARM_MIN_LEAD_SEC=120 RESUME_SLOT_CACHE="$SLOT_BUSY_1879" SLOT_MAX_AGE=0 \
    HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879b.jsonl" TMPDIR="$TMP" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time smart --handover "$HO_1879B" --long-gap 2>&1)
rc=$?
assert_rc "1879b a comfortable sentinel lead arms untouched (rc=0)" 0 "$rc"
assert_not_contains "1879b no needless push when the lead is fine" "pushed the target forward" "$out"

# --- 1879c: a reported-successful create that armed NOTHING -----------------
# /create returns 0 and records nothing; /query is therefore empty. Pre-fix the
# banner printed RESUME ARMED over an empty scheduler.
LIAR="$TMP/liar-stub-bin"
mkdir -p "$LIAR"
cat > "$LIAR/at" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null 2>&1 || true
exit 0
EOF
cat > "$LIAR/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$LIAR/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe unavailable -> the NextRunTime verify fail-opens, so this
# case exercises the existence verify specifically.
exit 1
EOF
cat > "$LIAR/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$LIAR/at" "$LIAR/atq" "$LIAR/powershell" "$LIAR/claude"
HO_1879C="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879c.jsonl" posix_env "$LIAR" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879C" 2>&1)
rc=$?
assert_rc "1879c create-said-yes but nothing is scheduled -> FAILURE (rc=2)" 2 "$rc"
assert_contains "1879c the ERR names the missing entry" "post-arm verify found NO scheduler entry" "$out"
assert_not_contains "1879c no SUCCESS banner over an empty scheduler" "RESUME ARMED" "$out"

# --- 1879d: idempotency against an arm that already FIRED -------------------
# Arm for real, then reproduce the fired state exactly: the runner deletes its
# own registration (empty SCHED_DB) and appends its `armed-resume` start row to
# the flow-run ledger. The scheduler now reads clean; only the ledger remembers.
LEDGER_1879="$TMP/1879d.jsonl"
: > "$DB_1879"; rm -f "$DBD_1879"/job-*; : > "$LEDGER_1879"
HO_1879D="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D" 2>&1)
rc=$?
assert_rc "1879d first arm of this handover succeeds (rc=0)" 0 "$rc"
TASK_1879=$(printf '%s\n' "$out" | sed -n 's/^ *Task name: //p' | head -1 | tr -d '\r')
if [ -n "$TASK_1879" ]; then
    echo "PASS 1879d the arm reported a task name ($TASK_1879)"
else
    echo "FAIL 1879d could not read the derived task name from the banner"
    FAILED=$((FAILED + 1))
fi
# Fire it: self-delete + the ledger row the emitted runner writes.
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" bash "$(dirname "$ARM")/../lib/flow-run-ledger.sh" \
    --append-start "armed-resume" "" "testhost" "claude" "" "$TASK_1879" "" 4242 >/dev/null

out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D" 2>&1)
rc=$?
assert_rc "1879d re-arming a FIRED, still-unfinished handover is refused (rc=15)" 15 "$rc"
assert_contains "1879d the ERR names the already-fired state" "ALREADY FIRED" "$out"
assert_contains "1879d the ERR explains why the scheduler looks clean" "deletes its own" "$out"
if [ "$(OSTYPE=linux-gnu count_slots "$DB_1879" "$DBD_1879")" = "0" ]; then
    echo "PASS 1879d the refusal armed nothing (0 slots)"
else
    echo "FAIL 1879d the refusal still armed something ($(OSTYPE=linux-gnu count_slots "$DB_1879" "$DBD_1879") slots)"
    FAILED=$((FAILED + 1))
fi

out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D" --force 2>&1)
rc=$?
assert_rc "1879d --force overrides the fired-arm refusal (rc=0)" 0 "$rc"

# An automated safety arm is exempt (same carve-out as the long-gap
# guard): auto-arm-on-cap.sh cannot pass --force, and a watchdog that parks the
# machine is worse than the double-fire it is guarding against.
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
out=$(ARM_RESUME_SAFETY_ARM=1 TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D" 2>&1)
rc=$?
assert_rc "1879d ARM_RESUME_SAFETY_ARM=1 is exempt from the fired-arm refusal (rc=0)" 0 "$rc"

# A run that ENDED is not a held seat. This is what keeps every stable-handover
# caller working -- auto-arm-on-cap.sh re-arms the operator's same status.md all
# day, and "fired once, refuse forever" would escalate it to MALFUNCTION.
LEDGER_1879B="$TMP/1879d-ended.jsonl"
: > "$DB_1879"; rm -f "$DBD_1879"/job-*; : > "$LEDGER_1879B"
HO_1879D3="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879B" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D3" 2>&1)
rc=$?
assert_rc "1879d seed: first arm of the completed-run fixture (rc=0)" 0 "$rc"
TASK_1879B=$(printf '%s\n' "$out" | sed -n 's/^ *Task name: //p' | head -1 | tr -d '\r')
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
FR_LIB="$(dirname "$ARM")/../lib/flow-run-ledger.sh"
RUN_1879B=$(HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879B" bash "$FR_LIB" \
    --append-start "armed-resume" "" "testhost" "claude" "" "$TASK_1879B" "" 4243)
HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879B" bash "$FR_LIB" \
    --append-end "armed-resume" "$RUN_1879B" "" 0 "complete" "" "session finished" >/dev/null

out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879B" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D3" 2>&1)
rc=$?
assert_rc "1879d a fired run that COMPLETED re-arms freely (rc=0)" 0 "$rc"
assert_not_contains "1879d no refusal once the run ended" "ALREADY FIRED" "$out"

# A DIFFERENT handover is untouched by another handover's fire -- the normal
# chain (worker N arms handover N+1) must never trip this guard.
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
HO_1879D2="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D2" 2>&1)
rc=$?
assert_rc "1879d a different handover still arms freely (rc=0)" 0 "$rc"
assert_not_contains "1879d no cross-handover fired-block" "ALREADY FIRED" "$out"

# --- 7757: usage-limit arm/resume keys + restart cap ------------------------
# --limit-reset <tag> keys a usage-limit arm on (handover, reset time). Replaying
# the same arm (same reset) is a no-op even after the first one fired and ended
# -- the scheduler reads clean and rc 15 lets an ended run re-arm, so only the
# key stops the second session. A fourth restart of one handover inside 5
# minutes is refused (rc=23); a different reset tag is a different key.
LEDGER_7757="$TMP/7757.jsonl"
: > "$DB_1879"; rm -f "$DBD_1879"/job-*; : > "$LEDGER_7757"
HO_7757="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_7757" --limit-reset R1 2>&1)
rc=$?
assert_rc "7757 first limit arm (reset R1) succeeds (rc=0)" 0 "$rc"
TASK_7757=$(printf '%s\n' "$out" | sed -n 's/^ *Task name: //p' | head -1 | tr -d '\r')
# Fire it and let the session end: scheduler clean, ledger start+end row.
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
RUN_7757=$(HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" bash "$FR_LIB" \
    --append-start "armed-resume" "" "testhost" "claude" "" "$TASK_7757" "" 7757)
HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" bash "$FR_LIB" \
    --append-end "armed-resume" "$RUN_7757" "" 0 "complete" "" "limit hit again" >/dev/null
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_7757" --limit-reset R1 2>&1)
rc=$?
assert_rc "7757 replaying the same limit arm is a no-op (rc=0)" 0 "$rc"
assert_contains "7757 the replay names the limit-resume key" "limit-resume key" "$out"
if [ "$(OSTYPE=linux-gnu count_slots "$DB_1879" "$DBD_1879")" = "0" ]; then
    echo "PASS 7757 the replay armed no second session (0 slots)"
else
    echo "FAIL 7757 the replay armed a second session ($(OSTYPE=linux-gnu count_slots "$DB_1879" "$DBD_1879") slots)"
    FAILED=$((FAILED + 1))
fi
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_7757" --limit-reset R2 2>&1)
rc=$?
assert_rc "7757 a different reset time is a different key and arms (rc=0)" 0 "$rc"
if [ "$(OSTYPE=linux-gnu count_slots "$DB_1879" "$DBD_1879")" = "1" ]; then
    echo "PASS 7757 the different reset time queued one session"
else
    echo "FAIL 7757 the different reset time queued $(OSTYPE=linux-gnu count_slots "$DB_1879" "$DBD_1879") sessions, want 1"
    FAILED=$((FAILED + 1))
fi
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
# The R1 fire is restart one; seed two more fired rows inside the window, then
# the next arm is the fourth restart.
for _n in 2 3; do
    _run=$(HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" bash "$FR_LIB" \
        --append-start "armed-resume" "" "testhost" "claude" "" "$TASK_7757" "" 775$_n)
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" bash "$FR_LIB" \
        --append-end "armed-resume" "$_run" "" 0 "complete" "" "limit hit again" >/dev/null
done
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_7757" --limit-reset R3 2>&1)
rc=$?
assert_rc "7757 a fourth restart inside 5 minutes is refused (rc=23)" 23 "$rc"
assert_contains "7757 the refusal says why" "restarted 3 times in 5 minutes" "$out"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_7757" --limit-reset R5 --force 2>&1)
rc=$?
assert_rc "7757 --force overrides the restart cap (rc=0)" 0 "$rc"
if [ "$(OSTYPE=linux-gnu count_slots "$DB_1879" "$DBD_1879")" = "1" ]; then
    echo "PASS 7757 --force at the cap queued one session"
else
    echo "FAIL 7757 --force at the cap queued $(OSTYPE=linux-gnu count_slots "$DB_1879" "$DBD_1879") sessions, want 1"
    FAILED=$((FAILED + 1))
fi
# A plain (non-limit) arm of the same handover never meets either key.
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_7757" 2>&1)
rc=$?
assert_rc "7757 a non-limit arm is untouched by the limit keys and the restart cap (rc=0)" 0 "$rc"
assert_not_contains "7757 no limit-key message on a non-limit arm" "limit-resume key" "$out"

# The key is only a no-op once its arm FIRED; a cancelled or reaped arm re-arms.
# The restart window is 5 minutes: rows older than that do not count. --force
# with the SAME tag as a recorded key arms again. One fresh handover and ledger.
LEDGER_7757B="$TMP/7757b.jsonl"
: > "$DB_1879"; rm -f "$DBD_1879"/job-*; : > "$LEDGER_7757B"
HO_7757B="$(make_handover "$WORK_REPO")"
arm_7757b() {
    TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757B" \
        SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
        bash "$ARM" --time "$(future_time)" --handover "$HO_7757B" "$@" 2>&1
}
slots_7757b() { OSTYPE=linux-gnu count_slots "$DB_1879" "$DBD_1879"; }
out=$(arm_7757b --limit-reset R1)
rc=$?
assert_rc "7757 window: first limit arm on a fresh handover (rc=0)" 0 "$rc"
TASK_7757B=$(printf '%s\n' "$out" | sed -n 's/^ *Task name: //p' | head -1 | tr -d '\r')
for _n in 1 2 3; do
    _run=$(HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757B" bash "$FR_LIB" \
        --append-start "armed-resume" "" "testhost" "claude" "" "$TASK_7757B" "" 7758$_n)
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757B" bash "$FR_LIB" \
        --append-end "armed-resume" "$_run" "" 0 "complete" "" "limit hit again" >/dev/null
done
# Age every seeded start row to 2020: three restarts, none inside the window.
sed 's/"fired_at":"[^"]*"/"fired_at":"2020-01-01T00:00:00Z"/' "$LEDGER_7757B" > "$LEDGER_7757B.aged" \
    && mv "$LEDGER_7757B.aged" "$LEDGER_7757B"
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
out=$(arm_7757b --limit-reset R2)
rc=$?
assert_rc "7757 window: three restarts older than 5 minutes do not trip the cap (rc=0)" 0 "$rc"
assert_not_contains "7757 window: no restart-cap refusal for old rows" "restarted" "$out"
# R2 is keyed and its job is still queued: the scheduler dedup answers, not the key.
out=$(arm_7757b --limit-reset R2)
rc=$?
assert_rc "7757 stale key: a job the scheduler still holds meets the rc 3 dedup" 3 "$rc"
assert_not_contains "7757 stale key: a queued job is not a silent key no-op" "limit-resume key" "$out"
# The arm is cancelled before it fires: no start row after the key, so it re-arms.
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
out=$(arm_7757b --limit-reset R2)
rc=$?
assert_rc "7757 stale key: a cancelled arm that never fired re-arms (rc=0)" 0 "$rc"
assert_not_contains "7757 stale key: the re-arm is not dropped as a replay" "limit-resume key" "$out"
if [ "$(slots_7757b)" = "1" ]; then
    echo "PASS 7757 stale key: the re-arm queued one session"
else
    echo "FAIL 7757 stale key: the re-arm queued $(slots_7757b) sessions, want 1"
    FAILED=$((FAILED + 1))
fi
# R2 fires and ends: now the replay is the no-op, and --force with the SAME tag re-arms.
_run=$(HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757B" bash "$FR_LIB" \
    --append-start "armed-resume" "" "testhost" "claude" "" "$TASK_7757B" "" 77589)
HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_7757B" bash "$FR_LIB" \
    --append-end "armed-resume" "$_run" "" 0 "complete" "" "limit hit again" >/dev/null
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
out=$(arm_7757b --limit-reset R2)
rc=$?
assert_rc "7757 force: the replay of a fired key is a no-op (rc=0)" 0 "$rc"
assert_contains "7757 force: the replay names the limit-resume key" "limit-resume key" "$out"
out=$(arm_7757b --limit-reset R2 --force)
rc=$?
assert_rc "7757 force: --force with the SAME recorded tag arms again (rc=0)" 0 "$rc"
assert_not_contains "7757 force: --force skips the recorded key" "limit-resume key" "$out"
if [ "$(slots_7757b)" = "1" ]; then
    echo "PASS 7757 force: --force queued one session"
else
    echo "FAIL 7757 force: --force queued $(slots_7757b) sessions, want 1"
    FAILED=$((FAILED + 1))
fi
# A key that cannot be written warns, and the arm that already succeeded stays armed.
mkdir -p "$TMP/7757c/limit-keys.txt"
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$TMP/7757c/flow-runs.jsonl" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_7757B" --limit-reset R9 2>&1)
rc=$?
assert_rc "7757 key write: an unwritable key file does not fail the arm (rc=0)" 0 "$rc"
assert_contains "7757 key write: the failed key write is reported" "limit-resume key NOT recorded" "$out"
if [ "$(slots_7757b)" = "1" ]; then
    echo "PASS 7757 key write: the arm stays armed"
else
    echo "FAIL 7757 key write: the arm queued $(slots_7757b) sessions, want 1"
    FAILED=$((FAILED + 1))
fi

: > "$DB_1879"; rm -f "$DBD_1879"/job-*; rm -rf "$DBD_1879"; mkdir -p "$DBD_1879"
HO_1879E="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879e.jsonl" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" \
    PATH="$S1879:$PATH" OSTYPE=linux-gnu bash "$ARM" \
    --time "$(future_time)" --handover "$HO_1879E" 2>&1)
rc=$?
assert_rc "1879e a real at-job passes the existence verify (rc=0)" 0 "$rc"
assert_contains "1879e the at arm reports armed" "RESUME ARMED" "$out"

: > "$DB_1879"; rm -f "$DBD_1879"/job-*; rm -rf "$DBD_1879"; mkdir -p "$DBD_1879"
HO_1879E2="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879e2.jsonl" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" \
    PATH="$LIAR:$PATH" OSTYPE=linux-gnu bash "$ARM" \
    --time "$(future_time)" --handover "$HO_1879E2" 2>&1)
rc=$?
assert_rc "1879e an at queue that swallowed the job -> FAILURE (rc=2)" 2 "$rc"
assert_contains "1879e the POSIX ERR names the missing entry" "post-arm verify found NO scheduler entry" "$out"

# A create can outlive its explicit target. Use the stateful at backend, with
# the real clock crossing the target while at -t is blocked (no fake date).
make_lapse_stub() { # <dir> <deadline> [<fire-delay>] [keep-snapshot]
    local dir="$1" deadline="$2" delay="${3:-}" keep="${4:-0}"
    make_stateful_sched "$dir"
    mv "$dir/at" "$dir/at-stateful"
    cat > "$dir/at" <<EOF
#!/usr/bin/env bash
bash "$dir/at-stateful" "\$@" || exit
[ "\${1:-}" = -t ] || exit 0
while [ "\$(date +%s)" -le $deadline ]; do sleep 1; done
[ "$keep" = 1 ] || rm -f "\$SCHED_DB_DIR"/job-*
if [ -n "$delay" ]; then
    # The runner self-deletes first; its ledger write can lag behind at's return.
    ( sleep "${delay:-0}"; HIMMEL_FLOW_RUNS_LEDGER="\$HIMMEL_FLOW_RUNS_LEDGER" \\
        bash "$FR_LIB" --append-start armed-resume '' testhost claude '' \\
        "$TASK_1879F" '' 4247 >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
fi
exit 0
EOF
    chmod +x "$dir/at"
}
lapse_hhmm() {
    python3 -c 'import datetime; n=datetime.datetime.now(); print((n+datetime.timedelta(minutes=1 if n.second < 45 else 2)).strftime("%H:%M"))'
}
lapse_epoch() {
    python3 -c 'import datetime,sys; h,m=map(int,sys.argv[1].split(":")); n=datetime.datetime.now().astimezone(); t=n.replace(hour=h,minute=m,second=0,microsecond=0); print(int((t if t>n else t+datetime.timedelta(days=1)).timestamp()))' "$1"
}
: > "$DB_1879"; rm -f "$DBD_1879"/job-*
HO_1879F="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879f-seed.jsonl" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879F" 2>&1)
rc=$?
assert_rc "1879f seed arm succeeds" 0 "$rc"
TASK_1879F=$(printf '%s\n' "$out" | sed -n 's/^ *Task name: //p' | head -1 | tr -d '\r')
assert_contains "1879f seed reports a real task identity" "HIMMEL-Resume-" "$TASK_1879F"
LEDGER_1879F="$TMP/1879f.jsonl"

for scenario in 1879f-empty 1879f-fired 1879h 1879j 1999a 1999b; do
    : > "$DB_1879"; rm -f "$DBD_1879"/job-*; : > "$LEDGER_1879F"
    LAPSE_HHMM=$(lapse_hhmm); LAPSE_EPOCH=$(lapse_epoch "$LAPSE_HHMM")
    delay=""; keep=0
    case "$scenario" in
        1879f-fired|1879j) delay=0 ;;
        1999a) delay=1 ;;
    esac
    [ "$scenario" != 1879j ] || keep=1
    case "$scenario" in
        1879h|1999b)
            stamp=2020-01-01T00:00:00Z
            if [ "$scenario" = 1999b ]; then
                stamp=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$LAPSE_EPOCH")
            fi
            prior=$(HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" bash "$FR_LIB" \
                --append-start armed-resume "$stamp" testhost claude '' "$TASK_1879F" '' 4245)
            HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" bash "$FR_LIB" \
                --append-end armed-resume "$prior" '' 0 complete '' 'prior run finished' >/dev/null ;;
    esac
    LAPSE_STUB="$TMP/$scenario-stub"
    make_lapse_stub "$LAPSE_STUB" "$((LAPSE_EPOCH + 3))" "$delay" "$keep"
    find "$TMP" -name arms.jsonl -delete 2>/dev/null || true
    out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" \
        SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" posix_env "$LAPSE_STUB" \
        bash "$ARM" --time "$LAPSE_HHMM" --handover "$HO_1879F" 2>&1)
    rc=$?
    case "$scenario" in
        1879f-empty|1879h|1999b)
            assert_rc "$scenario no evidence of this arm's fire refuses" 2 "$rc"
            assert_contains "$scenario names the failed create" "REGISTERED NOTHING" "$out"
            assert_not_contains "$scenario never claims consumed" "RESUME CONSUMED" "$out" ;;
        *)
            assert_rc "$scenario this arm's own start row proves consumption" 0 "$rc"
            assert_contains "$scenario reports consumed" "RESUME CONSUMED" "$out"
            assert_not_contains "$scenario never calls a fired arm a failed create" "REGISTERED NOTHING" "$out"
            REG_1879F=$(find "$TMP" -name arms.jsonl -exec grep -lF "$TASK_1879F" {} + 2>/dev/null || true)
            if [ -z "$REG_1879F" ]; then rc=0; else rc=1; fi
            assert_rc "$scenario consumed arm publishes no arms-registry record" 0 "$rc" ;;
    esac
    assert_not_contains "$scenario never claims armed" "RESUME ARMED" "$out"
    if [ "$scenario" = 1879j ]; then
        if [ -f "$DBD_1879/job-$(cat "$DBD_1879/.counter")" ]; then rc=0; else rc=1; fi
        assert_rc "1879j consumed snapshot is not reaped" 0 "$rc"
    fi
done
fi

# ---------------------------------------------------------------------------
# 1879-1365: the guard now keys on BOTH halves of the fired
# session's identity (cwd AND handover), and answers a read-only sweep.
# ---------------------------------------------------------------------------
if _sec_selected "1879-1365" "1365" "HIMMEL-1365" "1998" "HIMMEL-1998"; then
echo "--- 1879-1365 ---"
HO_T1365="$(make_handover "$WORK_REPO")"
out=$(env -u ARM_TEMP_CWD_OK -u ARM_FIXTURE_OK TMPDIR="$TMP" \
    PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$HO_T1365" 2>&1)
rc=$?
assert_rc "1879-1365 a temp-rooted fixture is refused (rc=12)" 12 "$rc"
assert_contains "1879-1365 the ERR names the handover file, not just the cwd" "handover file:" "$out"
assert_contains "1879-1365 the ERR names the ticket's opt-in spelling" "ARM_FIXTURE_OK=1" "$out"

out=$(env -u ARM_TEMP_CWD_OK ARM_FIXTURE_OK=1 TMPDIR="$TMP" \
    PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$HO_T1365" --dry-run 2>&1)
rc=$?
assert_rc "1879-1365 ARM_FIXTURE_OK=1 opts in (rc=0)" 0 "$rc"

# Sweep both scheduler stores through their real POSIX readers. Report-only
# means neither the at job nor the crontab entry may be changed.
LTA="$TMP/lta-stub-bin"; LTA_DB="$TMP/lta-atdir"
make_stateful_sched "$LTA"
mkdir -p "$LTA_DB"
for target in "$TMP/scratchpad/work2" /tmp /srv/himmel; do
    printf '# HIMMEL-Resume-sweep\ncd %s || exit 1\n' "$target" > "$LTA_DB/job-1"
    before=$(cat "$LTA_DB/job-1")
    out=$(SCHED_DB_DIR="$LTA_DB" posix_env "$LTA" bash "$ARM" --list-temp-arms 2>&1)
    rc=$?
    if [ "$target" = /srv/himmel ]; then
        assert_rc "LTA clean at sweep exits 0" 0 "$rc"
        assert_contains "LTA clean at sweep reports no suspect entry" "none — no armed resume entry" "$out"
    else
        assert_rc "LTA at sweep reports $target" 16 "$rc"
        assert_contains "LTA at sweep names its target" "target: $target" "$out"
        assert_contains "LTA at sweep names its job" "at-job-1" "$out"
        assert_contains "LTA at sweep is report-only" "REPORT ONLY" "$out"
    fi
    if [ "$(cat "$LTA_DB/job-1")" = "$before" ]; then rc=0; else rc=1; fi
    assert_rc "LTA at sweep preserves $target job" 0 "$rc"
done
rm -f "$LTA_DB/job-1"
printf '* * * * * cd /tmp && true # HIMMEL-Resume-sweep\n' > "$LTA_DB/crontab.fixture"
before=$(cat "$LTA_DB/crontab.fixture")
out=$(SCHED_DB_DIR="$LTA_DB" posix_env "$LTA" bash "$ARM" --list-temp-arms 2>&1)
rc=$?
assert_rc "LTA cron sweep reports a bare-root hit" 16 "$rc"
assert_contains "LTA cron sweep sees mid-line cd target" "target: /tmp" "$out"
assert_contains "LTA cron sweep is report-only" "REPORT ONLY" "$out"
if [ "$(cat "$LTA_DB/crontab.fixture")" = "$before" ]; then rc=0; else rc=1; fi
assert_rc "LTA cron sweep preserves the entry" 0 "$rc"
fi

# ---------------------------------------------------------------------------
# one file per leg: arming the second half of a split worker is
# refused (rc 17).
#
# The 2026-08-17 incident: one worker wrote session-25 (state) AND session-26
# (orders) and armed on 26, so the relaunch loaded the orders half and the
# state was orphaned. Refusal needs BOTH conditions — a sibling written inside
# this worker window AND no relaunch ever made from it — so the allow cases below
# pin one condition each; without them the check would refuse every short worker.
# ---------------------------------------------------------------------------
if _sec_selected "1830" "HIMMEL-1830"; then
echo "--- 1830 ---"
R1830="$TMP/h1830"
mkdir -p "$R1830/repo" "$R1830/chain"
( cd "$R1830/repo" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
_mk1830() {  # <path> <title>
    printf -- '---\nticket: HIMMEL-9830\nresume_cwd: %s\n---\n\n# %s\n' "$R1830/repo" "$2" > "$1"
}
HO_1830_A="$R1830/chain/EPIC-9830-dispatch-session-4.md"
HO_1830_B="$R1830/chain/EPIC-9830-dispatch-session-5.md"
_mk1830 "$HO_1830_A" "worker state half"
_mk1830 "$HO_1830_B" "worker orders half"
_a1830() {  # <ledger> <handover>
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh HIMMEL_FLOW_RUNS_LEDGER="$1" \
        posix_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$2" --dry-run 2>&1)
}
# An EXISTING but empty ledger. A ledger that is absent entirely proves nothing
# about the sibling, so the guard fails open there — the refusal needs a ledger
# that could have carried the evidence and does not.
E1830="$TMP/1830-empty.jsonl"; : > "$E1830"

# (a) REFUSAL: both files just written, nothing ever relaunched from session-4.
_a1830 "$E1830" "$HO_1830_B"; rc=$?
assert_rc "1830 arming the second half of a split worker refuses (rc=17)" 17 "$rc"
assert_contains "1830 the ERR names the sibling it would orphan" "EPIC-9830-dispatch-session-4.md" "$out"
assert_contains "1830 the ERR names the opt-out" "ARM_SPLIT_WORKER_OK=1" "$out"

# (b) ALLOW: same pair, but a relaunch WAS made from session-4 — i.e. it was a
# real worker's file, and this is a normal chain that simply moved fast. The
# ledger row carries session-4's REAL arm identity, taken from arm-resume's own
# at task marker: the evidence is matched on the sibling's canonical-path hash, so a
# hand-written task name would prove nothing about this fixture.
_a1830 "$E1830" "$HO_1830_A"; rc=$?
assert_rc "1830 seed: the sibling itself arms cleanly (rc=0)" 0 "$rc"
TASK_1830_A=$(printf '%s\n' "$out" | sed -n 's/^ *# \(HIMMEL-Resume-[^ ]*\)$/\1/p' | head -1)
assert_contains "1830 seed emits a real at task identity" "HIMMEL-Resume-" "$TASK_1830_A"
L1830="$TMP/1830-launched.jsonl"
printf '{"flow":"armed-resume","ev":"start","run_id":"r1","task_name":"%s"}\n' "$TASK_1830_A" > "$L1830"
_a1830 "$L1830" "$HO_1830_B"; rc=$?
assert_rc "1830 a sibling that WAS a relaunch point still arms (rc=0)" 0 "$rc"

# (b2) …but ANOTHER chain's row must not clear it (panel r1 [codex-1]): same
# ticket, same worker number, different handover file. Evidence is per-path.
L1830F="$TMP/1830-foreign.jsonl"
printf '{"flow":"armed-resume","ev":"start","run_id":"r1","task_name":"HIMMEL-Resume-HIMMEL-9830-other-chain-s4-other_chain_session_4-h0123456789ab"}\n' > "$L1830F"
_a1830 "$L1830F" "$HO_1830_B"; rc=$?
assert_rc "1830 a DIFFERENT chain's worker-4 row does not clear the refusal (rc=17)" 17 "$rc"

# (c) ALLOW: no ledger evidence either, but the sibling is old — a previous
# worker's file, not something this session just wrote.
touch -t 202601010000 "$HO_1830_A"
_a1830 "$E1830" "$HO_1830_B"; rc=$?
assert_rc "1830 an OLD sibling is a previous worker, not a split (rc=0)" 0 "$rc"

# (d) The escape hatch is real: re-make the sibling fresh, opt out explicitly.
_mk1830 "$HO_1830_A" "worker state half"
out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh HIMMEL_FLOW_RUNS_LEDGER="$E1830" \
    ARM_SPLIT_WORKER_OK=1 posix_env "$SCHED_STUB_T17" bash "$ARM" \
    --time "$(future_time)" --handover "$HO_1830_B" --dry-run 2>&1)
rc=$?
assert_rc "1830 ARM_SPLIT_WORKER_OK=1 opts out of the refusal (rc=0)" 0 "$rc"

# (e) A ZERO-PADDED chain (panel r3 [codex-1]): `session-08.md` is a legal
# filename but octal to bash arithmetic — `$((08 - 1))` is a fatal "value too
# great for base" that aborted the whole arm under set -e. The sibling lookup
# must also find the same-width `-07.md`, not only a bare `-7.md`.
HO_1830_P7="$R1830/chain/EPIC-9830-dispatch-session-07.md"
HO_1830_P8="$R1830/chain/EPIC-9830-dispatch-session-08.md"
_mk1830 "$HO_1830_P7" "padded state half"
_mk1830 "$HO_1830_P8" "padded orders half"
_a1830 "$E1830" "$HO_1830_P8"; rc=$?
assert_rc "1830 a zero-padded split worker refuses cleanly (rc=17, not an arithmetic abort)" 17 "$rc"
assert_contains "1830 the padded sibling is the one named" "EPIC-9830-dispatch-session-07.md" "$out"
fi

# ---------------------------------------------------------------------------
# --safety-child marks the RELAUNCH env, on every runner.
#
# auto-arm-on-cap.sh's stale escalation passes this flag; the relaunched
# session reads AUTO_ARM_SAFETY_CHILD out of its own env and refuses to
# escalate again, which is what bounds the self-sustaining +5h chain. If the
# mark never reaches the child the whole depth limit is inert, so each runner's
# emitted text is asserted here — with the flag AND without it (the negative is
# what makes the injection conditional rather than always-on).
# ---------------------------------------------------------------------------
if _sec_selected "812" "HIMMEL-812"; then
echo "--- 812 ---"
HO_812="$(make_handover "$WORK_REPO")"
_SC812='AUTO_ARM_SAFETY_CHILD=1'

# macOS/crontab: one line, so the mark is an export ahead of the launch body.
MACBIN_812="$TMP/macbin-812"; mkdir -p "$MACBIN_812"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN_812/claude"; chmod +x "$MACBIN_812/claude"   # HIMMEL-3074
CRON_STORE_812="$TMP/cron-812.store"; : > "$CRON_STORE_812"
printf '#!/bin/sh\nexit 1\n' > "$MACBIN_812/at"; chmod +x "$MACBIN_812/at"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN_812/atq"; chmod +x "$MACBIN_812/atq"
cat > "$MACBIN_812/crontab" <<CRONEOF812
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_812" 2>/dev/null ;;
  -) cat > "$CRON_STORE_812" ;;
  *) exit 0 ;;
esac
CRONEOF812
chmod +x "$MACBIN_812/crontab"
out=$(env PATH="$MACBIN_812:$PATH" OSTYPE=darwin23 bash "$ARM" --time "$(future_time)" --handover "$HO_812" --safety-child --dry-run 2>&1)
rc=$?
assert_rc "812 cron: --safety-child dry-run exits 0" 0 "$rc"
assert_contains "812 cron: the crontab entry exports the mark" "export $_SC812" "$out"
out=$(env PATH="$MACBIN_812:$PATH" OSTYPE=darwin23 bash "$ARM" --time "$(future_time)" --handover "$HO_812" --dry-run 2>&1)
assert_not_contains "812 cron: no mark without the flag" "$_SC812" "$out"
assert_contains "812 cron: the entry CLEARS an ambient mark" "unset AUTO_ARM_SAFETY_CHILD" "$out"

# linux/at: the job body is a script, so the mark is its own export line.
DBD_812="$TMP/h812.atdir"; rm -rf "$DBD_812"; mkdir -p "$DBD_812"
out=$(SCHED_DB="$TMP/h812-sched.db" SCHED_DB_DIR="$DBD_812" PATH="$STATEFUL_STUB:$PATH" OSTYPE=linux-gnu \
    bash "$ARM" --time "$(future_time)" --handover "$HO_812" --safety-child --dry-run 2>&1)
rc=$?
assert_rc "812 at: --safety-child dry-run exits 0" 0 "$rc"
assert_contains "812 at: the at job body exports the mark" "export $_SC812" "$out"
out=$(SCHED_DB="$TMP/h812-sched.db" SCHED_DB_DIR="$DBD_812" PATH="$STATEFUL_STUB:$PATH" OSTYPE=linux-gnu \
    bash "$ARM" --time "$(future_time)" --handover "$HO_812" --dry-run 2>&1)
assert_not_contains "812 at: no mark without the flag" "$_SC812" "$out"
# `at` snapshots the SUBMITTING env, so the clear is load-bearing here, not
# cosmetic: an ordinary arm made from a safety-child session must not relaunch
# still carrying the mark (panel r3 [codex-2]).
assert_contains "812 at: the job body CLEARS an ambient mark" "unset AUTO_ARM_SAFETY_CHILD" "$out"
fi

# ---------------------------------------------------------------------------
# a chief arm exports HIMMEL_CONSOLE_DOC / HIMMEL_CONSOLE_WORKDIR
# into the relaunch so the PreCompact snapshot hook
# (scripts/hooks/chief-precompact-snapshot.sh) can fire; any other arm gets
# neither, and BOTH runners always-clear an ambient pair first (`at` snapshots
# the submitting env). "Chief" = handover basename *-chief.md, the same
# test the model default uses. Both crontab and `at` runners are pinned.
# ---------------------------------------------------------------------------
if _sec_selected "2973" "HIMMEL-2973"; then
echo "--- 2973 ---"
HO_2973="$(make_handover "$WORK_REPO")"
HO_2973C="$HANDOVER_DIR/n46-chief.md"
cp "$HO_2973" "$HO_2973C"
CW_2973="$TMP/cw2973"
_WD2973="$CW_2973/precompact-n46-chief"

MACBIN_2973="$TMP/macbin-2973"; mkdir -p "$MACBIN_2973"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN_2973/claude"; chmod +x "$MACBIN_2973/claude"
printf '#!/bin/sh\nexit 1\n' > "$MACBIN_2973/at"; chmod +x "$MACBIN_2973/at"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN_2973/atq"; chmod +x "$MACBIN_2973/atq"
CRON_STORE_2973="$TMP/cron-2973.store"; : > "$CRON_STORE_2973"
cat > "$MACBIN_2973/crontab" <<CRONEOF2973
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_2973" 2>/dev/null ;;
  -) cat > "$CRON_STORE_2973" ;;
  *) exit 0 ;;
esac
CRONEOF2973
chmod +x "$MACBIN_2973/crontab"

# crontab runner: chief arm exports the pair; a non-chief arm only clears.
out=$(env CHIEF_WORK_DIR="$CW_2973" PATH="$MACBIN_2973:$PATH" OSTYPE=darwin23 bash "$ARM" --time "$(future_time)" --handover "$HO_2973C" --dry-run 2>&1)
rc=$?
assert_rc "2973 cron: chief arm dry-run exits 0" 0 "$rc"
assert_contains "2973 cron: the entry exports HIMMEL_CONSOLE_DOC" "export HIMMEL_CONSOLE_DOC=$HO_2973C" "$out"
assert_contains "2973 cron: the entry exports HIMMEL_CONSOLE_WORKDIR (basename slug + path-hash suffix)" "HIMMEL_CONSOLE_WORKDIR=$_WD2973-h" "$out"
_wd_c=$(printf '%s\n' "$out" | sed -n 's/.*\(HIMMEL_CONSOLE_WORKDIR=[^ ]*\).*/\1/p' | head -n 1)
assert_contains "2973 cron: the entry CLEARS an ambient pair first" "unset HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_WORKDIR" "$out"
assert_contains "2973 cron: the entry exports the HIMMEL_CONSOLE=1 chief marker (HIMMEL-6918)" " HIMMEL_CONSOLE=1" "$out"
assert_contains "2973 cron: the entry CLEARS an ambient chief marker first (HIMMEL-6918)" "unset HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_WORKDIR HIMMEL_CONSOLE" "$out"
out=$(env CHIEF_WORK_DIR="$CW_2973" PATH="$MACBIN_2973:$PATH" OSTYPE=darwin23 bash "$ARM" --time "$(future_time)" --handover "$HO_2973" --dry-run 2>&1)
assert_not_contains "2973 cron: a non-chief arm exports no HIMMEL_CONSOLE_DOC" "export HIMMEL_CONSOLE_DOC" "$out"
assert_contains "2973 cron: a non-chief arm still CLEARS an ambient pair" "unset HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_WORKDIR" "$out"
assert_not_contains "2973 cron: a non-chief arm exports no HIMMEL_CONSOLE=1 (HIMMEL-6918)" " HIMMEL_CONSOLE=1" "$out"
assert_contains "2973 cron: a non-chief arm still CLEARS an ambient chief marker (HIMMEL-6918)" "unset HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_WORKDIR HIMMEL_CONSOLE" "$out"

# Two chief docs sharing a basename (different repos' handovers/) must not
# share a workdir: the checker picks the highest-numbered snap without checking
# which document wrote it.
mkdir -p "$TMP/other2973"; HO_2973D="$TMP/other2973/n46-chief.md"; cp "$HO_2973" "$HO_2973D"
out=$(env CHIEF_WORK_DIR="$CW_2973" PATH="$MACBIN_2973:$PATH" OSTYPE=darwin23 bash "$ARM" --time "$(future_time)" --handover "$HO_2973D" --dry-run 2>&1)
assert_contains "2973 cron: a same-basename chief doc elsewhere still exports a workdir" "HIMMEL_CONSOLE_WORKDIR=$_WD2973-h" "$out"
assert_not_contains "2973 cron: a same-basename chief doc elsewhere gets a DIFFERENT workdir" "$_wd_c" "$out"

# linux/at runner: same contract, as job-body lines.
DBD_2973="$TMP/h2973.atdir"; rm -rf "$DBD_2973"; mkdir -p "$DBD_2973"
out=$(SCHED_DB="$TMP/h2973-sched.db" SCHED_DB_DIR="$DBD_2973" CHIEF_WORK_DIR="$CW_2973" PATH="$STATEFUL_STUB:$PATH" OSTYPE=linux-gnu \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2973C" --dry-run 2>&1)
rc=$?
assert_rc "2973 at: chief arm dry-run exits 0" 0 "$rc"
assert_contains "2973 at: the job body exports HIMMEL_CONSOLE_DOC" "export HIMMEL_CONSOLE_DOC=$HO_2973C" "$out"
assert_contains "2973 at: the job body exports HIMMEL_CONSOLE_WORKDIR (basename slug + path-hash suffix)" "HIMMEL_CONSOLE_WORKDIR=$_WD2973-h" "$out"
assert_contains "2973 at: the job body CLEARS an ambient pair first" "unset HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_WORKDIR" "$out"
assert_contains "2973 at: the job body exports the HIMMEL_CONSOLE=1 chief marker (HIMMEL-6918)" " HIMMEL_CONSOLE=1" "$out"
out=$(SCHED_DB="$TMP/h2973-sched.db" SCHED_DB_DIR="$DBD_2973" CHIEF_WORK_DIR="$CW_2973" PATH="$STATEFUL_STUB:$PATH" OSTYPE=linux-gnu \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2973" --dry-run 2>&1)
assert_not_contains "2973 at: a non-chief arm exports no HIMMEL_CONSOLE_DOC" "export HIMMEL_CONSOLE_DOC" "$out"
assert_contains "2973 at: a non-chief arm still CLEARS an ambient pair" "unset HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_WORKDIR" "$out"
assert_not_contains "2973 at: a non-chief arm exports no HIMMEL_CONSOLE=1 (HIMMEL-6918)" " HIMMEL_CONSOLE=1" "$out"
fi

# ---------------------------------------------------------------------------
# own-identity exclusion in the ticket-mutex scan is per-backend.
#
# list_existing returns a task NAME on schtasks, a whole crontab LINE on cron
# and an opaque `at-job-N` on at. The mutex's exclusion compared the marker to
# $TASK_NAME, which can only ever be true on schtasks — so on POSIX a --force
# re-arm of the SAME handover saw its own slot and WARNed that a DIFFERENT
# handover holds the ticket. Both POSIX backends are forced from any host
# (OSTYPE + a PATH stub), exactly as the macOS/1879e sections do: a
# Windows-green says nothing about the two branches this fixes.
# ---------------------------------------------------------------------------
if _sec_selected "1636" "HIMMEL-1636"; then
echo "--- 1636 ---"
R1636="$TMP/h1636"
mkdir -p "$R1636/repo"
( cd "$R1636/repo" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
# Worker B is a SECOND file for the same ticket: it is the positive control that
# keeps every assert_not_contains below honest (the scan does find genuinely
# foreign slots on this backend), and re-arming worker A would hit the rc-3
# per-handover dedup before the ticket scan is ever reached.
HO_1636_A="$R1636/worker-a.md"
HO_1636_B="$R1636/worker-b.md"
printf -- '---\nticket: HIMMEL-9636\nresume_cwd: %s\n---\n\n# HIMMEL-9636 worker A\n' "$R1636/repo" > "$HO_1636_A"
printf -- '---\nticket: HIMMEL-9636\nresume_cwd: %s\n---\n\n# HIMMEL-9636 worker B\n' "$R1636/repo" > "$HO_1636_B"
_1636_WARN="already has another armed resume slot"

# --- at backend (linux): list_existing returns `at-job-N` -------------------
DBD_1636="$TMP/h1636.atdir"; rm -rf "$DBD_1636"; mkdir -p "$DBD_1636"
_a1636_at() {
    local ho="$1"; shift
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh HIMMEL_FLOW_RUNS_LEDGER="$TMP/1636-at.jsonl" \
        SCHED_DB="$TMP/h1636-sched.db" SCHED_DB_DIR="$DBD_1636" \
        PATH="$STATEFUL_STUB:$PATH" OSTYPE=linux-gnu \
        bash "$ARM" --time "$(future_time)" --handover "$ho" "$@" 2>&1)
}
_a1636_at "$HO_1636_A"; rc=$?
assert_rc "1636 at: worker A arms cleanly (rc=0)" 0 "$rc"
_a1636_at "$HO_1636_A" --force; rc=$?
assert_rc "1636 at: --force re-arm of the SAME handover succeeds (rc=0)" 0 "$rc"
assert_not_contains "1636 at: own at-job is NOT misread as a DIFFERENT handover" "$_1636_WARN" "$out"
_a1636_at "$HO_1636_B"; rc=$?
assert_rc "1636 at: a genuinely DIFFERENT handover on the same ticket still refuses (rc=13)" 13 "$rc"
assert_contains "1636 at: that refusal is the ticket mutex" "$_1636_WARN" "$out"

# --- crontab backend (macOS): list_existing returns the whole LINE ----------
MACBIN_1636="$TMP/macbin-1636"; mkdir -p "$MACBIN_1636"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN_1636/claude"; chmod +x "$MACBIN_1636/claude"   # HIMMEL-3074
CRON_STORE_1636="$TMP/cron-1636.store"; : > "$CRON_STORE_1636"
# at/atq must never be reached on macOS (arm-resume picks crontab there); a
# loud-failing `at` proves it, exactly as the macOS section's stub does.
printf '#!/bin/sh\necho "at MUST NOT be called on macOS" >&2; exit 1\n' > "$MACBIN_1636/at"; chmod +x "$MACBIN_1636/at"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN_1636/atq"; chmod +x "$MACBIN_1636/atq"
cat > "$MACBIN_1636/crontab" <<CRONEOF1636
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_1636" 2>/dev/null ;;
  -) cat > "$CRON_STORE_1636" ;;
  *) exit 0 ;;
esac
CRONEOF1636
chmod +x "$MACBIN_1636/crontab"
_a1636_cron() {
    local ho="$1"; shift
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh HIMMEL_FLOW_RUNS_LEDGER="$TMP/1636-cron.jsonl" \
        PATH="$MACBIN_1636:$PATH" OSTYPE=darwin23 \
        bash "$ARM" --time "$(future_time)" --handover "$ho" "$@" 2>&1)
}
_a1636_cron "$HO_1636_A"; rc=$?
assert_rc "1636 cron: worker A arms cleanly (rc=0)" 0 "$rc"
_a1636_cron "$HO_1636_A" --force; rc=$?
assert_rc "1636 cron: --force re-arm of the SAME handover succeeds (rc=0)" 0 "$rc"
assert_not_contains "1636 cron: own crontab LINE is NOT misread as a DIFFERENT handover" "$_1636_WARN" "$out"
_a1636_cron "$HO_1636_B"; rc=$?
assert_rc "1636 cron: a genuinely DIFFERENT handover on the same ticket still refuses (rc=13)" 13 "$rc"
assert_contains "1636 cron: that refusal is the ticket mutex" "$_1636_WARN" "$out"
fi

# ---------------------------------------------------------------------------
# optional --model passthrough into the relaunch payload.
#   Present -> flows into the generated at payload as `--model <name>`, right
#   after the prompt/--channels, mirroring the --channels passthrough shape
#   (T12/T13 above). Absent -> ruling 30 defaults a non-chief
#   arm to `--model opus`; a *-chief.md handover is exempt (ruling 25,
#   operator default) and stays free of any --model token.
# ---------------------------------------------------------------------------
if _sec_selected "2192" "HIMMEL-2192"; then
HO_2192=$(make_handover "$WORK_REPO")
out=$(posix_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model opus --dry-run 2>&1)
rc=$?
assert_rc "2192 --model dry-run exits 0" 0 "$rc"
assert_contains "2192 --model flows into the at payload" '--model opus' "$out"

out=$(posix_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --force --dry-run 2>&1)
rc=$?
assert_rc "2192 no-flag dry-run exits 0" 0 "$rc"
assert_contains "2192 no --model given defaults a non-chief arm to opus (ruling 30)" '--model opus' "$out"
assert_contains "2192 no --model given names ruling 30 in the reason" "non-chief arms default to opus -- ruling 30" "$out"

HO_2192_CHIEF="${HO_2192%.md}-chief.md"
cp -- "$HO_2192" "$HO_2192_CHIEF"
out=$(posix_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$HO_2192_CHIEF" --force --dry-run 2>&1)
rc=$?
assert_rc "2192 no-flag chief-named dry-run exits 0" 0 "$rc"
assert_not_contains "2192 no --model token for a chief-named handover (ruling 25)" "--model" "$out"

# crontab treats an unescaped % as end-of-command +
# stdin even inside %q-quoting, so a MODEL containing % needed \%-escaping
# in the (earlier) inline crontab entry. Since the runner-file
# redesign (fold of Goomal's fix/arm-resume-macos-cron), --model lives in the
# generated runner FILE body, parsed by /bin/sh (not crontab) -- so it is now
# left BARE, and the \%-escape scope narrows to q_runner alone (the runner
# PATH, the one value still on the crontab line itself; see the
# ARM_RUNNER_DIR case at the end of this section). Forced through the crontab
# backend the same way the "macOS backend" section above does (OSTYPE=darwin23
# + a stub crontab binary) -- a proven pattern in this suite for deterministic
# crontab coverage.
CRONBIN2192="$TMP/cronbin2192"; mkdir -p "$CRONBIN2192"
printf '#!/bin/sh\nexit 0\n' > "$CRONBIN2192/claude"; chmod +x "$CRONBIN2192/claude"   # HIMMEL-3074
CRON_STORE_2192="$TMP/cron2192.store"; : > "$CRON_STORE_2192"
cat > "$CRONBIN2192/crontab" <<CRONEOF
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_2192" 2>/dev/null ;;
  -) cat > "$CRON_STORE_2192" ;;
  *) exit 0 ;;
esac
CRONEOF
chmod +x "$CRONBIN2192/crontab"
HO_2192_PCT=$(make_handover "$WORK_REPO")
out=$(env PATH="$CRONBIN2192:$PATH" OSTYPE="darwin23" ARM_RUNNER_DIR="$TMP/runners2192" bash "$ARM" --time "$(future_time)" --handover "$HO_2192_PCT" --model 'a%b' --dry-run 2>&1)
rc=$?
assert_rc "2192 crontab --model with percent dry-run exits 0" 0 "$rc"
assert_contains "2192 runner preview leaves percent BARE in --model (parsed by /bin/sh, not crontab)" '--model a%b' "$out"
assert_not_contains "2192 RED CONTROL -- --model is not \\%-escaped (that scope narrowed to q_runner)" '--model a\%b' "$out"
# ARM_RUNNER_DIR is the ONE value left on the crontab line itself (the
# runner's own path) -- it still needs the \%-escape crontab requires.
out=$(env PATH="$CRONBIN2192:$PATH" OSTYPE="darwin23" ARM_RUNNER_DIR="$TMP/run%ners2192" bash "$ARM" --time "$(future_time)" --handover "$HO_2192_PCT" --dry-run 2>&1)
rc=$?
assert_rc "2192 crontab entry with a %-bearing ARM_RUNNER_DIR dry-run exits 0" 0 "$rc"
assert_contains "2192 crontab entry escapes percent in the runner path (still crontab-parsed)" 'run\%ners2192/HIMMEL-Resume-' "$out"

# Value-less --model must ERROR, not consume the next option as the model
# name (CR finding codex-1: `--model --dry-run` would otherwise swallow
# --dry-run and arm the real scheduler).
out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model --dry-run 2>&1)
rc=$?
assert_rc "2192 --model followed by an option exits 2" 2 "$rc"
assert_contains "2192 value-less --model error names the flag" "--model requires a non-empty" "$out"

out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model= --dry-run 2>&1)
rc=$?
assert_rc "2192 empty --model= exits 2" 2 "$rc"

# --model=--dry-run must ERROR too (same option-like-value gap as the
# space-separated form above,).
out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model=--dry-run 2>&1)
rc=$?
assert_rc "2192 --model=--dry-run exits 2" 2 "$rc"
assert_contains "2192 --model= option-like value error names the flag" "--model requires a non-empty" "$out"

out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model 'op"us' --dry-run 2>&1)
rc=$?
assert_rc "2192 --model with a double quote exits 2" 2 "$rc"
assert_contains "2192 double-quote --model error names the reason" "--model must not contain a double quote" "$out"

out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model $'opus\necho-x' --dry-run 2>&1)
rc=$?
assert_rc "2192 --model with an LF exits 2" 2 "$rc"
assert_contains "2192 control-char --model error names the reason" "--model must contain only printable, non-whitespace characters" "$out"
fi

# ---------------------------------------------------------------------------
# crontab tails: q_prompt/q_channels lack %-escaping.
# _crontab_schedule() %q-quotes q_prompt/q_channels but (pre-fix) never
# followed up with the \%-escape 2192 already applies to q_model -- crontab
# (unlike /bin/sh) reads an unescaped % as end-of-command + stdin even inside
# %q-quoting, so a handover path or --channels value containing % silently
# truncated the scheduled command at fire time. Forced through the crontab
# backend the same way 2192's own %-in---model test above does (OSTYPE=darwin23
# + a stub crontab); RESUME_PROMPT always embeds the handover PATH verbatim
# ("load $HANDOVER_PATH overnight mode. ..."), so a %-bearing handover path is
# the natural vector for q_prompt specifically.
# Since the runner-file redesign (fold of Goomal's fix/arm-resume-macos-cron),
# q_prompt/q_channels/q_cwd all moved into the runner FILE body (/bin/sh
# parsed, not crontab), so these assertions now check for BARE % there --
# same \%-escape-scope-narrowing rationale as 2192 above.
# ---------------------------------------------------------------------------
if _sec_selected "2199" "HIMMEL-2199"; then
CRONBIN2199="$TMP/cronbin2199"; mkdir -p "$CRONBIN2199"
printf '#!/bin/sh\nexit 0\n' > "$CRONBIN2199/claude"; chmod +x "$CRONBIN2199/claude"   # HIMMEL-3074
CRON_STORE_2199="$TMP/cron2199.store"; : > "$CRON_STORE_2199"
cat > "$CRONBIN2199/crontab" <<CRONEOF
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_2199" 2>/dev/null ;;
  -) cat > "$CRON_STORE_2199" ;;
  *) exit 0 ;;
esac
CRONEOF
chmod +x "$CRONBIN2199/crontab"

HO_2199_PCT="$HANDOVER_DIR/handover-100%.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf 'resume_cwd: %s\n' "$WORK_REPO"
    printf -- '---\n'
    printf '# Test handover\n'
} > "$HO_2199_PCT"

out=$(env ARM_BRIDGE_LIVE=0 PATH="$CRONBIN2199:$PATH" OSTYPE="darwin23" ARM_RUNNER_DIR="$TMP/runners2199" bash "$ARM" --time "$(future_time)" --handover "$HO_2199_PCT" --channels 'a%b' --long-gap --dry-run 2>&1)
rc=$?
assert_rc "2199 crontab %-in-prompt/channels dry-run exits 0" 0 "$rc"
# Content AFTER the % in each field proves nothing truncated there -- these
# fields are /bin/sh-parsed runner-file content now (not the crontab line),
# so % is correctly left BARE; a truncation would still drop the tail.
assert_contains "2199 runner preview leaves percent BARE in the prompt (from the %-bearing handover path)" 'handover-100%.md\ overnight\ mode' "$out"
assert_contains "2199 runner preview leaves percent BARE in --channels" '--channels a%b' "$out"
assert_not_contains "2199 RED CONTROL -- prompt/channels are not \\%-escaped (that scope narrowed to q_runner)" 'handover-100\%.md\ overnight\ mode' "$out"
assert_not_contains "2199 RED CONTROL -- --channels is not \\%-escaped" '--channels a\%b' "$out"
assert_contains "2199 crontab entry's trailing marker survives past both (nothing truncated)" '# HIMMEL-Resume-handover-100' "$out"

# CR round on this ticket (critic-panel [codex-1]): q_cwd sits in the SAME
# crontab entry (`cd $q_cwd && ...`) as q_prompt/q_channels but was missed by
# the first pass -- a % in RESUME_CWD (the git-toplevel-derived working
# directory) truncates the entry exactly the same way.
CWD_PCT="$TMP/work%repo"; mkdir -p "$CWD_PCT"
HO_2199_CWD=$(make_handover "$CWD_PCT")
out=$(env PATH="$CRONBIN2199:$PATH" OSTYPE="darwin23" ARM_RUNNER_DIR="$TMP/runners2199cwd" bash "$ARM" --time "$(future_time)" --handover "$HO_2199_CWD" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "2199 crontab %-in-cwd dry-run exits 0" 0 "$rc"
assert_contains "2199 runner preview leaves percent BARE in cwd" 'work%repo && unset' "$out"
assert_not_contains "2199 RED CONTROL -- cwd is not \\%-escaped" 'work\%repo && unset' "$out"
fi


if _sec_selected "2545" "HIMMEL-2545"; then
# These payload previews use --dedup-any, so earlier real-arm fixtures must
# not leave either backend's shared scheduler populated.
: > "$TMP/sched-stub-t17.tasks"
rm -f "$TMP/sched-stub-t17.atdir"/job-*
_2545_UNSET='unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID'
_2545_EXPORT='export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1'

# (a) the default POSIX backend (`at` on Linux).
HO_2545=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2545" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "2545a default-backend dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    *)
        assert_contains "2545a at body clears the child-session marker + CLAUDE_PID" "$_2545_UNSET" "$out"
        assert_contains "2545a at body forces session persistence" "$_2545_EXPORT" "$out"
        ;;
esac
# The marker is only ever CLEARED, never granted to the relaunched session.
assert_not_contains "2545a body never grants CLAUDE_CODE_CHILD_SESSION=1" "CLAUDE_CODE_CHILD_SESSION=1" "$out"

# (b) the cron backend builds its own single-LINE $tail — forced the way the
# "macOS backend" and 2192 sections do it (OSTYPE=darwin23 + a stub scheduler
# binary), because a one-line entry could easily have been patched only on
# the multi-line POSIX twin.
CRONBIN2545="$TMP/cronbin2545"; mkdir -p "$CRONBIN2545"
printf '#!/bin/sh\nexit 0\n' > "$CRONBIN2545/claude"; chmod +x "$CRONBIN2545/claude"   # HIMMEL-3074
CRON_STORE_2545="$TMP/cron2545.store"; : > "$CRON_STORE_2545"
cat > "$CRONBIN2545/crontab" <<CRONEOF
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_2545" 2>/dev/null ;;
  -) cat > "$CRON_STORE_2545" ;;
  *) exit 0 ;;
esac
CRONEOF
chmod +x "$CRONBIN2545/crontab"
HO_2545_CRON=$(make_handover "$WORK_REPO")
out=$(env PATH="$CRONBIN2545:$PATH" OSTYPE="darwin23" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2545_CRON" --dry-run 2>&1)
rc=$?
assert_rc "2545b cron dry-run exits 0" 0 "$rc"
assert_contains "2545b cron entry clears the child-session marker + CLAUDE_PID" "$_2545_UNSET" "$out"
assert_contains "2545b cron entry forces session persistence" "$_2545_EXPORT" "$out"

# The proxy variants build separate launch strings and need the same clears.
HO_2545_CRON_HP=$(make_handover "$WORK_REPO")
: > "$CRON_STORE_2545"
out=$(HIMMEL_HEADROOM_PROXY=1 env PATH="$CRONBIN2545:$PATH" OSTYPE="darwin23" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2545_CRON_HP" --dry-run 2>&1)
rc=$?
assert_rc "2545d cron headroom-proxy dry-run exits 0" 0 "$rc"
assert_contains "2545d cron headroom-proxy entry clears the child-session marker + CLAUDE_PID + CLAUDE_CODE_SESSION_ID" "$_2545_UNSET" "$out"
assert_contains "2545d cron headroom-proxy entry forces session persistence" "$_2545_EXPORT" "$out"

# (e) the `at` backend's HEADROOM-PROXY variant — same rationale as (d), for
# the other plain-vs-proxied pair of launch strings.
HO_2545_AT_HP=$(make_handover "$WORK_REPO")
out=$(HIMMEL_HEADROOM_PROXY=1 PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2545_AT_HP" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "2545e at headroom-proxy dry-run exits 0" 0 "$rc"
assert_contains "2545e at headroom-proxy body clears the child-session marker + CLAUDE_PID + CLAUDE_CODE_SESSION_ID" "$_2545_UNSET" "$out"
assert_contains "2545e at headroom-proxy body forces session persistence" "$_2545_EXPORT" "$out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
# a stale-fixture run must ANNOUNCE ITSELF rather than hand
# back a plausible failure list. future_time() refreshes with >=600s of its
# target left, so this is unreachable in a healthy run — the last value it
# handed out is still in the future. If wall-clock HAS passed it, some late arm
# asked for a time already in the past, arm-resume rolled it to TOMORROW, and
# the long-gap guard refused it rc=9: every "expected rc=N, got rc=9" above is
# then fixture rot, not a defect in the code under test. Deliberately not a
# FAIL — the run's real verdict stands; this only labels it.
# Two conditions, because neither alone covers the whole run: a target that
# expired MID-run is erased by the next refresh, so future_time() latches a
# marker file at that moment (panel r2 codex-2), while the second half catches
# a target that expired after the LAST handout and so was never refreshed away.
# Both read the cache FILE — the function runs in a command-substitution
# subshell, so nothing it assigns to a variable is visible here (r3 codex-1).
_ft_last_target=0; _ft_last_value=""
[ -s "$_FT_FILE" ] && read -r _ft_last_target _ft_last_value < "$_FT_FILE"
if [ -f "$_FT_STALE_FILE" ] || { [ -n "$_ft_last_value" ] && [ "$(date +%s)" -ge "$_ft_last_target" ]; }; then
    echo "WARN test-arm-resume.sh: the run outlived its own fixture window -- a future_time() target (last: $_ft_last_value) went PAST during the run, so any rc=9 above is suite shelf life (HIMMEL-1579), not a code defect. Re-run on an idle box before believing this list."
fi
# the real crontab/at queue must be byte-identical to what this
# run started with -- any case that reached the real scheduler despite its
# stub is a leak into the operator's own crontab/at, not a test failure to
# shrug off.
# a non-dry-run arm runs the REAL bank-preflight, whose producer
# refresh writes the usage cache at $CADENCE_USAGE_CACHE. The suite points that
# at $TMP and swaps in a stub producer that logs the cache path each refresh
# was handed (the scratch file only appears if a live OAuth fetch
# succeeds, so it proved nothing on hosts where it fails). A non-empty log
# proves a real arm reached the preflight; every line being $TMP/bank-cache.json
# proves the redirect held (else it would have rewritten the operator's live
# /tmp/claude/statusline-usage-cache.json). A --only run may skip every real arm.
if [ -z "$ONLY_FILTERS" ]; then
    if [ ! -s "$BANK_PRODUCER_LOG" ]; then
        echo "FAIL no non-dry-run arm reached the bank-preflight producer refresh -- the cache-redirect check below would be vacuous (HIMMEL-3911)"
        FAILED=$((FAILED + 1))
    elif grep -qvxF "$TMP/bank-cache.json" "$BANK_PRODUCER_LOG"; then
        echo "FAIL a bank-preflight refresh was aimed at a cache other than \$TMP/bank-cache.json -- a real arm may have rewritten the live usage cache (HIMMEL-3846):"
        grep -vxF "$TMP/bank-cache.json" "$BANK_PRODUCER_LOG"
        FAILED=$((FAILED + 1))
    fi
fi
CRONTAB_SNAPSHOT_AFTER=$(PATH="$SCHED_REAL_PATH" crontab -l 2>/dev/null || true)
if [ "$CRONTAB_SNAPSHOT_AFTER" != "$CRONTAB_SNAPSHOT_BEFORE" ]; then
    echo "FAIL the real crontab changed during this run -- a case leaked into the operator's live crontab:"
    diff <(printf '%s\n' "$CRONTAB_SNAPSHOT_BEFORE") <(printf '%s\n' "$CRONTAB_SNAPSHOT_AFTER") || true
    FAILED=$((FAILED + 1))
fi
ATQ_SNAPSHOT_AFTER=$(PATH="$SCHED_REAL_PATH" atq 2>/dev/null || true)
if [ "$ATQ_SNAPSHOT_AFTER" != "$ATQ_SNAPSHOT_BEFORE" ]; then
    echo "FAIL the real at queue changed during this run -- a case leaked into the operator's live at queue:"
    diff <(printf '%s\n' "$ATQ_SNAPSHOT_BEFORE") <(printf '%s\n' "$ATQ_SNAPSHOT_AFTER") || true
    FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
