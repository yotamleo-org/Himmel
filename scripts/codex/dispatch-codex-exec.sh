#!/usr/bin/env bash
# scripts/codex/dispatch-codex-exec.sh - the codex-exec lane's dispatch
# chokepoint.
#
# WHY: the lane's safety requirements must be structural, not prose (the
# lanes.json row alone cannot enforce them). This wrapper encodes the
# invariants at the single entry point (arg checks run first,
# then the preflight, then codex - nothing reaches codex unchecked):
#   1. ACL preflight: normalize-worktree-acl.sh <worktree> runs before the
#      codex CLI is invoked and aborts the dispatch on failure (Windows
#      aged-worktree SID gap; the preflight is a no-op on other platforms).
#   2. Model defaults to the codex critic in scripts/cr/critics.json unless
#      caller-named (codex-variant model names 400 under ChatGPT-plan auth).
#   3. --background refused (upstream: background jobs die silently; use the
#      default --wait behavior + scripts/codex/companion-liveness.sh).
#   4. Workspace-redirect (-C/--cd/--add-dir) and sandbox-widening flags
#      refused - the preflight covers only the dispatched worktree.
#   5. Shared-branch mode, opt-in: the caller
#      names an EXISTING branch the worktree must already be checked out on
#      (the caller states intent, the wrapper verifies reality - branch
#      match, never main/master, no uncommitted changes). On success the
#      wrapper acquires the single-writer lock (scripts/lib/shared-branch-
#      lock.sh) for the duration of the codex run so parallel lanes cannot
#      write the shared branch concurrently, and releases it on every
#      CATCHABLE exit path (an EXIT trap; a SIGKILL/hard-kill cannot be
#      trapped, so recover a leaked lock manually with the helper's release
#      verb). Exit 4 = the lock is held by another writer; recovery is the
#      lock helper's own release verb (see scripts/codex/README.md).
#      Default posture (no --shared-branch) is unchanged: own worktree, own
#      throwaway branch, no lock.
#   6. Job registry + descendant reap: the codex-exec CLI sandbox
#      leaks its own MCP-server fleet (npx/node children under cmd.exe
#      wrappers) that the app-server fingerprint cannot see (no
#      codex path marker survives on those processes once codex.exe is gone).
#      This wrapper now ALWAYS runs codex as a child (never exec's it, in
#      either path - exec would drop the trap below), records the child pid
#      under CODEX_JOBS_DIR right after it starts, and on EXIT reaps the
#      child's still-live descendants via reap-mcp-fleet.{sh,ps1} before
#      removing the registry entry. A stale registry entry (dispatcher killed
#      before its own EXIT trap ran) is still visible to reap-mcp-fleet's
#      registry-driven maintenance mode.
#   7. Reasoning-effort passthrough, opt-in: the caller may pass
#      --reasoning-effort <value> or --reasoning-effort=<value> with value in
#      none|low|medium|high|xhigh|max. The codex CLI has no native flag for
#      this - the wrapper validates the enum, strips the raw flag from the
#      passthrough, and translates it into a trusted `-c
#      model_reasoning_effort="<value>"` override appended to pin_args (the
#      caller-supplied `-c`/`--config` flag itself stays refused above; only
#      this wrapper-computed override is emitted). Does NOT change the
#      model selection below; this flag only lets the default (or a
#      caller-named model) run at a non-default reasoning effort.
#   8. Watchdog + ledger: the wait below
#      used to be UNBOUNDED, so a wedged headless run was invisible - no
#      timeout, no kill, and (unlike the codex-wsl twin) no flow-run-ledger
#      row to show it had even started. Now:
#        - the run is timeboxed to CODEX_EXEC_TIMEOUT (default 1800s, the
#          codex-exec lane's own `timeoutSeconds` in scripts/lanes/lanes.json
#          - registry METADATA that nothing used to enforce; the suite pins
#          the two together so they cannot drift apart silently);
#        - on expiry the process TREE is killed via scripts/lib/proc-tree.sh
#          (group signal, verified, Windows taskkill fallback), the dispatch
#          exits 124 - the code GNU `timeout` and run-shell-tests.sh already
#          use - and says so on stderr;
#        - start/end rows land in ~/.himmel/flow-runs.jsonl exactly as
#          dispatch-codex-wsl.sh writes them, outcome complete|timeout|error;
#        - the job-registry JSON is PRESERVED under $CODEX_JOBS_DIR/failed/
#          on a timeout or a nonzero exit instead of being deleted by the
#          EXIT trap, so the forensic trace outlives the failure. It leaves
#          the live-jobs glob ($JOBS_DIR/*.json) so reap-mcp-fleet's
#          maintenance scan does not re-report a dead job forever.
#      STDIN: `codex exec` reads stdin to EOF even when the prompt is argv
#      ("Reading additional input from stdin..."), so a tty OR an empty open
#      pipe blocks before a token is spent. Default to </dev/null; only an
#      explicit --stdin-brief passes the caller's stdin through.
#      Timeout evidence includes a reason, distinguishing an empty stdout
#      event log at kill time from a run that emitted output.
#   9. Hook-trust preflight: codex keys hook trust to the
#      absolute .codex/hooks.json path, so a fresh worktree runs with none of
#      himmel's hooks. The dispatch refuses (exit 2, before
#      the lock/ledger/registry) unless every hook of every event of the
#      worktree's hooks.json has a trusted entry in $CODEX_HOME/config.toml
#      whose hash equals the one codex recomputes, under a
#      primary checkout that resolves. There is no bypass:
#      --dangerously-bypass-hook-trust stays refused by the filter, and a
#      CODEX_BIN script naming it is refused too.
#
# Usage:
#   dispatch-codex-exec.sh --worktree <path> [--shared-branch <branch>] [--stdin-brief] [--reasoning-effort <none|low|medium|high|xhigh|max>] [--context-tier <272k|353k|900k>] [codex exec args...]
#
# Exit: codex rc, or stdout-relay rc if codex succeeded; watchdog timeout wins.
# Wrapper codes: 2 usage/refusal | 4 lock held | 124 watchdog timeout | 127 no codex
#
# Environment:
#   CODEX_BIN            Override the codex CLI (tests inject a stub).
#   CODEX_CRITICS_FILE   Override the model registry path (tests). Default-model
#                        resolution requires node; explicit overrides do not.
#   CODEX_ACL_NORMALIZE  Override the preflight script path (tests).
#   CODEX_HOOK_TRUST_CHECK  Override the hook-trust check (tests): a script
#                        taking <worktree>, rc 0 = trusted. Default: the
#                        built-in check against $CODEX_HOME/config.toml.
#   SBL_HELPER           Override the shared-branch-lock.sh path (tests).
#   CODEX_JOBS_DIR        Override the job registry dir (tests; default
#                         $HOME/.himmel/state/codex-exec-jobs).
#   CODEX_REAP_HELPER     Override the reap-mcp-fleet.sh path (tests).
#   CODEX_EXEC_TIMEOUT    Watchdog budget in seconds (default 1800 = the
#                         codex-exec lane's timeoutSeconds).
#   HIMMEL_FLOW_RUNS_LEDGER  Ledger path override (the flow-run-ledger lib's
#                         own var; tests point it at a temp file).
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

# CODEX_BIN and CODEX_HOOK_TRUST_CHECK are registered seams
# (scripts/chokepoints.json): refuse one that differs from the session's launch
# env. Sourced by BASH_SOURCE, never PATH's dirname, before any seam is read.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "dispatch-codex-exec.sh: cannot load $_csg_lib - refusing (HIMMEL-3914)" >&2
    exit 96
