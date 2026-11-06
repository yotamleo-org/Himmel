#!/usr/bin/env bash
# test-headed-arm-worker-env.sh - headed-arm-worker.sh reads and writes the
# worker-session names.
#
#   W1. HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff turns the guard on and
#       reaches the worker.
#   W2. a set mode reaches the worker; a junk mode refuses the launch.
#   W3. WORKER_SESSION_LANE picks the lane.
#   W4. caller-preset WORKER_SESSION_PROFILE_* / _ID / _CLAUDE_BIN tokens are
#       stripped (a sibling's values never reach the worker).
#   W5. every set name reaches the worker.
#   W6. HIMMEL_WORKER=1 changes nothing: same report with and without it.
#   W7. --profile worker-vm is leg-vm: a brief naming no test VM is refused.
#
# Dry-run only: nothing launches.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/headed-arm-worker.sh"
export HEADED_ARM_WORKER_PROFILES="$HERE/../../lanes/plugin-profiles.mjs"
export PLUGIN_PROFILES_ADAPTERS="$HERE/../../guardrails/himmel-adapters.json"
export UNGUARDED_LAUNCH_OK=1  # HIMMEL-9026: scratch fixtures; guard rows drop it
unset HIMMEL_CONSOLE_DOC CADENCE_USAGE_LANE WORKER_SESSION_LANE WORKER_SESSION_CONTEXT WORKER_SESSION_REPO WORKER_SESSION_EFFORT HEADED_ARM_LAUNCHER HEADED_ARM_LAUNCHER_ENV HEADED_ARM_LAUNCHER_ENV_LINES \
    HEADED_ARM_RECORDER IMPL_GUARD_OK INLINE_IMPL_OK HIMMEL_CONSOLE_LEG HIMMEL_LEAN_WORKER_SESSION WORKER_SESSION_CLAUDE_BIN WORKER_SESSION_PROFILE \
    WORKER_SESSION_PROFILE_SETTINGS WORKER_SESSION_PROFILE_PREFACE WORKER_SESSION_PROFILE_MCP_CONFIG WORKER_SESSION_PROFILE_NO_SETTING_SOURCES WORKER_SESSION_ID \
    WORKER_SESSION_HEADLESS WORKER_SESSION_API_LANE HIMMEL_API_LANE HIMMEL_API_ACCOUNT CR_TRIGGER_SUPPRESS HIMMEL_CONSOLE_NAME \
    CLAUDE_CODE_EFFORT_LEVEL HIMMEL_WORKER_SESSION_CONTEXT_MODE HIMMEL_WORKER_SESSION_AUTOCOMPACT HIMMEL_WORKER \
    WORKER_SESSION_CONTEXT WORKER_SESSION_PROFILE WORKER_SESSION_HEADLESS WORKER_SESSION_API_LANE \
    WORKER_SESSION_LANE WORKER_SESSION_EFFORT HIMMEL_WORKER_SESSION_CONTEXT_MODE HIMMEL_WORKER_SESSION_AUTOCOMPACT \
    WORKER_SESSION_PROFILE_SETTINGS WORKER_SESSION_PROFILE_PREFACE WORKER_SESSION_PROFILE_MCP_CONFIG \
    WORKER_SESSION_PROFILE_NO_SETTING_SOURCES WORKER_SESSION_ID WORKER_SESSION_CLAUDE_BIN \
    HIMMEL_WORKER_SESSION_PROFILE HIMMEL_LEAN_WORKER_SESSION WORKER_SESSION_REPO WORKER_SESSION_AUTOCOMPACT_AB \
    HEADED_ARM_WORKER_CLAUDE_BIN HEADED_ARM_WORKER_SYSTEMD_RUN \
    HEADED_ARM_WORKER_TARGET HEADED_ARM_WORKER_PROFILES HEADED_ARM_WORKER_SHIM \
    HIMMEL_HOLD_KEY HIMMEL_HOLD_DOC HIMMEL_HOLD_LABEL WRITE_HOLD_OK 2>/dev/null || true

