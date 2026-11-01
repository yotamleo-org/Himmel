#!/usr/bin/env bash
# cadence-format.sh — shared runner-format version + staleness probe for
# generated cadence runners.
#
# Cadence runners (.sh) are GENERATED artifacts, baked at arm time by the
# cadence emitters. They hard-code paths/payload config and are NOT regenerated
# when the himmel code changes. So an operator who armed BEFORE a runner-format
# change keeps firing stale runners with no nudge (this is exactly what bit
# the --settings injection only took effect after a manual
# `arm --force`).
#
# This lib is the single source of truth: WRITERS stamp
# CADENCE_RUNNER_FORMAT_VERSION into every runner at arm time, and the READERS
# (himmel-doctor C8, himmel-update post-pull nudge) probe the stamp to detect
# stale armed cadences and point the operator at the matching `arm --force`.
#
# Sourced, not executed. bash 3.2-safe; no side effects.

# Bump when a runner/fragment format change requires an ALREADY-armed cadence to
# be re-armed (--force) to take effect. Runners armed before the stamp existed
# carry no marker and read as version 0 (stale). New users (first arm after a
# bump) get the current version automatically, so they never false-positive.
#
# v2: per-worker --model pins injected into every runner + the
# synthesize/health frequency shift (weekly→daily, monthly→weekly). An armed
# v1 cadence still fires, but on the OLD frequencies with NO model pin (so it
# inherits the operator's saved default tier) — nudge `arm --force`.
# v3: flow-run ledger start/end rows around each fired runner.
# v4: the pipeline-cadence --settings fragment now carries an
# enabledPlugins block that force-enables obsidian-triage@himmel (the operator
# disables it interactively; the nightly cadence must re-enable it). An armed
# v3 cadence fires with the OLD fragment (no enabledPlugins), so once the
# interactive disable lands the pipeline runs with the plugin OFF — nudge
# `arm --force` to regenerate the fragment. Same class as the bug
# noted at the top of this file.
# v7: the generated cron runner takes a self-overlap lock before
# rotating its log and firing the payload. cron has no MultipleInstancesPolicy,
# so the POSIX worker was the unguarded one — and once `qmd-cadence.sh arm
# --ship-to` can point that runner at ship-index.sh, two overlapping runs race
# on the receiver's single `<target>.preship` rollback copy and can leave no
# recoverable index. An armed v6 cron runner keeps firing WITHOUT the lock, so
# an operator running the cadence on POSIX must `arm --force` to pick it up.
# v13: the pipeline FetchHealth cron runner now writes flow-run ledger
# start/end rows like every other worker — an armed v12 runner keeps firing with
# NO ledger row, so that worker stays invisible to stall / never-started
# detection and "stopped firing" is indistinguishable from "never armed".
# v14: the three pipeline CLAUDE workers wrap
# their claude invocation in a bounded retry/resume loop — up to 3 attempts,
# 60s then 180s backoff, and ONLY when the attempt's own log carries the
# transient upstream signature (`API Error: … Server error / overloaded / 5xx /
# mid-response`); every attempt lands its own flow-run ledger row pair tagged
# `attempt=N/3`. An armed v13 runner keeps firing with NO retry, so a worker that
# dies on a transient API error (the 2026-07-17 harvest, 48 minutes in, 7 clips
# already harvested) still just sits unfinished until a human notices. Re-arm
# with `pipeline-cadence.sh arm --force`. The other cadences are unaffected but
# stamp v14 too, so one version answers "is this runner current".
# v15: the three pipeline CLAUDE workers gate before they spend.
# Every one of them now runs scripts/lib/usage-preflight.sh first (with
# CADENCE_USAGE_WORKER set, so ~/.himmel/cadence-ledger.jsonl finally attributes the
# spend instead of logging leg:"unknown") and passes an explicit
# --permission-mode; the synthesize worker additionally runs the free
# scripts/luna/synth-input-check.sh and skips the session outright on a night
# with no newly triaged clips. A v14 runner has NO bank guard at all — it is the
# shape the 2026-08-23 cadence audit found spending the subscription bank
# unconditionally every night — so re-arm with
# `pipeline-cadence.sh arm --force`. The other cadences are unaffected but stamp
# v15 too, so one version still answers "is this runner current".
# v16: a new runner joins the stamped set — upstream-watch, the
# daily delta-gated scan of open upstream PRs/issues (replacing the resident
# 20-minute interactive-claude poller per the 2026-09-01 operator ruling). It
# fires a plain shell script (never claude), so there is nothing for a v15
# runner to have missed and no re-arm is needed for existing cadences; this
# bump exists only to add "upstream-watch" to CADENCE_RUNNER_BASENAMES below so
# its own runner participates in the same staleness-stamp convention.
# v17: the three pipeline POSIX runners (pipeline-harvest,
# pipeline-synthesize, pipeline-health) now stamp the FULL arm-time PATH
# snapshot instead of prepending only the node directory
# (`export PATH=<node_dir>:$PATH`) — the old line left every other arm-time
# user bin dir (~/.local/bin uv tools, bun, cargo, go) off PATH under cron's
# minimal PATH=/usr/bin:/bin, which is why the ig-media-enrich worker could not
# find gallery-dl. One shared helper (runner_path_snapshot in
# pipeline-cadence.sh) now feeds both the pipeline runners and the
# pipeline-fetch-health runner, so the two can no longer disagree. An armed
# v16 pipeline runner keeps firing with the old node-dir-only PATH; re-arm
# with `pipeline-cadence.sh arm --force` to pick up the full snapshot. The
# other cadences are unaffected but stamp v17 too, so one version still
# answers "is this runner current".
# v18: the pipeline-harvest runner's baked prompt now passes
# `--include-evidence` to /ig-media-enrich. Triage Phase 8 moves finished clips
# into Clippings/_evidence/ and the default selection skips that folder, so every
# reel left scope one step before enrichment (0 selected / 0 enriched). The
# prompt is BAKED into the runner at arm time — regenerating it needs an arm, the
# stamp only lets doctor/update flag the old runner — so an armed v17 harvest
# keeps firing the old prompt; re-arm with `pipeline-cadence.sh arm --force`. The
# other cadences are unaffected but stamp v18 too, so one version still answers
# "is this runner current".
# v19: the pipeline POSIX runners log `[PIPELINE-WORKER-FAILED ...]`,
# exit 3 on any zero-rc outcome short of complete, and call
# scripts/luna/cadence-alert.sh on a failure; the harvest prompt adds
# /x-media-enrich; the settings fragment allows the obsidian-triage commands.
# Re-arm with `pipeline-cadence.sh arm --force`.
# v20: the pipeline-harvest and pipeline-synthesize POSIX runners
# run obsidian-triage's daily-timeline.mjs after the worker (must-not-abort: a
# failure logs and never changes the runner's exit code). Re-arm with
# `pipeline-cadence.sh arm --force`.
# v21: the pipeline POSIX runners alert (`[PIPELINE-WORKER-FAILED
# cd-vault]`) when the cd into the vault fails. Re-arm with
# `pipeline-cadence.sh arm --force`.
# v22: the graphmap (luna/himmel semantic + ast-luna/ast-himmel),
# qmd-reindex and upstream-watch POSIX runners now write flow-run start/end rows
# and call scripts/luna/cadence-alert.sh `fail` on a failed worker / `clear` on a
# completed one, through cadence_posix_worker_start / cadence_posix_worker_end below.
# An armed v21 runner of those kinds fails silently and leaves no ledger row.
# The graphmap-publish runner is unchanged (graph-cadence.sh alerts and writes
# its own rows). The alert call pins the arm-time PATH so the sender finds bun
# under cron.
# Re-arm with
# `graphmap-cadence.sh|qmd-cadence.sh|upstream-watch-cadence.sh arm --force`.
# v23: the qmd-reindex runner also refreshes the salus named index
# (a second `qmd-reindex.sh --index salus` fire when salus.yml exists). An armed
# v22 qmd runner never refreshes it. Re-arm with `qmd-cadence.sh arm --force`.
# v24: every runner that launches claude loads CLAUDE_CODE_OAUTH_TOKEN from the
# operator's token file (~/.config/himmel/claude-oauth-token) when the variable
# is unset. On macOS the interactive login lives in the Keychain, which cron
# cannot read, so an armed v23 runner fails "Not logged in" on every fire. Re-arm
# with `pipeline-cadence.sh|graphmap-cadence.sh|drift-fix-cadence.sh arm --force`
# (claude workers only; the setup steps are in docs/setup/new-machine.md).
# shellcheck disable=SC2034  # consumed by sourcing scripts (pipeline-cadence/doctor/update)
CADENCE_RUNNER_FORMAT_VERSION=24

