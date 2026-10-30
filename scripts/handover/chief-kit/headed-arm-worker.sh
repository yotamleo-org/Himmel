#!/usr/bin/env bash
# scripts/handover/chief-kit/headed-arm-worker.sh - versioned WORKER launcher
# A thin wrapper around scripts/handover/headed-arm.sh that
# pins every worker arm to the standard --autocompact 200000 ceiling (a native-lane
# Sonnet 5.5 launch on a profile with sonnetAutocompact, today worker-impl and
# worker-eval, pins 450000 instead) - the window
# itself measures 1M regardless (docs/internals/lane-calibration.md "What a
# plain launch reports") - and adds the worker-only env the chief lane does not
# need.
#
# WHY: workers were
# ALREADY on the standard window today - the mechanism is the
# model-id suffix (`<model>[1m]` + `--autocompact auto` = 1M; no suffix =
# standard - see docs/internals/lane-calibration.md "Context mode" and
# headed-arm.sh's own --context handling, which this wrapper reuses rather
# than forking). What was missing was a fail-closed PIN: the resolved worker argv
# must carry the cost-driving `--autocompact` (200000, or the profile's Sonnet 5.5
# ceiling), not merely lack a [1m] model suffix. WORKER_SESSION_CONTEXT=1m therefore refuses with an actionable exit 2.
# The raw model string is still headed-arm.sh's concern: a caller handing this
# wrapper an already-[1m]-suffixed model gets it forwarded unchanged, and
# headed-arm.sh strips it under standard mode (test-headed-arm-worker.sh asserts
# this end-to-end).
#
# Folds the two prior ad-hoc kit-local copies (headed-arm-worker.sh,
# headed-arm-worker-cwd.sh - identical except an WORKER_SESSION_REPO override) into ONE
# versioned script: WORKER_SESSION_REPO now maps onto headed-arm.sh's own
# HEADED_ARM_REPO seam instead of a second, parallel repo-root variable.
#
# Usage: headed-arm-worker.sh [--dry-run] [--fleet <manifest>] <session-name> <handover-doc> \
#                           <signal-file> <deadline-epoch> <log> [model]
# Run detached, same as headed-arm.sh itself:
#   setsid nohup bash headed-arm-worker.sh ... >/dev/null 2>&1 &
#
# --dry-run: prints the argv this would hand to headed-arm.sh (name, doc,
# signal, deadline, log, model, resolved context) plus the worker env this
# wrapper adds, and exits 0 without touching the signal/deadline wait loop,
# the claim lock, or konsole. The test seam - but not the ONLY proof: the
# suite also drives the real (non-dry) path with KONSOLE_CMD/PGREP_CMD stubs
# (the same seams headed-arm.sh's own suite uses) to confirm the launched
# argv matches what --dry-run predicted.
#
# --ignore-denials: launch a worker even though it has an un-acked
# SHIP-STEP / PAUSE-RISK classifier-denial page on record. WITHOUT it the launch
# is refused, exit 14, with a message naming `ack-denial.sh <worker>` (the normal
# fix: review why the worker was parked, then ack it). The check keys on the
# session name and on the worktree slug in the handover doc's resume_cwd, reads
# only the page/ack records under ${HIMMEL_DENIAL_ACK_DIR:-~/.himmel/state/
# denial-acks} (never the denial log), and fails open: no record, an acked one,
# a REPEAT, or an unreadable record launches. Exit 14 joins 2 usage, 10 fleet
# cap, 11 bank exhausted, 12 macOS whitespace.
#
# --headless (or WORKER_SESSION_HEADLESS=1 in the launching shell, the flag
# wins): the same launch with no konsole - the worker runs as a Claude Code
# background session (headed-arm.sh adds --bg), and its env goes into the
# per-worker settings file because the session inherits the claude daemon's env,
# not ours. Needs a profile; native lane only. End a headless leg: `kill <pid>`
# (the pid= in the log's `headless=1` line, or `claude agents --json`), then
# `claude rm <short-id>`. Where -p vs --bg fits which job: docs/internals/headless-modes.md.
# A headless worker cannot pass seams to chokepoints: the seam
# guard ignores the per-worker settings file and refuses (exit 96) whenever a
# seam differs from the claude daemon's env, so merge-on-green.sh and go.sh
# refuse there. Use a headed worker for anything that ships.
#
# Platform guard: POSIX bash 3.2+, same as headed-arm.sh
# itself (konsole is Linux/KDE-only).
#
# Seams: HEADED_ARM_WORKER_TARGET overrides the headed-arm.sh path this wrapper
# execs (default: ../headed-arm.sh next to this script) so a suite can point
# it at a fixture without touching PATH. HEADED_ARM_WORKER_PREFLIGHT overrides
# the scripts/lib/usage-preflight.sh path the fleet-size cap below calls
# (default: ../../lib/usage-preflight.sh next to this script), same reason.
# HEADED_ARM_UNAME overrides the platform worker_propagate_env's whitespace
# refusal branches on (default: real `uname -s`) - the same seam name and
# idiom headed-arm.sh itself defines and its own suite already overrides
# with HEADED_ARM_UNAME=Linux/Darwin; resolved again HERE because this
# wrapper is a separate process that must settle that decision before it
# ever execs into headed-arm.sh.
#
# Exit 10: the fleet-size cap refused the launch - see the
# preflight call below. Exit 11: the $LANE bank is
# exhausted (SKIPPED-BANK) - same preflight call, distinct refusal reason.
# Exit 12: on macOS, worker_propagate_env refused a worker-process
# env value that contains whitespace - it cannot round-trip through
# HEADED_ARM_LAUNCHER_ENV's whitespace-split token list, and macOS has no
# other channel for it (a plain export never reaches an `open -a` worker there).
# On any other platform, plain-export inheritance already carries such a
# value, so worker_propagate_env leaves it there instead of refusing - see its
# own doc comment below. All three exit codes are distinct from
# headed-arm.sh's own exit codes (0-9 and 13), since this wrapper never
# reaches headed-arm.sh in any of these cases.
#
# --lane: native (default), claudex,
# openrouter or deepseek (see lane_registry below; glm refuses).
# OpenRouter uses HEADED_ARM_WORKER_OPENROUTER_BIN (default ../../claude-openrouter),
# the same recorder/profile shim, a pinned Sonnet 5.5 slug and WORKER_SESSION_LANE=openrouter.
# Its backend credit floor replaces subscription-bank admission, not fleet admission.
# --lane claudex (or
# WORKER_SESSION_LANE=claudex in the launching shell - the flag wins if both are
# given) routes the worker through scripts/claude-codex on the codex weekly
# bank instead of the Claude subscription bank: it routes headed-arm.sh's
# HEADED_ARM_LAUNCHER through the preface shim to the claudex binary (seam:
# HEADED_ARM_WORKER_CLAUDEX_BIN, default ../../claude-codex), turns on the `script`
# tty recorder (HEADED_ARM_RECORDER=1 - load-bearing: konsole -e output is
# otherwise lost and a silent claudex death is undiagnosable), and exports
# CLAUDEX_LANE_OK=1 + CLAUDE_CODE_EFFORT_LEVEL=${CLAUDE_CODE_EFFORT_LEVEL:-${WORKER_SESSION_EFFORT:-xhigh}}
# (an explicit value wins, then WORKER_SESSION_EFFORT, then decision 223's gpt-6.1-sol default) into the
# launched process via HEADED_ARM_LAUNCHER_ENV. An empty/omitted MODEL
# defaults to gpt-6.1-sol for this lane (native's own --judge default,
# claude-opus-5-5, is a Claude tier and would defeat the point of
# switching lanes). Context stays this wrapper's standard pin:
# --autocompact 200000 is the worker's ceiling; scripts/claude-codex's
# own CLAUDE_CODE_AUTO_COMPACT_WINDOW=272000 default never applies because
# `exec claude "$@"` forwards the CLI flag, which wins. An unknown lane
# name is a usage error (exit 2), not a silent fallback to native.
#
# --profile: applies a named plugin profile
# from scripts/lanes/plugin-profiles.json to the launched worker, plus the worker
# preface (docs/handover/worker-preface.md) and the lean-SessionStart switch. Also
# settable as WORKER_SESSION_PROFILE in the launching shell; the flag wins if both are
# given, same precedence as --lane. A launch that supplies NO profile (no
# --profile, no WORKER_SESSION_PROFILE, and neither --relay nor --judge, which force one)
# is REFUSED with exit 2 unless --no-profile is passed: an
# unprofiled worker silently runs without the standing preface and without the
# lean plugin set, its launch log indistinguishable from a profiled one, and
# it cannot know what it was not given. --no-profile is the explicit opt-out
# for a brief that carries the preface pasted in itself; it conflicts (exit 2)
# with any resolved profile (--profile, WORKER_SESSION_PROFILE, --relay, --judge) rather
# than silently dropping one, and the real launch records it in the launch
# log. Under --no-profile NOTHING else changes: no settings file is written,
# no env is exported, and the argv handed to headed-arm.sh is byte-identical
# to what it was before --profile existed (a suite case pins exactly that).
# Given a profile, three things happen:
#   1. plugin-profiles.mjs resolves the name to an enabledPlugins map, written
#      as a settings JSON next to the launch log (the per-uid chief work dir
#      the chief already owns), and HEADED_ARM_LAUNCHER is pointed at
#      scripts/lanes/worker-claude-launcher.sh, which PREPENDS `--settings <that
#      file>` to headed-arm.sh's fixed argv. headed-arm.sh itself is untouched.
#   2. The same shim prepends `--append-system-prompt-file <worker-preface>`, so
#      the invariant worker rules ride the system prompt instead of being retyped
#      into every brief. On the claudex lane this worker-preface is a per-worker
#      concatenation of docs/handover/worker-preface.md and the claudex
#      coordination preface, written next to the launch log at real-launch
#      time. On the native lane the
#      brief's own contract (the brief up to but excluding its `## Results`
#      tail, or the whole file if it has none) does NOT ride this preface -
#      measured, riding it re-pays the contract on EVERY API call
#      (contract x calls), 25-30x costlier over a typical worker than
#      re-injecting it only after a compaction (contract x (compactions+1)).
#      Instead it is written to its own per-worker <name>.worker-contract.md, and a
#      SessionStart hook with `"matcher": "compact"` is added to the
#      generated <name>.leg-settings.json to `cat` it back in whenever a
#      compaction fires - the `load <brief> and continue` first turn is the
#      only thing still compactable, and this hook re-supplies the contract
#      the moment it would otherwise be lost.
#   3. HIMMEL_LEAN_WORKER_SESSION=1 is exported, which silences the three advisory
#      SessionStart hooks (where-are-we, qmd staleness, graphify freshness) a
#      worker never acts on. inject-initiative.sh deliberately still speaks.
#   4. When the profile declares an mcpServers allowlist,
#      plugin-profiles.mjs's definitions are written as a second JSON next to
#      the settings file, and the shim additionally prepends `--mcp-config
#      <that file> --strict-mcp-config` — stripping every MCP server NOT
#      named there, including the user-level ones (graphify, obsidian-vault,
#      context7 in ~/.claude.json) that were the bulk of the un-measured
#      first-turn floor and that a plugin profile alone cannot touch. A
#      profile with no mcpServers field changes nothing here (no file, no
#      flags); an unresolvable name refuses (exit 2) rather than launching
#      without it.
# WHY the worker profiles are thin: the measured floor is schema-shaped, not
# roster-shaped (~40k of a 74.3k first-turn floor is tool + MCP schemas), so a
# "profile by skill set" would resolve to the same manifest. worker-eval and
# worker-docs exist to carry a different context setting, not a different roster:
# a profile's sonnetAutocompact / sonnetContextGuard apply to the native lane on a
# claude-sonnet-5 model only (worker-impl 450000 + hand-off, worker-eval 450000 +
# compaction, worker-docs 200000). See the _comment in plugin-profiles.json.
# --profile composes with --lane claudex: the shim prepends
# profile flags, then execs scripts/claude-codex via WORKER_SESSION_CLAUDE_BIN. The
# backend and its guarded argument screen remain in the launch path.
# Seams: HEADED_ARM_WORKER_PROFILES overrides the plugin-profiles.mjs resolver
# path, HEADED_ARM_WORKER_PREFACE the preface file, HEADED_ARM_WORKER_SHIM the
# launcher shim - all script-relative by default, all so the suite can drive
# the real code against fixtures.
#
# --relay: launches the Sonnet relay half of a split chief.
# Forces --profile chief-relay (a real --profile conflicts, exit 2); an
# empty MODEL defaults to claude-sonnet-5-5 and WORKER_SESSION_EFFORT defaults low, both
# only under this flag. Exports HIMMEL_CONSOLE_RELAY=1, the marker
# inbox-send.sh's Guard C already refuses --token under and the Task 26
# write-deny hook will key writes off - a distinct signal from the profile.
#
# --judge: launches a judge
# session through this SAME launcher rather than a separate mechanism. Forces
# --profile console-judge (a real --profile conflicts, exit 2, same shape as
# --relay above); an empty MODEL defaults to claude-opus-5-5 at high effort
# but only on the native lane. HIMMEL_CONSOLE_LEG=1 is
# already exported for every worker, so Guard E (go.sh refuses under it,
# merge-on-green.sh demands a chief GO) already covers a judge. A judge
# also gets HIMMEL_CONSOLE_JUDGE=1, the marker the plugin
# hook guard-judge-writes.sh keys its write-deny on. What DOES differ from a
# plain leg: no IMPL_GUARD_OK/INLINE_IMPL_OK (a judge does not implement),
# a raised HIMMEL_READ_CLAMP_LINES (independent reading is the job), and the
# judge preface instead of the worker preface.
#
# WORKER_SESSION_SUPPRESS_CR_TRIGGER: set in the launching shell to
# suppress the CodeRabbit auto-trigger for this one worker - see the
# WORKER_SESSION_REPO-style fold below for the mechanism. CodeRabbit is best effort
# the knob exists so a chief can skip the review on a PR
# that will never get one (machine-generated class), never to ration or
# sequence it. Opt-out, default ON: unset changes nothing.
#
# WORKER_SESSION_API_LANE=on: set in the launching shell to give this worker HIMMEL_API_LANE=on
# and HIMMEL_API_ACCOUNT=auto, so the PR critic runs on API credit. Opt-in,
# default OFF: unset changes nothing.
set -u
# refuse a chokepoint seam that differs from the session's launch env.
# Parameter expansion, not dirname: a PATH-shadowed dirname must not pick
# what is sourced before the seam guard.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "headed-arm-worker.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/handover/chief-kit/headed-arm-worker.sh || exit 96

# HEADED_ARM_UNAME - same seam name and default-
# expansion idiom headed-arm.sh itself defines; resolved again HERE because
# this wrapper is a separate process that must settle worker_propagate_env's
# platform branch before it ever execs into headed-arm.sh. Test seam:
# HEADED_ARM_UNAME=Darwin|Linux|... overrides it without a real uname call,
# same as headed-arm.sh's own suite already does.
HEADED_ARM_UNAME="${HEADED_ARM_UNAME:-$(uname -s 2>/dev/null)}"
export HEADED_ARM_UNAME

usage() {
    echo "usage: headed-arm-worker.sh [--dry-run] [--headless] [--fleet <manifest>] [--ignore-denials] [--no-prior-art-check] [--lane native|claudex|openrouter|deepseek] (--profile <name[,name...]> | --no-profile) [--relay] [--judge] [--consult] [--rm-release <R>] [--chief <name>] [--context-guard compact|handoff|none] <session-name> <handover-doc> <signal-file> <deadline-epoch> <log> [model]" >&2
    echo "  --context-guard: the worker context guard (default none = off, except a Sonnet launch on a profile that sets one: worker-impl hands off, worker-eval compacts); see docs/internals/worker-context-guard.md" >&2
}

# worker_propagate_env NAME VALUE - on macOS, `open -a` starts a worker
# from a FRESH environment (konsole-macos.sh's own header - PATH excepted, by
# a deliberate policy this fix leaves untouched), so a plain `export` here
# never reaches the worker process on that platform. Only an explicit token on
# headed-arm.sh's own `env ... NAME=VALUE ...` command line does: it is baked
# into the launched .command file's argv (`%q`-quoted), not inherited, so it
# survives the boundary a plain export does not. Every worker-process var this
# wrapper sets (IMPL_GUARD_OK, WORKER_SESSION_PROFILE_*, HIMMEL_CONSOLE_LEG, ...) must go
# through this function instead of a bare `export`. Vars headed-arm.sh itself
# consumes in THIS SAME process tree (HEADED_ARM_REPO, HEADED_ARM_LAUNCHER,
# HEADED_ARM_RECORDER, HEADED_ARM_REQUIRED_AUTOCOMPACT, ...) never cross that
# boundary and must NOT be routed through it - they stay plain exports.
#
# A caller-preset HEADED_ARM_LAUNCHER_ENV is preserved (appended to, never
# replaced) and wins on a name clash: this function only ever adds a NAME not
# already present as a token. HEADED_ARM_LAUNCHER_ENV is a whitespace-split
# token list (same contract as CODEX_USAGE_PROBE_CMD) with no quoting scheme,
# so a value containing whitespace cannot become a token: it would silently
# mis-split into extra bogus tokens. On macOS (HEADED_ARM_UNAME=Darwin), the
# token list is the ONLY channel to the worker, so such a value is refused
# loudly (exit 12) rather than silently corrupted. On every other platform, a
# plain `export` already reaches the worker via ordinary environment
# inheritance (this was true before and must stay true), so the
# value is left there untouched, a stderr warning explains why no token was
# added, and this function returns without exit.
_worker_propagate_one() {
    _worker_prop_name="$1"
    _worker_prop_value="$2"
    case "$_worker_prop_value" in
        *[[:space:]]*)
            if [ "$HEADED_ARM_UNAME" = "Darwin" ]; then
                echo "headed-arm-worker: refusing to propagate $_worker_prop_name: value contains whitespace, which HEADED_ARM_LAUNCHER_ENV's token list cannot carry ($_worker_prop_name=$_worker_prop_value)" >&2
                exit 12
            fi
            echo "headed-arm-worker: $_worker_prop_name value contains whitespace - leaving it to plain-export inheritance instead of HEADED_ARM_LAUNCHER_ENV (whose token list cannot carry it); harmless on $HEADED_ARM_UNAME, which inherits this process's environment directly" >&2
            export "$_worker_prop_name=$_worker_prop_value"
            unset -v _worker_prop_name _worker_prop_value
            return
            ;;
    esac
    export "$_worker_prop_name=$_worker_prop_value"
    set -f
    for _worker_prop_tok in ${HEADED_ARM_LAUNCHER_ENV:-}; do
        case "$_worker_prop_tok" in
            "$_worker_prop_name="*)
                set +f
                unset -v _worker_prop_name _worker_prop_value _worker_prop_tok
                return
                ;;
        esac
    done
    set +f
    HEADED_ARM_LAUNCHER_ENV="${HEADED_ARM_LAUNCHER_ENV:+$HEADED_ARM_LAUNCHER_ENV }$_worker_prop_name=$_worker_prop_value"
    export HEADED_ARM_LAUNCHER_ENV
    unset -v _worker_prop_name _worker_prop_value _worker_prop_tok
}

# worker_propagate_env NAME VALUE - _worker_propagate_one for NAME. A
# caller-preset token is dropped (worker_env_drop_token) before it is set, so no
# caller-preset token can leave the name carrying two values.
worker_propagate_env() {
    _worker_propagate_one "$1" "$2"
}

# worker_env_drop_token NAME - remove every NAME=... token from a
# caller-preset HEADED_ARM_LAUNCHER_ENV, keeping the rest in order. For a var
# this wrapper must own outright (a scrubbed knob, a validated value), where
# worker_propagate_env's caller-wins de-dupe would otherwise let the preset token
# reach the worker. set -f so no caller token is glob-expanded.
worker_env_drop_token() {
    _worker_drop_one "$1"
}

_worker_drop_one() {
    _worker_drop_kept=""
    set -f
    for _worker_drop_tok in ${HEADED_ARM_LAUNCHER_ENV:-}; do
        case "$_worker_drop_tok" in
            "$1="*) ;;
            *) _worker_drop_kept="${_worker_drop_kept:+$_worker_drop_kept }$_worker_drop_tok" ;;
        esac
    done
    set +f
    [ -n "${HEADED_ARM_LAUNCHER_ENV:-}" ] && HEADED_ARM_LAUNCHER_ENV="$_worker_drop_kept"
    unset -v _worker_drop_kept _worker_drop_tok
}

# worker_env_drop_prefix PREFIX - worker_env_drop_token for every
# PREFIX*=... token (the himmel-bus identity namespace, HIMMEL_BUS_*).
worker_env_drop_prefix() {
    _worker_drop_kept=""
    set -f
    for _worker_drop_tok in ${HEADED_ARM_LAUNCHER_ENV:-}; do
        case "$_worker_drop_tok" in
            "$1"*=*) ;;
            *) _worker_drop_kept="${_worker_drop_kept:+$_worker_drop_kept }$_worker_drop_tok" ;;
        esac
    done
    set +f
    [ -n "${HEADED_ARM_LAUNCHER_ENV:-}" ] && HEADED_ARM_LAUNCHER_ENV="$_worker_drop_kept"
    unset -v _worker_drop_kept _worker_drop_tok
}