fi
chokepoint_seam_guard scripts/codex/dispatch-codex-exec.sh || exit 96

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="${CODEX_ACL_NORMALIZE:-$SCRIPT_DIR/normalize-worktree-acl.sh}"
CODEX="${CODEX_BIN:-codex}"
LOCK_HELPER="${SBL_HELPER:-$SCRIPT_DIR/../lib/shared-branch-lock.sh}"
JOBS_DIR="${CODEX_JOBS_DIR:-$HOME/.himmel/state/codex-exec-jobs}"
REAP_HELPER="${CODEX_REAP_HELPER:-$SCRIPT_DIR/reap-mcp-fleet.sh}"
# Invariant 8: the lane's timeoutSeconds, overridable per dispatch. Kept as a
# literal default rather than parsed out of lanes.json so the chokepoint has
# no JSON-reader dependency on its hot path; test-dispatch-codex-exec.sh
# asserts the two match, which is what actually prevents the drift.
EXEC_TIMEOUT="${CODEX_EXEC_TIMEOUT:-1800}"

# the passthrough-args filter is shared with dispatch-codex-wsl.sh.
# shellcheck source=codex-arg-filter.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/codex-arg-filter.sh"
# Invariant 8: the ledger the codex-wsl twin already writes, and the ONE
# process-tree kill - never a hand-rolled taskkill here.
# shellcheck source=../lib/flow-run-ledger.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/flow-run-ledger.sh"
# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/proc-tree.sh"

usage() {
    echo "usage: dispatch-codex-exec.sh --worktree <path> [--shared-branch <branch>] [--stdin-brief] [codex exec args...]" >&2
    exit 2
}

# codex-adv-style minimal JSON string escaping (backslash, quote) - mirrors
# shared-branch-lock.sh's _sbl_json_escape. Worktree paths on Windows carry
# backslashes that must not break the registry file's JSON.
_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Invariant 6 state, initialized up front (set -u safe) and read by the
# single composed EXIT trap below regardless of which early-exit path fires.
# WORKTREE/SHARED_BRANCH are declared here too (ahead of their normal parsing
# spot below) so the trap never trips set -u on an early usage() exit.
WORKTREE=""
SHARED_BRANCH=""
LOCK_ACQUIRED=""
CODEX_CHILD_PID=""
JOB_FILE=""
STARTED_AT=""
# Invariant 8 state.
RUN_ID=""
LEDGER_STARTED=""
EFFECTIVE_MODEL=""
CODEX_RC=""
WATCH_PID=""
TIMEOUT_FLAG=""
EVENT_LOG=""
OUTPUT_PID=""
STDIN_BRIEF=0

# Invariant 8: one end row per started run, emitted exactly once. `outcome`
# is explicit for the timeout path; otherwise derived from the exit code the
# same way the codex-wsl twin derives it.
_emit_end_row() {
    local rc="$1" outcome="${2:-}"
    if [ -z "$outcome" ]; then
        outcome="complete"
        [ "$rc" -eq 0 ] 2>/dev/null || outcome="error"
    fi
    flow_run_append "$(flow_run_row_end "codex-exec" "$RUN_ID" "" "$rc" "$outcome" 1 "")"
    LEDGER_STARTED=""
}

# Invariant 8: keep the registry entry as evidence instead of deleting it.
# Moved into failed/ rather than left in place so reap-mcp-fleet's live-jobs
# glob ($JOBS_DIR/*.json) does not keep re-reporting a job that is already
# dead. Clearing JOB_FILE disarms the EXIT trap's rm for this dispatch.
# A failed move still keeps the evidence (JOB_FILE is cleared either way, so
# the trap's rm never fires on it) but leaves it in the LIVE glob, where
# reap-mcp-fleet's maintenance scan will keep reporting a job that is already
# dead. Evidence beats glob hygiene, so the file stays - but say so, because a
# silently-degraded preserve is the exact shape this whole invariant exists to
# remove (panel codex-3).
_preserve_job_file() {
    [ -n "$JOB_FILE" ] && [ -f "$JOB_FILE" ] || return 0
    if ! { mkdir -p "$JOBS_DIR/failed" 2>/dev/null \
        && mv -f "$JOB_FILE" "$JOBS_DIR/failed/$(basename "$JOB_FILE")" 2>/dev/null; }; then
        echo "dispatch-codex-exec.sh: WARN could not move the job registry entry to $JOBS_DIR/failed/ - keeping it at $JOB_FILE instead (evidence preserved; reap-mcp-fleet's maintenance scan will report it as a dead job until removed)" >&2
    fi
    JOB_FILE=""
}

# Single composed EXIT trap.
# Registered once, up front, so every early-exit path (usage errors, deny-
# listed flags, preflight failure) also runs it - each branch below is a
# no-op until its guard var is actually set, so nothing fires for a dispatch
# that never reached codex.
# shellcheck disable=SC2329,SC2317 # invoked indirectly via `trap ... EXIT`
_dispatch_cleanup() {
    if [ -n "$WATCH_PID" ]; then
        kill -TERM -"$WATCH_PID" 2>/dev/null || kill -TERM "$WATCH_PID" 2>/dev/null
        wait "$WATCH_PID" 2>/dev/null
    fi
    if [ -n "$SHARED_BRANCH" ] && [ -n "$LOCK_ACQUIRED" ]; then
        bash "$LOCK_HELPER" release "$WORKTREE" "$SHARED_BRANCH"
    fi
    # Invariant 8: an abnormal-but-catchable exit between the start row and
    # the normal end row would otherwise leave a dangling start (the ledger's
    # own "still running" reading). Emit the end row here too - _emit_end_row
    # clears LEDGER_STARTED, so the normal path never double-writes.
    if [ -n "$LEDGER_STARTED" ]; then
        _emit_end_row "${CODEX_RC:-1}"
    fi
    if [ -n "$OUTPUT_PID" ]; then
        proc_tree_terminate "$OUTPUT_PID" >&2
        wait "$OUTPUT_PID" 2>/dev/null
    fi
    [ -n "$TIMEOUT_FLAG" ] && rm -f "$TIMEOUT_FLAG" 2>/dev/null
    [ -n "$EVENT_LOG" ] && rm -f "$EVENT_LOG" "$EVENT_LOG.fifo" 2>/dev/null
    if [ -n "$CODEX_CHILD_PID" ]; then
        bash "$REAP_HELPER" --root-pid "$CODEX_CHILD_PID" --started-at "$STARTED_AT" --kill || true
        [ -n "$JOB_FILE" ] && rm -f "$JOB_FILE" 2>/dev/null
    fi
    return 0
}
trap _dispatch_cleanup EXIT

# Invariant 8: a malformed budget must REFUSE, never silently degrade back to
# the unbounded wait this invariant exists to remove. The upper bound is not
# cosmetic: a digit string too large for `sleep` makes it exit IMMEDIATELY with
# "invalid time interval", which the watchdog would read as its budget having
# elapsed and kill a run that had just started (panel r3, dropped citation).
# 86400 = one day; a codex dispatch budget beyond that is a typo, not intent.
case "$EXEC_TIMEOUT" in
    ''|*[!0-9]*|0) echo "dispatch-codex-exec.sh: CODEX_EXEC_TIMEOUT must be a positive integer number of seconds, got '$EXEC_TIMEOUT'" >&2; exit 2 ;;
esac
# The length test comes FIRST and is not redundant: `[ <20-digit> -gt … ]`
# overflows bash's own integer conversion and returns an ERROR rc, which the
# `||` would read as "not too large" - letting through exactly the value this
# ceiling exists to refuse. Anything over 6 digits is already past 86400.
if [ "${#EXEC_TIMEOUT}" -gt 6 ] || [ "$EXEC_TIMEOUT" -gt 86400 ]; then
    echo "dispatch-codex-exec.sh: CODEX_EXEC_TIMEOUT=$EXEC_TIMEOUT exceeds the 86400s (1 day) ceiling - refusing (a value sleep cannot parse would fire the watchdog instantly and kill the run)" >&2
    exit 2
fi