FAILED=0
check() {
    if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 -- expected '$3', got '$2'"; FAILED=$((FAILED + 1)); fi
}
contains() {
    case "$2" in *"$3"*) echo "PASS $1" ;; *) echo "FAIL $1 -- missing '$3'"; FAILED=$((FAILED + 1)) ;; esac
}
not_contains() {
    case "$2" in *"$3"*) echo "FAIL $1 -- found '$3'"; FAILED=$((FAILED + 1)) ;; *) echo "PASS $1" ;; esac
}
dry() { bash "$SCRIPT" --dry-run --no-profile "$@" HIMMEL-9999-worker some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1; }

rc=0; out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff dry)" || rc=$?
check "W1 mode set: exit 0" "$rc" "0"
contains "W1 the mode reaches the worker" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff"

out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact dry)"
contains "W2 a set mode reaches the worker" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact"
rc=0; out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=junk dry)" || rc=$?
check "W2 a junk new mode refuses the launch (exit 2)" "$rc" "2"
contains "W2 the refusal names the mode variable" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE"

rc=0; out="$(WORKER_SESSION_LANE=claudex dry)" || rc=$?
check "W3 WORKER_SESSION_LANE=claudex: exit 0" "$rc" "0"
contains "W3 WORKER_SESSION_LANE=claudex picks the claudex lane" "$out" "lane=claudex"

out="$(HEADED_ARM_LAUNCHER_ENV='WORKER_SESSION_PROFILE_SETTINGS=/tmp/stale-s WORKER_SESSION_PROFILE_PREFACE=/tmp/stale-p WORKER_SESSION_PROFILE_MCP_CONFIG=/tmp/stale-m WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 WORKER_SESSION_ID=stale-id WORKER_SESSION_CLAUDE_BIN=/tmp/stale-bin KEEP_ME=1' \
    WORKER_SESSION_PROFILE_SETTINGS=/tmp/stale-s WORKER_SESSION_CLAUDE_BIN=/tmp/stale-bin dry)"
for stale in /tmp/stale-s /tmp/stale-p /tmp/stale-m WORKER_SESSION_PROFILE_NO_SETTING_SOURCES stale-id /tmp/stale-bin; do
    not_contains "W4 a caller-preset $stale never reaches the worker" "$out" "$stale"
done
contains "W4 an unrelated caller token is kept" "$out" "KEEP_ME=1"

out="$(dry)"
contains "W5 the autocompact ceiling reaches the worker" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000"
out="$(dry --lane claudex)"
contains "W5 the lane reaches the worker" "$out" "WORKER_SESSION_LANE=claudex"

base="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff dry)"
marked="$(HIMMEL_WORKER=1 HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff dry)"
check "W6 HIMMEL_WORKER=1 changes nothing in the launch report" "$marked" "$base"

T="$(mktemp -d "${TMPDIR:-/tmp}/hal-worker-env.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
# the single-writer register lives under HOME: pinned, so nothing here can reach the real one
export HOME="$T/home"
mkdir -p "$HOME"
printf '# HIMMEL-9999 brief with no test VM named\n' >"$T/doc.md"
for p in worker-vm leg-vm; do
    rc=0; out="$(bash "$SCRIPT" --dry-run --profile "$p" HIMMEL-9999-worker "$T/doc.md" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
    check "W7 --profile $p with no VM in the brief refuses (exit 2)" "$rc" "2"
    contains "W7 --profile $p names the VM refusal" "$out" "refusing a worker-vm launch"
done

# W8. the repo and A/B seams.
mkdir -p "$T/newrepo"
out="$(WORKER_SESSION_REPO="$T/newrepo" dry)"
contains "W8 WORKER_SESSION_REPO alone picks the repo" "$out" "HEADED_ARM_REPO=$T/newrepo"
rc=0; out="$(WORKER_SESSION_AUTOCOMPACT_AB=300000 dry)" || rc=$?
check "W8 WORKER_SESSION_AUTOCOMPACT_AB is validated (exit 2)" "$rc" "2"
contains "W8 the validation sees the value" "$out" "got: 300000"

# W9. a consult refuses its caller-chosen seams.
mkdir -p "$T/repo9"
printf '# HIMMEL-9999 consult brief\n' >"$T/consult.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$T/other.sh"
for seam9 in HEADED_ARM_WORKER_CLAUDE_BIN HEADED_ARM_WORKER_SYSTEMD_RUN HEADED_ARM_WORKER_TARGET HEADED_ARM_WORKER_PROFILES; do
    rc=0; out="$(env "$seam9=$T/other.sh" WORKER_SESSION_REPO="$T/repo9" bash "$SCRIPT" --dry-run --consult --profile design-motion HIMMEL-9999-c "$T/consult.md" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
    check "W9 a consult with $seam9 refuses (exit 2)" "$rc" "2"
    contains "W9 the $seam9 refusal says so" "$out" "--consult refuses"