DRY_RUN=0
RELAY=0
JUDGE=0
CONSULT=0
RM=0              # --profile release-manager
RM_RELEASE=""     # --rm-release <R>, required by that profile
READONLY_ROLE=0   # judge, consult or release manager: no implementation permissions, raised read clamp
NO_PROFILE=0
IGNORE_DENIALS=0
NO_PRIOR_ART_CHECK=0
# shellcheck source=scripts/lib/env-alias.sh
# shellcheck disable=SC1091
. "$_csg_dir/../../lib/env-alias.sh"
HEADLESS=0
[ "${WORKER_SESSION_HEADLESS:-}" = "1" ] && HEADLESS=1
LANE="${WORKER_SESSION_LANE:-native}"
: "${WORKER_SESSION_EFFORT:=}"
PROFILE="${WORKER_SESSION_PROFILE:-}"
CHIEF_FLAG=""
# the worker context guard is off unless the caller asks, by
# --context-guard or a HIMMEL_WORKER_SESSION_CONTEXT_MODE in the launching env
# (the flag wins), or a profile sets one for a native-lane claude-sonnet-5 launch.
CONTEXT_GUARD="${HIMMEL_WORKER_SESSION_CONTEXT_MODE:-}"
FLEET_MANIFEST=""
while :; do
    case "${1:-}" in
        --dry-run) DRY_RUN=1; shift ;;
        --relay) RELAY=1; shift ;;
        --judge) JUDGE=1; shift ;;
        --consult) CONSULT=1; shift ;;
        --ignore-denials) IGNORE_DENIALS=1; shift ;;
        --no-profile) NO_PROFILE=1; shift ;;
        --no-prior-art-check) NO_PRIOR_ART_CHECK=1; shift ;;
        --headless) HEADLESS=1; shift ;;
        --fleet)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then usage; exit 2; fi
            FLEET_MANIFEST="$2"; shift 2 ;;
        --lane)
            # `--lane` as the LAST arg leaves only 1 positional,
            # so `shift 2` fails (rc=1) and shifts NOTHING under `set -u`
            # (no `set -e` here to catch it) - the case above then matches
            # `--lane` again forever. Require a value before consuming it.
            if [ "$#" -lt 2 ]; then
                usage
                echo "headed-arm-worker: --lane requires a value (native, claudex, openrouter or deepseek)" >&2
                exit 2
            fi
            LANE="$2"; shift 2 ;;
        --profile)
            # Same missing-value trap as --lane above: without this guard a
            # trailing `--profile` re-matches forever under `set -u`.
            if [ "$#" -lt 2 ]; then
                usage
                echo "headed-arm-worker: --profile requires a value (a profile name from scripts/lanes/plugin-profiles.json; run \`node scripts/lanes/plugin-profiles.mjs --list\`)" >&2
                exit 2
            fi
            PROFILE="$2"; shift 2 ;;
        --chief)
            # Same missing-value trap as --lane/--profile above.
            if [ "$#" -lt 2 ]; then
                usage
                echo "headed-arm-worker: --chief requires a value (the owning chief's session name)" >&2
                exit 2
            fi
            CHIEF_FLAG="$2"; shift 2 ;;
        --console)
            usage
            echo "headed-arm-worker: --console was renamed to --chief" >&2
            exit 2 ;;
        --rm-release)
            # Same missing-value trap as --lane/--profile above.
            if [ "$#" -lt 2 ]; then
                usage
                echo "headed-arm-worker: --rm-release requires a value (the release the manager is bound to, e.g. v1.1.3)" >&2
                exit 2
            fi
            RM_RELEASE="$2"; shift 2 ;;
        --context-guard)
            # Same missing-value trap as --lane/--profile above.
            if [ "$#" -lt 2 ]; then
                usage
                echo "headed-arm-worker: --context-guard requires a value (compact, handoff or none)" >&2
                exit 2
            fi
            CONTEXT_GUARD="$2"; shift 2 ;;
        *) break ;;
    esac
done

# --relay: forces the chief-relay plugin profile - a relay is
# plugin-less by design, so any other --profile (flag or WORKER_SESSION_PROFILE) is a
# real conflict, not a preference to silently override.
if [ "$RELAY" -eq 1 ]; then
    if [ -n "$PROFILE" ] && [ "$PROFILE" != "chief-relay" ]; then
        usage
        echo "headed-arm-worker: --relay forces --profile chief-relay (got: $PROFILE)" >&2
        exit 2
    fi
    PROFILE="chief-relay"
fi

# --judge: forces console-judge the same way --relay forces
# chief-relay above - a real conflicting --profile refuses rather than
# silently overriding. --judge and --relay therefore also refuse each other
# here (each forces a different profile), which is the correct outcome: a
# session is not both roles at once.
if [ "$JUDGE" -eq 1 ]; then
    if [ -n "$PROFILE" ] && [ "$PROFILE" != "console-judge" ]; then
        usage
        echo "headed-arm-worker: --judge forces --profile console-judge (got: $PROFILE)" >&2
        exit 2
    fi
    PROFILE="console-judge"
fi

# --consult: a short read-only session that borrows the plugin set
# of the REQUESTED profile list (--profile design,design-motion). Unlike --judge
# it forces nothing, so the profile must be explicit (flag or WORKER_SESSION_PROFILE, never
# the brief's `profile:` line), and it refuses every non-additive profile even as
# a single name: operator/bare inject nothing, and the chief/relay/judge role
# profiles carry guard semantics a consult must not inherit. It also refuses a
# worker-worktree cwd (an explicit WORKER_SESSION_REPO/HEADED_ARM_REPO under .claude/worktrees/):
# a consult reads, it never runs inside a worker's checkout.
if [ "$CONSULT" -eq 1 ]; then
    if [ "$JUDGE" -eq 1 ] || [ "$RELAY" -eq 1 ] || [ "$NO_PROFILE" -eq 1 ]; then
        usage
        echo "headed-arm-worker: --consult refuses --judge, --relay and --no-profile (a consult is its own role and needs the requested profile)" >&2
        exit 2
    fi
    if [ -z "$PROFILE" ]; then
        usage
        echo "headed-arm-worker: --consult refuses an empty profile: pass --profile <name[,name...]> (the plugin set to consult with)" >&2
        exit 2
    fi
    _consult_rest="$PROFILE,"
    while [ -n "$_consult_rest" ]; do
        _consult_m="${_consult_rest%%,*}"; _consult_rest="${_consult_rest#*,}"
        case "$_consult_m" in
            operator|bare|chief|chief-relay|console|console-relay|console-judge|release-manager)
                usage
                echo "headed-arm-worker: --consult refuses profile \"$_consult_m\": non-additive or role profiles cannot back a consult (got: $PROFILE)" >&2
                exit 2
                ;;
        esac
    done
    if [ "$LANE" != "native" ]; then
        usage
        echo "headed-arm-worker: --consult refuses --lane $LANE: the read-only envelope is native-lane only (claudex settings-deny parity is unverified, so it fails closed)" >&2
        exit 2
    fi
    # The EFFECTIVE repo, derived the way headed-arm.sh derives it (WORKER_SESSION_REPO folds
    # onto HEADED_ARM_REPO; neither set = the checkout this script lives in), then
    # canonicalised so a relative or symlinked path cannot dodge the glob. An
    # unresolvable repo fails closed.
    _consult_raw="${WORKER_SESSION_REPO:-${HEADED_ARM_REPO:-$(dirname "$0")/../../..}}"
    if ! _consult_repo="$(cd -P "$_consult_raw" 2>/dev/null && pwd -P)"; then
        usage
        echo "headed-arm-worker: --consult cannot resolve its repo ($_consult_raw): refusing" >&2
        exit 2
    fi
    case "$_consult_repo/" in
        */.claude/worktrees/*)
            usage
            echo "headed-arm-worker: --consult refuses a worker worktree cwd (effective repo $_consult_repo is under .claude/worktrees/): launch it from the chief's own checkout" >&2
            exit 2
            ;;
    esac
    # The envelope below sandboxes the consult's Bash (bubblewrap +
    # socat on Linux; macOS uses the built-in Seatbelt). Claude Code's own
    # failIfUnavailable already fails closed, but only as a dead window: refuse at
    # arm time instead. CONSULT_*_BIN are test seams.
    if [ "$(uname -s)" = "Linux" ]; then
        if ! command -v "${CONSULT_BWRAP_BIN:-bwrap}" >/dev/null 2>&1 || ! command -v "${CONSULT_SOCAT_BIN:-socat}" >/dev/null 2>&1; then
            usage
            echo "headed-arm-worker: --consult needs bwrap (bubblewrap) AND socat on PATH for its Bash sandbox: install both, then relaunch" >&2
            exit 2
        fi
    fi
    CONSULT_REPO_CANON="$_consult_repo"
    unset -v _consult_raw _consult_repo
    # Same class as F1's shim refusal below: a caller-chosen seam
    # can launch the consult unconfined. HEADED_ARM_WORKER_CLAUDE_BIN has no in-repo
    # value (the shim would exec it with `--setting-sources ""`, which a foreign
    # binary can ignore), so it refuses outright. TARGET and PROFILES must resolve
    # to the in-repo file, and are then pinned to that CANONICAL path so a
    # symlinked directory cannot be retargeted between this check and their use.
    if [ -n "${HEADED_ARM_WORKER_CLAUDE_BIN:-}" ]; then
        echo "headed-arm-worker: --consult refuses HEADED_ARM_WORKER_CLAUDE_BIN=$HEADED_ARM_WORKER_CLAUDE_BIN: a consult runs the PATH claude, which honours its --setting-sources confinement" >&2
        exit 2
    fi
    if [ -n "${HEADED_ARM_WORKER_SYSTEMD_RUN:-}" ]; then
        echo "headed-arm-worker: --consult refuses HEADED_ARM_WORKER_SYSTEMD_RUN=$HEADED_ARM_WORKER_SYSTEMD_RUN: a consult only runs the system /usr/bin/systemd-run" >&2
        exit 2
    fi
    _consult_kit="$(cd -P "$(dirname "$0")" && pwd -P)"
    for _consult_pair in "HEADED_ARM_WORKER_TARGET ../headed-arm.sh" "HEADED_ARM_WORKER_PROFILES ../../lanes/plugin-profiles.mjs"; do
        _consult_var="${_consult_pair%% *}"; _consult_rel="${_consult_pair#* }"
        _consult_val="${!_consult_var:-}"
        _consult_want="$(cd -P "$_consult_kit/$(dirname "$_consult_rel")" && pwd -P)/$(basename "$_consult_rel")"
        # Unset = the in-repo default, pinned to the same canonical
        # path: the default spelling is built from $0, which a symlink can reach.
        _consult_got="$_consult_want"
        [ -z "$_consult_val" ] || _consult_got="$(cd -P "$(dirname "$_consult_val")" 2>/dev/null && pwd -P)/$(basename "$_consult_val")"
        if [ "$_consult_got" != "$_consult_want" ]; then
            echo "headed-arm-worker: --consult refuses $_consult_var=$_consult_val: only $_consult_want is the in-repo file a consult may run" >&2
            exit 2
        fi
        printf -v "$_consult_var" '%s' "$_consult_want"
    done
    unset -v _consult_kit _consult_pair _consult_var _consult_rel _consult_val _consult_got _consult_want
    # A PATH token reaches the shim's environment and would pick
    # which claude it runs; the shim pins its own PATH under a consult, and the
    # token refuses here too rather than ride along. A bash startup token (the
    # startup files, the option imports, the xtrace prompt, an exported
    # function) would run caller code inside the launcher's bash; the consult
    # entry strips them anyway, and they refuse here so the intent is visible.
    # A loader or node preload token (LD_PRELOAD, LD_LIBRARY_PATH,
    # LD_AUDIT, NODE_OPTIONS) would load caller code into every binary the
    # consult runs; same treatment. A token that is not NAME=VALUE becomes
    # `env`'s command operand (or an option) at headed-arm.sh's launch site, so
    # it would run as the session command: it refuses too.
    set -f
    for _consult_tok in ${HEADED_ARM_LAUNCHER_ENV:-}; do
        case "$_consult_tok" in
            PATH=*)
                set +f
                echo "headed-arm-worker: --consult refuses a PATH token in HEADED_ARM_LAUNCHER_ENV ($_consult_tok): a consult's claude comes from a pinned PATH, never the caller's" >&2
                exit 2
                ;;
            BASH_ENV=*|ENV=*|SHELLOPTS=*|BASHOPTS=*|PS4=*|CDPATH=*|GLOBIGNORE=*|BASH_FUNC_*)
                set +f
                echo "headed-arm-worker: --consult refuses a bash startup token in HEADED_ARM_LAUNCHER_ENV (${_consult_tok%%=*}): a consult's launcher runs on a clean bash" >&2
                exit 2
                ;;
            LD_PRELOAD=*|LD_LIBRARY_PATH=*|LD_AUDIT=*|NODE_OPTIONS=*)
                set +f
                echo "headed-arm-worker: --consult refuses a loader or node preload token in HEADED_ARM_LAUNCHER_ENV (${_consult_tok%%=*}): a consult's binaries load no caller code" >&2
                exit 2
                ;;
        esac
        # Spelled-out classes, not ranges: a range is locale-dependent in a glob.
        case "${_consult_tok%%=*}" in
            "$_consult_tok"|''|[0123456789]*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]*)
                set +f
                echo "headed-arm-worker: --consult refuses a token that is not NAME=VALUE in HEADED_ARM_LAUNCHER_ENV ($_consult_tok): the launch site would run it as a command" >&2
                exit 2
                ;;
        esac
    done
    set +f
    unset -v _consult_tok
    # The recorder's `script -c` runs the launch line in a shell
    # it finds through PATH. A consult is native-lane only and never records.
    unset -v HEADED_ARM_RECORDER
fi

[ "$JUDGE" -eq 1 ] || [ "$CONSULT" -eq 1 ] && READONLY_ROLE=1

# --no-profile is the deliberate opt-out; a profile from ANY
# source (flag, WORKER_SESSION_PROFILE, or the one --relay/--judge just forced) is a real
# conflict, not one to resolve by silently dropping either side.
if [ "$NO_PROFILE" -eq 1 ] && [ -n "$PROFILE" ]; then
    usage
    echo "headed-arm-worker: --no-profile conflicts with the profile requested via --profile, WORKER_SESSION_PROFILE, --relay or --judge (got: $PROFILE)" >&2
    exit 2
fi

# Lane registry: one row per lane, ONE code path below. A row
# gives the launcher binary (LANE_BIN_NAME under scripts/, LANE_BIN_OVERRIDE
# is its test seam), the chief channel (sendmessage = native SendMessage,
# file = document + file inbox, LANE_PREFACE names its worker-preface-<x>.md) and
# the admission gate (LANE_BANK_GATE is the CADENCE_USAGE_LANE usage-preflight
# checks). The default model stays with each lane's block below; deepseek takes
# it from the launcher's own export. glm refuses until it has a launcher
# contract. An unknown lane is a usage error, never a fallback to native.
# ponytail: usage-preflight.sh has no deepseek row, so deepseek rides its
# backend-gated "openrouter" gate (the launcher checks balance itself) and the
# fleet census labels it native; upgrade path = a deepseek row there.
lane_registry() {
    LANE_BIN_NAME=""; LANE_BIN_OVERRIDE=""; LANE_CHANNEL=sendmessage
    LANE_PREFACE=""; LANE_BANK_GATE="$1"; LANE_REFUSE=""
    case "$1" in
        native) ;;
        claudex)
            LANE_BIN_NAME=claude-codex; LANE_BIN_OVERRIDE="${HEADED_ARM_WORKER_CLAUDEX_BIN:-}"
            LANE_CHANNEL="file"; LANE_PREFACE=claudex ;;
        openrouter)
            LANE_BIN_NAME=claude-openrouter; LANE_BIN_OVERRIDE="${HEADED_ARM_WORKER_OPENROUTER_BIN:-}"
            LANE_CHANNEL="file"; LANE_PREFACE=openrouter ;;
        deepseek)
            LANE_BIN_NAME=claude-deepseek; LANE_BIN_OVERRIDE="${HEADED_ARM_WORKER_DEEPSEEK_BIN:-}"
            LANE_CHANNEL="file"; LANE_PREFACE=claudex; LANE_BANK_GATE=openrouter ;;
        glm) LANE_REFUSE="glm has no launcher contract yet (the GLM slice of HIMMEL-4084 has not landed)" ;;
        *) return 1 ;;
    esac
}
if ! lane_registry "$LANE"; then
    usage
    echo "headed-arm-worker: unknown lane: $LANE (expected native, claudex, openrouter or deepseek)" >&2
    exit 2
fi
if [ -n "$LANE_REFUSE" ]; then
    usage
    echo "headed-arm-worker: --lane $LANE refused: $LANE_REFUSE" >&2
    exit 2
fi

# --chief: charset-checked here because it is an explicit,
# user-typed flag - same refuse-on-bad-input stance as --lane/--profile
# above. It lands in a filesystem path downstream (merge-block-alert.sh's
# chief inbox lookup), so only letters, digits, '.', '_' and '-' pass, and
# "." / ".." are refused outright: they pass that charset but
# are path components, routing the lookup outside the chief directory.
if [ -n "$CHIEF_FLAG" ]; then
    case "$CHIEF_FLAG" in
        .|..)
            usage
            echo "headed-arm-worker: --chief: name must not be '.' or '..' (got: $CHIEF_FLAG)" >&2
            exit 2
            ;;
        *[!A-Za-z0-9._-]*)
            usage
            echo "headed-arm-worker: --chief: name must contain only letters, digits, '.', '_' or '-' (got: $CHIEF_FLAG)" >&2
            exit 2
            ;;
    esac
fi

# --headless: the background session takes its env from the
# claude daemon, so the worker's own env is written into the profile's settings
# file. With no profile there is no such file, and the worker would silently run
# on whatever env the daemon was spawned with. The claudex lane wraps claude
# in script(1) for a tty, which has no background form.
if [ "$HEADLESS" -eq 1 ]; then
    if [ "$NO_PROFILE" -eq 1 ]; then
        usage
        echo "headed-arm-worker: --headless needs a profile (the worker's env rides in the profile's settings file); drop --no-profile" >&2
        exit 2
    fi
    if [ "$LANE" != "native" ]; then
        usage
        echo "headed-arm-worker: --headless supports the native lane only (got: $LANE)" >&2
        exit 2
    fi
    export HEADED_ARM_HEADLESS=1
else
    unset HEADED_ARM_HEADLESS
fi

if [ "$#" -lt 5 ]; then
    usage
    exit 2
fi

NAME="$1"; DOC="$2"; SIGNAL="$3"; DEADLINE="$4"; LOG="$5"; MODEL="${6:-}"

# role-to-profile rule: a `profile: <name>` line in the brief's first
# 60 lines selects the worker's profile when neither --profile nor WORKER_SESSION_PROFILE did
# (an explicit flag/env is the override and always wins; --no-profile opts out
# and is left alone). Only the explicit field is honoured here - inferring a
# profile from the doc would silently end the unprofiled-launch refusal below.
if [ -z "$PROFILE" ] && [ "$NO_PROFILE" -eq 0 ] && [ -f "$DOC" ]; then
    # shellcheck disable=SC2016  # backticks in the sed regex are literal
    PROFILE="$(head -n 60 "$DOC" | sed -n -E 's/^[>* -]*profile:[[:space:]]*`?([A-Za-z0-9._,-]+)`?[[:space:]]*$/\1/p' | head -n 1)"  # read-sink-ok: DOC is the handover doc this launcher was asked to arm
fi

# leg-*, console and console-relay are the old names of the worker-*, chief and
# chief-relay registry keys (plugin-profiles.mjs PROFILE_ALIASES); map them here
# so the worker-vm check below and every profile consumer see one name. With
# legacy names off an old id stays as typed and fails as an unknown profile.
case "$PROFILE" in
    *leg-*|*console*)
        if legacy_names_on; then
            PROFILE="$(printf '%s' "$PROFILE" | sed -E 's/(^|,)leg-(impl|bus|vm|e2e)(,|$)/\1worker-\2\3/g; s/(^|,)leg-(impl|bus|vm|e2e)(,|$)/\1worker-\2\3/g; s/(^|,)console-relay(,|$)/\1chief-relay\2/g; s/(^|,)console(,|$)/\1chief\2/g; s/(^|,)console(,|$)/\1chief\2/g')"
        fi
        ;;
esac

# --profile release-manager: a judge-shaped role session bound to one release.
# It is read-only like a judge, native-lane only, never composed into a profile
# list, and requires --rm-release <R>, which names its state dir
# (release/<R>/) to guard-rm-writes.sh. --judge/--relay/--consult already
# refused it above.
case ",$PROFILE," in
    *,release-manager,*)
        if [ "$PROFILE" != "release-manager" ]; then
            usage
            echo "headed-arm-worker: profile \"release-manager\" cannot be composed in a profile list (got: $PROFILE)" >&2
            exit 2
        fi
        RM=1
        ;;
esac
if [ "$RM" -eq 1 ]; then
    if [ "$LANE" != "native" ]; then
        usage
        echo "headed-arm-worker: --profile release-manager refuses --lane $LANE: the release manager is native-lane only" >&2
        exit 2
    fi
    case "$RM_RELEASE" in
        "" | . | .. | *[!A-Za-z0-9._-]*)
            usage
            echo "headed-arm-worker: --profile release-manager requires --rm-release <R> (letters, digits, '.', '_' or '-'; got: ${RM_RELEASE:-<none>})" >&2
            exit 2
            ;;
    esac
    READONLY_ROLE=1
elif [ -n "$RM_RELEASE" ]; then
    usage
    echo "headed-arm-worker: --rm-release is only for --profile release-manager (got profile: ${PROFILE:-<none>})" >&2
    exit 2
fi

# same stance as the Tier-line refusal below - this wrapper
# refuses an under-specified dispatch rather than launching it. No profile and
# no explicit --no-profile would launch a worker with no standing preface and no
# lean plugin set, silently (see the --profile header comment). Runs before the
# --dry-run exit so a dry-run exercises the very decision it is predicting.
if [ -z "$PROFILE" ] && [ "$NO_PROFILE" -eq 0 ]; then
    usage
    echo "headed-arm-worker: refusing an unprofiled launch: pass --profile <name> (or set WORKER_SESSION_PROFILE; names: \`node scripts/lanes/plugin-profiles.mjs --list\`) so the worker gets docs/handover/worker-preface.md and the lean plugin set. Pass --no-profile only when the brief itself carries the preface pasted in." >&2
    exit 2
fi

# the worker-vm profile exists to start sessions on a test VM, so its
# brief must name one: a key of scripts/lib/vms.json that is an ubuntu guest and
# not kind=station, the same set the guest launcher accepts.
case ",$PROFILE," in
    *,worker-vm,*)
        if ! node -e '
const fs = require("fs");
const [regFile, doc] = process.argv.slice(1);
const reg = JSON.parse(fs.readFileSync(regFile, "utf8"));
const text = fs.readFileSync(doc, "utf8");
const named = Object.entries(reg).some(([vm, e]) => e.os === "ubuntu" && e.kind !== "station"
    && new RegExp("(^|[^A-Za-z0-9_-])" + vm + "($|[^A-Za-z0-9_-])").test(text));
process.exit(named ? 0 : 1);
' "${HEADED_ARM_WORKER_VMS_JSON:-$(dirname "$0")/../../lib/vms.json}" "$DOC" 2>/dev/null; then
            echo "headed-arm-worker: refusing a worker-vm launch: $DOC names no registered test VM (a key of scripts/lib/vms.json that is an ubuntu guest and not a station, e.g. ubuntu_new). Name the VM in the brief." >&2
            exit 2
        fi
        ;;
esac

# a fresh worker or judge brief carries a front-matter `description:`
# line (scripts/lib/worker-identity.sh resolves it), so every surface can say what
# the worker is doing next to its label. Same template-shaped gate as the Prior art
# check below, but --no-prior-art-check does not skip it. A doc whose Results
# already holds a bullet has run (worker_doc_has_run): a relaunch of it is a resume
# of a worker briefed before the field existed, and launches without one.
if [ "$RELAY" -eq 0 ] && [ "$CONSULT" -eq 0 ] && [ -f "$DOC" ] \
    && grep -Eq '^> \*\*(Contract|Completion condition):\*\*' "$DOC"; then
    # shellcheck source=../../lib/worker-identity.sh
    . "$(dirname "$0")/../../lib/worker-identity.sh"
    if [ -z "$(worker_description_field "$DOC")" ] && ! worker_doc_has_run "$DOC"; then
        echo "headed-arm-worker: refusing launch: $DOC has no front-matter 'description:' line. Add one plain-language line saying what this worker is doing and why between the leading '---' lines (the first must be the file's first line, no blank line or BOM before it), e.g. 'description: Add a description line to every worker brief' (docs/handover/worker-brief-template.md)." >&2
        exit 2
    fi
fi

# a worker or judge brief carries a filled `> **Prior art:**` line
# (brief-lint.sh), so the chief's one retrieval at dispatch reaches the worker.
# gated on every brief, not only a template-shaped one (a
# `> **Contract:**` or `> **Completion condition:**` line), so a brief that drops
# both fields cannot escape it. Relay and consult briefs are not worker/judge briefs.
if [ "$NO_PRIOR_ART_CHECK" -eq 0 ] && [ "$RELAY" -eq 0 ] && [ "$CONSULT" -eq 0 ] && [ -f "$DOC" ]; then
    if ! prior_art_err="$(bash "$(dirname "$0")/brief-lint.sh" "$DOC" 2>&1)"; then
        echo "headed-arm-worker: refusing launch: $prior_art_err (fill the Prior art line, or pass --no-prior-art-check to launch without it)" >&2
        exit 2
    fi
fi

# --relay defaults MODEL to the Sonnet relay's own default (an explicit model
# still wins, same precedence as --lane/--profile above); WORKER_SESSION_EFFORT defaults
# low for the same reason a relay runs plugin-less - it is not the implementor.
# Gated on RELAY: a non-relay worker's model default is headed-arm.sh's own, and
# must stay untouched (--dry-run's no-relay report is pinned byte-identical).
if [ "$RELAY" -eq 1 ]; then
    [ -z "$MODEL" ] && MODEL=claude-sonnet-5-5
    : "${WORKER_SESSION_EFFORT:=low}"
    export WORKER_SESSION_EFFORT
fi

# --judge defaults MODEL to the Opus tier at high effort, but ONLY on the
# native lane - the tier gate below matches a claude-* prefix, so a claudex
# judge would carry no cost gate at all under a borrowed default. --judge
# --lane claudex is left to fall through to the claudex lane's own gpt-6.1-sol
# default further down, unchanged: a known gap (design §3.2 P1), not this
# ticket's to close. Fable is retired as the judge DEFAULT (Opus
# 5.5 high measured ~2.7x cheaper per verdict than Fable 5.1 with comparable
# wall time and zero missed findings in the measured dataset); the effort
# default is set here, before the native-lane effort resolver below, so that
# resolver's own "an explicit CLAUDE_CODE_EFFORT_LEVEL wins" check treats it
# exactly like a caller-set value and never falls through to lanes.json's
# opus row (medium) instead. An explicit model still wins over the MODEL
# default; Fable stays available as an explicit, tier-gated choice.
#
# CLAUDE_CODE_EFFORT_LEVEL/WORKER_SESSION_EFFORT are deliberately kept as
# ambient worker-process input further down (the scrub loop's exclusion list),
# because a normal native worker's own effort resolver (below) needs a caller's
# explicit value to win. But a judge is armed by a WORKER, not only by a
# chief, and that worker's own shell can carry an inherited
# CLAUDE_CODE_EFFORT_LEVEL=low from ITS OWN launch - textually
# indistinguishable from a deliberate override, so the exclusion above let it
# silently beat this judge's high default. A chief's actual deliberate
# override therefore gets its own name, HIMMEL_CONSOLE_JUDGE_EFFORT, which
# nothing else in this wrapper ever sets or reads - only a caller that means
# to override a judge's effort would set it. Overwriting
# CLAUDE_CODE_EFFORT_LEVEL here unconditionally (not just when unset) makes
# this the last word for a native judge against ambient/inherited input -
# this assignment, not the worker_propagate_env de-dupe below, is what a judge
# brief means by "the effort channel". it is NOT the only
# override channel left: a caller-preset HEADED_ARM_LAUNCHER_ENV token for
# CLAUDE_CODE_EFFORT_LEVEL still wins downstream, because
# worker_env_propagate's "caller-preset token wins" de-dupe (:242-249) leaves
# an existing token alone rather than replacing it with this value. That is
# a second, deliberate-only channel (a worker's own shell never reaches it -
# headed-arm.sh unsets HEADED_ARM_LAUNCHER_ENV before a worker's own children
# launch), unaffected by this ticket and not a bug to fix here.
if [ "$CONSULT" -eq 1 ] && [ "$LANE" = "native" ]; then
    # a consult is a short question, not a verdict - Sonnet at medium.
    [ -z "$MODEL" ] && MODEL=claude-sonnet-5-5
    CLAUDE_CODE_EFFORT_LEVEL="${HIMMEL_CONSOLE_JUDGE_EFFORT:-medium}"
fi
if [ "$JUDGE" -eq 1 ] && [ "$LANE" = "native" ]; then
    [ -z "$MODEL" ] && MODEL=claude-opus-5-5
    CLAUDE_CODE_EFFORT_LEVEL="${HIMMEL_CONSOLE_JUDGE_EFFORT:-high}"
fi
# the release manager takes the judge's explicit-effort path under its own
# override name, HIMMEL_RM_EFFORT.
if [ "$RM" -eq 1 ]; then
    [ -z "$MODEL" ] && MODEL=claude-opus-5-5
    CLAUDE_CODE_EFFORT_LEVEL="${HIMMEL_RM_EFFORT:-high}"
fi
# The model the chief asked for, defaults applied; the check before the exec
# refuses a native launch whose --model to claude has drifted from it.
ASKED_MODEL="$MODEL"

HERE="$(cd "$(dirname "$0")" && pwd)"
HEADED_ARM="${HEADED_ARM_WORKER_TARGET:-$HERE/../headed-arm.sh}"

# refuse to re-dispatch a worker whose worktree slug (from the
# handover doc's resume_cwd) or session name has an un-acked SHIP-STEP /
# PAUSE-RISK page record newer than its latest ack (chief-wait.sh writes the
# page, ack-denial.sh the ack; see denial-ack-lib.sh). Exit 14, message naming
# ack-denial.sh and the override. No record, an acked one, a REPEAT, an unreadable
# lib or record all launch: this only ever fails OPEN. Runs before --dry-run's
# exit so a dry-run predicts the refusal, and before any real-launch write.
if [ "$IGNORE_DENIALS" -eq 0 ] && [ -r "$HERE/denial-ack-lib.sh" ]; then
    # shellcheck source=scripts/handover/chief-kit/denial-ack-lib.sh
    . "$HERE/denial-ack-lib.sh"
    for _den_label in "$NAME" "$(denial_doc_label "$DOC" 2>/dev/null)"; do
        [ -n "$_den_label" ] || continue
        _den_key="$(denial_key "$_den_label")" || continue
        if _den_hit="$(denial_unacked "$_den_key")"; then
            echo "headed-arm-worker: refusing to launch $NAME: an un-acked ${_den_hit%% *} classifier denial (x${_den_hit##* }) is on record for $_den_key. Review why the worker was parked, then run: bash $HERE/ack-denial.sh $_den_key   (or pass --ignore-denials to launch anyway)" >&2
            exit 14
        fi
    done
    unset _den_label _den_key _den_hit
fi

# a chief-spawned worker that runs merge-on-green.sh from its own
# (linked) worktree gets exit 17 "no chief GO" - handover_root() falls back
# to `git rev-parse --show-toplevel`, which resolves to the WORKTREE, not the
# chief's checkout, and <worktree>/handovers does not exist. Resolve the
# handover root HERE, in this wrapper's own process (still running in the
# CHIEF's launching cwd - no konsole child exists yet), and export it
# explicitly as HANDOVER_DIR so the worker's own handover_root() call binds to
# the exact same root the chief used to write its GO (chief-kit/go.sh).
# HANDOVER_DIR is already a registered seam var (scripts/lib/handover-path.sh)
# read by every handover script; this widens nothing - it only makes each
# launch's already-resolved root explicit instead of leaving a worker in a
# linked worktree to silently re-derive (and miss) it. Skip resolving only
# when the chief's own launching shell already set HANDOVER_DIR (Mode B -
# already correct, nothing to resolve) or when this process can't resolve
# one either (nothing to propagate - unchanged behavior from before this
# ticket).
if [ -z "${HANDOVER_DIR:-}" ]; then
    unset -f handover_root 2>/dev/null || true
    # handover_root reads only the live env, so feed it the
    # primary's .env HANDOVER_DIR first (same loader every handover script
    # uses); without this a chief launched with no exported HANDOVER_DIR
    # resolved the inline <cwd>/handovers stub on a Mode B station. A live
    # non-empty value is never overridden (load_dotenv only fills absent).
    # shellcheck source=scripts/lib/load-dotenv.sh
    # shellcheck disable=SC1091
    if . "$HERE/../../lib/load-dotenv.sh" 2>/dev/null; then
        load_dotenv HANDOVER_DIR 2>/dev/null || true
    fi
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    if . "$HERE/../../lib/handover-path.sh" 2>/dev/null; then
        _worker_handover_root="$(handover_root 2>/dev/null)" || _worker_handover_root=""
        [ -n "$_worker_handover_root" ] && worker_propagate_env HANDOVER_DIR "$_worker_handover_root"
        unset -v _worker_handover_root
    fi
fi

# Propagate HANDOVER_DIR whenever it is
# non-empty, not only when the block above just resolved it - the normal
# case for a grouped chief already exports HANDOVER_DIR before this
# wrapper ever runs (Mode B above), and that caller-preset value needs the
# exact same macOS token-list crossing as the self-resolved case; on Linux
# it was already reaching the worker via inheritance, so this is a no-op there.
# worker_propagate_env de-dupes by NAME against any HEADED_ARM_LAUNCHER_ENV
# token already present, so re-calling it for the value the block above just
# propagated is a harmless no-op, not a double-add.
[ -n "${HANDOVER_DIR:-}" ] && worker_propagate_env HANDOVER_DIR "$HANDOVER_DIR"

# refuse a worker or judge whose handover doc's resume_cwd resolves
# INSIDE the handover root (exit 15). The root commonly lives in an Obsidian
# vault, which indexes every file regardless of .gitignore, so a judge whose
# cwd is in the vault and whose scratch is a repo tree hung it twice (609k
# files; a docs-only fix never reached chief-written briefs).
# This is the one launcher every worker and judge goes through, so the gate lives
# here. Both paths are realpath'd (symlinks followed) and the resume_cwd's
# not-yet-existing tail is resolved through its deepest existing ancestor, so
# neither a symlink under ~/.cache nor a fresh subdirectory dodges it. A worker
# worktree, a ~/.cache path and a doc with no resume_cwd are untouched, and no
# resolvable root (nothing to guard) launches as before. Runs before --dry-run's
# exit, like the denial gate above, so a dry-run predicts the refusal.
# ponytail: a `..` inside the NOT-yet-existing tail is not collapsed, so such a
# path is judged by its literal tail; it cannot be entered anyway (the launch
# cd fails on a missing component), upgrade path: normalise the tail lexically.
_worker_phys_path() { # <path> -> physical path on stdout; a missing tail is kept verbatim
    local p="$1" tail="" base
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while [ ! -d "$p" ]; do
        base="${p##*/}"
        [ -n "$base" ] || { p="${p%/}"; [ -n "$p" ] || break; continue; }
        tail="/$base$tail"
        p="${p%/*}"
        [ -n "$p" ] || p="/"
    done
    p="$(cd -P "$p" 2>/dev/null && pwd -P)" || return 1
    [ "$p" = "/" ] && p=""
    printf '%s%s\n' "$p" "$tail"
}
_worker_rcwd="$(awk '
    /^---[[:space:]]*$/ { fm++; if (fm == 2) exit; next }
    fm == 1 && /^resume_cwd:[[:space:]]*/ { sub(/^resume_cwd:[[:space:]]*/, ""); print; exit }