if [ "${1:-}" = "--worktree" ]; then
    [ -n "${2:-}" ] || usage
    WORKTREE="$2"
    shift 2
fi
[ -n "$WORKTREE" ] || usage
[ -d "$WORKTREE" ] || { echo "dispatch-codex-exec.sh: worktree not found: $WORKTREE" >&2; exit 2; }

if [ "${1:-}" = "--shared-branch" ]; then
    [ -n "${2:-}" ] || usage
    SHARED_BRANCH="$2"
    shift 2
fi

# Wrapper-only opt-in, after --worktree/--shared-branch and before codex args.
if [ "${1:-}" = "--stdin-brief" ]; then
    STDIN_BRIEF=1
    shift
fi

# codex-adv r5: an arbitrary existing directory must not become a
# workspace-write codex workspace (the ACL preflight no-ops off-Windows, so it
# is not the path constraint). Canonicalize and require a .claude/worktrees
# path - the same containment rule normalize-worktree-acl.ps1 enforces.
# pwd -P (codex-adv final round): logical pwd would let a symlink/junction
# placed under .claude/worktrees satisfy the string check while the physical
# target lives outside it. Dispatch uses the PHYSICAL path too.
WT_ABS="$(cd "$WORKTREE" 2>/dev/null && pwd -P)" || { echo "dispatch-codex-exec.sh: cannot resolve worktree: $WORKTREE" >&2; exit 2; }
case "$WT_ABS" in
    */.claude/worktrees/*) ;;
    *) echo "dispatch-codex-exec.sh: refusing worktree outside .claude/worktrees: $WT_ABS (the lane dispatches only into repo worktrees)" >&2; exit 2 ;;
esac
WORKTREE="$WT_ABS"

# Invariant 5: shared-branch mode gate. Trunk is checked FIRST
# and unconditionally - main/master is refused as the requested branch
# regardless of what the worktree actually has checked out (fail fast on an
# obviously-wrong request before doing any git introspection). Then the
# caller's stated intent is verified against reality (branch match), then
# the tree must be clean - a shared handoff starts from committed state,
# not an ambient local diff a concurrent writer would never see.
if [ -n "$SHARED_BRANCH" ]; then
    case "$SHARED_BRANCH" in
        main|master) echo "dispatch-codex-exec.sh: --shared-branch refuses trunk branch '$SHARED_BRANCH' - never point a worker at main/master" >&2; exit 2 ;;
    esac
    CURRENT_BRANCH="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null)" || { echo "dispatch-codex-exec.sh: cannot resolve the checked-out branch for $WORKTREE" >&2; exit 2; }
    if [ "$CURRENT_BRANCH" != "$SHARED_BRANCH" ]; then
        echo "dispatch-codex-exec.sh: --shared-branch '$SHARED_BRANCH' does not match the worktree's checked-out branch '$CURRENT_BRANCH' - the caller names the intent, the wrapper verifies the reality" >&2
        exit 2
    fi
    WT_STATUS="$(git -C "$WORKTREE" status --porcelain 2>/dev/null)" || { echo "dispatch-codex-exec.sh: cannot determine worktree status for $WORKTREE" >&2; exit 2; }
    if [ -n "$WT_STATUS" ]; then
        echo "dispatch-codex-exec.sh: --shared-branch '$SHARED_BRANCH' refused - worktree has uncommitted changes (shared handoff starts from committed state)" >&2
        exit 2
    fi
fi

# shellcheck disable=SC2034 # read by the sourced arg filter.
CAF_ACCEPT_CONTEXT_TIER=1
if ! codex_filter_passthrough_args "$@"; then
    exit 2
fi
have_model="$CAF_HAVE_MODEL"
have_sandbox="$CAF_HAVE_SANDBOX"
reasoning_effort="$CAF_REASONING_EFFORT"
# Invariant 10: the context tier is ALWAYS pinned (unstated = 272k, the cheapest),
# so an ambient CODEX_CONTEXT_WINDOW can never buy a pricier tier.
context_window="$CAF_CONTEXT_WINDOW"
export CODEX_CONTEXT_WINDOW="$context_window"
NEW_ARGS=()
if [ "${#CAF_NEW_ARGS[@]}" -gt 0 ]; then
    NEW_ARGS=("${CAF_NEW_ARGS[@]}")
fi
# Rebuild the positional args with --reasoning-effort/its value stripped
# (codex has no native flag for it - Invariant 7 translates it to -c below).
# The count guard avoids "${NEW_ARGS[@]}" on a zero-element array, which
# is an unbound-variable error under `set -u` on pre-4.4 bash (macOS ships
# 3.2 - this script is Bash 3.2 safe).
if [ "${#NEW_ARGS[@]}" -gt 0 ]; then
    set -- "${NEW_ARGS[@]}"
else
    set --
fi

# Invariant 1: ACL preflight, fail-closed.
if ! bash "$NORMALIZE" "$WORKTREE"; then
    echo "dispatch-codex-exec.sh: ACL preflight failed for $WORKTREE - dispatch aborted (manual recovery: bash scripts/codex/normalize-worktree-acl.sh <worktree>)" >&2
    exit 1
fi

# Invariant 9: hook-trust preflight, fail-closed. codex keys hook
# trust to the ABSOLUTE .codex/hooks.json path of the PRIMARY checkout (a linked
# worktree's hook discovery resolves there), so an untrusted tree would run the
# lane with no himmel hooks at all (an in-workspace force
# push succeeded). The filter refuses --dangerously-bypass-hook-trust, so the
# only honest options are to refuse or to run guarded: refuse unless every
# hook of the primary checkout's hooks.json has a trusted state entry in
# $CODEX_HOME/config.toml, and refuse a worktree whose own hooks.json differs
# from the primary's (the hooks in effect would not be the ones it carries). Runs before
# the lock, the ledger start row and the job registry, so a refusal leaves
# nothing behind. CODEX_HOOK_TRUST_CHECK swaps the check (tests; same idiom as
# CODEX_ACL_NORMALIZE): <script> <worktree>, rc 0 trusted, nonzero refuses.
# every hook of EVERY event is checked, and each trusted_hash must
# equal the hash codex recomputes from the hook definition (openai/codex
# rust-v0.161.0: hooks/src/engine/discovery.rs hook_hash() +
# config/src/fingerprint.rs version_for_toml(); see the port in the node program
# below), because an edited hooks.json under an already trusted path keeps a
# stale hash that codex silently drops. A primary checkout that cannot be
# resolved refuses instead of trusting the worktree's own path.
# ponytail: the port tracks codex-cli 0.161.0's identity shape (command hooks
# only; any other hook type refuses as unverifiable); a codex release that
# changes the identity refuses every dispatch until this is re-ported, which is
# the fail-closed direction - upgrade path is re-reading discovery.rs on a bump.
# ponytail: the hooks.json reader is a closed grammar (known keys only, integer
# tokens of at most 16 digits, nesting at most 32, matchers limited to literals
# and | ( ) . * + ? ^ $) because JS and serde/Rust parse-semantic differences kept
# surviving every open-ended refusal list; a valid hooks.json outside it (a
# bracket class or escape in a matcher, a new handler field) refuses, which is
# the fail-closed direction. Upgrade path is a Rust-regex-compatible validator
# and a schema generated from the codex release.
_hook_trust_check() {
    local wt="$1" hooks_json=""
    local cfg="${CODEX_HOME:-$HOME/.codex}/config.toml" primary_native="$1" primary="" common
    # codex resolves a LINKED worktree's hook discovery to the PRIMARY checkout's
    # .codex (rust-v0.161.0 config/src/state.rs hooks_config_folder, verified live
    # on a linked worktree: hooks/list reports the primary's hooks.json path), so
    # the file whose hooks run, and whose hashes codex recomputes, is the
    # primary's - never the worktree's own copy.
    common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    case "$common" in
        */.git) primary="${common%/.git}" ;;
        *) echo "cannot resolve the primary checkout of $wt (git-common-dir='${common:-unresolved}'): codex keys trust to that path, so the trust state cannot be verified" >&2; return 1 ;;
    esac
    hooks_json="$primary/.codex/hooks.json"
    [ -f "$hooks_json" ] || { echo "dispatch-codex-exec.sh: the primary checkout $primary has no .codex/hooks.json - the lane would run with no himmel hook chain" >&2; return 1; }
    if [ "$wt" != "$primary" ]; then
        if [ ! -f "$wt/.codex/hooks.json" ] || ! cmp -s "$wt/.codex/hooks.json" "$hooks_json"; then
            echo "$wt/.codex/hooks.json differs from (or is missing beside) the primary checkout's $hooks_json: codex runs the PRIMARY's hooks in a linked worktree, so the hooks in effect are not the ones this worktree carries" >&2
            return 1
        fi
    fi
    # Git Bash: codex on Windows keys trust to the native path spelling.
    primary_native="$primary"
    if command -v cygpath >/dev/null 2>&1; then
        primary_native="$(cygpath -w "$primary" 2>/dev/null || echo "$primary")"
    fi
    # shellcheck disable=SC2016 # JS source, no shell expansion intended
    node -e '
