#!/usr/bin/env bash
# test-headed-arm-leg-worker-env.sh - headed-arm-leg.sh reads and writes the
# worker-session names beside the old leg names (read-both, the new one wins).
#
#   W1. HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff alone turns the guard on, and
#       both mode names reach the leg.
#   W2. a set new mode wins over the old one; a new `none` falls back to the old.
#   W3. WORKER_SESSION_LANE picks the lane like LEG_LANE.
#   W4. caller-preset WORKER_SESSION_PROFILE_* / _ID / _CLAUDE_BIN tokens are
#       stripped like their old names (a sibling's values never reach the leg).
#   W5. every set name reaches the leg under both names.
#   W6. HIMMEL_WORKER=1 changes nothing: same report with and without it.
#   W7. --profile worker-vm is leg-vm: a brief naming no test VM is refused.
#
# Dry-run only: nothing launches.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/headed-arm-leg.sh"
export HEADED_ARM_LEG_PROFILES="$HERE/../../lanes/plugin-profiles.mjs"
export PLUGIN_PROFILES_ADAPTERS="$HERE/../../guardrails/himmel-adapters.json"
unset HIMMEL_CONSOLE_DOC CADENCE_BANK_LANE LEG_LANE LEG_CONTEXT LEG_REPO LEG_EFFORT HEADED_ARM_LAUNCHER HEADED_ARM_LAUNCHER_ENV \
    HEADED_ARM_RECORDER IMPL_GUARD_OK INLINE_IMPL_OK HIMMEL_CONSOLE_LEG HIMMEL_LEAN_LEG LEG_CLAUDE_BIN LEG_PROFILE \
    LEG_PROFILE_SETTINGS LEG_PROFILE_PREFACE LEG_PROFILE_MCP_CONFIG LEG_PROFILE_NO_SETTING_SOURCES LEG_SESSION_ID \
    LEG_HEADLESS LEG_API_LANE HIMMEL_API_LANE HIMMEL_API_ACCOUNT CR_TRIGGER_SUPPRESS HIMMEL_CONSOLE_NAME \
    CLAUDE_CODE_EFFORT_LEVEL HIMMEL_LEG_CONTEXT_MODE HIMMEL_LEG_AUTOCOMPACT HIMMEL_WORKER \
    WORKER_SESSION_LANE WORKER_SESSION_EFFORT HIMMEL_WORKER_SESSION_CONTEXT_MODE HIMMEL_WORKER_SESSION_AUTOCOMPACT \
    WORKER_SESSION_PROFILE_SETTINGS WORKER_SESSION_PROFILE_PREFACE WORKER_SESSION_PROFILE_MCP_CONFIG \
    WORKER_SESSION_PROFILE_NO_SETTING_SOURCES WORKER_SESSION_ID WORKER_SESSION_CLAUDE_BIN \
    HIMMEL_WORKER_SESSION_PROFILE HIMMEL_LEAN_WORKER_SESSION WORKER_SESSION_REPO WORKER_SESSION_AUTOCOMPACT_AB LEG_AUTOCOMPACT_AB \
    HEADED_ARM_WORKER_CLAUDE_BIN HEADED_ARM_LEG_CLAUDE_BIN HEADED_ARM_WORKER_SYSTEMD_RUN HEADED_ARM_LEG_SYSTEMD_RUN \
    HEADED_ARM_WORKER_TARGET HEADED_ARM_LEG_TARGET HEADED_ARM_WORKER_PROFILES HEADED_ARM_WORKER_SHIM HEADED_ARM_LEG_SHIM 2>/dev/null || true

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
dry() { bash "$SCRIPT" --dry-run --no-profile "$@" HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1; }

rc=0; out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff dry)" || rc=$?
check "W1 new mode alone: exit 0" "$rc" "0"
contains "W1 new mode alone: the new mode reaches the leg" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff"
contains "W1 new mode alone: the old mode name carries it too" "$out" "HIMMEL_LEG_CONTEXT_MODE=handoff"

out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact HIMMEL_LEG_CONTEXT_MODE=handoff dry)"
contains "W2 a set new mode wins over the old one" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact"
not_contains "W2 the old mode value is not launched" "$out" "=handoff"
out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=none HIMMEL_LEG_CONTEXT_MODE=handoff dry)"
contains "W2 a new none falls back to the old mode" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff"
rc=0; out="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=junk dry)" || rc=$?
check "W2 a junk new mode refuses the launch (exit 2)" "$rc" "2"
contains "W2 the refusal names the new name" "$out" "HIMMEL_WORKER_SESSION_CONTEXT_MODE"

rc=0; out="$(WORKER_SESSION_LANE=claudex dry)" || rc=$?
check "W3 WORKER_SESSION_LANE=claudex: exit 0" "$rc" "0"
contains "W3 WORKER_SESSION_LANE=claudex picks the claudex lane" "$out" "lane=claudex"
out="$(WORKER_SESSION_LANE=claudex LEG_LANE=native dry)"
contains "W3 a set new lane wins over the old one" "$out" "lane=claudex"