' "$DOC" 2>/dev/null)"
_worker_rcwd="${_worker_rcwd%"${_worker_rcwd##*[![:space:]]}"}"
_worker_rcwd="${_worker_rcwd#\'}"; _worker_rcwd="${_worker_rcwd%\'}"
_worker_rcwd="${_worker_rcwd#\"}"; _worker_rcwd="${_worker_rcwd%\"}"
case "$_worker_rcwd" in \~|\~/*) _worker_rcwd="${HOME:-}${_worker_rcwd#\~}" ;; esac
_worker_vroot="${HANDOVER_DIR:-}"
if [ -z "$_worker_vroot" ] && command -v handover_root >/dev/null 2>&1; then
    _worker_vroot="$(handover_root 2>/dev/null)" || _worker_vroot=""
fi
if [ -n "$_worker_rcwd" ] && [ -n "$_worker_vroot" ]; then
    _worker_rcwd_phys="$(_worker_phys_path "$_worker_rcwd")" || _worker_rcwd_phys=""
    _worker_vroot_phys="$(_worker_phys_path "$_worker_vroot")" || _worker_vroot_phys=""
    if [ -n "$_worker_rcwd_phys" ] && [ -n "$_worker_vroot_phys" ]; then
        case "$_worker_rcwd_phys" in
        "$_worker_vroot_phys"|"$_worker_vroot_phys"/*)
            echo "headed-arm-worker: refusing to launch $NAME: the doc's resume_cwd ($_worker_rcwd -> $_worker_rcwd_phys) is inside the handover root ($_worker_vroot_phys), which an Obsidian vault indexes file by file. Judge scratch belongs under ~/.cache/himmel/verdicts/<qid>/; a worker belongs in a worktree under its repo's .claude/worktrees." >&2
            exit 15
            ;;
        esac
    fi
fi
# refuse (exit 2) a worker whose resume_cwd names a worker worktree path
# (.../.claude/worktrees/<type>+<slug>) that is not an existing git worktree: 8
# of 38 audited workers failed their first call on exactly this, and the worker then
# spends one to three turns creating it at the most expensive moment. Verify and
# refuse, never create: the launcher stays read-only on the repo. Only that path
# shape is checked, so a judge's scratch dir and a doc with no resume_cwd launch
# unchanged. Runs before --dry-run's exit so a chief's dry-run sees it.
# ponytail: the slug rule assumes the clean-garden `<type>+<slug>` basename, so a
# differently named worktree dir gets a best-effort create command, upgrade path:
# read the branch from `git worktree list` once a case needs it.
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
case "$_worker_rcwd" in
*/.claude/worktrees/*)
    _worker_wt_top="$(git_clean -C "$_worker_rcwd" rev-parse --show-toplevel 2>/dev/null)" || _worker_wt_top=""
    _worker_wt_phys="$(cd -P "$_worker_rcwd" 2>/dev/null && pwd -P)" || _worker_wt_phys=""
    if [ -z "$_worker_wt_top" ] || [ "$_worker_wt_top" != "$_worker_wt_phys" ]; then
        _worker_wt_base="${_worker_rcwd%/}"; _worker_wt_base="${_worker_wt_base##*/}"
        echo "headed-arm-worker: refusing to launch $NAME: the doc's resume_cwd ($_worker_rcwd) is not an existing git worktree. Create it first, from the repo's primary checkout: bash scripts/worktree.sh new ${_worker_wt_base/+//} --no-prune" >&2
        exit 2
    fi
    # With no repo override, use this repo's worktree or a registered adopter's
    # worktree as the session cwd, never the launcher's primary checkout.
    # An unregistered repo and --consult launch as before.
    # ponytail: registered = the registry lists the worktree's primary checkout, upgrade
    # path: read himmel-adopted.json once it carries local repo paths.
    if [ -z "${WORKER_SESSION_REPO:-}" ] && [ -z "${HEADED_ARM_REPO:-}" ] && [ "$CONSULT" -ne 1 ]; then
        _worker_rc_common="$(git_clean -C "$_worker_rcwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || _worker_rc_common="" # swallow-ok: empty means no registry match, the launch keeps the harness cwd
        _worker_self_common="$(git_clean -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || _worker_self_common="" # swallow-ok: empty leaves the harness cwd rule to the registry match alone
        # ponytail: a repo with a separate git dir (git init --separate-git-dir) has no <checkout>/.git, so
        # it is not matched and launches as before, upgrade path: match the registry paths by git common dir.
        if [ -n "$_worker_rc_common" ] && { [ "$_worker_rc_common" = "$_worker_self_common" ] \
            || bash "$HERE/../register-state.sh" --check --repo-path "${_worker_rc_common%/.git}" >/dev/null 2>&1; }; then
            HEADED_ARM_REPO="$_worker_wt_phys"
            export HEADED_ARM_REPO
            # headed-arm.sh passes DOC to the session as written and starts it in the new cwd
            case "$DOC" in /*) ;; *) DOC="$PWD/$DOC" ;; esac
        fi
        unset -v _worker_rc_common _worker_self_common
    fi
    ;;
esac
# the judge's own doc and qid, resolved while _worker_phys_path
# exists; exported for guard-judge-writes.sh with the judge marker below. A
# qid is the <qid> of a resume_cwd ~/.cache/himmel/verdicts/<qid>/scratch,
# and stays empty (the guard then allows no verdict write) when it is not.
_judge_doc=""; _judge_qid=""
if [ "$JUDGE" -eq 1 ]; then
    _judge_doc="$(_worker_phys_path "$DOC")" || _judge_doc=""
    if [ -n "$_worker_rcwd" ]; then
        _judge_rcwd="$(_worker_phys_path "$_worker_rcwd")" || _judge_rcwd=""
        case "$_judge_rcwd" in
            */.cache/himmel/verdicts/*/scratch)
                _judge_qid="${_judge_rcwd%/scratch}"; _judge_qid="${_judge_qid##*/}"
                case "$_judge_qid" in "" | *[!A-Za-z0-9._-]*) _judge_qid="" ;; esac
                ;;
        esac
    fi
fi
# the release manager's own doc, for guard-rm-writes.sh the same way.
_rm_doc=""
[ "$RM" -eq 1 ] && { _rm_doc="$(_worker_phys_path "$DOC")" || _rm_doc=""; }
unset -f _worker_phys_path
unset -v _worker_rcwd _worker_rcwd_phys _worker_vroot _worker_vroot_phys _worker_wt_top _worker_wt_phys _worker_wt_base

# Context resolution: off-values stay standard;
# the one old 1m opt-in is resolved explicitly so the argv guard below can
# reject it with a useful message rather than silently ignoring operator input.
#
# the `design` profile (and only it) resolves 1m by itself - an
# operator ruling (2026-10-01) that early compaction hurts design work, so no
# WORKER_SESSION_CONTEXT or brief Context line is needed; every other profile keeps a
# standard window (200000, or 450000 for a Sonnet 5.5 profile) and a bare
# WORKER_SESSION_CONTEXT=1m is still refused below.
PROFILES_MJS="${HEADED_ARM_WORKER_PROFILES:-$HERE/../../lanes/plugin-profiles.mjs}"
CONTEXT="standard"
RESOLVED_AUTOCOMPACT="200000"
DESIGN_CONTEXT_REASON=""
CONTEXT_SOURCE="operator-ruling"
SONNET_CEILING=0
GUARD_FROM_PROFILE=0
if [ -n "$PROFILE" ]; then
    if ! _worker_context_json="$(node "$PROFILES_MJS" "$PROFILE" --context)" \
        || ! CONTEXT="$(printf '%s' "$_worker_context_json" | jq -er '.contextMode | select(. == "standard" or . == "1m")')" \
        || ! RESOLVED_AUTOCOMPACT="$(printf '%s' "$_worker_context_json" | jq -er '.autocompact | select(type == "number" and . >= 200000 and . <= 1000000 and floor == .)')"; then
        echo "headed-arm-worker: --profile $PROFILE: context resolver failed; refusing launch" >&2
        exit 2
    fi
    if [ "$CONTEXT" = "1m" ]; then
        CONTEXT_SOURCE="profile $PROFILE contextMode 1m"
        DESIGN_CONTEXT_REASON="$CONTEXT_SOURCE"
    elif [ "$RESOLVED_AUTOCOMPACT" != "200000" ]; then
        echo "headed-arm-worker: standard profile must resolve autocompact 200000" >&2
        exit 2
    fi
    # The operator's per-profile ruling (2026-10-30). A profile may
    # give a Sonnet launch a higher standard ceiling (sonnetAutocompact, up to
    # 450000) and a default context guard (sonnetContextGuard). Only the native
    # lane on a claude-sonnet-5 model takes either: the 450000 ceiling was measured
    # there, and another lane, an older Sonnet or the bare alias keeps the 200000
    # above with no guard. Opus and Fable never read either. An explicit
    # --context-guard (including none) wins over the profile's default.
    # This is the one place the ceiling is decided; headed-arm.sh is handed the value.
    if [ "$CONTEXT" = "standard" ] && [ "$LANE" = "native" ]; then
        case "$MODEL" in
            claude-sonnet-5*)
                if _sonnet_ceiling="$(printf '%s' "$_worker_context_json" | jq -er '.sonnetAutocompact | select(type == "number" and . >= 200000 and . <= 450000 and floor == .)')"; then
                    RESOLVED_AUTOCOMPACT="$_sonnet_ceiling"
                    [ "$_sonnet_ceiling" = "200000" ] || SONNET_CEILING=1
                    if [ -z "$CONTEXT_GUARD" ]; then
                        CONTEXT_GUARD="$(printf '%s' "$_worker_context_json" | jq -r '.sonnetContextGuard // empty')"
                        [ -z "$CONTEXT_GUARD" ] || GUARD_FROM_PROFILE=1
                    fi
                fi ;;
        esac
    fi