const fs = require("fs");
const [hooksFile, cfgFile, ...prefixes] = process.argv.slice(1);
// codex (hooks/src config: HooksFile is deny_unknown_fields, serde rejects wrong
// types and duplicate fields) loads ZERO hooks from a file that fails to parse,
// so this parse is strict in the same directions: duplicate keys, unknown
// top-level fields and wrong types refuse here instead of passing as trusted.
const parseStrict = (text) => {
    let i = 0;
    const ws = () => { while (i < text.length && " \t\n\r".includes(text[i])) i++; };
    const fail = (m) => { throw new Error(m + " at offset " + i); };
    const str = () => {
        const start = i;
        i++;
        while (i < text.length && text[i] !== "\"") { if (text[i] === "\\") i++; i++; }
        if (i >= text.length) fail("unterminated string");
        i++;
        const s = JSON.parse(text.slice(start, i));
        // serde_json rejects a lone surrogate escape that JSON.parse accepts, and
        // codex then loads no hook at all.
        if (/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/.test(s)) fail("lone surrogate escape in a string");
        return s;
    };
    // serde_json stops at 128 levels; a shallower closed cap keeps the two readers
    // from ever disagreeing on a deep document.
    const val = (depth = 0) => {
        ws();
        const c = text[i];
        if ((c === "{" || c === "[") && depth >= 32) fail("nesting deeper than 32");
        if (c === "{") {
            i++;
            const o = Object.create(null);
            ws();
            if (text[i] === "}") { i++; return o; }
            for (;;) {
                ws();
                if (text[i] !== "\"") fail("expected an object key");
                const k = str();
                if (Object.prototype.hasOwnProperty.call(o, k)) fail("duplicate key " + JSON.stringify(k));
                ws();
                if (text[i] !== ":") fail("expected a colon");
                i++;
                o[k] = val(depth + 1);
                ws();
                if (text[i] === ",") { i++; continue; }
                if (text[i] === "}") { i++; return o; }
                fail("expected a comma or a closing brace");
            }
        }
        if (c === "[") {
            i++;
            const a = [];
            ws();
            if (text[i] === "]") { i++; return a; }
            for (;;) {
                a.push(val(depth + 1));
                ws();
                if (text[i] === ",") { i++; continue; }
                if (text[i] === "]") { i++; return a; }
                fail("expected a comma or a closing bracket");
            }
        }
        if (c === "\"") return str();
        const m = /^[^\s,\]}]+/.exec(text.slice(i));
        if (!m) fail("unexpected token");
        i += m[0].length;
        if (m[0] === "true" || m[0] === "false" || m[0] === "null") return JSON.parse(m[0]);
        // Closed number grammar: the only accepted token is a plain non-negative
        // integer of at most 16 digits. A float, an exponent, a minus, a leading
        // zero or an out-of-range number is read differently (or rejected) by
        // serde_json, so it refuses here wherever it appears, known field or not.
        if (!/^(?:0|[1-9][0-9]{0,15})$/.test(m[0])) fail("number token " + JSON.stringify(m[0].slice(0, 24)) + " is outside the accepted grammar");
        return JSON.parse(m[0]);
    };
    const v = val();
    ws();
    if (i !== text.length) fail("trailing content");
    return v;
};
let hooks;
try {
    // fatal decoder: an invalid UTF-8 byte is a read error for codex (no hooks
    // load), while a lenient decode would turn it into U+FFFD and pass.
    hooks = parseStrict(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(fs.readFileSync(hooksFile)));
} catch (error) {
    console.error("codex would load no hooks from " + hooksFile + ": " + error.message);
    process.exit(2);
}
const crypto = require("crypto");
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isStrOrNull = (v) => v === undefined || v === null || typeof v === "string";
// isSafeInteger, not isInteger: a value past 2^53 (1e20 overflows u64 and codex
// rejects the whole file) cannot be told apart from an in-range one after a JS
// parse, so the check refuses the whole band (fail-safe).
const isU64OrNull = (v) => v === undefined || v === null || (Number.isSafeInteger(v) && v >= 0);
const shape = [];
if (!isObj(hooks)) {
    shape.push("top level is not an object");
} else {
    for (const k of Object.keys(hooks)) {
        if (k !== "description" && k !== "hooks") shape.push("unknown top-level field " + JSON.stringify(k));
    }
    if (!isStrOrNull(hooks.description)) shape.push("description is not a string");
    if (hooks.hooks !== undefined && !isObj(hooks.hooks)) shape.push("hooks is not an object");
}
if (shape.length) {
    console.error("codex would load no hooks from " + hooksFile + ": " + shape.join("; "));
    process.exit(2);
}
const events = hooks.hooks || {};
let cfg = "";
try { cfg = fs.readFileSync(cfgFile, "utf8"); } catch (error) { /* absent = nothing trusted */ }
// [hooks.state.<key>] tables: a literal (single-quoted) or basic ("...") key.
// trusted: key -> the trusted_hash string (enabled = false entries drop out).
const trusted = new Map();
let key = null, hash = null, off = false;
const flush = () => { if (key !== null && hash !== null && !off) trusted.set(key, hash); };
// A header-looking line inside a multi-line string is string content
// to codex, so track """ / \x27\x27\x27 across lines (single-line strings and
// comments skipped) and read only the lines that start outside one.
// The same for a line inside a multi-line array or inline table
// (bracket/brace depth outside strings): its [ line is an element, not a header.
let ml = null, depth = 0;
const trackStrings = (line) => {
    let i = 0;
    while (i < line.length) {
        if (ml !== null) {
            if (ml.charAt(0) === "\"" && line[i] === "\\") { i += 2; continue; }
            if (line.startsWith(ml, i)) {
                i += 3;
                for (let extra = 0; extra < 2 && line[i] === ml.charAt(0); extra++) i++;
                ml = null;
            } else i++;
            continue;
        }
        const c = line[i];
        if (c === "#") return;
        if (c === "\"" || c === "\x27") {
            if (line.startsWith(c + c + c, i)) { ml = c + c + c; i += 3; continue; }
            i++;
            while (i < line.length && line[i] !== c) i += (c === "\"" && line[i] === "\\") ? 2 : 1;
            i++;
            continue;
        }
        if (c === "[" || c === "{") depth++;
        else if ((c === "]" || c === "}") && depth > 0) depth--;
        i++;
    }
};
// TOML basic-string escapes: \b \t \n \f \r \e \" \\ \uXXXX \UXXXXXXXX \xHH. A key
// is compared decoded. Strict (header keys) returns null on \x, \e,
// an unknown escape or an invalid code point and the caller refuses the key:
// toml 1.0 fails the whole file on \x / \e and 1.1 decodes it, which one codex
// links is not verified, and the raw text could equal a real key that itself
// holds a backslash (a Windows path, a\x41).
const basicEsc = { b: "\b", t: "\t", n: "\n", f: "\f", r: "\r", e: "\x1b", "\"": "\"", "\\": "\\" };
const decodeBasic = (s, strict) => {
    let bad = false;
    const out = s.replace(/\\(?:u([0-9A-Fa-f]{4})|U([0-9A-Fa-f]{8})|x([0-9A-Fa-f]{2})|([\s\S]))/g,
        (all, u, big, x, ch) => {
            if (ch === undefined) {
                if (x !== undefined && strict) { bad = true; return all; }
                const cp = parseInt(u || big || x, 16);
                if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) { if (strict) bad = true; return all; }
                return String.fromCodePoint(cp);
            }
            if (!Object.prototype.hasOwnProperty.call(basicEsc, ch) || (strict && ch === "e")) {
                if (strict) bad = true;
                return strict ? all : ch;
            }
            return basicEsc[ch];
        });
    return bad ? null : out;
};
// The name of a key line, a quoted key decoded and trimmed: fail closed, so
// " enabled " and "enabled" both read as enabled.
const keyName = (raw) => {
    if (raw.charAt(0) === "\x27") return raw.slice(1, -1).trim();
    if (raw.charAt(0) !== "\"") return raw;
    return decodeBasic(raw.slice(1, -1), false).trim();
};
for (const line of cfg.split(/\r?\n/)) {
    const insideValue = ml !== null || depth > 0;
    trackStrings(line);
    if (insideValue) continue;
    if (/^\s*\[/.test(line)) {
        flush();
        const m = line.match(/^\s*\[hooks\.state\.(?:\x27([^\x27]+)\x27|"((?:[^"\\]|\\.)*)")\]\s*(?:#.*)?$/);
        // decodeBasic returns null for an escape it refuses: key = null trusts nothing.
        key = m ? (m[1] !== undefined ? m[1] : decodeBasic(m[2], true)) : null;
        hash = null; off = false;
    } else if (key !== null) {
        const h = line.match(/^\s*trusted_hash\s*=\s*"([^"]+)"/);
        if (h) hash = h[1];
        // codex reads enabled as a bool: anything but true discards the entry.
        // Positive form: [\s\S] in the comment tail, since `.` skips U+2028/U+2029.
        // The key may be quoted ("enabled", \x27enabled\x27).
        const kv = line.match(/^\s*("(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27|[A-Za-z0-9_-]+)\s*=([\s\S]*)$/);
        if (kv && keyName(kv[1]) === "enabled" && !/^\s*true\s*(?:#[\s\S]*)?$/.test(kv[2])) off = true;
    }
}
flush();
// An unterminated string, array or table is a config codex cannot parse: trust nothing.
if (ml !== null || depth > 0) trusted.clear();
// Port of codex hook_hash(): sha256 of the compact JSON, object keys sorted, of
// { event_name, matcher?, hooks: [normalized handler] }.
const labels = { PreToolUse: "pre_tool_use", PermissionRequest: "permission_request", PostToolUse: "post_tool_use", PreCompact: "pre_compact", PostCompact: "post_compact", SessionStart: "session_start", SessionEnd: "session_end", UserPromptSubmit: "user_prompt_submit", SubagentStart: "subagent_start", SubagentStop: "subagent_stop", Stop: "stop", Interrupt: "interrupt" };
const ctxEvents = new Set(["PreToolUse", "PostToolUse", "SessionStart", "UserPromptSubmit", "SubagentStart"]);
const sorted = (v) => Array.isArray(v) ? v.map(sorted)
    : (v && typeof v === "object") ? Object.keys(v).sort().reduce((o, k) => { o[k] = sorted(v[k]); return o; }, {})
    : v;
// codex drops the matcher before hashing for these events (matcher_pattern_for_event).
const noMatcherEvents = new Set(["UserPromptSubmit", "Stop", "Interrupt"]);
const expectedHash = (event, group, hook) => {
    const shortEvent = event === "SessionEnd" || event === "Interrupt";
    const t = Number.isInteger(hook.timeout) ? hook.timeout : undefined;
    const win = hook.commandWindows !== undefined ? hook.commandWindows : hook.command_windows;
    const handler = {
        type: "command",
        command: (process.platform === "win32" && typeof win === "string") ? win : hook.command,
        async: hook.async === true,
        timeout: shortEvent ? Math.min(Math.max(t === undefined ? 1 : t, 1), 3) : Math.max(t === undefined ? 600 : t, 1),
    };
    if (typeof hook.statusMessage === "string") handler.statusMessage = hook.statusMessage;
    if (ctxEvents.has(event) && Number.isInteger(hook.additionalContextLimit) && hook.additionalContextLimit !== 2500) {
        handler.additionalContextLimit = hook.additionalContextLimit;
    }
    const identity = { event_name: labels[event], hooks: [handler] };
    if (typeof group.matcher === "string" && !noMatcherEvents.has(event)) identity.matcher = group.matcher;
    return "sha256:" + crypto.createHash("sha256").update(JSON.stringify(sorted(identity))).digest("hex");
};
// Strict shape of the known events (serde: wrong types, a duplicated command
// alias, an unknown handler type or a missing required field fail the whole file
// and codex then loads no hook at all).
const badShape = [];
const matcherOk = (m) => {
    if (m === undefined || m === null || m === "" || m === "*") return true;
    // Closed matcher grammar: JS RegExp and the Rust regex crate disagree on
    // escapes, classes, counted repetition and lookaround, so only the subset both
    // read the same is accepted: literals [A-Za-z0-9_-], | ( ) . * + ? ^ $, no
    // backslash, no bracket, no brace. A quantifier needs an atom before it (and
    // may then take one lazy ?), groups balance to at most 16 deep (Rust refuses
    // past 250) and no alternative or group is empty.
    // No counted repetition, so the compiled size is linear in the
    // length; a length cap keeps it far under the Rust compile-size limit.
    // ponytail: a conservative length bound, not the crate real size accounting
    // (it refuses some matchers codex would compile); revisit if a legitimate
    // matcher over 1024 chars is ever refused, by compiling in the real crate.
    if (m.length > 1024) return false;
    let prev = "start", depth = 0, lazy = false;
    for (const c of m) {
        if (/[A-Za-z0-9_-]|\./.test(c)) { prev = "atom"; lazy = false; continue; }
        if (c === "(") { if (++depth > 16) return false; prev = "start"; continue; }
        if (c === ")") {
            if (depth === 0 || prev === "start" || prev === "alt") return false;
            depth--; prev = "atom"; lazy = false; continue;
        }
        if (c === "|") {
            if (prev === "start" || prev === "alt") return false;
            prev = "alt"; continue;
        }
        if (c === "^" || c === "$") { prev = "anchor"; continue; }
        if (c === "*" || c === "+" || c === "?") {
            if (prev === "atom") { prev = "quant"; lazy = false; continue; }
            if (prev === "quant" && c === "?" && !lazy) { lazy = true; continue; }
            return false;
        }
        return false;
    }
    if (depth !== 0 || prev === "start" || prev === "alt") return false;
    try { new RegExp(m, "u"); return true; } catch (error) { return false; }
};
const known = (o, keys) => Object.keys(o).filter((k) => !keys.includes(k));
const handlerKeys = {
    command: ["type", "command", "commandWindows", "command_windows", "timeout", "async", "statusMessage", "additionalContextLimit"],
    mcp_tool: ["type", "server", "tool", "timeout", "async", "statusMessage"],
    prompt: ["type", "prompt", "model", "timeout", "statusMessage"],
    agent: ["type", "prompt", "model", "timeout", "statusMessage"],
};
for (const event of Object.keys(events)) {
    if (!labels[event]) { badShape.push("unknown hook event " + JSON.stringify(event) + " (closed schema)"); continue; }
    const groups = events[event];
    if (!Array.isArray(groups)) { badShape.push(event + " is not an array"); continue; }
    groups.forEach((group, gi) => {
        const at = event + "[" + gi + "]";
        if (!isObj(group)) { badShape.push(at + " is not an object"); return; }
        for (const k of known(group, ["matcher", "hooks"])) badShape.push(at + " has unknown field " + JSON.stringify(k));
        if (!isStrOrNull(group.matcher)) badShape.push(at + ".matcher is not a string");
        if (group.hooks !== undefined && !Array.isArray(group.hooks)) { badShape.push(at + ".hooks is not an array"); return; }
        if (typeof group.matcher === "string" && !noMatcherEvents.has(event) && !matcherOk(group.matcher)) {
            badShape.push(at + ".matcher is not a valid regular expression (codex skips the group)");
        }
        (group.hooks || []).forEach((hook, hi) => {
            const h = at + ".hooks[" + hi + "]";
            if (!isObj(hook)) { badShape.push(h + " is not an object"); return; }
            if (typeof hook.type === "string" && Object.prototype.hasOwnProperty.call(handlerKeys, hook.type)) {
                for (const k of known(hook, handlerKeys[hook.type])) badShape.push(h + " has unknown field " + JSON.stringify(k));
            }
            if (hook.type === "command") {
                if (typeof hook.command !== "string") badShape.push(h + ".command is not a string");
                // codex skips a command that is empty after Rust str::trim (Unicode
                // White_Space; JS trim would also strip U+FEFF, which Rust keeps).
                else if ([...hook.command].every((ch) => { const n = ch.codePointAt(0); return (n >= 9 && n <= 13) || (n >= 0x2000 && n <= 0x200a) || [32, 0x85, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000].includes(n); })) badShape.push(h + ".command is empty (codex skips the hook)");
                if (hook.commandWindows !== undefined && hook.command_windows !== undefined) badShape.push(h + " carries both commandWindows and command_windows");
                if (!isStrOrNull(hook.commandWindows) || !isStrOrNull(hook.command_windows)) badShape.push(h + ".commandWindows is not a string");
                if (!isU64OrNull(hook.timeout)) badShape.push(h + ".timeout is not a non-negative integer");
                if (hook.async !== undefined && typeof hook.async !== "boolean") badShape.push(h + ".async is not a boolean");
                if (!isStrOrNull(hook.statusMessage)) badShape.push(h + ".statusMessage is not a string");
                if (!isU64OrNull(hook.additionalContextLimit)) badShape.push(h + ".additionalContextLimit is not a non-negative integer");
            } else if (hook.type === "mcp_tool") {
                if (typeof hook.server !== "string" || typeof hook.tool !== "string") badShape.push(h + " mcp_tool needs string server and tool");
            } else if (hook.type !== "prompt" && hook.type !== "agent") {
                badShape.push(h + ".type is not a known hook handler type");
            }
        });
    });
}
if (badShape.length) {
    console.error("codex would load no hooks from " + hooksFile + ": " + badShape.join("; "));
    process.exit(2);
}
const missing = [];
let preCount = 0;
for (const event of Object.keys(events)) {
    const groups = events[event] || [];
    if (!labels[event]) {
        if (Array.isArray(groups) && groups.some(g => isObj(g) && Array.isArray(g.hooks) && g.hooks.length)) missing.push(event + " (unknown hook event, cannot verify)");
        continue;
    }
    groups.forEach((group, gi) => (group.hooks || []).forEach((hook, hi) => {
        if (event === "PreToolUse") preCount++;
        const id = labels[event] + ":" + gi + ":" + hi;
        const suffix = "/.codex/hooks.json:" + id;
        const winSuffix = "\\.codex\\hooks.json:" + id;
        let found, hit = false;
        for (const p of prefixes) {
            for (const k of [p + suffix, p + winSuffix]) {
                if (trusted.has(k)) { hit = true; found = trusted.get(k); }
            }
        }
        if (!hit) { missing.push(id); return; }
        if (hook.type !== "command" || typeof hook.command !== "string") { missing.push(id + " (non-command hook, cannot verify its hash)"); return; }
        if (found !== expectedHash(event, group, hook)) missing.push(id + " (stale trusted_hash: hooks.json changed since it was trusted)");
    }));
}
if (preCount === 0) missing.push("pre_tool_use (hooks.json declares no PreToolUse hooks)");
if (missing.length) {
    console.error(missing.join(", "));
    process.exit(1);
}
' "$hooks_json" "$cfg" "$primary" "$primary_native"
}
if [ -n "${CODEX_HOOK_TRUST_CHECK:-}" ]; then
    echo "dispatch-codex-exec.sh: NOTE hook-trust check overridden by CODEX_HOOK_TRUST_CHECK=$CODEX_HOOK_TRUST_CHECK (test-only)" >&2
    bash "$CODEX_HOOK_TRUST_CHECK" "$WORKTREE"
    TRUST_RC=$?
    TRUST_MISSING=""
else
    TRUST_MISSING="$(_hook_trust_check "$WORKTREE" 2>&1)"
    TRUST_RC=$?
fi
if [ "$TRUST_RC" -ne 0 ]; then
    echo "dispatch-codex-exec.sh: hooks for $WORKTREE are not trusted - refusing to launch a lane with no himmel guard chain (untrusted: ${TRUST_MISSING:-see above}; trust state: ${CODEX_HOME:-$HOME/.codex}/config.toml)." >&2
    echo "dispatch-codex-exec.sh: remedy: open an interactive codex session in that worktree, review and trust its project hooks at the trust prompt, then re-dispatch. The lane offers no trust bypass." >&2
    exit 2
fi

# Invariant 5: acquire the single-writer lock now that the gate
# and the ACL preflight both passed. The composed EXIT trap (registered up
# front) releases on every CATCHABLE exit from here on (codex CLI missing,
# worktree vanishing, codex nonzero exit) once LOCK_ACQUIRED is set - a
# leaked lock is worse than a redundant release call. A SIGKILL/hard-kill is
# NOT catchable, so a crash there can still leak the lock; recover it
# manually with the helper's release verb (see scripts/codex/README.md).
if [ -n "$SHARED_BRANCH" ]; then
    bash "$LOCK_HELPER" acquire "$WORKTREE" "$SHARED_BRANCH" codex-exec
    SBL_RC=$?
    if [ "$SBL_RC" -ne 0 ]; then
        # Honest messaging (M1): rc 11 = genuinely held by another writer (the
        # helper already printed holder info to stderr); any other nonzero is a
        # usage/derivation/filesystem error from the helper, not contention.
        # Both still exit 4 (the lane's "lock not acquired" code).
        if [ "$SBL_RC" -eq 11 ]; then
            echo "dispatch-codex-exec.sh: shared-branch lock not acquired for '$SHARED_BRANCH' - another worker holds it (recovery: bash scripts/lib/shared-branch-lock.sh release <dir> <branch> if the holder is stale)" >&2
        else
            echo "dispatch-codex-exec.sh: shared-branch lock not acquired for '$SHARED_BRANCH' (rc=$SBL_RC) - the lock helper could not derive a git common dir or hit a filesystem error (see its stderr above)" >&2
        fi
        exit 4
    fi
    # Do NOT register a new trap here - the composed _dispatch_cleanup trap is
    # already active (registered up front); setting LOCK_ACQUIRED is enough
    # to arm its lock-release branch. This also keeps a lock held by another
    # writer (the rc-4 path above) untouched by our own trap.
    LOCK_ACQUIRED=1
fi

# The codex CLI must resolve before the tail exec (a bare bash "not found"
# line would not name the CODEX_BIN override; CR round-3 finding).
if ! command -v "$CODEX" >/dev/null 2>&1; then
    echo "dispatch-codex-exec.sh: codex CLI not found: $CODEX (install it or set CODEX_BIN)" >&2
    exit 127
fi

# the argv filter bounds the CALLER's flags, but CODEX_BIN can name
# a wrapper that adds --dangerously-bypass-hook-trust (or the sandbox/rules
# bypasses) itself. CODEX_BIN is a registered chokepoint seam (scripts/
# chokepoints.json), and here a resolved script (shebang) naming a refused flag
# is refused before launch, as is any such flag in the argv finally passed.
# ponytail: a static text scan of a script wrapper (HIMMEL-5347) - a compiled wrapper or a
# flag assembled at run time evades it; upgrade path is pinning CODEX_BIN to the
# resolved codex install (basename + realpath allowlist, no own CODEX_HOME).
CODEX_RESOLVED="$(command -v "$CODEX" 2>/dev/null || true)"
if [ -n "$CODEX_RESOLVED" ] && [ -f "$CODEX_RESOLVED" ] && [ "$(head -c 2 "$CODEX_RESOLVED" 2>/dev/null)" = "#!" ]; then
    if grep -qE -e '--dangerously-bypass-hook-trust|--dangerously-bypass-approvals-and-sandbox|--yolo|--ignore-rules' "$CODEX_RESOLVED" 2>/dev/null; then
        echo "dispatch-codex-exec.sh: refusing CODEX_BIN '$CODEX': the script names a refused trust/sandbox bypass flag (the lane's argv filter cannot see a wrapper's own flags)" >&2
        exit 2
    fi
fi

# The worktree can vanish between the -d check and here (the preflight takes
# real wall-clock) - name that failure distinctly from a preflight abort.
if ! cd "$WORKTREE"; then
    echo "dispatch-codex-exec.sh: worktree vanished before dispatch: $WORKTREE" >&2
    exit 1
fi

# Invariant 2: share the critic's model source.
# left this lane's pin divergent; that stale default later 404'd. Only an
# unreadable registry permits the named fallback; invalid content must refuse.
FALLBACK_MODEL="gpt-6.1-sol"
CRITICS_FILE="${CODEX_CRITICS_FILE:-$SCRIPT_DIR/../cr/critics.json}"
# Sandbox pin (codex-adv r4): ambient $CODEX_HOME/config.toml can default the
# sandbox to danger-full-access - always pass an EXPLICIT safe --sandbox when
# the caller did not name one, so ambient config cannot widen the run.
pin_args=""
if [ "$have_model" -eq 1 ]; then
    # Inspect only model values, not prompt text; leave caller argv untouched.
    model_value=""
    model_next=0
    for arg in "$@"; do
        if [ "$model_next" -eq 1 ]; then
            model_value="$arg"
            model_next=0
        else
            case "$arg" in
                --model|-m) model_next=1; continue ;;
                --model=*) model_value="${arg#--model=}" ;;
                -m=*) model_value="${arg#-m=}" ;;
                -m?*) model_value="${arg#-m}" ;;
                *) continue ;;
            esac
        fi
        case "$model_value" in
            *-codex) echo "dispatch-codex-exec.sh: WARN codex-variant model '$model_value' may return 400 on ChatGPT auth" >&2 ;;
        esac
    done
    EFFECTIVE_MODEL="caller-named"
