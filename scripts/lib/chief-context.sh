#!/usr/bin/env bash
# Shared arming-time context-window (1m|standard) decision primitives
# (re-pinned by T6).
#
# WHY: the same decisions -- is a model Fable-family (the CLI silently
# strips a [1m] suffix there), what autocompact value a mode maps to, and
# what the DEFAULT mode is when nothing explicit was given -- used to be
# duplicated across scripts/handover/arm-resume.sh, headed-arm.sh and
# chief.sh's print-only mirror. chief.sh's own header called that
# duplication "deliberate ... mirrored here (not shared -- a different
# script)"; this file is what makes it genuinely shared instead, so the
# printed launch line and the actually-launched value cannot drift apart.
#
# Bash 3.2-compatible: no `local -n` namerefs (unavailable pre-4.3). Each
# function that needs to hand back more than an exit code sets a bare
# CHIEF_CONTEXT_* global instead. Callers keep their own prose/wording --
# this file only owns the DECISION, not the human-readable reason string
# each caller logs (those strings are pinned by each caller's own test
# suite and legitimately differ between scripts) -- except the source word
# after the mode (`context=1m (explicit)`) and the durable launch-context row,
# which a reader keys on and so come from chief_context_source_label /
# chief_context_write_record below.
#
# Functions:
#   chief_context_valid <value>            -- rc 0 iff value is 1m|standard
#   chief_context_model_is_fable <model>   -- rc 0 iff model is Fable-family
#   chief_context_model_takes_1m_suffix <model>
#                                             -- rc 0 iff the model needs [1m] to
#                                                run 1M (opus-4-6 / sonnet-4-6)
#   chief_context_has_1m_suffix <model>    -- rc 0 iff model ends in [1m]
#   chief_context_strip_1m_suffix <model>  -- prints model with [1m] stripped
#   chief_context_autocompact <mode>       -- prints the autocompact value
#                                                for a resolved mode
#   chief_context_default <is_chief> <chief_context_env>
#                                             -- sets CHIEF_CONTEXT_RESOLVED_MODE
#                                                and CHIEF_CONTEXT_RESOLVED_SOURCE
#                                                for when no explicit value
#                                                was given
#   chief_context_source_label <explicit 0|1>
#                                             -- prints explicit|default, the
#                                                source word both arms log and record
#   chief_context_write_record <session> <mode> <source> <autocompact>
#                                             -- appends the durable launch-context
# row, rc 0 iff written
#   chief_context_worker_env_unset_names      -- prints, one per line, every var a
#                                                worker sets on itself that must never
# reach a chief it arms
#   chief_context_launch_seam_env_names    -- prints the subset of that list that
# only shapes a launch

chief_context_valid() {
    case "$1" in
        1m|standard) return 0 ;;
        *) return 1 ;;
    esac
}

# Fable-FAMILY match, not a literal string -- fable, fable-5, claude-fable-5,
# Claude-Fable-5 all match. Case-insensitive substring, same idiom every
# caller already used before this file existed.
chief_context_model_is_fable() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *fable*) return 0 ;;
        *) return 1 ;;
    esac
}