# Marker line stamped into each generated runner: `# <marker> N`.
CADENCE_FORMAT_MARKER="himmel-cadence-runner-format:"

# Basename registry for generated cadence runners. Keep explicit: a stray
# foreign *.sh in a runner dir must not poison the staleness probe.
# shellcheck disable=SC2034  # consumed by cadence_runner_stamp callers/tests
CADENCE_RUNNER_BASENAMES="pipeline-harvest pipeline-synthesize pipeline-health graphmap-luna graphmap-himmel qmd-reindex drift-fix fork-resync graphify-update-ggs upstream-watch graphmap-ast-luna graphmap-ast-himmel graphmap-publish-himmel graphmap-semantic-luna doctor-cadence"

# cadence_posix_worker_start <q_flow_lib> <flow> <task>
# cadence_posix_worker_end <q_flow_lib> <q_alert_lib> <flow> [ok_rcs] [skip_rcs]
# Print the shared flow-run + alert block of a generated POSIX runner,
# each line indented four spaces to sit inside the runner's `{ ... } >> "$log"`
# group. _start goes BEFORE the payload line, _end AFTER it; the runner must have
# set `log` and captured the payload's status in `_rc`. <q_*_lib> are already
# `%q`-quoted paths. ok_rcs / skip_rcs are space-separated exit codes: ok_rcs
# (default `0`) are a completed worker (clear the alert), skip_rcs a benign skip
# (record skipped, neither alert nor clear); every other rc is a failure. Check
# the payload's own exit-code contract before passing either list, or an
# expected non-zero exit pages the operator. Never changes the runner's own rc.
# shellcheck disable=SC2016  # single-quoted $log/$_rc are emitted literally for the runner's own /bin/sh
cadence_posix_worker_start() {
    printf '    _flow_run_id=$(%s --append-start %s "" "" "" "" %s "$log" "$$" 2>/dev/null) || _flow_run_id=\n' "$1" "$2" "$3"
}
# shellcheck disable=SC2016  # as above
cadence_posix_worker_end() {
    local q_flow_lib="$1" q_alert_lib="$2" flow="$3" ok="${4:-0}" skip="${5:-}" rc pat q_path
    pat=""
    for rc in $ok; do pat="$pat${pat:+|}$rc"; done
    printf '    case "$_rc" in\n'
    printf '        %s) _flow_outcome=complete ;;\n' "${pat:-0}"
    pat=""
    for rc in $skip; do pat="$pat${pat:+|}$rc"; done
    if [ -n "$pat" ]; then printf '        %s) _flow_outcome=skipped ;;\n' "$pat"; fi
    printf '        *) _flow_outcome=error ;;\n'
    printf '    esac\n'
    printf '    test "$_flow_run_id" != "" && %s --append-end %s "$_flow_run_id" "" "$_rc" "$_flow_outcome" "" "" >/dev/null 2>&1 || true\n' "$q_flow_lib" "$flow"
    printf '    case "$_flow_outcome" in\n'
    # The alert sender needs bun, which lives off cron's minimal PATH: pin the
    # ARM-time PATH onto the alert calls only, never the payload's.
    q_path=$(printf '%q' "$PATH")
    printf '        complete) PATH=%s %s clear %s || true ;;\n' "$q_path" "$q_alert_lib" "$flow"
    printf '        error) PATH=%s %s fail %s "rc-$_rc" "$log" || true ;;\n' "$q_path" "$q_alert_lib" "$flow"
    printf '    esac\n'
}