else
    EFFECTIVE_MODEL="$FALLBACK_MODEL"
    if [ -r "$CRITICS_FILE" ]; then
        if ! EFFECTIVE_MODEL="$(node -e '
const fs = require("fs");
try {
    const registry = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const model = registry.panel.find(row => row.slug === "codex").model;
    // pin_args is word-split below: reject whitespace, glob and flag injection.
    if (typeof model !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:/-]*$/.test(model)) throw new Error("invalid codex model");
    process.stdout.write(model);
} catch (error) {
    console.error("dispatch-codex-exec.sh: cannot read codex critic model: " + error.message);
    process.exit(2);
}
' "$CRITICS_FILE")"; then
            exit 2
        fi
    fi
    pin_args="--model $EFFECTIVE_MODEL"
fi
if [ "$have_sandbox" -eq 0 ]; then
    pin_args="$pin_args --sandbox workspace-write"
fi
# Invariant 7: translate the validated --reasoning-effort enum
# into a trusted -c override (codex has no native flag for this). The value
# is quoted (a real TOML string) so it survives pin_args' later unquoted
# word-splitting as ONE argv token; the enum has no embedded whitespace so
# splitting on the surrounding space is safe.
if [ -n "$reasoning_effort" ]; then
    # shellcheck disable=SC2089  # the embedded quotes are intentional TOML string syntax for the -c override; see SC2090 note below where pin_args is expanded
    pin_args="$pin_args -c model_reasoning_effort=\"$reasoning_effort\""