fi
# Only the immediate headed-arm renderer reads these; never child launcher-env.
export HEADED_ARM_CONTEXT_PROFILE="$PROFILE"
_CONTEXT_BRIEF_REASON="$(grep -m1 -E '^> \*\*Context:\*\* 1m — operator-ruling: ' "$DOC" 2>/dev/null | sed -E 's/^> \*\*Context:\*\* 1m — operator-ruling: //; s/^[[:space:]]+//; s/[[:space:]]+$//')"
if [ "${WORKER_SESSION_CONTEXT:-}" = "1m" ]; then
    CONTEXT="1m"
    RESOLVED_AUTOCOMPACT="auto"
    SONNET_CEILING=0
    # The profile's guard goes with its Sonnet ceiling; an explicit --context-guard stays.
    [ "$GUARD_FROM_PROFILE" != "1" ] || CONTEXT_GUARD=""
    # An env override needs its own brief ruling, even on a design profile.
    CONTEXT_SOURCE="operator-ruling"
    DESIGN_CONTEXT_REASON="$_CONTEXT_BRIEF_REASON"
fi

# the audited autocompact A/B arm. WORKER_SESSION_AUTOCOMPACT_AB is launch
# input (200000 = control, 400000 = treatment; nothing else). The 400000 arm is
# opened by a brief ruling line, same shape as the 1m ruling above, and is
# refused alongside any 1m context. The value never leaks onward: both names are
# unset here and the marker headed-arm.sh reads is exported only at the exec.
AB_ARM=""
AB_REASON=""
_ab_in="${WORKER_SESSION_AUTOCOMPACT_AB:-}"
unset -v WORKER_SESSION_AUTOCOMPACT_AB HEADED_ARM_AB_AUTOCOMPACT HEADED_ARM_SONNET_AUTOCOMPACT
worker_env_drop_token WORKER_SESSION_AUTOCOMPACT_AB
worker_env_drop_token HEADED_ARM_AB_AUTOCOMPACT
worker_env_drop_token HEADED_ARM_SONNET_AUTOCOMPACT
case "$_ab_in" in
    '') ;;
    200000) AB_ARM="200k" ;;
    400000) AB_ARM="400k" ;;
    *)
        echo "headed-arm-worker: WORKER_SESSION_AUTOCOMPACT_AB must be 200000 or 400000, got: $_ab_in" >&2
        exit 2 ;;
esac
if [ -n "$AB_ARM" ] && { [ "$CONTEXT" != "standard" ] || [ "$RESOLVED_AUTOCOMPACT" != "200000" ]; }; then
    # The control arm is checked too: a 1m worker recorded as the 200k control
    # would contaminate the comparison.
    if [ "$SONNET_CEILING" = "1" ]; then
        echo "headed-arm-worker: refusing worker launch: WORKER_SESSION_AUTOCOMPACT_AB=$_ab_in needs the standard 200000 context, but profile $PROFILE gives this Sonnet launch the profile's Sonnet ceiling $RESOLVED_AUTOCOMPACT; run the A/B arm on a profile without one (worker-docs)" >&2
    else
        echo "headed-arm-worker: refusing worker launch: WORKER_SESSION_AUTOCOMPACT_AB=$_ab_in needs the standard 200000 context (got context=$CONTEXT autocompact=$RESOLVED_AUTOCOMPACT); the A/B arm never combines with a 1m opt-in" >&2
    fi
    exit 2
fi
if [ "$AB_ARM" = "400k" ]; then
    AB_REASON="$(grep -m1 -E '^> \*\*Context:\*\* ab-400k — operator-ruling: ' "$DOC" 2>/dev/null | sed -E 's/^> \*\*Context:\*\* ab-400k — operator-ruling: //; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -z "$AB_REASON" ]; then
        echo "headed-arm-worker: refusing worker launch: WORKER_SESSION_AUTOCOMPACT_AB=400000 needs '> **Context:** ab-400k — operator-ruling: <reason>' in $DOC" >&2
        exit 2
    fi
    RESOLVED_AUTOCOMPACT="400000"
fi
unset -v _ab_in

# chief-only knobs that must never reach a worker's own process,
# and therefore never reach the konsole child this wrapper execs into via
# headed-arm.sh (whose env -u list only clears the
# session-identity vars, not this one). CHIEF_CONTEXT is read by
# headed-arm.sh to pick a CHIEF's --autocompact ceiling; a worker's ceiling is
# already pinned above via WORKER_SESSION_CONTEXT/RESOLVED_AUTOCOMPACT, which never
# consults CHIEF_CONTEXT, so unsetting it here loses nothing. A chief
# armed with CHIEF_CONTEXT=1m in its own environ (the same leak, one hop
# earlier - out of scope here, see the ticket) would otherwise forward it to
# every worker it arms. Kept as a list, not a bare `unset`, so --dry-run can
# print it and test-headed-arm-worker.sh can assert the exact set and fail on
# drift if a future chief-only knob needs the same treatment.
# the scrub also strips NAME=... tokens from a caller-preset
# HEADED_ARM_LAUNCHER_ENV. worker_propagate_env appends to that list rather than
# replacing it, and headed-arm.sh hands every token to the worker on every lane,
# so an `unset` alone let a caller-listed CHIEF_CONTEXT=1m come straight
# back into the worker.
#
# HIMMEL_CONSOLE_JUDGE_EFFORT is the same class of hazard as
# CHIEF_CONTEXT, not the WORKER_SESSION_PROFILE_* class further down - it is consumed
# above (line ~469) for THIS invocation only, and a judge's own persisting
# shell must not keep it exported: an armed judge that itself later arms a
# nested judge would otherwise have its ambient (inherited, not deliberate)
# HIMMEL_CONSOLE_JUDGE_EFFORT silently win again, the exact same "ambient
# looks deliberate" failure this ticket closes for CLAUDE_CODE_EFFORT_LEVEL.
# The release-manager marker, binding and effort override are the same class:
# a release manager arming a worker must not hand that worker its mode-2 fence.
WORKER_SESSION_ENV_SCRUB="CHIEF_CONTEXT HIMMEL_CONSOLE_JUDGE_EFFORT HIMMEL_CONSOLE_JUDGE_DOC HIMMEL_CONSOLE_JUDGE_QID HIMMEL_RELEASE_MANAGER HIMMEL_RM_DOC HIMMEL_RM_RELEASE HIMMEL_RM_EFFORT HIMMEL_CONSOLE"
for _worker_env_scrub in $WORKER_SESSION_ENV_SCRUB; do
    unset "$_worker_env_scrub"
    worker_env_drop_token "$_worker_env_scrub"
done
unset -v _worker_env_scrub

# (#1334 CR follow-up) A different reason than the CHIEF_CONTEXT scrub above
# but the same shape: this wrapper's own process may itself BE a worker that is
# now arming a SIBLING worker, and WORKER_SESSION_PROFILE_SETTINGS/WORKER_SESSION_PROFILE_PREFACE/
# WORKER_SESSION_PROFILE_MCP_CONFIG - both the plain env var and the
# HEADED_ARM_LAUNCHER_ENV token worker-1's own launch added - are still live in
# that shell. Unlike CHIEF_CONTEXT these three names DO belong on a worker, so
# this is not a "must never reach a worker" scrub - it is "must be recomputed by
# THIS worker, never inherited from a sibling". Dropping the token only where a
# name is re-propagated is not enough: a path that does NOT touch a given name
# this run (no --profile; a profile with mcpServers: null skips
# WORKER_SESSION_PROFILE_MCP_CONFIG entirely) would otherwise leave that sibling's stale
# value live - the plain var read at
# real-launch time (WORKER_SESSION_PROFILE_MCP_CONFIG's write-if-set check further down)
# and the token forwarded to the actually-launched worker. Scrubbing both, once,
# before any branch, means every path starts clean and the existing
# worker_propagate_env calls are the only thing that can set them again.
# WORKER_SESSION_PROFILE_NO_SETTING_SOURCES rides the same scrub: only --consult sets it.
# WORKER_SESSION_ID too: a sibling's id reused here would collide.
for _worker_env_scrub in \
    WORKER_SESSION_PROFILE_SETTINGS WORKER_SESSION_PROFILE_PREFACE WORKER_SESSION_PROFILE_MCP_CONFIG WORKER_SESSION_PROFILE_NO_SETTING_SOURCES WORKER_SESSION_ID; do
    unset -v "$_worker_env_scrub"
    worker_env_drop_token "$_worker_env_scrub"
done
unset -v _worker_env_scrub

# same "this wrapper's own process may itself BE a worker" hazard as
# the WORKER_SESSION_PROFILE_* scrub above, but for the rest of the names a worker sets on
# itself while arming a SIBLING (most often a judge). A judge deliberately
# never gets IMPL_GUARD_OK/INLINE_IMPL_OK re-set below (a judge doesn't
# implement) - without this scrub, an inherited value from the calling worker's
# own session reaches it anyway, unset+undetected. chief_context_worker_env_unset_names
# (scripts/lib/chief-context.sh) is the single source of truth for this set
# already - chief.sh's do_arm() blindly unsets the whole list before arming
# headed-arm.sh directly, which is safe there because do_arm() never reads any
# of these names as input. This wrapper DOES read six of them as deliberate,
# tested ambient input (HANDOVER_DIR above; HIMMEL_CONSOLE_NAME,
# CLAUDE_CODE_EFFORT_LEVEL, WORKER_SESSION_EFFORT and HEADED_ARM_UNAME further down;
# HIMMEL_CONSOLE_LEG has a pinned caller-preset-wins override test, case 31b),
# so scrubbing those here would destroy the exact feature they exist for -
# they are excluded by name, not by re-deriving a second list. The three
# WORKER_SESSION_PROFILE_* names are excluded because the loop above already scrubbed
# them; HEADED_ARM_LAUNCHER_ENV is excluded because it is the container being
# cleaned, not a name inside it. WORKER_SESSION_CLAUDE_BIN is NOT excluded:
# unlike the six
# names above, this wrapper never reads WORKER_SESSION_CLAUDE_BIN back as deliberate
# input on this native lane - only the claudex branch and the
# HEADED_ARM_WORKER_CLAUDE_BIN test seam below ever set it again, both via a
# fresh `worker_propagate_env` call after this point. Scrubbing var+token here
# closes the leak: a claudex worker's own `WORKER_SESSION_CLAUDE_BIN=<claude-codex>`
# inherited into a native --judge/--profile launch would otherwise reach
# worker-claude-launcher.sh's `CLAUDE_BIN="${WORKER_SESSION_CLAUDE_BIN:-claude}"` (see
# worker-claude-launcher.sh:63) and exec the wrong binary. Every remaining name
# is set-only, so unsetting it early and letting the existing
# worker_propagate_env/export calls below re-set it is a no-op for a normal
# chief-launched worker or judge and closes the leak for a worker-launched one.
# shellcheck source=scripts/lib/chief-context.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/chief-context.sh"
# WORKER_SESSION_EFFORT is excluded (not scrubbed) same as the other five
# names above, so it still passes through unchanged into a --judge launch as
# a plain ambient var. Harmless today: a native judge never reads WORKER_SESSION_EFFORT
# back (only the claudex branch further down and the relay path do), so an
# inherited value has nothing to affect here. It would matter the day a
# judge itself arms a claudex worker and forwards WORKER_SESSION_EFFORT to it - watch for
# that if the judge role ever grows a claudex-arming path.
for _worker_env_scrub in $(chief_context_worker_env_unset_names); do
    case "$_worker_env_scrub" in
        HANDOVER_DIR|HIMMEL_CONSOLE_NAME|CLAUDE_CODE_EFFORT_LEVEL|WORKER_SESSION_EFFORT|HEADED_ARM_UNAME) continue ;;
        HIMMEL_CONSOLE_LEG) continue ;;
        # the chief's chosen context mode is launch input, read below.
        HIMMEL_WORKER_SESSION_CONTEXT_MODE) continue ;;
        WORKER_SESSION_PROFILE_SETTINGS|WORKER_SESSION_PROFILE_PREFACE|WORKER_SESSION_PROFILE_MCP_CONFIG) continue ;;
        HEADED_ARM_LAUNCHER_ENV) continue ;;
    esac
    unset -v "$_worker_env_scrub"
    worker_env_drop_token "$_worker_env_scrub"
done
unset -v _worker_env_scrub

if [ -n "$PROFILE" ]; then
    worker_propagate_env HIMMEL_WORKER_SESSION_PROFILE "$PROFILE"
fi

# the scrub above just dropped any inherited WORKER_SESSION_CLAUDE_BIN, var
# and token, unconditionally. test-headed-arm-worker.sh's --headless suite
# (run_headless(), case 29) needs a way to point worker-claude-launcher.sh's
# `CLAUDE_BIN="${WORKER_SESSION_CLAUDE_BIN:-claude}"` (worker-claude-launcher.sh:63) at a
# stub, without reintroducing the leak the scrub just closed - a plain
# WORKER_SESSION_CLAUDE_BIN in this wrapper's own process env is now indistinguishable
# from a stale sibling leak, so the suite gets its own dedicated seam name
# instead. A real caller never sets this; only a test does. Scoped to the
# native lane so it can never race the claudex branch's own
# `worker_propagate_env WORKER_SESSION_CLAUDE_BIN "$CLAUDEX_BIN"` further down - no
# existing or new caller combines the two.
#
# The seam name itself is unset right after use (var + any launcher-env
# token) for the same reason HIMMEL_CONSOLE_JUDGE_EFFORT is scrubbed above:
# an armed worker that itself later arms a nested worker/judge must not have an
# ambient HEADED_ARM_WORKER_CLAUDE_BIN, inherited from its own launch, silently
# satisfy this seam again - only the immediate caller of THIS invocation may
# set it.
if [ "$LANE" = "native" ] && [ -n "${HEADED_ARM_WORKER_CLAUDE_BIN:-}" ]; then
    worker_propagate_env WORKER_SESSION_CLAUDE_BIN "$HEADED_ARM_WORKER_CLAUDE_BIN"
fi
unset -v HEADED_ARM_WORKER_CLAUDE_BIN
worker_env_drop_token HEADED_ARM_WORKER_CLAUDE_BIN

# a worker's ceiling is the resolved CLI pair, not the absence of a
# model suffix. Fail before dry-run reporting or preflight when context already
# resolves wrong; headed-arm.sh separately validates the exact argv it launches.
#
# a sanctioned operator ruling opens this door - mirrors the
# Tier-line gate below, same shape: a fixed marker line in the
# brief, grepped by exact prefix, non-blank free text required. CONTEXT_REASON
# stays empty for every standard-ceiling launch (the case above sets
# RESOLVED_AUTOCOMPACT to 200000, or to the profile's Sonnet ceiling, which the
# SONNET_CEILING test below skips), so this block is a no-op for every existing
# caller.
CONTEXT_REASON=""
if [ "$RESOLVED_AUTOCOMPACT" != "200000" ] && [ "$AB_ARM" != "400k" ] && [ "$SONNET_CEILING" != "1" ]; then
    CONTEXT_REASON="$DESIGN_CONTEXT_REASON"
    CONTEXT_REASON="$(printf '%s' "$CONTEXT_REASON" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -z "$CONTEXT_REASON" ]; then
        echo "headed-arm-worker: refusing worker launch: resolved argv lacks the required --autocompact 200000 ceiling (got --autocompact $RESOLVED_AUTOCOMPACT). unset WORKER_SESSION_CONTEXT and retry, or add '> **Context:** 1m — operator-ruling: <reason>' to $DOC for a sanctioned opt-in; use a chief arm, not a worker, for unsanctioned 1m context." >&2
        exit 2
    fi
    # headed-arm.sh's own 1m gate (unedited by this ticket) requires
    # CHIEF_CONTEXT=1m in ITS process env, not merely a resolved CONTEXT
    # positional - a var it consumes in THIS SAME process tree, so a plain
    # export (never worker_propagate_env) is the right channel, same convention
    # worker_propagate_env's own header documents for HEADED_ARM_REPO etc. The
    # scrub above already ran unconditionally and unset any
    # ambient value before this point; this is a deliberate, narrow re-set
    # for the one sanctioned exec below, not a change to that scrub. Any
    # further headed-arm-worker.sh launch this worker itself makes re-scrubs it
    # from scratch, so no ambient leak survives past this one call.
    [ "$RESOLVED_AUTOCOMPACT" != "auto" ] || export CHIEF_CONTEXT=1m
fi
# the one marker headed-arm.sh honours (paired to its exec PID).
# A plain export, same channel as CHIEF_CONTEXT above; headed-arm.sh unsets it.
[ "$AB_ARM" != "400k" ] || export HEADED_ARM_AB_AUTOCOMPACT=400000
# The Sonnet ceiling this wrapper resolved, handed to the renderer under the same
# pairing; headed-arm.sh does not derive it again from MODEL.
[ "$SONNET_CEILING" != "1" ] || export HEADED_ARM_SONNET_AUTOCOMPACT="$RESOLVED_AUTOCOMPACT"

# an Opus or Fable worker costs materially more per turn than the
# Sonnet default implementor, so it launches only when its brief names one of
# the four sanctioned reasons on a Tier line (CLAUDE.md: "raise effort
# before tier"). Matched by MODEL PREFIX, same reasoning as the [1m] suffix
# guard above - a suffix (e.g. claude-opus-5[1m]) must not dodge the gate.
TIER_GATE=""
case "$MODEL" in
    claude-opus-*|anthropic/claude-opus-*) TIER_GATE="opus" ;;
    claude-fable-*|anthropic/claude-fable-*) TIER_GATE="fable" ;;
esac
if [ -n "$TIER_GATE" ]; then
    TIER_REASON="$(grep -m1 -E "^> \*\*Tier:\*\* $TIER_GATE — " "$DOC" 2>/dev/null | sed -E "s/^> \*\*Tier:\*\* $TIER_GATE — //")"
    # `-z` alone treats a whitespace-only
    # reason (e.g. a Tier line with nothing but trailing spaces after the
    # dash) as non-empty, so strip surrounding whitespace before the check.
    TIER_REASON="$(printf '%s' "$TIER_REASON" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -z "$TIER_REASON" ]; then
        echo "headed-arm-worker: refusing $TIER_GATE launch: $DOC has no '> **Tier:** $TIER_GATE — <category>: <reason>' line (CLAUDE.md: raise effort before tier). Sanctioned reasons: multi-step design; a FINDING the chief could not verify at Sonnet; a Sonnet worker returned the work as above its tier; a standing operator ruling on model choice. Category tags (exact lowercase): design|unverified-finding|tier-return|operator-ruling." >&2
        exit 2
    fi
    # the design was left open (keyword vs enum vs LLM) - chief
    # ruling: a closed category TAG followed by free text, so paraphrase in
    # the free text can never be falsely rejected. Split on the first ':'.
    # both expansions below are no-ops when
    # no literal ':' is present, so a bare tag (e.g. "design" alone) would
    # otherwise pass with TIER_CATEGORY=TIER_REASON=the tag itself - require
    # the colon explicitly first.
    case "$TIER_REASON" in
        *:*) ;;
        *)
            echo "headed-arm-worker: refusing $TIER_GATE launch: $DOC's Tier reason must open with one of the four sanctioned category tags (exact lowercase) followed by ': ' and non-blank free text: design|unverified-finding|tier-return|operator-ruling." >&2
            exit 2
            ;;
    esac
    TIER_CATEGORY="${TIER_REASON%%:*}"
    TIER_REASON="${TIER_REASON#*:}"
    case "$TIER_CATEGORY" in
        design|unverified-finding|tier-return|operator-ruling) ;;
        *)
            echo "headed-arm-worker: refusing $TIER_GATE launch: $DOC's Tier reason must open with one of the four sanctioned category tags (exact lowercase) followed by ': ' and non-blank free text: design|unverified-finding|tier-return|operator-ruling." >&2
            exit 2
            ;;
    esac
    TIER_REASON="$(printf '%s' "$TIER_REASON" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -z "$TIER_REASON" ]; then
        echo "headed-arm-worker: refusing $TIER_GATE launch: $DOC's Tier reason has category '$TIER_CATEGORY' but no free text after the colon." >&2
        exit 2
    fi
fi

# advisory effort recommendation. Only when the brief carries
# '> **Effort-record:** <path>' (an effort-assess record). One stderr line;
# it never changes the launch, the exit code or the Tier gate, and any failure
# (missing/unreadable record, node absent, bad JSON) degrades to an
# 'unavailable' line. Absent marker = no output at all.
EFFORT_REC="$(grep -m1 -E '^> \*\*Effort-record:\*\* ' "$DOC" 2>/dev/null | sed -E 's/^> \*\*Effort-record:\*\* //; s/[[:space:]]+$//')" || EFFORT_REC=""
if [ -n "$EFFORT_REC" ]; then
    EFFORT_WHY=""
    EFFORT_JSON=""
    if [ ! -r "$EFFORT_REC" ]; then
        EFFORT_WHY="record not readable: $EFFORT_REC"
    elif ! EFFORT_JSON="$(node "$HERE/../../lanes/effort-route.mjs" "$EFFORT_REC" 2>&1)"; then
        EFFORT_WHY="effort-route failed: $(printf '%s' "$EFFORT_JSON" | head -n 1)"
    else
        EFFORT_LINE="$(printf '%s' "$EFFORT_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).advisory||"")}catch(e){}})' 2>/dev/null)" || EFFORT_LINE=""
        if [ -n "$EFFORT_LINE" ]; then
            echo "headed-arm-worker: advisory: recommended $EFFORT_LINE; launching WORKER_SESSION_EFFORT=${WORKER_SESSION_EFFORT:-<unset>}" >&2
        else
            EFFORT_WHY="effort-route output not parseable"
        fi
    fi
    [ -z "$EFFORT_WHY" ] || echo "headed-arm-worker: advisory: unavailable ($EFFORT_WHY)" >&2
fi

# WORKER_SESSION_REPO folds onto headed-arm.sh's own HEADED_ARM_REPO override seam -
# the one thing the two prior kit-local copies differed on.
if [ -n "${WORKER_SESSION_REPO:-}" ]; then
    HEADED_ARM_REPO="$WORKER_SESSION_REPO"
    export HEADED_ARM_REPO
fi