# Shared home resolution for cadence emitters and staleness readers.
cadence_user_home() {
    printf '%s' "${HOME:-/tmp}"
}

# cadence_oauth_token_lines
# Print the POSIX-sh lines a runner that launches claude puts right after its
# PATH line: when CLAUDE_CODE_OAUTH_TOKEN is unset or empty and the token file is
# a readable regular file, export the file's first line (CR/LF stripped). The
# default path is baked at arm time from the arming user's home; the
# HIMMEL_CLAUDE_TOKEN_FILE override is read at fire time. A missing file changes
# nothing and prints nothing, and the value is never echoed, logged or traced.
# shellcheck disable=SC2016  # the runner's own $vars are emitted literally
cadence_oauth_token_lines() {
    local q_default
    q_default=$(printf '%q' "$(cadence_user_home)/.config/himmel/claude-oauth-token")
    printf '%s\n' '# cron cannot read the macOS Keychain login: load the OAuth token from its file'
    printf '%s\n' 'if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then'
    printf '    _tokf=${HIMMEL_CLAUDE_TOKEN_FILE:-%s}\n' "$q_default"
    printf '%s\n' '    if [ -f "$_tokf" ] && [ -r "$_tokf" ]; then'
    printf '%s\n' '        _tok=$(head -n 1 "$_tokf" 2>/dev/null | tr -d "\r\n") || _tok='
    printf '%s\n' '        if [ -n "$_tok" ]; then CLAUDE_CODE_OAUTH_TOKEN=$_tok; export CLAUDE_CODE_OAUTH_TOKEN; fi'
    printf '%s\n' '    fi'
    printf '%s\n' '    unset _tokf _tok'
    printf '%s\n' 'fi'
}