done

# W10. a Sonnet worker profile exports its own guard share (73, so the
# deny lands 33 % = 330000 tokens, ahead of the earliest 450000 compaction at 343158);
# the share rides the same native-lane claude-sonnet-5 gate as the 450000 ceiling.
mkdir -p "$T/notcore-jira"
cat >"$T/notcore-jira/index.js" <<'NCEOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
NCEOF
export BRIEF_LINT_JIRA_CLI="$T/notcore-jira/index.js"
fx10() { printf '%s\n' '---' 'description: fixture brief' '---' '> **Prior art:** none found (qmd -c jira-himmel "fixture")' '' '# HIMMEL-9999 fixture brief' "$@"; }
fx10 >"$T/doc10.md"
fx10 '> **Tier:** opus — design: multi-step design' >"$T/opus-doc10.md"
dry10() { bash "$SCRIPT" --dry-run "${@:4}" --profile "$1" HIMMEL-9999-worker "$2" /tmp/nosig 99999999999 /tmp/worker.log "$3" 2>&1; }
out="$(dry10 worker-impl "$T/doc10.md" claude-sonnet-5-5)"
contains "W10 impl on Sonnet exports the profile share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=73"
out="$(dry10 worker-eval "$T/doc10.md" claude-sonnet-5-5)"
contains "W10 eval on Sonnet exports the profile share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=73"
out="$(dry10 worker-docs "$T/doc10.md" claude-sonnet-5-5)"
contains "W10 control: docs on Sonnet keeps the 200000 ceiling" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000"
contains "W10 control: docs on Sonnet exports no share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=<unset>"
out="$(dry10 worker-impl "$T/opus-doc10.md" claude-opus-5-5)"
contains "W10 control: impl on Opus keeps the 200000 ceiling" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000"
contains "W10 control: impl on Opus exports no share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=<unset>"
out="$(dry10 worker-impl "$T/doc10.md" claude-sonnet-5-5 --lane deepseek)"
contains "W10 control: impl on a non-native lane keeps the 200000 ceiling" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000"
contains "W10 control: impl on a non-native lane exports no share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=<unset>"
out="$(dry10 worker-impl "$T/doc10.md" claude-sonnet-4-6)"
contains "W10 control: impl on an older Sonnet exports no share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=<unset>"
fx10 '> **Context:** 1m — operator-ruling: HIMMEL-8825 fixture 1m worker' >"$T/onem-doc10.md"
out="$(WORKER_SESSION_CONTEXT=1m dry10 worker-impl "$T/onem-doc10.md" claude-sonnet-5-5)"
contains "W10 control: impl on Sonnet with a sanctioned 1m override resolves auto, not the 450000 ceiling" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=auto"
contains "W10 control: impl on Sonnet with a sanctioned 1m override exports no share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=<unset>"
out="$(HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50 dry10 worker-impl "$T/doc10.md" claude-sonnet-5-5)"
contains "W10 a share set in the launching shell is scrubbed: the profile's wins" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=73"
out="$(HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50 dry10 worker-docs "$T/doc10.md" claude-sonnet-5-5)"
contains "W10 control: a launching-shell share does not reach a profile without one" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=<unset>"
out="$(HEADED_ARM_LAUNCHER_ENV='HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50 KEEP_ME=1' dry10 worker-impl "$T/doc10.md" claude-sonnet-5-5)"
contains "W10 a stale launcher share token is replaced by the profile share" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=73"
not_contains "W10 the stale launcher share token is gone" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50"
out="$(HEADED_ARM_LAUNCHER_ENV='HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50 KEEP_ME=1' dry10 worker-docs "$T/doc10.md" claude-sonnet-5-5)"
contains "W10 control: a stale launcher share token does not reach a profile without one" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=<unset>"
not_contains "W10 control: the stale launcher share token is removed for a profile without one" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50"
for bad10 in 0 101 73.5 '"73"'; do
    printf '%s\n' '{"floor":["qmd@himmel"],"catalog":["qmd@himmel"],"profiles":{"operator":null,' \
        "\"worker-impl\":{\"enable\":[],\"contextBudget\":50000,\"contextMode\":\"standard\",\"autocompact\":200000,\"sonnetAutocompact\":450000,\"sonnetContextGuard\":\"handoff\",\"sonnetContextShare\":$bad10}}}" >"$T/bad-share.json"
    rc=0; out="$(PLUGIN_PROFILES_REGISTRY="$T/bad-share.json" dry10 worker-impl "$T/doc10.md" claude-sonnet-5-5)" || rc=$?
    check "W10 sonnetContextShare $bad10 refuses the launch (exit 2)" "$rc" "2"
    contains "W10 the refusal names sonnetContextShare" "$out" "sonnetContextShare"