# WORKER_SESSION_SUPPRESS_CR_TRIGGER: opt-out-by-chief seam for the
# CodeRabbit auto-trigger hooks (trigger-cr-on-pr-create.sh,
# trigger-cr-on-push.sh - both route their post through
# cr_trigger_post_review in scripts/lib/coderabbit-trigger-ledger.sh, so this ONE
# knob covers both; see that function for why). Set in the LAUNCHING shell
# (e.g. `WORKER_SESSION_SUPPRESS_CR_TRIGGER=1 bash headed-arm-worker.sh ...`), same
# pattern as WORKER_SESSION_REPO above, and folded here into CR_TRIGGER_SUPPRESS, the
# name the hooks/ledger actually read - never a flag, since this is a
# per-launch chief decision, not part of the worker's identity. Opt-out
# ONLY: leaving it unset changes nothing, which is the ticket's explicit
# requirement (the auto-trigger hook exists because manual triggering was
# left to discretion once already and every open PR went unreviewed)
# so a default-off seam here would recreate that exact failure.
if [ -n "${WORKER_SESSION_SUPPRESS_CR_TRIGGER:-}" ]; then
    worker_propagate_env CR_TRIGGER_SUPPRESS 1
fi

# WORKER_SESSION_API_LANE=on: opt-in seam, set in the LAUNCHING shell, that
# carries the API-lane switch into the worker so the PR critic bills API credit
# (claude-api.sh refuses rc 5 without HIMMEL_API_LANE=on). Account is "auto";
# the credit guard and per-call routing stay in claude-api.sh. Default OFF:
# unset or any other value changes nothing.
if [ "${WORKER_SESSION_API_LANE:-}" = "on" ]; then
    worker_propagate_env HIMMEL_API_LANE on
    worker_propagate_env HIMMEL_API_ACCOUNT auto
fi

# IMPL_GUARD_OK=1 / INLINE_IMPL_OK=1: worker-only env for
# guard-implementor-dispatch / orchestrator-inline-guard.
# headed-arm.sh's shared chief/worker child-env block does not set these.
# Export into THIS process so both survive konsole's `-e env -u ...`, which
# only unsets the three vars and otherwise inherits as-is.
# --judge: a judge does not implement, so neither permission is
# exported for it. The --dry-run report below reads both via ${VAR:-<unset>}
# rather than a bare $VAR, since a judge launch never sets them at all and
# this script runs under `set -u`.
if [ "$READONLY_ROLE" -ne 1 ]; then
    worker_propagate_env IMPL_GUARD_OK 1
    worker_propagate_env INLINE_IMPL_OK 1