# cadence_runner_stamp <runner_dir>
# Echo the MINIMUM format version stamped across the .sh runners under
# <runner_dir> (an unstamped runner reads as 0 — i.e. armed before stamping).
# Minimum, not first-found: a multi-runner re-arm interrupted between writes
# leaves a mixed set, and one current runner must not mask a stale sibling.
# Return:
#   0 — at least one runner present (version echoed on stdout)
#   1 — no runners present (cadence not armed via this dir, on this platform)
cadence_runner_stamp() {
    local dir="$1" name f ver min=""
    for name in $CADENCE_RUNNER_BASENAMES; do
        f="$dir/$name.sh"
        [ -f "$f" ] || continue
        ver="$(grep -oE "${CADENCE_FORMAT_MARKER}[[:space:]]*[0-9]+" "$f" 2>/dev/null \
            | head -1 | grep -oE '[0-9]+$' || true)"
        [ -n "$ver" ] || ver=0
        if [ -z "$min" ] || [ "$ver" -lt "$min" ]; then
            min="$ver"
        fi
    done
    [ -n "$min" ] || return 1
    printf '%s' "$min"
    return 0
}

# cadence_prov_record <task-marker>
# Record a `job register` provenance row for
# the cron entry an arm just installed, so a ledger-mode uninstall can remove
# exactly that line (matched by its trailing ` # <marker>`) and nothing else.
# Call it only AFTER the arm's cron_install succeeded. S18 reads the live
# identity straight back (the crontab line just installed, matched by the
# same marker) and records it with --post-text + --field identity_v=1, so
# uninstall only removes the line while it still reads exactly as installed;
# a failed read-back (no reader for this env, or the line could not be found)
# falls back to the pre-S18 unverified row. Best effort by design: an
# unwritable ledger must never fail an arm, so it WARNs and returns 0. Every
# provenance call runs in its own subshell so provenance.sh's/
# provenance-identity.sh's functions and shell options never leak into the
# arm script.
# ponytail: a --force re-arm over a crontab line the operator already had
# under this same marker still records preexisted=false -- the arm cannot
# tell a himmel-written line from a hand-written one of that name, and the
# identity read-back only verifies the LIVE line's content, not who wrote it
# first. No upgrade planned: closing this needs a preexisted-detection pass
# at arm time, which no ticket currently covers.
cadence_prov_record() {
    local marker="$1" dir lib token u
    dir="$(dirname "${BASH_SOURCE[0]}")"
    lib="$dir/provenance.sh"
    [ -r "$lib" ] || return 0
    u=$(jq -nc --arg m "$marker" '{unit:$m, fields:{scheduler:"cron"}}' 2>/dev/null) || u=""
    # shellcheck source=scripts/lib/provenance.sh
    # shellcheck source=scripts/lib/provenance-identity.sh
    token=$( ( . "$lib" && . "$dir/provenance-identity.sh" && [ -n "$u" ] && prov_identity_live job "$u" ) 2>/dev/null )
    case "$token" in
        *[!0-9a-f]*) token="" ;;
        *) [ "${#token}" -eq 64 ] || token="" ;;
    esac
    if [ -n "$token" ]; then
        # shellcheck source=scripts/lib/provenance.sh
        if ! ( . "$lib" \
                && prov_record register job - --unit "$marker" --scope user --class code \
                    --writer cadence-arm --field 'scheduler="cron"' --field preexisted=false \
                    --post-text "$token" --field identity_v=1 ) >/dev/null 2>&1; then
            echo "WARN cadence: could not record provenance for $marker (uninstall will not remove it)" >&2
        fi
    else
        # shellcheck source=scripts/lib/provenance.sh
        if ! ( . "$lib" \
                && prov_record register job - --unit "$marker" --scope user --class code \
                    --writer cadence-arm --field 'scheduler="cron"' --field preexisted=false ) >/dev/null 2>&1; then
            echo "WARN cadence: could not record provenance for $marker (uninstall will not remove it)" >&2
        fi
    fi
    return 0
}