fi
# Invariant 10: the tier also reaches codex itself as the trusted
# model_context_window override, unstated included (272k): native codex ignores
# CODEX_CONTEXT_WINDOW and would otherwise use its configured window.
pin_args="$pin_args -c model_context_window=$context_window"
# the argv codex is finally launched with never carries a refused
# trust/sandbox bypass flag, whatever built it (the caller args were already
# filtered; this covers the pin args and any later change to either).
# shellcheck disable=SC2086 # pin_args is a fixed, space-safe flag list
for _final_arg in $pin_args "$@"; do
    case "$_final_arg" in
        --dangerously-bypass-hook-trust|--dangerously-bypass-approvals-and-sandbox|--yolo|--ignore-rules)
            echo "dispatch-codex-exec.sh: refusing final argv carrying '$_final_arg'" >&2
            exit 2 ;;
    esac
done

# Invariants 5+6: NEVER exec codex in either path - exec
# replaces this process image, which would drop the composed EXIT trap above
# (losing both the shared-branch lock release and the fleet reap). Run codex
# as a background child so its pid is known immediately, register the job
# registry entry, then wait for it and propagate its exit code.
# Invariant 8: explicit <&0 preserves an opted-in brief
# across backgrounding. Otherwise use /dev/null even for non-tty stdin: an
# empty pipe held open by a tool harness is just as unbounded as a terminal.
STARTED_AT="$(date +%s)"
# Invariant 8: ledger start row BEFORE the spawn, so a dispatch that dies
# without ever reaching its end row still shows up as having started.
RUN_ID="codex-exec-$STARTED_AT-$$"
flow_run_append "$(flow_run_row_start "codex-exec" "$RUN_ID" "" "$(hostname 2>/dev/null || echo unknown)" "codex-exec" "$EFFECTIVE_MODEL" "$WORKTREE" "" "$$")"
LEDGER_STARTED=1
# The watchdog flag file is created empty and NON-empty means "the watchdog
# fired" (the `[ -s ]` idiom run-shell-tests.sh uses for the same handoff) -
# the watchdog subshell cannot set a variable in this shell.
# Created BEFORE the spawn, and a failure REFUSES rather than degrades (panel
# r2 codex-1): without the flag the watchdog would still kill the tree, but
# this shell could no longer TELL that it did - the run would report the
# child's bare signal status (143) instead of 124, skip the loud stderr line,
# keep no evidence, and cancel the watchdog mid-escalation. A watchdog whose
# verdict cannot be read is exactly the unobservable failure Invariant 8
# exists to remove, so it is not an acceptable degraded mode. Refusing here,
# before codex starts, also means nothing has been spent when it happens.
#
# The template is explicit: a BARE `mktemp` honours $TMPDIR on GNU but ignores it
# on macOS/BSD, so the flag/event files would land outside the
# caller's temp root. GNU's bare default is `$TMPDIR/tmp.XXXXXXXXXX`.
if ! TIMEOUT_FLAG="$(mktemp "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX" 2>/dev/null)" || [ -z "$TIMEOUT_FLAG" ]; then
    echo "dispatch-codex-exec.sh: cannot create the watchdog flag file (mktemp failed; TMPDIR=${TMPDIR:-<unset>}) - refusing to run codex with an unreadable watchdog verdict" >&2
    exit 2