fi
# HIMMEL_CONSOLE_LEG=1: marks the launched process as a
# chief-spawned worker, both lanes - including --judge (design §3.2, "the
# judge is a worker": this IS Guard E for a judge too). merge-on-green.sh then
# merges only on the chief's GO file (chief-kit/go.sh), and go.sh refuses
# to run under it.
worker_propagate_env HIMMEL_CONSOLE_LEG 1
# HIMMEL_CONSOLE_JUDGE=1: guard-judge-writes.sh denies a judge
# every push, PR, Jira, inbox and out-of-scope file write.
[ "$JUDGE" -eq 1 ] && worker_propagate_env HIMMEL_CONSOLE_JUDGE 1
# bind that guard to THIS judge - the doc and qid resolved above.
# A value the launcher could not derive stays unexported and the guard then
# allows nothing under the handover root (fail closed).
if [ "$JUDGE" -eq 1 ]; then
    case "$_judge_doc" in /*) worker_propagate_env HIMMEL_CONSOLE_JUDGE_DOC "$_judge_doc" ;; esac
    [ -n "$_judge_qid" ] && worker_propagate_env HIMMEL_CONSOLE_JUDGE_QID "$_judge_qid"
fi
# HIMMEL_RELEASE_MANAGER=1 turns on guard-rm-writes.sh's mode 2, bound to this
# doc and release. An underivable doc stays unexported, so the guard then
# allows no file write at all (fail closed).
if [ "$RM" -eq 1 ]; then
    worker_propagate_env HIMMEL_RELEASE_MANAGER 1
    case "$_rm_doc" in /*) worker_propagate_env HIMMEL_RM_DOC "$_rm_doc" ;; esac
    worker_propagate_env HIMMEL_RM_RELEASE "$RM_RELEASE"
fi
# HIMMEL_CONSOLE_NAME: the owning chief's session name, so a
# worker's merge-block alert (scripts/lib/merge-block-alert.sh,
# untouched by this ticket - it already reads this var) can route to the
# chief's own inbox instead of DMing the operator. Resolved from the first
# of three sources that yields a name - never guessed from the process tree:
#   1. --chief <name> (already charset-refused above if malformed)
#   2. the launching shell's own HIMMEL_CONSOLE_NAME
#   3. THIS process's own Claude session name (current_session_name(),
#      scripts/lib/session-name.sh) - set when this launcher call is itself
#      running inside a named chief session
# Sources 2 and 3 are re-checked against the same charset --chief was
# refused on above (it lands in the same inbox-lookup path), but a failure
# there does not abort the launch the way a bad --chief flag does: this
# seam is best-effort alert routing, not load-bearing for the worker, and
# The alert's own no-name fallback (operator DM) already covers "no usable
# name" cleanly. A candidate failing the charset check is therefore treated
# exactly like an empty source - try the next one, or export nothing.
_chief_name_ok() {
    case "$1" in
        ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}
# a caller-preset HIMMEL_CONSOLE_NAME= launcher token would win
# worker_propagate_env's name clash and reach the worker unvalidated, so drop it -
# only the name resolved below (or none) may propagate.
worker_env_drop_token HIMMEL_CONSOLE_NAME
if [ -n "$CHIEF_FLAG" ]; then
    CHIEF_NAME="$CHIEF_FLAG"
elif _chief_name_ok "${HIMMEL_CONSOLE_NAME:-}"; then
    CHIEF_NAME="$HIMMEL_CONSOLE_NAME"
else
    CHIEF_NAME=""
    # shellcheck source=../../lib/session-name.sh
    # shellcheck disable=SC1091
    if . "$HERE/../../lib/session-name.sh" 2>/dev/null; then
        _detected_chief_name="$(current_session_name 2>/dev/null)" || _detected_chief_name=""
        _chief_name_ok "$_detected_chief_name" && CHIEF_NAME="$_detected_chief_name"
        unset -v _detected_chief_name
    fi
fi
if [ -n "$CHIEF_NAME" ]; then
    # worker_propagate_env, not a bare export - on macOS `open -a`
    # starts a fresh environment, so a bare export never crosses and #1121's
    # chief-alert routing would silently stop reaching the worker.
    # _chief_name_ok already refuses whitespace, so worker_propagate_env's
    # Darwin exit 12 branch is unreachable for this variable.
    worker_propagate_env HIMMEL_CONSOLE_NAME "$CHIEF_NAME"
else
    unset HIMMEL_CONSOLE_NAME
fi
# the bus registration below names this chief as the worker's own.
BUS_CHIEF="$CHIEF_NAME"
# the bus identity is the launcher's alone. A caller-preset or
# ambient HIMMEL_BUS_* (a chief's own HIMMEL_BUS_NAME is live in its shell)
# must never reach a worker - only the name registered below does - and neither
# may a preset bind flag, which headed-arm.sh reads as "bind this session".
for _worker_bus_var in $(compgen -v HIMMEL_BUS_); do
    unset -v "$_worker_bus_var"
done
unset -v _worker_bus_var HEADED_ARM_BUS
worker_env_drop_prefix HIMMEL_BUS_
worker_env_drop_token HEADED_ARM_BUS
unset -v CHIEF_NAME
unset -f _chief_name_ok
# guard-worker-context-handoff.sh reads both from its own process env,
# which is fixed at launch, so a worker cannot flip them mid-session: the resolved
# --autocompact ceiling its threshold derives from, and the context mode
# (compact or handoff; none, the default, leaves the guard off and
# sets no mode at all). A caller-preset launcher token is dropped first, so only
# the values resolved here reach the worker.
case "$CONTEXT_GUARD" in
    ''|none) CONTEXT_GUARD="" ;;
    compact|handoff) ;;
    *)
        echo "headed-arm-worker: --context-guard / HIMMEL_WORKER_SESSION_CONTEXT_MODE must be compact or handoff, or none for off (got ${CONTEXT_GUARD})" >&2
        exit 2
        ;;
esac
worker_env_drop_token HIMMEL_WORKER_SESSION_CONTEXT_MODE
if [ -n "$CONTEXT_GUARD" ]; then
    worker_propagate_env HIMMEL_WORKER_SESSION_CONTEXT_MODE "$CONTEXT_GUARD"
else
    unset -v HIMMEL_WORKER_SESSION_CONTEXT_MODE
fi
unset -v CONTEXT_GUARD
worker_env_drop_token HIMMEL_WORKER_SESSION_AUTOCOMPACT
worker_propagate_env HIMMEL_WORKER_SESSION_AUTOCOMPACT "$RESOLVED_AUTOCOMPACT"
# HIMMEL_READ_CLAMP_LINES: raises read-clamp.sh's
# whole-file limit for a judge - independent reading is the job. 4000 is a
# judgment call (no source document names a number): ~10x the worker default of
# 400, generous for a design-sized doc without reopening the clamp entirely,
# which stays HIMMEL_READ_CLAMP_OK's own, operator-only lever. The repeat-read
# half of the clamp (read-clamp.sh's per-range dedup) is untouched.
[ "$READONLY_ROLE" -eq 1 ] && worker_propagate_env HIMMEL_READ_CLAMP_LINES 4000
# HIMMEL_CONSOLE_RELAY=1: marks this worker as the Sonnet relay half
# of a split chief. inbox-send.sh's Guard C already refuses --token under it
# (#733); the Task 26 write-deny hook denies writes under it. Both key off
# this exact marker, not the chief-relay profile above.
[ "$RELAY" -eq 1 ] && worker_propagate_env HIMMEL_CONSOLE_RELAY 1
# headed-arm.sh builds one argv array for both native and recorder launches and
# refuses exit 2 if this exact pair is absent. This is the final resolved-argv
# guard; the context-value check above gives the earlier operator-facing error.
# the required value tracks RESOLVED_AUTOCOMPACT, not a hardcoded
# 200000 - a sanctioned Context-line opt-in resolves it to `auto` above, and
# this guard must then require THAT value, not the standard ceiling.
export HEADED_ARM_REQUIRED_AUTOCOMPACT="$RESOLVED_AUTOCOMPACT"

# Native-lane effort: lanes.json's claude-tier
# effort is wired into the native Telegram dispatch (scripts/telegram/run.ts's
# laneEffort()/spawnSpec, CLAUDE_CODE_EFFORT_LEVEL). This mirrors the same
# match rule - exact model id, or the model prefixed "claude-<tier-id>-" - for
# a chief-launched native worker, which otherwise runs at ambient effort
# instead of the registry's declared value. Mirrored rather than imported:
# run.ts is TS/bun-only and off the worker's Do-not list to edit; jq is already
# a direct dependency of this file (the --profile settings merge below).
# Precedence: an explicit CLAUDE_CODE_EFFORT_LEVEL, then a valid WORKER_SESSION_EFFORT,
# then the registry row; the winner and its source print as one stderr line.
# An explicit CLAUDE_CODE_EFFORT_LEVEL from the LAUNCHING shell always wins
# over the registry - checked here, before the lookup, because
# worker_propagate_env's own `export` would otherwise silently overwrite it with
# the registry's value. It still needs the SAME worker_propagate_env call as the
# registry path (re-propagating a value already in the environment is a
# no-op), so it reaches HEADED_ARM_LAUNCHER_ENV's token list and shows up in
# the dry-run report the same way a registry-resolved value does.
if [ "$LANE" = "native" ]; then
    EFFORT_SOURCE=""
    # headed-arm.sh defaults an omitted model to this; the registry lookup must
    # match the model the worker launches.
    MODEL="${MODEL:-claude-opus-5-5}"
    # A caller-preset launcher token wins over worker_propagate_env, so the print
    # below reports it; read before the resolver appends its own token.
    # A presence flag, not -n: an empty preset is still the token the worker gets.
    PRESET_EFFORT=""
    PRESET_EFFORT_SET=0
    set -f
    for _effort_tok in ${HEADED_ARM_LAUNCHER_ENV:-}; do
        case "$_effort_tok" in
            CLAUDE_CODE_EFFORT_LEVEL=*) PRESET_EFFORT="${_effort_tok#*=}"; PRESET_EFFORT_SET=1 ;;
        esac
    done
    set +f
    if [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ]; then
        EFFORT_SOURCE="CLAUDE_CODE_EFFORT_LEVEL"
        worker_propagate_env CLAUDE_CODE_EFFORT_LEVEL "$CLAUDE_CODE_EFFORT_LEVEL"
    else
        case "${WORKER_SESSION_EFFORT:-}" in
            low | medium | high | xhigh | max)
                EFFORT_SOURCE="WORKER_SESSION_EFFORT"
                worker_propagate_env CLAUDE_CODE_EFFORT_LEVEL "$WORKER_SESSION_EFFORT"
                ;;
        esac
    fi
    if [ -z "$EFFORT_SOURCE" ]; then
        LANES_JSON="${HEADED_ARM_WORKER_LANES_JSON:-$HERE/../../lanes/lanes.json}"
        if [ -f "$LANES_JSON" ]; then
            NATIVE_EFFORT="$(jq -r --arg model "$MODEL" '
                [ .lanes[]? | select(.class == "claude-tier") | . as $lane
                  | select($lane.id == $model or ($model | startswith("claude-" + $lane.id + "-")))
                  | $lane.effort ] | first // empty
            ' "$LANES_JSON" 2>/dev/null)"
            case "$NATIVE_EFFORT" in
                low | medium | high | xhigh | max)
                    EFFORT_SOURCE="lanes.json"
                    worker_propagate_env CLAUDE_CODE_EFFORT_LEVEL "$NATIVE_EFFORT"
                    ;;
            esac
        fi
    fi
    if [ "$PRESET_EFFORT_SET" -eq 1 ]; then
        EFFORT_SOURCE="HEADED_ARM_LAUNCHER_ENV"
        EFFORT_SHOWN="$PRESET_EFFORT"
    else
        EFFORT_SHOWN="${CLAUDE_CODE_EFFORT_LEVEL:-}"
    fi
    [ -z "$EFFORT_SOURCE" ] || echo "headed-arm-worker: effort=$EFFORT_SHOWN source=$EFFORT_SOURCE" >&2
    # Asked equals effective: a valid WORKER_SESSION_EFFORT is what the worker must run at
    # unless an explicit CLAUDE_CODE_EFFORT_LEVEL or launcher token names the
    # override (the line above prints that source). Effective is read back from
    # the final token list, last token wins, as `env` applies it.
    EFFORT_ASKED=""
    case "${WORKER_SESSION_EFFORT:-}" in
        low | medium | high | xhigh | max) EFFORT_ASKED="$WORKER_SESSION_EFFORT" ;;
    esac
    EFFORT_EFFECTIVE="${CLAUDE_CODE_EFFORT_LEVEL:-}"
    set -f
    for _effort_tok in ${HEADED_ARM_LAUNCHER_ENV:-}; do
        case "$_effort_tok" in
            CLAUDE_CODE_EFFORT_LEVEL=*) EFFORT_EFFECTIVE="${_effort_tok#*=}" ;;
        esac
    done
    set +f
    if [ -n "$EFFORT_ASKED" ] && [ "$EFFORT_SOURCE" != "CLAUDE_CODE_EFFORT_LEVEL" ] && [ "$EFFORT_SOURCE" != "HEADED_ARM_LAUNCHER_ENV" ] && [ "$EFFORT_EFFECTIVE" != "$EFFORT_ASKED" ]; then
        echo "headed-arm-worker: refusing launch: asked effort=$EFFORT_ASKED (WORKER_SESSION_EFFORT) but the worker would run effort=$EFFORT_EFFECTIVE (source=${EFFORT_SOURCE:-none}); set CLAUDE_CODE_EFFORT_LEVEL explicitly if that is intended" >&2
        exit 2
    fi
fi

# Propagate the resolved registry values, including DeepSeek's existing
# openrouter bank gate, rather than inheriting the chief's lane.
# Native launches keep their environment unchanged.
if [ "$LANE" != "native" ]; then
    worker_env_drop_token WORKER_SESSION_LANE
    worker_env_drop_token CADENCE_USAGE_LANE
    worker_propagate_env WORKER_SESSION_LANE "$LANE"
    worker_propagate_env CADENCE_USAGE_LANE "$LANE_BANK_GATE"
fi

# claudex lane: see the --lane header comment above.
if [ "$LANE" = "claudex" ]; then
    LANE_BIN="${LANE_BIN_OVERRIDE:-$HERE/../../$LANE_BIN_NAME}"
    export HEADED_ARM_LAUNCHER="$LANE_BIN"
    worker_propagate_env CLAUDEX_LANE_OK 1
    worker_propagate_env CLAUDE_CODE_EFFORT_LEVEL "${CLAUDE_CODE_EFFORT_LEVEL:-${WORKER_SESSION_EFFORT:-xhigh}}"
    export HEADED_ARM_RECORDER=1
    [ -z "$MODEL" ] && MODEL="gpt-6.1-sol"
    # scripts/claude-codex reads only CODEX_MODEL; without this the positional
    # MODEL names a model the worker never runs.
    worker_propagate_env CODEX_MODEL "$MODEL"
fi

# OpenRouter: only the independently verified 1M tier slugs
# are admitted. Unknown ids fail closed; the metered backend gates credit
# before inference. Dry runs never query a remote API.
if [ "$LANE" = "openrouter" ]; then
    OR_MODEL="${MODEL:-anthropic/claude-sonnet-5.5}"
    OR_MODEL="${OR_MODEL%\[1m\]}"
    case "$OR_MODEL" in
        claude-sonnet-5-5) OR_MODEL=anthropic/claude-sonnet-5.5 ;;
        claude-opus-5-5) OR_MODEL=anthropic/claude-opus-5.5 ;;
        claude-fable-5-1) OR_MODEL=anthropic/claude-fable-5.1 ;;
    esac
    case "$OR_MODEL" in
        anthropic/claude-sonnet-5.5) MODEL=sonnet ;;
        anthropic/claude-opus-5.5) MODEL=opus ;;
        anthropic/claude-fable-5.1) MODEL="$OR_MODEL" ;;
        *) echo "headed-arm-worker: unsupported OpenRouter model: $OR_MODEL (no verified 1M slug; Haiku is not a worker tier)" >&2; exit 2 ;;
    esac
    LANE_BIN="${LANE_BIN_OVERRIDE:-$HERE/../../$LANE_BIN_NAME}"
    export HEADED_ARM_LAUNCHER="$LANE_BIN"
    worker_env_drop_token OPENROUTER_MODEL
    worker_propagate_env OPENROUTER_MODEL "$OR_MODEL"
    worker_propagate_env CLAUDE_CODE_EFFORT_LEVEL "${WORKER_SESSION_EFFORT:-medium}"
    export HEADED_ARM_RECORDER=1
fi

# DeepSeek: the launcher owns egress, balance floor, model pins
# and effort, so this block only routes to it. The default model is read from
# the launcher's own `export ANTHROPIC_MODEL=` line, never invented here; a
# launcher without one fails closed.
if [ "$LANE" = "deepseek" ]; then
    LANE_BIN="${LANE_BIN_OVERRIDE:-$HERE/../../$LANE_BIN_NAME}"
    export HEADED_ARM_LAUNCHER="$LANE_BIN"
    if [ -z "$MODEL" ]; then
        # single-quoted, double-quoted or bare; the quotes are stripped
        MODEL="$(sed -n -e 's/^export ANTHROPIC_MODEL=\(.*\)$/\1/p' "$LANE_BIN" 2>/dev/null | head -n 1 | sed -e "s/^'\\(.*\\)'\$/\\1/" -e 's/^"\(.*\)"$/\1/')"
        if [ -z "$MODEL" ]; then
            echo "headed-arm-worker: --lane deepseek: no default model (no ANTHROPIC_MODEL export in $LANE_BIN); pass a model" >&2
            exit 2
        fi
    fi
    export HEADED_ARM_RECORDER=1
fi

# --profile: resolve the plugin profile and point headed-arm.sh's
# launcher seam at the shim that will apply it. Resolution happens even under
# --dry-run (so a typo'd profile name fails the same way either way); only the
# settings FILE is withheld until we know we are really launching.
if [ -n "$PROFILE" ]; then
    PROFILES_MJS="${HEADED_ARM_WORKER_PROFILES:-$HERE/../../lanes/plugin-profiles.mjs}"
    WORKER_SESSION_SHIM="${HEADED_ARM_WORKER_SHIM:-$HERE/../../lanes/worker-claude-launcher.sh}"
    # A consult is confined only by the shim mapping
    # WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 to `--setting-sources ""`, so a shim
    # override pointing anywhere else would load the scopes unconfined: refuse it.
    # What is exported as the launcher is the CANONICAL path, not
    # the caller's spelling, which a symlinked directory could retarget after this.
    if [ "$CONSULT" -eq 1 ]; then
        _consult_shim="$(cd -P "$(dirname "$WORKER_SESSION_SHIM")" 2>/dev/null && pwd -P)/$(basename "$WORKER_SESSION_SHIM")"
        _consult_shim_want="$(cd -P "$HERE/../../lanes" && pwd -P)/worker-claude-launcher.sh"
        if [ "$_consult_shim" != "$_consult_shim_want" ]; then
            echo "headed-arm-worker: --consult refuses HEADED_ARM_WORKER_SHIM=${HEADED_ARM_WORKER_SHIM:-}: only $_consult_shim_want applies the consult's --setting-sources confinement" >&2
            exit 2
        fi
        WORKER_SESSION_SHIM="$_consult_shim"
        unset -v _consult_shim _consult_shim_want
    fi
    # --judge: the worker preface tells a read-only judge to
    # implement and ship, which is wrong for the role. HEADED_ARM_WORKER_PREFACE
    # stays the higher-precedence test seam either branch honors - only the
    # DEFAULT changes.
    if [ "$JUDGE" -eq 1 ]; then
        WORKER_SESSION_PREFACE="${HEADED_ARM_WORKER_PREFACE:-$HERE/../../../docs/handover/judge-preface.md}"
    elif [ "$CONSULT" -eq 1 ]; then
        WORKER_SESSION_PREFACE="${HEADED_ARM_WORKER_PREFACE:-$HERE/../../../docs/handover/consult-preface.md}"
    elif [ "$RM" -eq 1 ]; then
        WORKER_SESSION_PREFACE="${HEADED_ARM_WORKER_PREFACE:-$HERE/../../../docs/handover/rm-preface.md}"
    else
        WORKER_SESSION_PREFACE="${HEADED_ARM_WORKER_PREFACE:-$HERE/../../../docs/handover/worker-preface.md}"
    fi
    # Next to the launch log, i.e. inside the per-uid chief work dir the
    # chief already owns and cleans - never /tmp world-readable, never the
    # repo (it is generated, per-worker state).
    # Native lane only: the brief's own contract, re-injected by
    # the compact-matcher SessionStart hook below instead of ridden in the
    # preface on every call. Resolved to an absolute path:
    # the hook command re-parses this path in the worker's OWN process
    # at fire time, whose cwd need not match this launcher's cwd, so a
    # relative path would silently miss.
    _worker_log_dir="$(cd "$(dirname "$LOG")" && pwd)" || {
        echo "headed-arm-worker: --profile $PROFILE: cannot resolve log directory for $LOG" >&2
        exit 2
    }
    PROFILE_SETTINGS="$_worker_log_dir/$NAME.leg-settings.json"
    PROFILE_CONTRACT="$_worker_log_dir/$NAME.worker-contract.md"
    for _worker_need in "$PROFILES_MJS" "$WORKER_SESSION_SHIM" "$WORKER_SESSION_PREFACE"; do
        if [ ! -f "$_worker_need" ]; then
            echo "headed-arm-worker: --profile $PROFILE: required file missing: $_worker_need" >&2
            exit 2
        fi
    done
    # cwd matters: the resolver reads the machine's LIVE enabled-plugin set
    # from every settings layer under it, and disables anything outside the
    # catalog (deny-by-default beyond CATALOG). Resolve from the worker's repo.
    _worker_resolve_cwd="${HEADED_ARM_REPO:-$HERE/../../..}"
    [ -d "$_worker_resolve_cwd" ] || _worker_resolve_cwd="$HERE"
    if ! PROFILE_JSON="$(cd "$_worker_resolve_cwd" && node "$PROFILES_MJS" "$PROFILE" 2>&1)"; then
        echo "headed-arm-worker: --profile $PROFILE: resolver failed: $PROFILE_JSON" >&2
        exit 2
    fi
    if [ -z "$PROFILE_JSON" ]; then
        echo "headed-arm-worker: --profile $PROFILE: resolver produced no settings JSON" >&2
        exit 2
    fi
    # A worker works in its worktree by cd, never by EnterWorktree:
    # a pinned session's worktree-isolation screen refuses /pr-check step 0's
    # canonical fence (it runs the HIMMEL_REPO anchor's script, outside the
    # pin), so a worker whose diff touches scripts/cr/ could not review itself
    # without a human. A tool-name deny removes the tool from the worker's list.
    # The relay never works in a worktree and keeps its settings as they are.
    if [ "$RELAY" -eq 0 ]; then
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq '.permissions.deny = ((.permissions.deny // []) + ["EnterWorktree"])')"; then
            echo "headed-arm-worker: --profile $PROFILE: cannot add the EnterWorktree deny to settings JSON" >&2
            exit 2
        fi
    fi
    # HANDOVER_DIR reaches this wrapper as a plain exported string, which may
    # carry a trailing slash a caller happened to set. Normalize it once
    # through `cd -P && pwd -P` (the kit's own canonicaliser, matching
    # handover-path.sh's physical resolution) so both the root-equality
    # check below and the .locks deny pattern compare against the SAME
    # canonical form _worker_doc_dir (also `cd -P && pwd -P`-derived) uses - a
    # raw trailing-slash HANDOVER_DIR would otherwise silently bypass both
    # and a symlink component would otherwise let a
    # doc dir reached through it evade the comparison.
    _worker_handover_dir_norm=""
    if [ -n "${HANDOVER_DIR:-}" ]; then
        _worker_handover_dir_norm="$(cd -P "$HANDOVER_DIR" 2>/dev/null && pwd -P)"
        if [ -z "$_worker_handover_dir_norm" ]; then
            echo "headed-arm-worker: --profile $PROFILE: HANDOVER_DIR='$HANDOVER_DIR' is not a directory" >&2
            exit 2
        fi
    fi
    # A worker writes its Results bullets to its own handover doc,
    # which sits outside the worker's working directories whenever the resolved
    # handover root is external (Mode B) or the doc's own root otherwise -
    # the auto-mode classifier inconsistently refuses those writes as
    # Out-of-Place Publication. Grant only the DOC's own directory, never the
    # whole handover root: chief-kit/go.sh's merge GO is authenticated only
    # by the EXISTENCE of <handover_root>/.locks/go/<pr>.<sha> (go-gate.sh,
    # merge-on-green.sh), with no hook guarding that path today - widening a
    # worker's grant to the root would auto-approve its own Write there, letting
    # a worker mint its own merge GO. The doc's directory is a strict subdir of
    # the worker's own bucket (handovers/<user>/<repo>/...), which never
    # contains .locks/ (that sits at the handover ROOT) - verified below
    # rather than assumed, so a doc placed directly AT the root can never
    # collapse this grant back to the whole root.
    # A doc directory that EQUALS the handover root, or is an ANCESTOR of it
    # must never be granted:
    # additionalDirectories would then cover the whole root - and its
    # .locks/ - the exact privilege this grant exists to avoid. Rather than
    # refusing the launch outright (round-3 behaviour for the equal case),
    # skip the grant and fall back to today's classifier behaviour for this
    # worker's own doc writes; the launch still succeeds. Compared as canonical
    # absolute paths (both `cd -P && pwd -P`-derived, so a symlinked doc
    # directory resolves physically too) so a lookalike prefix like /a/bc
    # is never mistaken for an ancestor of /a/b.
    # When HANDOVER_DIR could not be resolved at all, _worker_handover_dir_norm
    # is empty and the root/ancestor comparison below cannot run - an
    # unknown root can never be proven safe, so treat that the same as a
    # confirmed root/ancestor match rather than falling through to an
    # ungated grant.
    _worker_doc_path=""
    if [ -n "$DOC" ] && _worker_doc_dir="$(cd -P "$(dirname "$DOC")" 2>/dev/null && pwd -P)"; then
        _worker_doc_path="$_worker_doc_dir/$(basename "$DOC")"
        _worker_doc_is_root_or_ancestor=0
        if [ -z "$_worker_handover_dir_norm" ]; then
            _worker_doc_is_root_or_ancestor=1
        elif [ "$_worker_doc_dir" = "$_worker_handover_dir_norm" ]; then
            _worker_doc_is_root_or_ancestor=1
        else
            case "$_worker_handover_dir_norm" in
                "$_worker_doc_dir"/*)
                    _worker_doc_is_root_or_ancestor=1
                    ;;
            esac
        fi
        if [ "$_worker_doc_is_root_or_ancestor" -eq 1 ]; then
            echo "headed-arm-worker: --profile $PROFILE: worker doc directory ($_worker_doc_dir) is the handover root or an ancestor of it, or HANDOVER_DIR could not be resolved (HANDOVER_DIR='${HANDOVER_DIR:-}') - skipping additionalDirectories grant for it" >&2
        elif [ "$CONSULT" -eq 1 ]; then
            # additionalDirectories become sandbox write roots: a consult's write set is its doc FILE only.
            :
        elif ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg dir "$_worker_doc_dir" \
            '.permissions.additionalDirectories = ((.permissions.additionalDirectories // []) + [$dir])')"; then
            echo "headed-arm-worker: --profile $PROFILE: cannot add the worker doc's directory to additionalDirectories" >&2
            exit 2
        fi
    fi
    unset -v _worker_doc_is_root_or_ancestor
    # Belt and braces: even scoped to the doc's own directory, deny Edit on
    # the handover root's .locks/** outright. Only Edit is emitted: Claude
    # Code applies an Edit(path) rule to every file-editing tool now, and
    # warns on every worker exit that Write/MultiEdit/NotebookEdit rules on the
    # same path are dead code - so seeding them protects
    # nothing. Deny wins over additionalDirectories, so this holds even if a
    # future change widens the grant back toward the root. Gated the same as
    # the EnterWorktree deny above: the relay never works in a worktree and
    # keeps its settings as they are. Both path rules here are spelled //abs:
    # Claude Code reads a single leading slash as project-relative, so /abs
    # would never match.
    if [ "$RELAY" -eq 0 ] && [ -n "$_worker_handover_dir_norm" ]; then
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg dir "$_worker_handover_dir_norm" \
            '.permissions.deny = ((.permissions.deny // []) + (["Edit"] | map(. + "(/" + $dir + "/.locks/**)")))')"; then
            echo "headed-arm-worker: --profile $PROFILE: cannot add the .locks deny to settings JSON" >&2
            exit 2
        fi
    fi
    # additionalDirectories above only widens the DIRECTORY
    # boundary check - it grants no permission `allow` rule, so the auto-mode
    # classifier could still deny the worker's own Edit of its handover doc
    # (N577, N582, N564 each parked on exactly this). Grant Edit on this
    # worker's OWN doc file only - an exact path, never a root-wide `**/*.md`
    # glob: a glob would let a worker edit a SIBLING worker's or a JUDGE's doc
    # (its Results, its RETASK block) under the same handover bucket (the
    # go-gate lock-file rationale above answers a
    # different question and does not cover cross-doc tampering). An exact
    # path carries no such risk regardless of where the doc sits relative to
    # the handover root, so this grant does not need the root/ancestor guard
    # the additionalDirectories widening above needs. Only Edit is emitted -
    # Claude Code now applies an Edit(path) rule to every file-editing tool
    # so a sibling Write/MultiEdit/NotebookEdit rule on
    # the same pattern is dead code. Gated the same as the .locks deny
    # (never the relay), plus JUDGE: a judge does not implement (design 3.2,
    # Guard E above) and never needs to write a WORKER's handover doc, so it
    # must not gain this grant even though it resolves its own DOC too.
    if [ "$RELAY" -eq 0 ] && [ "$READONLY_ROLE" -eq 0 ] && [ -n "$_worker_doc_path" ]; then
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg doc "$_worker_doc_path" \
            '.permissions.allow = ((.permissions.allow // []) + ["Edit(/" + $doc + ")"])')"; then
            echo "headed-arm-worker: --profile $PROFILE: cannot add the handover-doc Edit allow to settings JSON" >&2
            exit 2
        fi
    fi
    # --consult read-only envelope. The file-edit tools are denied
    # by BARE name, so no path-scoped allow can re-open them (deny wins), and the
    # session carries NO Edit allow at all. Its answer goes through exactly one
    # Bash allow: append-results.sh on its own consult doc. The allow list is
    # REPLACED, not appended to: a gateAllow profile (lane-impl, lane-content...)
    # would otherwise hand the consult its ship-step allows (merge-on-green etc.).
    # The Bash sandbox is ADDED to the classifier, not swapped for it:
    # autoAllowBashIfSandboxed stays false, so every Bash call is still classifier-gated.
    # Writes: the one doc FILE (append-results.sh only appends with >>, so a file bind
    # is enough) plus Claude Code's own temp dirs; the doc's parent dir (the shared
    # handover bucket) is never granted, and the additionalDirectories grant above is
    # skipped under --consult because Claude Code turns those into sandbox write roots.
    # The repo is denied. Outer settings scopes would MERGE their write roots into the
    # consult's,
    # so the consult loads none of the user/project/local scopes and the
    # managed ones that still load are refused when they widen it. A doc inside the repo is
    # always denied, so it is refused too.
    # ponytail: Bash sandboxed to the doc file plus Claude Code's temp dirs, reads open (no denyRead) and the symlink check is launch-time, upgrade to denyRead once the smoke test proves plugin reads survive (HIMMEL-4066 follow-ups)
    # ponytail: user/project/local scopes are not loaded, so only their hooks, deny/ask rules and env are carried (their allow rules, statusLine, plugin marketplaces and other keys are not), upgrade path a follow-up ticket when a consult needs another carried key
    if [ "$CONSULT" -eq 1 ]; then
        case "$_worker_doc_path/" in
            "$CONSULT_REPO_CANON"/*)
                echo "headed-arm-worker: --consult: the consult doc ($_worker_doc_path) is inside the repo ($CONSULT_REPO_CANON), which the sandbox always write-denies: put the doc under the handover root" >&2
                exit 2
                ;;
        esac
        # The consult launches with `--setting-sources ""` (the shim maps
        # WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 to it), so Claude Code loads NO user, project or
        # local scope: none of their additionalDirectories, Edit allows or sandbox keys can
        # become a sandbox write root. Proven live by smoke-consult-sandbox.sh. Those scopes'
        # hooks, deny/ask rules and env are CARRIED into the consult's own settings instead,
        # and nothing else of them is (env keys named CLAUDE_* are dropped: they configure
        # Claude Code itself). The scopes that still load under --setting-sources and outrank
        # --settings - managed-settings.json, every managed-settings.d/*.json drop-in and the
        # cached server policy remote-settings.json - are scanned and refused below.
        # Carried: user (home, then CLAUDE_CONFIG_DIR's: carrying both only adds guards), then project, then local
        # settings at the cwd repo, its git toplevel and the main checkout. A carried file jq
        # cannot read refuses: its guard hooks cannot be carried. CONSULT_SETTINGS_HOME /
        # CONSULT_MANAGED_SETTINGS are test seams that are honoured in production too.
        _cs_home="${CONSULT_SETTINGS_HOME:-$HOME}"
        _CS_SAFE_SANDBOX='["sandbox.enabled","sandbox.failIfUnavailable"]'
        case "$(uname -s)" in
            Darwin) _cs_managed="${CONSULT_MANAGED_SETTINGS:-/Library/Application Support/ClaudeCode/managed-settings.json}" ;;
            *) _cs_managed="${CONSULT_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}" ;;
        esac
        _cs_roots="$CONSULT_REPO_CANON"
        # shellcheck source=scripts/lib/git-clean.sh
        . "$HERE/../../lib/git-clean.sh"
        git_env_scrub
        _cs_top="$(git -C "$CONSULT_REPO_CANON" rev-parse --show-toplevel 2>/dev/null)" || _cs_top=""
        _cs_gc="$(git -C "$CONSULT_REPO_CANON" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || _cs_gc=""
        [ -n "$_cs_top" ] && _cs_roots="$_cs_roots
$_cs_top"
        [ -n "$_cs_gc" ] && _cs_roots="$_cs_roots
$(dirname "$_cs_gc")"
        _cs_files="$_cs_managed
$_cs_home/.claude/remote-settings.json
${CLAUDE_CONFIG_DIR:-/nonexistent}/remote-settings.json"
        for _cs_d in "$(dirname "$_cs_managed")"/managed-settings.d/*.json; do
            _cs_files="$_cs_files
$_cs_d"
        done
        _cs_user="$_cs_home/.claude/settings.json"
        [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$_cs_home/.claude" ] && _cs_user="$_cs_user
$CLAUDE_CONFIG_DIR/settings.json"
        _cs_seen=""; _cs_proj=""; _cs_local=""
        while IFS= read -r _cs_r; do
            [ -n "$_cs_r" ] || continue
            case "
$_cs_seen
" in *"
$_cs_r
"*) continue ;; esac
            _cs_seen="$_cs_seen
$_cs_r"
            _cs_proj="$_cs_proj
$_cs_r/.claude/settings.json"
            _cs_local="$_cs_local
$_cs_r/.claude/settings.local.json"
        done <<EOF_CS_ROOTS
$_cs_roots
EOF_CS_ROOTS
        _cs_carry=()
        while IFS= read -r _cs_f; do
            [ -f "$_cs_f" ] || continue
            if ! jq -e 'type == "object"' "$_cs_f" >/dev/null 2>&1; then
                echo "headed-arm-worker: --consult: cannot parse $_cs_f, so its hooks and deny rules cannot be carried into the consult: fix or remove it" >&2
                exit 2
            fi
            _cs_carry+=("$_cs_f")
        done <<EOF_CS_CARRY
$_cs_user$_cs_proj$_cs_local
EOF_CS_CARRY
        # stdin is /dev/null so an empty carry list reads nothing (jq would otherwise wait on stdin).
        if ! _cs_carried="$(jq -n '[inputs] | {
              hooks: (reduce (.[] | (.hooks // {}) | to_entries[]) as $h ({}; .[$h.key] = ((.[$h.key] // []) + $h.value))),
              deny: [.[] | (.permissions.deny // [])[]],
              ask: [.[] | (.permissions.ask // [])[]],
              env: (reduce .[] as $s ({}; . + ($s.env // {})) | with_entries(select(.key | startswith("CLAUDE_") | not)))}' \
              ${_cs_carry[@]+"${_cs_carry[@]}"} </dev/null 2>/dev/null)"; then
            echo "headed-arm-worker: --consult: cannot carry the hooks, deny rules and env of: ${_cs_carry[*]-} (a hooks, permissions or env key of the wrong type): fix it" >&2
            exit 2
        fi
        while IFS= read -r _cs_f; do
            [ -f "$_cs_f" ] || continue
            # ALLOWLIST: refuse (a) any Edit/Write/NotebookEdit permissions.allow rule (merged into
            # the sandbox write roots), (b) non-empty permissions.additionalDirectories, (c) any
            # sandbox.* leaf outside _CS_SAFE_SANDBOX set to true. An unknown sandbox key refuses.
            # Fail closed: an existing scope file jq cannot read (malformed, JSONC, a
            # non-object intermediate) cannot be shown not to widen the sandbox.
            if ! _cs_n="$(jq -r --argjson safe "$_CS_SAFE_SANDBOX" '
                first(
                  ((.permissions.allow // [])[] | select(type == "string" and test("^(Edit|Write|NotebookEdit)(\\(|$)")) | "permissions.allow rule " + .),
                   (if ((.permissions.additionalDirectories // []) | length) > 0 then "permissions.additionalDirectories" else empty end),
                   ((.sandbox // {}) as $sb | $sb | paths(type != "object") as $p
                    | ($p | map(tostring) | join(".")) as $j
                    | select(($safe | index("sandbox." + $j)) == null or ($sb | getpath($p)) != true)
                    | "sandbox." + $j)
                ) // empty' "$_cs_f" 2>/dev/null)"; then
                echo "headed-arm-worker: --consult: cannot parse $_cs_f, so it cannot be shown not to widen the sandbox: fix or remove it" >&2
                exit 2
            fi
            if [ -n "$_cs_n" ]; then
                echo "headed-arm-worker: --consult: managed scope $_cs_f carries $_cs_n, which still loads under --setting-sources, merges into the consult's sandbox and would widen it: remove or scope it" >&2
                exit 2
            fi
            # MANAGED scopes outrank the consult's own --settings, so the pins below cannot beat
            # them: refuse a managed scope that turns on env scrub (its sandbox adds allowWrite
            # /home /tmp /var ...), sets a permissive defaultMode, or carries a policyHelper(s).
            if ! _cs_n="$(jq -r '
                first(
                  ((.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB // empty) | tostring | ascii_downcase
                    | select(. != "" and . != "0" and . != "false") | "env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"),
                  ((.permissions.defaultMode // empty) | select(. == "bypassPermissions" or . == "acceptEdits")
                    | "permissions.defaultMode " + .),
                  ((.. | objects | keys[] | select(. == "policyHelper" or . == "policyHelpers"))
                    | "key " + .)
                ) // empty' "$_cs_f" 2>/dev/null)"; then
                echo "headed-arm-worker: --consult: cannot parse $_cs_f, so it cannot be shown not to widen the sandbox: fix or remove it" >&2
                exit 2
            fi
            if [ -n "$_cs_n" ]; then
                echo "headed-arm-worker: --consult: managed scope $_cs_f carries $_cs_n, which the consult's own settings cannot override and would widen the sandbox or its permissions" >&2
                exit 2
            fi
        done <<EOF_CS_FILES
$_cs_files
EOF_CS_FILES
        # ~/.claude.json top-level env is not a settings scope but is merged into the process env:
        # refuse a truthy env scrub there too (the flag-scope pin should win; belt and braces).
        for _cs_f in "$_cs_home/.claude.json" "${CLAUDE_CONFIG_DIR:-/nonexistent}/.claude.json"; do
            [ -f "$_cs_f" ] || continue
            if ! _cs_n="$(jq -r '(.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB // empty) | tostring | ascii_downcase
                | select(. != "" and . != "0" and . != "false")' "$_cs_f" 2>/dev/null)"; then
                echo "headed-arm-worker: --consult: cannot parse $_cs_f, so it cannot be shown not to turn on env scrub: fix or remove it" >&2
                exit 2
            fi
            if [ -n "$_cs_n" ]; then
                echo "headed-arm-worker: --consult: $_cs_f sets env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB, whose sandbox adds write roots (/home /tmp /var ...): remove it" >&2
                exit 2
            fi
        done
        unset -v _cs_f _CS_SAFE_SANDBOX _cs_n _cs_d _cs_r _cs_roots _cs_top _cs_gc _cs_files _cs_home _cs_managed _cs_user _cs_seen _cs_proj _cs_local _cs_carry
        if [ -L "$DOC" ]; then
            echo "headed-arm-worker: --consult: the consult doc must not be a symlink ($DOC): the sandbox binds the resolved file" >&2
            exit 2
        fi
        if [ -z "$_worker_doc_path" ]; then
            echo "headed-arm-worker: --consult: cannot resolve the consult doc path for $DOC" >&2
            exit 2
        fi
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg doc "$_worker_doc_path" --arg repo "$CONSULT_REPO_CANON" --argjson c "$_cs_carried" \
            '.hooks = (reduce ((.hooks // {}) | to_entries[]) as $h ($c.hooks; .[$h.key] = ((.[$h.key] // []) + $h.value)))
             | .permissions.deny = ((.permissions.deny // []) + $c.deny + ["Edit","Write","NotebookEdit"] | unique)
             | if ($c.ask | length) > 0 then .permissions.ask = ((.permissions.ask // []) + $c.ask | unique) else . end
             | .permissions.allow = ["Bash(bash scripts/handover/chief-kit/append-results.sh " + $doc + ":*)"]
             | del(.permissions.additionalDirectories)
             | .permissions.defaultMode = "auto"
             | .env = ($c.env + (.env // {}) + {CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: "0"})
             | .sandbox = {enabled: true, failIfUnavailable: true, allowUnsandboxedCommands: false,
                           autoAllowBashIfSandboxed: false,
                           filesystem: {allowWrite: [$doc], denyWrite: [$repo]}}')"; then
            echo "headed-arm-worker: --consult: cannot build the read-only envelope in settings JSON" >&2
            exit 2
        fi
        unset -v _cs_carried
    fi
    unset -v _worker_doc_path _worker_handover_dir_norm
    # Native lane only - the claudex lane keeps its own
    # coordination preface untouched. Resolved even under --dry-run, same
    # reasoning as the profile/mcp resolution above: a jq failure here must
    # fail the same way either way.
    if [ "$LANE" = "native" ]; then
        # %q shell-quotes PROFILE_CONTRACT (log dir + worker name are caller
        # args): the generated command is re-parsed
        # by a DIFFERENT shell when the hook fires, so an unescaped quote or
        # $(...) in the path would break out of it.
        _worker_contract_cmd="$(printf 'cat %q' "$PROFILE_CONTRACT")"
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg cmd "$_worker_contract_cmd" \
            '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{matcher:"compact", hooks:[{type:"command", command:$cmd, timeout:10}]}])')"; then
            echo "headed-arm-worker: --profile $PROFILE: cannot add compact-hook to settings JSON" >&2
            exit 2
        fi
        # Stop hook: an idle lock-holding worker keeps the prompt cache warm or
        # wraps (docs/handover/worker-sections/cache-keepalive.md). A consult is
        # a read-only one-question session with its own lifecycle: no hook.
        if [ "$CONSULT" -eq 0 ]; then
            _worker_ttl_cmd="$(printf 'bash %q' "$(cd "$HERE/../../hooks" && pwd)/guard-worker-cache-ttl.sh")"
            if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg cmd "$_worker_ttl_cmd" \
                '.hooks.Stop = ((.hooks.Stop // []) + [{hooks:[{type:"command", command:$cmd, timeout:10}]}])')"; then
                echo "headed-arm-worker: --profile $PROFILE: cannot add cache-TTL Stop hook to settings JSON" >&2
                exit 2
            fi
        fi
    fi
    # The shim reads these; propagate so they survive both konsole's
    # `-e env -u ...` (Linux) and `open -a`'s fresh environment (macOS).
    # (#1334) The early scrub above already dropped any sibling-worker token/var
    # for this exact name, so this is a plain fresh add, never a clash.
    worker_propagate_env WORKER_SESSION_PROFILE_SETTINGS "$PROFILE_SETTINGS"
    # Per-worker path, like PROFILE_SETTINGS above - the claudex
    # lane below overrides this to the same shape for its own coordination
    # preface; content is written only at real-launch time further down.
    WORKER_SESSION_PROFILE_PREFACE="$_worker_log_dir/$NAME.worker-preface.md"
    worker_propagate_env WORKER_SESSION_PROFILE_PREFACE "$WORKER_SESSION_PROFILE_PREFACE"
    # The consult loads no user/project/local scope: the shim turns this into
    # `--setting-sources ""`, which only narrows. Its hooks, deny/ask and env were carried above.
    [ "$CONSULT" -eq 1 ] && worker_propagate_env WORKER_SESSION_PROFILE_NO_SETTING_SOURCES 1
    export HEADED_ARM_LAUNCHER="$WORKER_SESSION_SHIM"
    # A consult's launcher is the entry beside the canonical shim:
    # an absolute `#!/bin/bash -p` that strips the bash startup variables and
    # exported functions, then runs the shim on the pinned PATH. headed-arm.sh
    # execs its launcher through `env`, where the shim's `#!/usr/bin/env bash`
    # would let PATH pick the interpreter.
    [ "$CONSULT" -eq 1 ] && export HEADED_ARM_LAUNCHER="${WORKER_SESSION_SHIM%/*}/worker-claude-launcher-consult.sh"
    # Lean SessionStart: the three advisory hooks go quiet. Only
    # the exact value 1 leans - the hooks are fail-open by construction.
    worker_propagate_env HIMMEL_LEAN_WORKER_SESSION 1
    # mcpServers allowlist: resolved (and, on an unknown name,
    # REFUSED) here so a typo'd server name fails the same way under --dry-run
    # and for real, same reasoning as the settings JSON above. "null" (the
    # field is absent) is a deliberate no-op: no file, no WORKER_SESSION_PROFILE_MCP_CONFIG,
    # the shim adds nothing.
    if ! MCP_NAMES_JSON="$(cd "$_worker_resolve_cwd" && node "$PROFILES_MJS" "$PROFILE" --mcp-servers 2>&1)"; then
        echo "headed-arm-worker: --profile $PROFILE: mcp-servers resolution failed: $MCP_NAMES_JSON" >&2
        exit 2
    fi
    if [ "$MCP_NAMES_JSON" != "null" ]; then
        if ! MCP_CONFIG_JSON="$(cd "$_worker_resolve_cwd" && node "$PROFILES_MJS" "$PROFILE" --mcp-config 2>&1)"; then
            echo "headed-arm-worker: --profile $PROFILE: mcp-config resolution failed: $MCP_CONFIG_JSON" >&2
            exit 2
        fi
        PROFILE_MCP_CONFIG="$_worker_log_dir/$NAME.leg-mcp.json"
        worker_propagate_env WORKER_SESSION_PROFILE_MCP_CONFIG "$PROFILE_MCP_CONFIG"
    fi