done

# W11. a worker launch carries its holder key, its launch doc and its label; a role that
# implements nothing carries none, and a key inherited from the worker that armed it is dropped.
fx10 >"$T/HIMMEL-9377-N5-case-2026-11-02.md"
fx10 >"$T/HIMMEL-9378-plain-notes.md"
out="$(cd "$T" && bash "$SCRIPT" --dry-run --no-profile HIMMEL-9377-N5-case HIMMEL-9377-N5-case-2026-11-02.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)"
contains "W11 HIMMEL_HOLD_KEY is the first ticket key of the doc's basename" "$out" "HIMMEL_HOLD_KEY=HIMMEL-9377"
contains "W11 HIMMEL_HOLD_DOC is absolute when the doc is given relative" "$out" "HIMMEL_HOLD_DOC=$T/HIMMEL-9377-N5-case-2026-11-02.md"
contains "W11 HIMMEL_HOLD_LABEL is the worker label" "$out" "HIMMEL_HOLD_LABEL=N5 "
out="$(cd "$T" && bash "$SCRIPT" --dry-run --no-profile HIMMEL-9378-plain HIMMEL-9378-plain-notes.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)"
rc11=$?
check "W11 a non-template doc launches (exit 0), no unset-function error" "$rc11" "0"
contains "W11 a non-template doc's label is its whole stem" "$out" "HIMMEL_HOLD_LABEL=HIMMEL-9378-plain-notes "
out="$(cd "$T" && WRITE_HOLD_OK=1 HIMMEL_HOLD_KEY=HIMMEL-1 HIMMEL_HOLD_LABEL=N99 bash "$SCRIPT" --dry-run --no-profile HIMMEL-9377-N5-case HIMMEL-9377-N5-case-2026-11-02.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)"
contains "W11 WRITE_HOLD_OK=1 set in the launching shell reaches the worker past the scrub" "$out" "WRITE_HOLD_OK=1"
contains "W11 a key inherited from another worker is replaced by this doc's" "$out" "HIMMEL_HOLD_KEY=HIMMEL-9377"
not_contains "W11 ... and so is its label" "$out" "HIMMEL_HOLD_LABEL=N99"
out="$(cd "$T" && HIMMEL_HOLD_KEY=HIMMEL-1 HIMMEL_HOLD_DOC=/x/y.md HIMMEL_HOLD_LABEL=N99 bash "$SCRIPT" --dry-run --relay HIMMEL-9377-N5-relay HIMMEL-9377-N5-case-2026-11-02.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)"
contains "W11 a --relay launch carries no key (an inherited one is dropped)" "$out" "HIMMEL_HOLD_KEY=<unset> HIMMEL_HOLD_DOC=<unset> HIMMEL_HOLD_LABEL=<unset>"
mkdir -p "$T/repo11"
out="$(cd "$T" && HIMMEL_HOLD_KEY=HIMMEL-1 WORKER_SESSION_REPO="$T/repo11" bash "$SCRIPT" --dry-run --consult --profile design-motion HIMMEL-9377-N5-c "$T/consult.md" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)"
contains "W11 a --consult launch carries no key" "$out" "HIMMEL_HOLD_KEY=<unset> HIMMEL_HOLD_DOC=<unset> HIMMEL_HOLD_LABEL=<unset>"