# chief_context_model_takes_1m_suffix <model> — [1m] only
# SELECTS 1M on Opus 4.6 / Sonnet 4.6 (plan-gated there). Opus 4.7+, Sonnet 5+,
# Haiku 5.5 and Fable run 1M natively, so a bare id plus --autocompact auto is
# the launch; a non-Anthropic id (gpt-*, glm-*, deepseek-*, anything with `/`)
# never takes the suffix (an HTTP 400 on gpt-5.6-sol[1m], docs/tooling-catalog.md).
chief_context_model_takes_1m_suffix() {
    case "$1" in */*) return 1 ;; esac
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        claude-opus-4-6*|claude-sonnet-4-6*|opus-4-6*|sonnet-4-6*) return 0 ;;
        *) return 1 ;;
    esac
}

chief_context_has_1m_suffix() {
    case "$1" in
        *\[1m\]) return 0 ;;
        *) return 1 ;;
    esac
}

chief_context_strip_1m_suffix() {
    case "$1" in
        *\[1m\]) printf '%s' "${1%\[1m\]}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# chief_context_autocompact <mode> -- prints the --autocompact value for a
# resolved mode, rc 1 on an unrecognized one (caller decides how to react;
# this file never exits the caller's process). `standard` and `1m` are the
# only values any caller's CLI/positional surface accepts today (this ticket
# adds no new one), but the parser itself stays generic on a trailing `k`
# shape -- T6 keeps the design doc's N3 generic <N>k resolver
# alive as the parser here even though the 400k tier it was written for is
# retired, per the v1 join design's explicit note that the shape, not the
# tier, is what survives.
chief_context_autocompact() {
    case "$1" in
        1m) printf '%s' 'auto' ;;
        standard) printf '%s' '200000' ;;
        *k)
            _cc_n="${1%k}"
            case "$_cc_n" in
                ''|*[!0-9]*) return 1 ;;
            esac
            printf '%s000' "$_cc_n"
            ;;
        *) return 1 ;;
    esac
}

# chief_context_default <is_chief 0|1> <chief_context_env value>
#
# Only for the no-explicit-value path. It exempts chiefs from
# the standard default: chiefs default to 1m, with
# CHIEF_CONTEXT=standard opting down; each caller
# passes the env value it read. Non-chief arms remain standard
# and ignore the environment. A valid env choice is explicit provenance.
# shellcheck disable=SC2034  # output-contract globals, read by sourcing callers (arm-resume.sh, headed-arm.sh, chief.sh)
chief_context_default() {
    CHIEF_CONTEXT_RESOLVED_MODE="standard"
    CHIEF_CONTEXT_RESOLVED_SOURCE="default"
    if [ "$1" -eq 1 ]; then
        CHIEF_CONTEXT_RESOLVED_MODE="1m"
        if chief_context_valid "$2"; then
            CHIEF_CONTEXT_RESOLVED_MODE="$2"
            CHIEF_CONTEXT_RESOLVED_SOURCE="chief-context-env"
        fi
    fi
}

# chief_context_source_label <explicit_given 0|1> -- prints the source word
# both arming paths log and record: `explicit` when the mode was named
# (--context / the launcher's positional) OR selected with CHIEF_CONTEXT
# (1m or standard), else `default`.
# Spec 2973 sec 2.4 keys on `context=1m (explicit)`. arm-resume.sh
# used to spell this from its own prose while headed-arm.sh spelled `(explicit)`,
# so a reader keying on the spec attributed one path and silently skipped the
# other; both callers take the word from here now. Read
# CHIEF_CONTEXT_RESOLVED_SOURCE only after chief_context_default ran.
chief_context_source_label() {
    if [ "$1" -eq 1 ] || [ "${CHIEF_CONTEXT_RESOLVED_SOURCE:-}" = "chief-context-env" ]; then
        printf '%s' explicit
    else
        printf '%s' default
    fi
}

# chief_context_write_record <session> <mode> <source> <autocompact>
#
# The durable launch-context row for a chief arm (it used to live in
# headed-arm.sh; moved it here so arm-resume.sh, the Windows
# station's arming path, writes the SAME row rather than a second shape). It is
# a row in the launch record dir (${HIMMELCTL_CACHE_DIR:-
# $HOME/.claude/himmel}/launch-logs/<session>.log, btrfs, not the tmpfs arm log
# that a reboot erases), keyed `headed-arm:` so it cannot read as a worker's
# `headed-arm-worker:` profile line. The prefix is shared on purpose: the reader
# (sc_launch_context, spec 2973 sec 2.4) asks what mode the SESSION received,
# not which launcher armed it, and a second prefix would leave every
# arm-resume chief `unknown` until each reader learns it.
#
# Best-effort: rc 0 iff the row was appended; rc 1 otherwise, and the caller
# says so in its own log (a lost record is `unknown` to the reader, never a
# proxy). A session name that is empty or carries `/` is refused here -- it is
# a filename component. Sets CHIEF_CONTEXT_RECORD_DIR (the dir the row went,
# or would have gone, to) for the caller's warning.
# shellcheck disable=SC2034  # output-contract global, read by sourcing callers
chief_context_write_record() {
    CHIEF_CONTEXT_RECORD_DIR="${HIMMELCTL_CACHE_DIR:-}"
    [ -z "$CHIEF_CONTEXT_RECORD_DIR" ] && [ -n "${HOME:-}" ] && CHIEF_CONTEXT_RECORD_DIR="$HOME/.claude/himmel"
    [ -n "$CHIEF_CONTEXT_RECORD_DIR" ] && CHIEF_CONTEXT_RECORD_DIR="$CHIEF_CONTEXT_RECORD_DIR/launch-logs"
    case "$1" in ""|*/*) return 1 ;; esac
    [ -n "$CHIEF_CONTEXT_RECORD_DIR" ] || return 1
    ( umask 077 && mkdir -p "$CHIEF_CONTEXT_RECORD_DIR" && \
        printf 'headed-arm: role=chief session=%s context=%s source=%s autocompact=%s launched=%s\n' \
            "$1" "$2" "$3" "$4" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            >> "$CHIEF_CONTEXT_RECORD_DIR/$1.log" ) 2>/dev/null
}