fi

# every claudex worker gets its document-channel coordination
# rules, even without a profile. Claude accepts one preface file, so a
# profiled worker gets its own concatenation, with the lane override last.
if [ "$LANE_CHANNEL" = "file" ]; then
    CLAUDEX_PREFACE="$HERE/../../../docs/handover/worker-preface-$LANE_PREFACE.md"
    export HEADED_ARM_LAUNCHER="${HEADED_ARM_WORKER_SHIM:-$HERE/../../lanes/worker-claude-launcher.sh}"
    worker_propagate_env WORKER_SESSION_CLAUDE_BIN "$LANE_BIN"
    for _worker_need in "$CLAUDEX_PREFACE" "$HEADED_ARM_LAUNCHER"; do
        if [ ! -f "$_worker_need" ]; then
            echo "headed-arm-worker: --lane claudex: required file missing: $_worker_need" >&2
            exit 2
        fi
    done
    if [ -n "$PROFILE" ]; then
        WORKER_SESSION_PROFILE_PREFACE="$_worker_log_dir/$NAME.worker-preface.md"
        worker_propagate_env WORKER_SESSION_PROFILE_PREFACE "$WORKER_SESSION_PROFILE_PREFACE"
    else
        WORKER_SESSION_PROFILE_PREFACE="$CLAUDEX_PREFACE"
        worker_propagate_env WORKER_SESSION_PROFILE_PREFACE "$WORKER_SESSION_PROFILE_PREFACE"
    fi
fi

# Per-worker memory cap: the konsole tab and everything under it run in their own
# systemd user scope, so a runaway test is OOM-killed inside the scope instead of
# systemd-oomd picking a victim among the station's workers and the chief.
# HIMMEL_WORKER_SESSION_MEMORY_MAX is a systemd size (256M, 12G, infinity); swap gets the
# same ceiling so the cap is not defeated by paging out. No systemd-run (macOS,
# a non-systemd host) or no working user manager launches uncapped, with a WARN.
# A consult resolves only the absolute system systemd-run, never the caller's PATH.
WORKER_SESSION_MEMORY_MAX="${HIMMEL_WORKER_SESSION_MEMORY_MAX:-12G}"
case "$WORKER_SESSION_MEMORY_MAX" in
    infinity) ;;
    *)
        if ! [[ "$WORKER_SESSION_MEMORY_MAX" =~ ^[1-9][0-9]*[KMGT]?$ ]]; then
            echo "headed-arm-worker: HIMMEL_WORKER_SESSION_MEMORY_MAX must be a systemd size (e.g. 12G, 256M, infinity), got: $WORKER_SESSION_MEMORY_MAX" >&2
            exit 2
        fi ;;
esac
WORKER_SESSION_SCOPE=()
WORKER_SESSION_SCOPE_WARN=""
WORKER_SESSION_SYSTEMD_RUN=""
if [ "$CONSULT" -eq 1 ]; then
    [ -x /usr/bin/systemd-run ] && WORKER_SESSION_SYSTEMD_RUN=/usr/bin/systemd-run
else
    WORKER_SESSION_SYSTEMD_RUN="${HEADED_ARM_WORKER_SYSTEMD_RUN:-}"
    [ -n "$WORKER_SESSION_SYSTEMD_RUN" ] || WORKER_SESSION_SYSTEMD_RUN="$(command -v systemd-run)" || WORKER_SESSION_SYSTEMD_RUN=""
fi
if [ "$HEADED_ARM_UNAME" != "Linux" ]; then
    WORKER_SESSION_SCOPE_WARN="not Linux ($HEADED_ARM_UNAME)"
elif [ -z "$WORKER_SESSION_SYSTEMD_RUN" ]; then
    WORKER_SESSION_SCOPE_WARN="no systemd-run found"
elif ! "$WORKER_SESSION_SYSTEMD_RUN" --user --scope --quiet -- true >/dev/null 2>&1; then
    WORKER_SESSION_SCOPE_WARN="systemd-run cannot start a user scope"
else
    WORKER_SESSION_SCOPE=("$WORKER_SESSION_SYSTEMD_RUN" --user --scope --quiet -p "MemoryMax=$WORKER_SESSION_MEMORY_MAX" -p "MemorySwapMax=$WORKER_SESSION_MEMORY_MAX" --)
fi

if [ "$LANE" = "native" ] && [ -n "$ASKED_MODEL" ] && [ "$MODEL" != "$ASKED_MODEL" ]; then
    echo "headed-arm-worker: refusing launch: asked model=$ASKED_MODEL but claude would be passed --model $MODEL" >&2
    exit 2
fi