# W12. a settings env pin of CLAUDE_CODE_EFFORT_LEVEL overrides the asked effort (claude 2.1.319,
# sandboxed HOME, mock API: pin high + `--effort medium` or env medium both still sent high). The launcher
# warns, never refuses, and stays quiet when the pin matches or there is none. HOME is the sandbox from W7.
unset CLAUDE_CONFIG_DIR CLAUDE_DIR 2>/dev/null || true
mkdir -p "$HOME/.claude" "$T/repo12/.claude"
printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"high"}}\n' >"$HOME/.claude/settings.json"
rc=0; out="$(WORKER_SESSION_EFFORT=medium dry)" || rc=$?
check "W12 a user-settings pin differing from the asked effort still launches (exit 0)" "$rc" "0"
contains "W12 the launcher warns about the pin" "$out" "WARNING"
contains "W12 the warning names the variable" "$out" "CLAUDE_CODE_EFFORT_LEVEL"
contains "W12 the warning names the settings file" "$out" "$HOME/.claude/settings.json"
contains "W12 the warning names the pinned effort" "$out" "pins high"
contains "W12 the warning names the asked effort" "$out" "asked effort=medium"
out="$(WORKER_SESSION_EFFORT=high dry)"
not_contains "W12 control: a pin equal to the asked effort is silent" "$out" "WARNING"
rm -f "$HOME/.claude/settings.json"
out="$(WORKER_SESSION_EFFORT=medium dry)"
not_contains "W12 control: no pin is silent" "$out" "WARNING"
printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"max"}}\n' >"$T/repo12/.claude/settings.json"
out="$(HEADED_ARM_REPO="$T/repo12" WORKER_SESSION_EFFORT=medium dry)"
contains "W12 a project-settings pin warns too" "$out" "$T/repo12/.claude/settings.json"
rm -f "$T/repo12/.claude/settings.json"
# a higher-precedence file that restates the asked effort wins over a user pin: nothing to warn about
printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"high"}}\n' >"$HOME/.claude/settings.json"
printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"medium"}}\n' >"$T/repo12/.claude/settings.local.json"
out="$(HEADED_ARM_REPO="$T/repo12" WORKER_SESSION_EFFORT=medium dry)"
not_contains "W12 control: a project-local pin equal to the asked effort overrides a user pin, so no warning" "$out" "WARNING"
printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"max"}}\n' >"$T/repo12/.claude/settings.local.json"
out="$(HEADED_ARM_REPO="$T/repo12" WORKER_SESSION_EFFORT=medium dry)"
contains "W12 the warning names the winning (project-local) pin" "$out" "$T/repo12/.claude/settings.local.json pins max"
not_contains "W12 ... and not the overridden user pin" "$out" "$HOME/.claude/settings.json pins"
rm -f "$HOME/.claude/settings.json" "$T/repo12/.claude/settings.local.json"
# a settings file the scan cannot read as a pin never changes the launch: same exit, no warning
for bad12 in '{ not json' '{"env":"high"}' '{"env":["high"]}' '[]'; do
    printf '%s\n' "$bad12" >"$HOME/.claude/settings.json"
    rc=0; out="$(WORKER_SESSION_EFFORT=medium dry)" || rc=$?
    check "W12 an unreadable pin ($bad12) leaves the launch exit 0" "$rc" "0"
    not_contains "W12 an unreadable pin ($bad12) is silent" "$out" "WARNING"
done
# no jq on PATH: the scan is skipped, the launch is unchanged even with a real pin present
printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"high"}}\n' >"$HOME/.claude/settings.json"
mkdir -p "$T/nojq-bin"
for nj12 in /usr/bin/* /bin/*; do
    [ -e "$T/nojq-bin/${nj12##*/}" ] || [ "${nj12##*/}" = jq ] || ln -s "$nj12" "$T/nojq-bin/${nj12##*/}"
done
rc=0; out="$(PATH="$T/nojq-bin" WORKER_SESSION_EFFORT=medium dry)" || rc=$?
if PATH="$T/nojq-bin" command -v jq >/dev/null 2>&1; then echo "FAIL W12 setup: jq is still on the stripped PATH"; FAILED=$((FAILED + 1)); fi
check "W12 no jq: the launch still exits 0" "$rc" "0"
not_contains "W12 no jq: the scan is skipped, no warning" "$out" "WARNING"
rm -f "$HOME/.claude/settings.json"

echo "---"
if [ "$FAILED" -gt 0 ]; then echo "FAILED: $FAILED case(s)"; exit 1; fi
echo "PASS all cases"
exit 0