fi
# Observe stdout (JSON events with --json), not stderr startup diagnostics.
# Retain only its first byte; the watchdog samples non-emptiness,
# not content. The owned relay forwards that byte and then the remaining stdin.
if ! EVENT_LOG="$(mktemp "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX" 2>/dev/null)" || [ -z "$EVENT_LOG" ]; then
    echo "dispatch-codex-exec.sh: cannot create the event log - refusing to run codex without timeout diagnostics" >&2
    exit 2
fi
# `set -m` puts the child in its OWN process group, which is what makes the
# watchdog's group signal reach codex's descendants instead of codex alone
# (scripts/lib/proc-tree.sh USAGE block). Restored immediately after.
set -m
# Own the relay separately so completion includes forwarded stdout without
# replacing the real codex PID in the job registry or process-tree watchdog.
# A one-byte read cannot overread the pipe, including binary/NUL output.
# Both stages belong to OUTPUT_PID's process group; && propagates either
# failure and keeps the existing wait/watchdog lifetime contract intact.
# A named pipe + real background subshell, NOT `exec 3> >(...)`: bash 3.2
# (stock macOS) does not make a process substitution a child of this shell,
# so `wait "$OUTPUT_PID"` below failed rc=127 there. The reader opens the fifo
# first (backgrounded, so it blocks harmlessly) and the `exec 3>` opens the
# write end, releasing both; the path is unlinked as soon as both ends are open.
EVENT_FIFO="$EVENT_LOG.fifo"
if ! mkfifo "$EVENT_FIFO" 2>/dev/null; then
    echo "dispatch-codex-exec.sh: cannot create the stdout relay fifo (mkfifo failed) - refusing to run codex without timeout diagnostics" >&2
    exit 2