if [ -n "$PROFILE" ]; then
    _prompt_effort="${CLAUDE_CODE_EFFORT_LEVEL:-<unset>}"
    set -f
    for _prompt_tok in ${HEADED_ARM_LAUNCHER_ENV:-}; do
        case "$_prompt_tok" in CLAUDE_CODE_EFFORT_LEVEL=*) _prompt_effort="${_prompt_tok#*=}" ;; esac
    done
    set +f
    _prompt_model="$MODEL"
    [ "$LANE" != openrouter ] || _prompt_model="$OR_MODEL"
    WORKER_LAUNCH_IDENTITY="Worker launch: effort=$_prompt_effort model=$_prompt_model"
    unset -v _prompt_effort _prompt_tok _prompt_model
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'headed-arm-worker: would exec: %s %s %s %s %s %s %s %s\n' \
        "$HEADED_ARM" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
    # scrub= and the resolved CHIEF_CONTEXT are folded into this
    # existing unconditional line (rather than a new line) so the no-flag dry-run
    # report keeps its established line count - a caller can still set
    # CHIEF_CONTEXT=1m and see it reported <unset> here, proving the scrub
    # above ran in THIS wrapper's own process before it ever execs into
    # headed-arm.sh.
    # ${VAR:-<unset>}, not a bare $VAR - a --judge dry-run never
    # exports IMPL_GUARD_OK/INLINE_IMPL_OK (see above) and this line must not
    # die on set -u the moment --judge is passed. A non-judge launch always
    # has both set to 1, so this stays byte-identical to before for every
    # existing caller.
    # CR_TRIGGER_SUPPRESS folded in the same way, for the same
    # reason - proves WORKER_SESSION_SUPPRESS_CR_TRIGGER->CR_TRIGGER_SUPPRESS ran in
    # THIS wrapper's own process, and stays <unset> (the default-ON case)
    # for every caller that never sets WORKER_SESSION_SUPPRESS_CR_TRIGGER.
    # HIMMEL_CONSOLE_NAME folded in the same way - proves the
    # three-source resolution above ran in THIS wrapper's own process, and
    # stays <unset> when no source yielded a well-formed name.
    # the context mode and ceiling the worker's context guard reads.
    printf 'headed-arm-worker: env IMPL_GUARD_OK=%s INLINE_IMPL_OK=%s HIMMEL_CONSOLE_LEG=%s HEADED_ARM_REPO=%s scrub=%s CHIEF_CONTEXT=%s CR_TRIGGER_SUPPRESS=%s HANDOVER_DIR=%s HIMMEL_CONSOLE_NAME=%s HIMMEL_API_LANE=%s HIMMEL_API_ACCOUNT=%s HIMMEL_WORKER_SESSION_CONTEXT_MODE=%s HIMMEL_WORKER_SESSION_AUTOCOMPACT=%s\n' \
        "${IMPL_GUARD_OK:-<unset>}" "${INLINE_IMPL_OK:-<unset>}" "$HIMMEL_CONSOLE_LEG" "${HEADED_ARM_REPO:-<derived by headed-arm.sh>}" \
        "$WORKER_SESSION_ENV_SCRUB" "${CHIEF_CONTEXT:-<unset>}" "${CR_TRIGGER_SUPPRESS:-<unset>}" "${HANDOVER_DIR:-<unset>}" "${HIMMEL_CONSOLE_NAME:-<unset>}" \
        "${HIMMEL_API_LANE:-<unset>}" "${HIMMEL_API_ACCOUNT:-<unset>}" \
        "${HIMMEL_WORKER_SESSION_CONTEXT_MODE:-<unset>}" "$HIMMEL_WORKER_SESSION_AUTOCOMPACT"
    # Printed ONLY under --relay: with the flag omitted this line is absent and
    # the dry-run report stays byte-identical to today's, same guarantee shape
    # as the --profile line below.
    if [ "$RELAY" -eq 1 ]; then
        printf 'headed-arm-worker: relay=%s HIMMEL_CONSOLE_RELAY=%s WORKER_SESSION_EFFORT=%s\n' \
            "$RELAY" "$HIMMEL_CONSOLE_RELAY" "$WORKER_SESSION_EFFORT"
    fi
    # Printed ONLY under --judge, same guarantee shape as --relay above.
    # preface-source names the FILE that will be concatenated into the per-worker
    # preface (WORKER_SESSION_PROFILE_PREFACE, in the --profile line below, is the
    # generated per-worker copy - this is the one place the SOURCE choice is
    # directly observable in --dry-run).
    if [ "$JUDGE" -eq 1 ]; then
        printf 'headed-arm-worker: judge=%s read-clamp-lines=%s preface-source=%s\n' \
            "$JUDGE" "${HIMMEL_READ_CLAMP_LINES:-<unset>}" "$WORKER_SESSION_PREFACE"
    fi
    if [ "$CONSULT" -eq 1 ]; then
        printf 'headed-arm-worker: consult=%s read-clamp-lines=%s preface-source=%s\n' \
            "$CONSULT" "${HIMMEL_READ_CLAMP_LINES:-<unset>}" "$WORKER_SESSION_PREFACE"
    fi
    if [ "$RM" -eq 1 ]; then
        printf 'headed-arm-worker: release-manager=%s readonly-role=%s HIMMEL_RELEASE_MANAGER=%s HIMMEL_RM_DOC=%s HIMMEL_RM_RELEASE=%s read-clamp-lines=%s preface-source=%s\n' \
            "$RM" "$READONLY_ROLE" "$HIMMEL_RELEASE_MANAGER" "${HIMMEL_RM_DOC:-<unset>}" "$HIMMEL_RM_RELEASE" \
            "${HIMMEL_READ_CLAMP_LINES:-<unset>}" "$WORKER_SESSION_PREFACE"
    fi
    printf 'headed-arm-worker: lane=%s launcher=%s launcher-env=%s memory-max=%s scope=%s' \
        "$LANE" "${HEADED_ARM_LAUNCHER:-claude (native default)}" "${HEADED_ARM_LAUNCHER_ENV:-<none>}" \
        "$WORKER_SESSION_MEMORY_MAX" "$([ "${#WORKER_SESSION_SCOPE[@]}" -gt 0 ] && echo yes || echo no)"
    if [ "$LANE_CHANNEL" = "file" ]; then
        printf ' exec-target=%s preface=%s recorder=%s' "$WORKER_SESSION_CLAUDE_BIN" "$WORKER_SESSION_PROFILE_PREFACE" "$HEADED_ARM_RECORDER"
    fi
    printf '\n'
    # Printed ONLY under --profile: with the flag omitted this whole line is
    # absent and the dry-run report is byte-identical to the earlier
    # one, matching the argv guarantee it describes.
    if [ -n "$PROFILE" ]; then
        printf 'headed-arm-worker: profile=%s settings=%s preface=%s contract=%s lean=%s mcp=%s mcp-config=%s autocompact=%s prompt=%s\n' \
            "$PROFILE" "$PROFILE_SETTINGS" "$WORKER_SESSION_PROFILE_PREFACE" "$PROFILE_CONTRACT" "$HIMMEL_LEAN_WORKER_SESSION" \
            "$MCP_NAMES_JSON" "${WORKER_SESSION_PROFILE_MCP_CONFIG:-<none>}" "$RESOLVED_AUTOCOMPACT" "$WORKER_LAUNCH_IDENTITY"
    fi
    # Printed ONLY for an Opus/Fable model that cleared the tier gate above;
    # absent for Sonnet/Haiku, matching the argv-report guarantee pattern above.
    if [ -n "$TIER_GATE" ]; then
        printf 'headed-arm-worker: tier=%s tier-category=%s tier-reason=%s\n' "$TIER_GATE" "$TIER_CATEGORY" "$TIER_REASON"
    fi
    # Printed ONLY for a profile default or sanctioned 1m Context-line opt-in,
    # shape as the Tier-gate line above.
    if [ -n "$CONTEXT_REASON" ]; then
        printf 'headed-arm-worker: context=1m (%s) context-reason=%s\n' "$CONTEXT_SOURCE" "$CONTEXT_REASON"
    fi
    # printed ONLY for an A/B arm launch.
    if [ -n "$AB_ARM" ]; then
        printf 'headed-arm-worker: ab-arm=%s autocompact=%s ab-reason=%s\n' "$AB_ARM" "$RESOLVED_AUTOCOMPACT" "${AB_REASON:-<control>}"
    fi
    # Printed ONLY under --headless, same guarantee shape as --relay above.
    if [ "$HEADLESS" -eq 1 ]; then
        printf 'headed-arm-worker: headless=1 launch=%s --bg --permission-mode auto (env merged into %s at launch)\n' \
            "$HEADED_ARM_LAUNCHER" "$PROFILE_SETTINGS"
    fi
    exit 0
fi

# Real launch: now write the resolved settings the shim will pass to claude.
if [ -n "$PROFILE" ]; then
    if ! printf '%s\n' "$PROFILE_JSON" > "$PROFILE_SETTINGS"; then
        echo "headed-arm-worker: --profile $PROFILE: cannot write settings to $PROFILE_SETTINGS" >&2
        exit 2
    fi
    chmod 600 "$PROFILE_SETTINGS" 2>/dev/null || true
    if [ "$LANE_CHANNEL" = "file" ]; then
        if ! awk -v identity="$WORKER_LAUNCH_IDENTITY" 'NR == 1 { print; print ""; print identity; next } { print }' \
            "$WORKER_SESSION_PREFACE" "$CLAUDEX_PREFACE" > "$WORKER_SESSION_PROFILE_PREFACE"; then
            echo "headed-arm-worker: --lane $LANE: cannot write preface to $WORKER_SESSION_PROFILE_PREFACE" >&2
            exit 2
        fi
        chmod 600 "$WORKER_SESSION_PROFILE_PREFACE" 2>/dev/null || true
    else
        # Native lane: the worker preface stays the standing
        # rule set only. The brief's own contract (up to the Results tail) is
        # written to its own file and re-injected by a SessionStart compact
        # hook (added to PROFILE_JSON above) instead of riding every API call
        # in the preface. awk stops at the Results tail (or never, printing
        # the whole file) rather than mapfile, for bash 3.2 (macOS ships 3.2;
        # see the Platform guard above).
        if ! awk -v identity="$WORKER_LAUNCH_IDENTITY" 'NR == 1 { print; print ""; print identity; next } { print }' \
            "$WORKER_SESSION_PREFACE" > "$WORKER_SESSION_PROFILE_PREFACE"; then
            echo "headed-arm-worker: --profile $PROFILE: cannot write preface to $WORKER_SESSION_PROFILE_PREFACE" >&2
            exit 2
        fi
        chmod 600 "$WORKER_SESSION_PROFILE_PREFACE" 2>/dev/null || true
        if ! awk '/^## Results/{exit} {print}' "$DOC" > "$PROFILE_CONTRACT"; then
            echo "headed-arm-worker: --profile $PROFILE: cannot write contract to $PROFILE_CONTRACT" >&2
            exit 2
        fi
        chmod 600 "$PROFILE_CONTRACT" 2>/dev/null || true
    fi
    # A worker on an adopted repo copies the preface's ship steps from a cwd that
    # is not a himmel checkout, where the relative `bash scripts/...` forms do not
    # resolve. Name the himmel anchor's absolute scripts in the
    # written copy: $HIMMEL_REPO, else the primary checkout this script lives in.
    # A worker whose repo root is this checkout (same git common dir, no
    # subdirectory prefix) keeps the relative form, which the gate guards
    # demand. A non-himmel repo with no
    # resolvable anchor keeps it too.
    _pf_anchor="${HIMMEL_REPO:-}"
    case "$_pf_anchor" in /*) ;; *)
        _pf_anchor="$(git_clean -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && _pf_anchor="$(dirname "$_pf_anchor")" || _pf_anchor="" ;; # swallow-ok: no anchor keeps the relative form
    esac
    if [ -n "${HEADED_ARM_REPO:-}" ] && [ -d "$_pf_anchor" ]; then
        _pf_repo_common="$(git_clean -C "$HEADED_ARM_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || _pf_repo_common="" # swallow-ok: not a git repo is not a himmel checkout
        _pf_anchor_common="$(git_clean -C "$_pf_anchor" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || _pf_anchor_common="" # swallow-ok: an unresolvable anchor compares unequal
        _pf_repo_prefix="$(git_clean -C "$HEADED_ARM_REPO" rev-parse --show-prefix 2>/dev/null)" || _pf_repo_prefix="." # swallow-ok: an unreadable prefix counts as below the root
        if [ -z "$_pf_repo_common" ] || [ "$_pf_repo_common" != "$_pf_anchor_common" ] || [ -n "$_pf_repo_prefix" ]; then
            _pf_esc="$(printf '%s' "$_pf_anchor" | sed -e 's/[\\&#]/\\&/g')"
            if sed -E "s#(^|[ \`(])scripts/#\\1${_pf_esc}/scripts/#g" "$WORKER_SESSION_PROFILE_PREFACE" > "$WORKER_SESSION_PROFILE_PREFACE.abs" \
                && mv "$WORKER_SESSION_PROFILE_PREFACE.abs" "$WORKER_SESSION_PROFILE_PREFACE"; then
                chmod 600 "$WORKER_SESSION_PROFILE_PREFACE" 2>/dev/null || true
            else
                rm -f "$WORKER_SESSION_PROFILE_PREFACE.abs"
                echo "$(date +%F_%T) headed-arm-worker: WARN preface paths not anchored; launching with the relative forms" >> "$LOG"
            fi
            unset -v _pf_esc
        fi
        unset -v _pf_repo_common _pf_anchor_common _pf_repo_prefix
    fi
    unset -v _pf_anchor
    # WORKER_SESSION_REPO_MAP=1 (launching shell, default off): put a token-capped
    # PageRank repo map of the worker's repo (its primary checkout's
    # graphify-out/graph.json) at the HEAD of the preface, so the preface's
    # turn-ending section stays last. WORKER_SESSION_REPO_MAP_TOKENS sets the cap (default
    # 2000). Advisory: no graph, a generator failure or a generator still
    # running after WORKER_SESSION_REPO_MAP_TIMEOUT seconds (default 30) launches without
    # it; so does a host with no GNU timeout, since the generator never runs unbounded.
    if [ "${WORKER_SESSION_REPO_MAP:-0}" = 1 ]; then
        REPO_MAP_CMD="${HEADED_ARM_WORKER_REPO_MAP:-$HERE/../../graphify/repo-map.py}"
        _rm_timeout="${WORKER_SESSION_REPO_MAP_TIMEOUT:-30}"
        # shellcheck source=scripts/lib/timeout-bin.sh
        . "$HERE/../../lib/timeout-bin.sh" 2>/dev/null
        _rm_graph="<no git repo>"
        if [ -n "${_TIMEOUT_BIN:-}" ] \
            && _rm_common="$(git -C "${HEADED_ARM_REPO:-$HERE/../../..}" rev-parse --path-format=absolute --git-common-dir)" \
            && _rm_graph="$(dirname "$_rm_common")/graphify-out/graph.json" \
            && _rm_map="$("$_TIMEOUT_BIN" -k 5 "$_rm_timeout" "$REPO_MAP_CMD" --graph "$_rm_graph" --max-tokens "${WORKER_SESSION_REPO_MAP_TOKENS:-2000}")" \
            && { printf '%s\n\n' "$_rm_map"; cat "$WORKER_SESSION_PROFILE_PREFACE"; } > "$WORKER_SESSION_PROFILE_PREFACE.map" \
            && mv "$WORKER_SESSION_PROFILE_PREFACE.map" "$WORKER_SESSION_PROFILE_PREFACE"; then
            echo "$(date +%F_%T) headed-arm-worker: repo-map=on graph=$_rm_graph tokens=${WORKER_SESSION_REPO_MAP_TOKENS:-2000}" >> "$LOG"
        else
            _rm_rc=$?
            _rm_why="rc=$_rm_rc"
            [ "$_rm_rc" = 124 ] && _rm_why="timed out after ${_rm_timeout}s"
            [ -n "${_TIMEOUT_BIN:-}" ] || _rm_why="no GNU timeout to bound the generator"
            rm -f "$WORKER_SESSION_PROFILE_PREFACE.map"
            echo "$(date +%F_%T) headed-arm-worker: WARN repo-map not injected (graph=$_rm_graph, $_rm_why); launching without it" >> "$LOG"
        fi
    fi
    if [ -n "${WORKER_SESSION_PROFILE_MCP_CONFIG:-}" ]; then
        if ! printf '%s\n' "$MCP_CONFIG_JSON" > "$WORKER_SESSION_PROFILE_MCP_CONFIG"; then
            echo "headed-arm-worker: --profile $PROFILE: cannot write mcp config to $WORKER_SESSION_PROFILE_MCP_CONFIG" >&2
            exit 2
        fi
        chmod 600 "$WORKER_SESSION_PROFILE_MCP_CONFIG" 2>/dev/null || true
    fi
fi

# fleet-size cap. Checked at ARM time, before headed-arm.sh's own
# signal/deadline wait loop even starts - refusing now is cheaper than
# refusing after waiting out the deadline. SKIPPED-FLEET refuses the launch
# outright. SKIPPED-BANK also refuses: we set
# CADENCE_USAGE_LANE="$LANE" above specifically so usage-preflight.sh checks
# the bank this lane actually draws on (the codex weekly bank for claudex,
# the CLAUDE five_hour/seven_day bank for native) - unlike arm-resume.sh,
# this wrapper has no separate bank-aware scheduling path to fall back on,
# so ignoring SKIPPED-BANK would let a launch through against an exhausted
# bank. Any other verdict (PROCEED, BANK-STALE, BANK-UNKNOWN) falls through.
BANK_PREFLIGHT="${HEADED_ARM_WORKER_PREFLIGHT:-$HERE/../../lib/usage-preflight.sh}"
if [ -f "$BANK_PREFLIGHT" ]; then
    # TTL from OUR OWN deadline plus a fixed grace period,
    # floored at 60s — a reservation must not outlive the arm attempt it
    # belongs to, but must also survive long enough to matter. codex-5 (this
    # round): for a FUTURE deadline, expiring the reservation exactly AT the
    # deadline leaves zero grace for the actual process spawn (scheduling
    # jitter, OS overhead) to complete and register in the live census —
    # another admission racing that gap sees the slot freed and can over-
    # admit the fleet right as this worker is coming up. The same +60s grace
    # also covers a near-past DEADLINE or clock skew, so the separate floor
    # below is now a belt-and-braces minimum rather than the only guard.
    _arm_fleet_ttl=$(( DEADLINE - $(date +%s) + 60 ))
    [ "$_arm_fleet_ttl" -ge 60 ] || _arm_fleet_ttl=60
    # this call launches a worker, so it declares launch intent —
    # the fleet cap must be able to actually refuse it, unlike a plain
    # bank-status READ.
    preflight_token="$(CADENCE_USAGE_WORKER="$NAME" CADENCE_USAGE_LANE="$LANE_BANK_GATE" CADENCE_USAGE_LAUNCH=1 CADENCE_USAGE_CALLER_PID="$$" FLEET_RESERVE_TTL="$_arm_fleet_ttl" bash "$BANK_PREFLIGHT" 2>>"$LOG")"
    if [ "$preflight_token" = SKIPPED-FLEET ]; then
        # NOT a reservation release here — usage-preflight.sh
        # only ever returns SKIPPED-FLEET from its admission block itself
        # (lock failure, at/over-cap, or a DUPLICATE reservation name), and
        # none of those paths ever create a reservation for OUR call. The
        # duplicate case in particular is someone ELSE's still-pending
        # reservation for this same name — deleting it here would release a
        # slot out from under that other, still-live arm attempt.
        echo "$(date +%F_%T) headed-arm-worker: refusing to launch $NAME - fleet-size cap reached (bypass: FLEET_CAP_OK=1 in the LAUNCHING shell)" >> "$LOG"
        exit 10
    fi
    if [ "$preflight_token" = SKIPPED-BANK ]; then
        # SKIPPED-BANK is only reachable AFTER fleet admission
        # already succeeded and reserved a slot for $NAME (admission runs
        # before any bank check) — release it now since this attempt is not
        # going to launch after all, rather than leaving it to expire by TTL.
        _arm_fleet_slots="${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-$(id -u)}"
        # The same admission-lock-failure bypass that
        # can reach here without ever creating OUR reservation (see the
        # comment above SKIPPED-FLEET) means a reservation already present
        # for $NAME may belong to an unrelated concurrent arm attempt —
        # verify pid ownership before deleting it out from under them.
        if [ "$(cat "${_arm_fleet_slots:?}/$NAME/pid" 2>/dev/null)" = "$$" ]; then
            rm -rf "${_arm_fleet_slots:?}/$NAME" 2>/dev/null
        fi
        echo "$(date +%F_%T) headed-arm-worker: refusing to launch $NAME - $LANE lane bank exhausted (park and retry later; see usage-preflight.sh for the parked lane's own bank status)" >> "$LOG"
        exit 11
    fi
fi

# a deliberate --no-profile launch looks exactly like a profiled
# one in headed-arm.sh's own log lines, so record the opt-out here.
# mint this launch's session uuid, append it to the doc's front
# matter (session_ids:, comma-separated, one per launch and relaunch) and hand
# it to the shim, which passes it to claude as --session-id. The digest step
# then digests the ids directly instead of searching by name. Only where the
# shim is the launcher (native + profile, headed, not a consult) and the doc
# opens on a front matter; the write is one temp file + mv, never the body.
# A symlinked doc is skipped: the mv would replace the link with a copy.
# the rewrite is worker-doc-lock.sh's, under the lock every doc
# writer shares, so a concurrent append-results.sh bullet is never lost.
_worker_sid=""
if [ "$LANE" = "native" ] && [ -n "$PROFILE" ] && [ "$HEADLESS" -eq 0 ] && [ "$CONSULT" -eq 0 ] \
    && [ ! -L "$DOC" ] && [ "$(head -n 1 "$DOC" 2>/dev/null)" = "---" ]; then  # read-sink-ok: DOC is the handover doc this launcher was asked to arm
    # shellcheck source=scripts/handover/chief-kit/worker-doc-lock.sh
    . "$HERE/worker-doc-lock.sh"
    _worker_sid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)"
    _worker_sid="$(printf '%s' "$_worker_sid" | tr 'A-F' 'a-f')"
    if worker_doc_add_session_id "$DOC" "$_worker_sid"; then
        worker_propagate_env WORKER_SESSION_ID "$_worker_sid"
    else
        _worker_sid=""
        echo "$(date +%F_%T) headed-arm-worker: WARN session id NOT recorded in $DOC (the digest step falls back to its name search)" >> "$LOG"
    fi
fi

if [ "$NO_PROFILE" -eq 1 ]; then
    echo "$(date +%F_%T) headed-arm-worker: WARN --no-profile: docs/handover/worker-preface.md NOT injected and no plugin profile applied (the brief must carry the preface)" >> "$LOG"
fi

# this wrapper execs into headed-arm.sh below, so its own
# "armed:" line (headed-arm.sh) never sees TIER_GATE - log the reason
# ourselves, same append style as the SKIPPED-FLEET/SKIPPED-BANK lines above.
if [ -n "$TIER_GATE" ]; then
    echo "$(date +%F_%T) headed-arm-worker: tier=$TIER_GATE tier-category=$TIER_CATEGORY tier-reason=$TIER_REASON" >> "$LOG"
fi
# same reasoning as the TIER_GATE line above - headed-arm.sh's
# own "armed:" line never sees CONTEXT_REASON, so log it ourselves.
if [ -n "$CONTEXT_REASON" ]; then
    echo "$(date +%F_%T) headed-arm-worker: context=1m ($CONTEXT_SOURCE) context-reason=$CONTEXT_REASON" >> "$LOG"
fi
# the A/B arm is audited in the arm log too.
if [ -n "$AB_ARM" ]; then
    echo "$(date +%F_%T) headed-arm-worker: ab-arm=$AB_ARM autocompact=$RESOLVED_AUTOCOMPACT ab-reason=${AB_REASON:-<control>}" >> "$LOG"
fi

# record what this launch WAS, where a cohort query can find it
# after the fact. The launch-time facts (profile, role, model) are not
# recoverable from the transcript, so this is the only moment they exist.
# One appended line per real launch (never --dry-run) in the himmelctl cache
# dir, which uninstall already removes wholesale (scripts/install/
# uninstall-manifest.tsv, row himmelctl-cache). Launch metadata only - the
# fields below are the whole record; no env value and nothing from
# ~/.claude.json is ever read into it. Best-effort: a record that cannot be
# written is noted in $LOG and never stops the launch.
# ponytail: this records the launch ATTEMPT that reached the exec below;
# headed-arm.sh can still refuse it (duplicate session name, missing pin).
# A refused launch of a NEW name has no transcript, so a reader joining on
# the session name never counts it - but a refused DUPLICATE of a live
# session's name does match that session's transcript, and its line (which
# may carry a different profile) sits beside the original: the log is
# append-only and carries no attempt id, so the reader must not assume one
# line per session (it is not decided here; the reader's owner decides).
# ponytail: with no HIMMELCTL_CACHE_DIR and no HOME nothing is written -
# falling back to /tmp would leave a file uninstall cannot find (the
# accepted HOME-unset divergence, not repeated here).
_ll_cache="${HIMMELCTL_CACHE_DIR:-}"
[ -z "$_ll_cache" ] && [ -n "${HOME:-}" ] && _ll_cache="$HOME/.claude/himmel"
if [ -n "$_ll_cache" ]; then
    _ll_role=worker
    [ "$RELAY" -eq 1 ] && _ll_role=relay
    [ "$JUDGE" -eq 1 ] && _ll_role=judge
    [ "$CONSULT" -eq 1 ] && _ll_role=consult
    # a consult line also names the chief that launched it; every other role's line
    # keeps its exact key set (the cost cohort reader and test 28c pin it).
    _ll_asker=""
    [ "$CONSULT" -eq 1 ] && _ll_asker=" chief=${CHIEF_FLAG:-unknown}"
    # an A/B arm launch also records its arm; every other line keeps its key set.
    [ -z "$AB_ARM" ] || _ll_asker="$_ll_asker ab_arm=$AB_ARM"
    # the transcript is named by the session uuid, so the line carries it (when this launch
    # minted one) beside profile and lane: the opening-size reader joins on it.
    _ll_sid=""
    [ -z "$_worker_sid" ] || _ll_sid=" session_id=$_worker_sid"
    if ! ( umask 077 && mkdir -p "$_ll_cache/launch-logs" && \
        printf 'headed-arm-worker: profile=%s lane=%s model=%s role=%s session=%s%s launched=%s%s\n' \
            "${PROFILE:-none}" "$LANE" "${MODEL:-default}" "$_ll_role" "$NAME" "$_ll_sid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ll_asker" \
            >> "$_ll_cache/launch-logs/$NAME.log" ) 2>/dev/null; then
        echo "$(date +%F_%T) headed-arm-worker: WARN launch record NOT written under $_ll_cache/launch-logs (the cost cohort cannot see this launch)" >> "$LOG"
    fi
fi

# the pid and session id of a headless worker exist only after
# headed-arm.sh launches it, so it appends them to the same durable record.
if [ "$HEADLESS" -eq 1 ] && [ -n "$_ll_cache" ]; then
    export HEADED_ARM_LAUNCH_RECORD="$_ll_cache/launch-logs/$NAME.log"
fi

# Pre-accept the folder/hooks trust prompt for the worker's cwd, on
# the config the lane's claude reads, so a fresh worktree or eval clone does not
# park a headed worker at a prompt nobody answers. worker-pretrust.sh refuses any cwd
# that is not a chief worktree or an eval clone. Non-fatal by design: a failure
# only costs the prompt this used to cost. A consult never runs in a worker cwd.
# With no WORKER_SESSION_REPO the worker runs in the primary checkout, which never qualifies.
if [ "$CONSULT" -ne 1 ] && [ -n "${HEADED_ARM_REPO:-}" ]; then
    bash "$HERE/worker-pretrust.sh" "$LANE" "$HEADED_ARM_REPO" \
        || echo "headed-arm-worker: WARN trust pre-accept not applied (see above); the worker may stop at the folder-trust prompt" >&2
fi

# A profile that lists himmel-bus in mcpServers
# opts in. The launcher registers the session under its own name before launch
# (the only party that knows it before the model exists), hands the worker
# HIMMEL_BUS_NAME and nothing else, and tells headed-arm.sh to bind the claude
# pid it resolves. No secret exists: identity is (name, pid, start time).
# Fail-open on purpose: no profile requires the bus in phase 1, and an
# unregistered worker is merely unbound (bus send refused) and keeps today's
# channels, so a register failure warns (launch log, launcher stdout, a
# bus=FAIL: worker-doc bullet) and never blocks a launch of the live fleet. A headless worker
# never binds (spec 8.5), so it is not registered either; nor is a worker whose doc
# names no chief, which has nobody to register with.
# ponytail: fail-open only until a profile can require the bus, upgrade path HIMMEL-4818 phase 2.
# A profile with no mcpServers field (null) loads every user MCP server,
# himmel-bus among them, so it opts in too.
case "${MCP_NAMES_JSON:-}" in
    *'"himmel-bus"'*|null)
        if [ "$HEADLESS" -ne 1 ] && [ -z "$BUS_CHIEF" ]; then
            echo "$(date +%F_%T) headed-arm-worker: $NAME names no chief - not registered on the bus" >> "$LOG"
        elif [ "$HEADLESS" -ne 1 ]; then
            BUS_CLI="${HEADED_ARM_BUS_CLI:-$HERE/../../../marketplace/plugins/himmel-bus/bin/bus}"
            BUS_ROLE=worker
            [ "$JUDGE" -eq 1 ] && BUS_ROLE=judge
            [ "$CONSULT" -eq 1 ] && BUS_ROLE=consult
            BUS_ARGS=(register "$NAME" --role "$BUS_ROLE" --console "$BUS_CHIEF")
            # WORKER_SESSION_BUS_PAIR: the worker a judge or consult was launched for (spec 3c).
            [ "$BUS_ROLE" != worker ] && [ -n "${WORKER_SESSION_BUS_PAIR:-}" ] && BUS_ARGS+=(--pair "$WORKER_SESSION_BUS_PAIR")
            if BUS_OUT="$("$BUS_CLI" "${BUS_ARGS[@]}" 2>&1)"; then
                worker_propagate_env HIMMEL_BUS_NAME "$NAME"
                # The CLI that registered is the CLI that binds.
                export HEADED_ARM_BUS=1 HEADED_ARM_BUS_CLI="$BUS_CLI"
            else
                echo "$(date +%F_%T) headed-arm-worker: WARN bus register failed for $NAME - launching unbound: $BUS_OUT" >> "$LOG"
                # a failed register was only ever in the log, so the
                # bus sat dead unseen. Say it on stdout and leave a bus=FAIL:
                # bullet in the worker doc (a lowercase lead is a non-status
                # bullet: the tick tail ignores it, a grep for bus=FAIL finds it).
                # WRAPPED is stripped: worker_tail_status reads a final unmarked
                # bullet containing it as a wrap.
                BUS_REASON="$(printf '%s' "$BUS_OUT" | tr '\n>' ' -' | sed 's/WRAPPED//g' | cut -c1-160)"
                echo "headed-arm-worker: WARN bus register failed for $NAME - launching unbound (bus=FAIL:$BUS_REASON)"
                bash "$HERE/append-results.sh" "$DOC" "bus=FAIL:$BUS_REASON" >/dev/null 2>&1 || true
            fi
        fi
        ;;
esac
unset -v BUS_CLI BUS_ROLE BUS_ARGS BUS_OUT BUS_REASON BUS_CHIEF WORKER_SESSION_BUS_PAIR

# Every headed worker gets one bus-idle-waker, started by headed-arm.sh once the
# konsole pid exists (only it knows the pid). A headless worker has no konsole and
# a consult is a throwaway, so neither is armed; an ambient value never rides in.
unset -v HEADED_ARM_WAKER
if [ "$HEADLESS" -ne 1 ] && [ "$CONSULT" -ne 1 ]; then
    export HEADED_ARM_WAKER="${HEADED_ARM_WORKER_WAKER:-$HERE/../bus-idle-waker.sh}"
fi

# Paired with this exec's PID: headed-arm.sh ignores stale ambient values.
export HEADED_ARM_CONTEXT_PID="$$" HEADED_ARM_WORKER_PROFILES="$PROFILES_MJS"
# A consult runs headed-arm.sh on the pinned runtime: an absolute
# `bash -p` (no PATH lookup of its `#!/usr/bin/env bash`, no startup file, no
# exported function), the bash startup variables stripped, and the pinned PATH
# already set, so the PATH headed-arm.sh hands its own exec of the launcher is
# the pinned one. Every other launch keeps the plain exec below.
HA_RUN=("$HEADED_ARM")
HA_SH=(bash)
if [ "$CONSULT" -eq 1 ]; then
    # shellcheck source=../../lanes/consult-env.sh
    if ! . "${WORKER_SESSION_SHIM%/*}/consult-env.sh"; then
        echo "headed-arm-worker: --consult cannot load ${WORKER_SESSION_SHIM%/*}/consult-env.sh: refusing" >&2
        exit 2
    fi
    if ! _consult_bash="$(consult_pin_bash)"; then
        echo "headed-arm-worker: --consult needs /usr/bin/bash or /bin/bash: refusing" >&2
        exit 2
    fi
    consult_scrub_args
    HA_RUN=(/usr/bin/env "${CONSULT_SCRUB[@]}" PATH="$(consult_pin_path)" "$_consult_bash" -p "$HEADED_ARM")
    # The --fleet hand-off below starts its own bash first: same absolute -p one.
    HA_SH=("$_consult_bash" -p)
fi
if [ -n "$WORKER_SESSION_SCOPE_WARN" ] && [ "$DRY_RUN" -eq 0 ]; then
    # An uncapped worker is said on stdout, in the log and as a memcap=FAIL: bullet in
    # the worker doc (lowercase lead: the tick tail ignores it, a grep finds it).
    echo "$(date +%F_%T) headed-arm-worker: WARN memory cap NOT applied for $NAME ($WORKER_SESSION_SCOPE_WARN) - launching uncapped" >> "$LOG"
    echo "headed-arm-worker: WARN memory cap NOT applied for $NAME - launching uncapped (memcap=FAIL:$WORKER_SESSION_SCOPE_WARN)"
    bash "$HERE/append-results.sh" "$DOC" "memcap=FAIL:$WORKER_SESSION_SCOPE_WARN" >/dev/null 2>&1 || true
fi
if [ "${#WORKER_SESSION_SCOPE[@]}" -gt 0 ]; then
    HA_RUN=("${WORKER_SESSION_SCOPE[@]}" "${HA_RUN[@]}")
fi
if [ -n "$FLEET_MANIFEST" ]; then
    # Keep headed-arm.sh's profile/context handoff paired to its own exec PID.
    "${HA_SH[@]}" -c 'export HEADED_ARM_CONTEXT_PID="$$"; exec "$@"' bash \
        "${HA_RUN[@]}" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
    launch_rc=$?
    [ "$launch_rc" -eq 0 ] || exit "$launch_rc"
    _fm_arm=()
    [ -z "$AB_ARM" ] || _fm_arm=(--arm "$AB_ARM")
    if ! bash "$HERE/fleet-manifest.sh" add "$FLEET_MANIFEST" --lane "$LANE" ${_fm_arm[@]+"${_fm_arm[@]}"} "$DOC"; then
        echo "headed-arm-worker: launch handed off but fleet manifest update failed: $FLEET_MANIFEST" >&2
        exit 1
    fi
    exit 0
fi
exec "${HA_RUN[@]}" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