out="$(HEADED_ARM_LAUNCHER_ENV='WORKER_SESSION_PROFILE_SETTINGS=/tmp/stale-s WORKER_SESSION_PROFILE_PREFACE=/tmp/stale-p WORKER_SESSION_PROFILE_MCP_CONFIG=/tmp/stale-m WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 WORKER_SESSION_ID=stale-id WORKER_SESSION_CLAUDE_BIN=/tmp/stale-bin KEEP_ME=1' \
    WORKER_SESSION_PROFILE_SETTINGS=/tmp/stale-s WORKER_SESSION_CLAUDE_BIN=/tmp/stale-bin dry)"
for stale in /tmp/stale-s /tmp/stale-p /tmp/stale-m WORKER_SESSION_PROFILE_NO_SETTING_SOURCES stale-id /tmp/stale-bin; do
    not_contains "W4 a caller-preset $stale never reaches the leg" "$out" "$stale"
done
contains "W4 an unrelated caller token is kept" "$out" "KEEP_ME=1"

out="$(dry)"
contains "W5 the autocompact ceiling reaches the leg under the new name" "$out" "HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000"
contains "W5 and under the old name" "$out" "HIMMEL_LEG_AUTOCOMPACT=200000"
out="$(dry --lane claudex)"
contains "W5 the lane reaches the leg under the new name" "$out" "WORKER_SESSION_LANE=claudex"
contains "W5 and under the old name" "$out" "LEG_LANE=claudex"

base="$(HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff dry)"
marked="$(HIMMEL_WORKER=1 HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff dry)"
check "W6 HIMMEL_WORKER=1 changes nothing in the launch report" "$marked" "$base"

T="$(mktemp -d "${TMPDIR:-/tmp}/hal-worker-env.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
printf '# HIMMEL-9999 brief with no test VM named\n' >"$T/doc.md"
for p in worker-vm leg-vm; do
    rc=0; out="$(bash "$SCRIPT" --dry-run --profile "$p" HIMMEL-9999-leg "$T/doc.md" /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
    check "W7 --profile $p with no VM in the brief refuses (exit 2)" "$rc" "2"
    contains "W7 --profile $p names the VM refusal" "$out" "refusing a leg-vm launch"
done

# W8. the renamed repo and A/B seams: an old name alone still works, a set new name wins.
mkdir -p "$T/oldrepo" "$T/newrepo"
out="$(LEG_REPO="$T/oldrepo" dry)"
contains "W8 LEG_REPO alone still picks the repo" "$out" "HEADED_ARM_REPO=$T/oldrepo"
out="$(WORKER_SESSION_REPO="$T/newrepo" dry)"
contains "W8 WORKER_SESSION_REPO alone picks the repo" "$out" "HEADED_ARM_REPO=$T/newrepo"
out="$(WORKER_SESSION_REPO="$T/newrepo" LEG_REPO="$T/oldrepo" dry)"
contains "W8 a set WORKER_SESSION_REPO wins over LEG_REPO" "$out" "HEADED_ARM_REPO=$T/newrepo"
not_contains "W8 the old repo is not launched" "$out" "HEADED_ARM_REPO=$T/oldrepo"
rc=0; out="$(LEG_AUTOCOMPACT_AB=300000 dry)" || rc=$?
check "W8 LEG_AUTOCOMPACT_AB alone is still validated (exit 2)" "$rc" "2"
contains "W8 the validation sees the old name's value" "$out" "got: 300000"
rc=0; out="$(WORKER_SESSION_AUTOCOMPACT_AB=300000 LEG_AUTOCOMPACT_AB=200000 dry)" || rc=$?
check "W8 a set WORKER_SESSION_AUTOCOMPACT_AB wins over the old one (exit 2)" "$rc" "2"
contains "W8 the winning value is the new name's" "$out" "got: 300000"

# W9. a consult refuses the old spellings of its caller-chosen seams too.
mkdir -p "$T/repo9"
printf '# HIMMEL-9999 consult brief\n' >"$T/consult.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$T/other.sh"
for seam9 in HEADED_ARM_LEG_CLAUDE_BIN HEADED_ARM_LEG_SYSTEMD_RUN HEADED_ARM_LEG_TARGET HEADED_ARM_LEG_PROFILES; do
    rc=0; out="$(env "$seam9=$T/other.sh" WORKER_SESSION_REPO="$T/repo9" bash "$SCRIPT" --dry-run --consult --profile design-motion HIMMEL-9999-c "$T/consult.md" /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
    check "W9 a consult with $seam9 refuses (exit 2)" "$rc" "2"
    contains "W9 the $seam9 refusal says so" "$out" "--consult refuses"
done

echo "---"
if [ "$FAILED" -gt 0 ]; then echo "FAILED: $FAILED case(s)"; exit 1; fi
echo "PASS all cases"
exit 0