# chief_context_worker_env_unset_names -- prints, one per line, every env var
# name scripts/handover/chief-kit/headed-arm-worker.sh sets on a worker itself,
# via worker_propagate_env (crosses macOS's `open -a` boundary too) or a plain
# `export` (crosses via ordinary fork/exec inheritance to every descendant of
# the long-running worker process, not just its immediate child). A worker's own
# shell keeps every one of these live for its whole session, so a later
# `chief.sh next --arm` run from inside that shell inherits them unless the
# caller strips this exact set first -- do_arm() in chief.sh
# is that caller. headed-arm-worker.sh is read-only (its own handling is queued
# separately); test-chief.sh asserts this list still names every
# `worker_propagate_env NAME` call site there, so a name added to that file
# without a matching line here fails the sync test instead of leaking silently.
chief_context_worker_env_unset_names() {
    printf '%s\n' \
        HANDOVER_DIR \
        CR_TRIGGER_SUPPRESS \
        HIMMEL_API_LANE \
        HIMMEL_API_ACCOUNT \
        IMPL_GUARD_OK \
        INLINE_IMPL_OK \
        HIMMEL_CONSOLE_LEG \
        HIMMEL_CONSOLE_NAME \
        HIMMEL_BUS_NAME \
        HIMMEL_READ_CLAMP_LINES \
        HIMMEL_CONSOLE_RELAY \
        HIMMEL_CONSOLE_JUDGE \
        HIMMEL_CONSOLE_JUDGE_DOC \
        HIMMEL_CONSOLE_JUDGE_QID \
        HIMMEL_RELEASE_MANAGER \
        HIMMEL_RM_DOC \
        HIMMEL_RM_RELEASE \
        HIMMEL_WORKER_SESSION_CONTEXT_MODE \
        HIMMEL_WORKER_SESSION_AUTOCOMPACT \
        CLAUDE_CODE_EFFORT_LEVEL \
        CLAUDEX_LANE_OK \
        WORKER_SESSION_LANE \
        CADENCE_USAGE_LANE \
        OPENROUTER_MODEL \
        CODEX_MODEL \
        WORKER_SESSION_PROFILE_SETTINGS \
        WORKER_SESSION_PROFILE_PREFACE \
        WORKER_SESSION_PROFILE_MCP_CONFIG \
        WORKER_SESSION_PROFILE_NO_SETTING_SOURCES \
        WORKER_SESSION_ID \
        WORKER_SESSION_REMOTE_CONTROL \
        HIMMEL_WORKER_SESSION_PROFILE \
        WORKER_SESSION_CLAUDE_BIN \
        HIMMEL_LEAN_WORKER_SESSION \
        WORKER_SESSION_EFFORT \
        HEADED_ARM_UNAME \
        HEADED_ARM_REQUIRED_AUTOCOMPACT \
        HEADED_ARM_LAUNCHER \
        HEADED_ARM_RECORDER \
        HEADED_ARM_LAUNCHER_ENV
}

# chief_context_launch_seam_env_names -- prints, one per line, the names in
# the list above that only choose HOW a later headed-arm launch builds its
# claude argv (the shim, its binary and its profile flags), never who the
# session is or which guards it runs under. arm-resume.sh clears exactly these
# in its `at` job body (F2): `at` snapshots the submitter's env, so
# an arm made from inside a consult would otherwise hand the resumed session
# WORKER_SESSION_PROFILE_NO_SETTING_SOURCES
# and friends. The rest of the list stays live
# there on purpose: HIMMEL_CONSOLE_LEG turns worker-only guard hooks ON and
# HANDOVER_DIR names the root, so clearing them would widen, not narrow.
chief_context_launch_seam_env_names() {
    printf '%s\n' \
        WORKER_SESSION_PROFILE_SETTINGS \
        WORKER_SESSION_PROFILE_PREFACE \
        WORKER_SESSION_PROFILE_MCP_CONFIG \
        WORKER_SESSION_PROFILE_NO_SETTING_SOURCES \
        WORKER_SESSION_ID \
        WORKER_SESSION_REMOTE_CONTROL \
        WORKER_SESSION_CLAUDE_BIN \
        HEADED_ARM_LAUNCHER \
        HEADED_ARM_LAUNCHER_ENV
}