fi
( dd bs=1 count=1 of="$EVENT_LOG" 2>/dev/null && cat "$EVENT_LOG" - ) < "$EVENT_FIFO" &
OUTPUT_PID=$!
exec 3> "$EVENT_FIFO"
rm -f "$EVENT_FIFO"
if [ "$STDIN_BRIEF" -eq 0 ]; then
    # shellcheck disable=SC2086,SC2090  # pin_args is a fixed, space-safe flag list built above; embedded quotes are intentional, single argv tokens once split
    "$CODEX" exec $pin_args "$@" </dev/null >&3 3>&- &
else
    # shellcheck disable=SC2086,SC2090  # see above
    "$CODEX" exec $pin_args "$@" <&0 >&3 3>&- &
fi
CODEX_CHILD_PID=$!
exec 3>&-
# Invariant 8: the watchdog. Its own group too, so standing it down below
# takes its `sleep` with it rather than leaking one sleeper per dispatch.
( sleep "$EXEC_TIMEOUT"
  # Flag BEFORE terminating, not after: proc_tree_terminate spends its TERM
  # grace before returning, and by then the parent's `wait` has already been
  # released by the kill and stood this watchdog down - the flag would never
  # be written and a killed run would report the child's bare 143.
  # rc 1 = the probe CONFIRMS the child had already exited, i.e. it finished
  # in the instant before this fired. Nothing to kill, nothing to claim.
  proc_tree_process_alive "$CODEX_CHILD_PID"
  if [ "$?" -eq 1 ]; then
      # A finished codex can still have output queued in the relay. Its wait
      # must stay bounded too, including a descendant holding stdout open.
      proc_tree_process_alive "$OUTPUT_PID"
      [ "$?" -eq 1 ] && exit 0
  fi
  if [ -s "$EVENT_LOG" ]; then
      printf 'timeout after %ss\n' "$EXEC_TIMEOUT" > "$TIMEOUT_FLAG"
  else
      printf 'no events before timeout — stdin pass-through?\n' > "$TIMEOUT_FLAG"
  fi
  proc_tree_terminate "$CODEX_CHILD_PID" >&2
  proc_tree_terminate "$OUTPUT_PID" >&2 ) &
WATCH_PID=$!
set +m

# Job registry: one file per job so a leaked fleet (dispatcher
# killed before its own EXIT trap ran) is still visible to reap-mcp-fleet's
# registry-driven maintenance mode. Best-effort: a write failure here does
# not abort the dispatch - the at-source reap below still works off
# CODEX_CHILD_PID/STARTED_AT regardless of whether the registry file exists.
mkdir -p "$JOBS_DIR" 2>/dev/null
JOB_FILE="$JOBS_DIR/${STARTED_AT}-${CODEX_CHILD_PID}.json"
printf '{"codex_pid":%s,"dispatch_pid":%s,"worktree":"%s","started_at":%s}\n' \
    "$CODEX_CHILD_PID" "$$" "$(_json_escape "$WORKTREE")" "$STARTED_AT" \
    > "$JOB_FILE" 2>/dev/null

wait "$CODEX_CHILD_PID"
CODEX_RC=$?
wait "$OUTPUT_PID"
OUTPUT_RC=$?
OUTPUT_PID=""
# A successful child is not a successful dispatch if stdout forwarding failed.
# Preserve the child's failure when both fail; the watchdog still wins below.
if [ "$CODEX_RC" -eq 0 ] && [ "$OUTPUT_RC" -ne 0 ]; then
    CODEX_RC=$OUTPUT_RC
fi

# Invariant 8: reading the flag is race-free here - `wait` has returned, so a
# watchdog that has not flagged yet will find the child confirmed gone and
# flag nothing. Whether to stand it down depends on WHY the child is gone
# (run-shell-tests.sh's asymmetry): if the watchdog is the reason, it may be
# mid-escalation and cancelling it would strand the survivor it was about to
# SIGKILL - let it finish. Otherwise it is still asleep; cancel it (group
# signal first, so its own `sleep` goes too, rather than leaking a sleeper
# per dispatch).
if [ -s "$TIMEOUT_FLAG" ]; then
    wait "$WATCH_PID" 2>/dev/null
else
    kill -TERM -"$WATCH_PID" 2>/dev/null || kill -TERM "$WATCH_PID" 2>/dev/null
    wait "$WATCH_PID" 2>/dev/null
fi
WATCH_PID=""

if [ -s "$TIMEOUT_FLAG" ]; then
    # LOUD: the whole point of this invariant is that a wedged unattended run
    # can no longer end quietly. 124 is what GNU `timeout` and
    # run-shell-tests.sh already report, so downstream readers keep their
    # meaning.
    CODEX_RC=124
    echo "dispatch-codex-exec.sh: codex-exec: TIMEOUT after ${EXEC_TIMEOUT}s - killed tree (worktree $WORKTREE, run $RUN_ID; raise the budget with CODEX_EXEC_TIMEOUT, evidence kept at $JOBS_DIR/failed/)" >&2
    _emit_end_row 124 timeout
    # Keep the existing registry fields; add only the watchdog's diagnosis.
    IFS= read -r TIMEOUT_REASON < "$TIMEOUT_FLAG"
    if [ -f "$JOB_FILE" ]; then
        printf '{"codex_pid":%s,"dispatch_pid":%s,"worktree":"%s","started_at":%s,"reason":"%s"}\n' \
            "$CODEX_CHILD_PID" "$$" "$(_json_escape "$WORKTREE")" "$STARTED_AT" \
            "$(_json_escape "$TIMEOUT_REASON")" > "$JOB_FILE"
    fi
    _preserve_job_file
elif [ "$CODEX_RC" -ne 0 ]; then
    _emit_end_row "$CODEX_RC"
    _preserve_job_file
else
    _emit_end_row 0
fi
exit "$CODEX_RC"
