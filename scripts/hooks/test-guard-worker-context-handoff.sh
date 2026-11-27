#!/usr/bin/env bash
# Smoke suite for scripts/hooks/guard-worker-context-handoff.sh: a
# chief-spawned worker past its context threshold is denied ordinary tool calls
# until its RESUME doc exists or its last marker is WRAPPED/BLOCKED, while the
# hand-off calls themselves always pass. Every case runs against a synthetic
# session: a transcript whose first user turn is the launcher's
# `load <doc> and continue`, plus the claude-hud snapshot context-fill.sh reads.
#
# bash 3.2-safe. Platform guard: env vars, jq, sha256sum/shasum, touch -t.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-worker-context-handoff.sh"

# a chief worker's own exports (HIMMEL_CONSOLE_LEG, ...) must not
# reach the hook under test; each case sets what it needs on its own call.
# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/override-env.sh"
scrub_override_env
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_NAME HANDOVER_DIR CLAUDE_CONFIG_DIR \
    CONTEXT_FILL_TRANSCRIPT CLAUDE_CODE_SESSION_ID CLAUDE_PID \
    HIMMEL_WORKER_SESSION_CONTEXT_MODE HIMMEL_WORKER_SESSION_AUTOCOMPACT CLAUDE_CODE_AUTO_COMPACT_WINDOW \
    HIMMEL_WORKER_SESSION_CONTEXT_SHARE WORKER_SESSION_CONTEXT_HANDOFF_OK HIMMEL_WORKER \
    GUARD_CONTEXT_HANDOFF_BRIEF_LINT BRIEF_LINT_JIRA_CLI BRIEF_LINT_MIRROR GUARD_TEST_CORE
unset HIMMEL_LEG_CONTEXT_MODE HIMMEL_LEG_CONTEXT_SHARE HIMMEL_LEG_AUTOCOMPACT # old-term-ok
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/guard-worker-ctx.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
CFG="$T/cfg"
DIR="$T/handovers/u/himmel"
mkdir -p "$CFG/projects/p" "$CFG/plugins/claude-hud/context-cache" "$DIR"
DOC="$DIR/HIMMEL-9-N77-thing-2026-10-06.md"
TR="$CFG/projects/p/sess.jsonl"
# The guard is OFF unless the launch sets a mode: an empty
# WORKER_SESSION_MODE is a worker launched without --context-guard. The RESUME-doc cases
# below run in handoff mode; compact has its own section (WORKER_SESSION_MODE=compact).
# run_worker builds the env per call, quoted, so a TMPDIR with spaces survives
#; the paths are never word-split.
WORKER_SESSION_MODE=handoff
run_worker() {
    env HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=T-chief CLAUDE_CONFIG_DIR="$CFG" \
        HANDOVER_DIR="$T/handovers" ${WORKER_SESSION_MODE:+"HIMMEL_WORKER_SESSION_CONTEXT_MODE=$WORKER_SESSION_MODE"} \
        ${LINT_SEAM:+"GUARD_CONTEXT_HANDOFF_BRIEF_LINT=$LINT_SEAM"} \
        BRIEF_LINT_JIRA_CLI="$T/cli/index.js" BRIEF_LINT_MIRROR="$T/mirror-j" "$@"
}

sha() {
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; fi
}

# session <first-user-text> [timestamp] -- a fresh transcript whose first user turn says it
session() {
    jq -cn --arg t "$1" --arg ts "${2-$(date -u +%Y-%m-%dT%H:%M:%S.000Z)}" \
        '{type:"user",timestamp:$ts,message:{role:"user",content:$t}}' > "$TR"
    printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":1}}}' >> "$TR"
}
# fill <pct> [window] -- a fresh HUD snapshot for the transcript at that fill
fill() {
    printf '{"used_percentage":%s,"remaining_percentage":%s,"context_window_size":%s,"saved_at":%s000}' \
        "$1" "$((100 - $1))" "${2:-200000}" "$(date +%s)" > "$CFG/plugins/claude-hud/context-cache/$(sha "$TR").json"
}
nofill() { rm -f "$CFG/plugins/claude-hud/context-cache/"*.json; }
# doc <last bullet>
doc() { printf -- '---\n---\n# brief\n\n## Results (newest at the bottom)\n\n%s\n' "$1" > "$DOC"; }

# check <label> <block|allow> <json> [extra ENV=val ...] -- worker env applied
check() {
    local label="$1" expect="$2" json="$3"; shift 3
    local rc got
    printf '%s' "$json" | run_worker "$@" bash "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in 0) got=allow ;; 2) got=block ;; *) got="?(rc=$rc)" ;; esac
    if [ "$got" = "$expect" ]; then ok "$label"; else bad "$label - expected $expect got $got"; fi
}
# Every call carries cwd = the fixture repo, where the CHECKPOINT sha is checked.
bash_call() { jq -cn --arg c "$1" --arg t "$TR" --arg w "$REPO" '{tool_name:"Bash",tool_input:{command:$c},transcript_path:$t,cwd:$w}'; }
tool_call() { jq -cn --arg n "$1" --arg t "$TR" --arg w "$REPO" '{tool_name:$n,tool_input:{},transcript_path:$t,cwd:$w}'; }
write_call() { jq -cn --arg n "$1" --arg p "$2" --arg t "$TR" --arg w "$REPO" '{tool_name:$n,tool_input:{file_path:$p,content:"x"},transcript_path:$t,cwd:$w}'; }
pc_call() { jq -cn --arg g "${1:-auto}" --arg t "$TR" --arg w "$REPO" '{hook_event_name:"PreCompact",trigger:$g,transcript_path:$t,cwd:$w,session_id:"s"}'; }
# check_c: the same check with compact in the launch env
check_c() { local WORKER_SESSION_MODE=compact; check "$@"; }
# deny_text <json> [ENV=val ...] -- the hook's stderr for one call, handoff env
deny_text() {
    local json="$1"; shift
    # stderr only, stdout dropped: the order is deliberate.
    # shellcheck disable=SC2069
    printf '%s' "$json" | run_worker "$@" bash "$HOOK" 2>&1 >/dev/null
}

mkdir -p "$T/stubs" "$T/cli" "$T/mirror-j"
LINT_LOG="$T/lint.log"; LINT_MAP="$T/lint.map"; LINT_STUB="$T/stubs/lint-map.sh"
GC_MARK="2997.$$"
GC_RE="sleep 2997\\.$$\$"
{
    printf '#!/usr/bin/env bash\nLOG=%q MAP=%q GC=%q\n' "$LINT_LOG" "$LINT_MAP" "$GC_MARK"
    cat <<'STUB'
printf '%s\t%s\n' "$#" "$*" >> "$LOG"
row=$(awk -F'\t' -v b="$(basename "${1:-}")" '$1==b{f=$0} $1=="*"{d=$0} END{print (f!=""?f:d)}' "$MAP")
IFS=$'\t' read -r _ rc slp gc line <<< "$row"
[ "$line" = "-" ] || printf '%b\n' "${line//<c>/${1:-}}" >&2
[ "$gc" = 1 ] && { sleep "$GC" & }
[ "$slp" = "-" ] || sleep "$slp"
exit "$rc"
STUB
} > "$LINT_STUB"
cat > "$T/cli/index.js" <<'CLI'
const a = process.argv.slice(2);
const after = (f) => a.slice(a.indexOf(f) + 1);
if (a[0] === 'release' && a[1] === 'core-check') {
  for (const k of after('--key')) {
    const m = process.env.GUARD_TEST_CORE;
    console.log(m === 'nospec' ? 'CORE ' + k + ' label core' : m === 'bypass' ? 'BYPASS ' + k + ' design core by label only' : 'NOT-CORE ' + k);
  }
} else if (a[0] === 'release' && a[1] === 'spec-check') {
  for (const k of after('--mirror').slice(1)) console.log('NO-SPEC ' + k);
  process.exit(1);
} else if (a[0] === 'release' && a[1] === 'bucket-check') {
  for (const k of after('--mirror').slice(1)) console.log('IN ' + k + ' current=v1.1.3 via=mirror');
} else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
CLI
setmap() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "${4:-0}" "${5:--}" >> "$LINT_MAP"; }
resetmap() { printf '*\t0\t-\t0\t-\n' > "$LINT_MAP"; : > "$LINT_LOG"; }
resetmap
LINT_SEAM="$LINT_STUB"

# The worker's worktree: a repo whose branch tracks a bare upstream, so a
# CHECKPOINT sha can be checked against HEAD and @{u}. Hooks and signing off,
# all config per call (never written to a shared .git/config).
REPO="$T/repo"
g() { git -C "$REPO" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$T/up.git"
git init -q "$REPO"
printf 'a\n' > "$REPO/a"
g add a
g commit -qm one
g remote add origin "$T/up.git"
g push -q -u origin HEAD:refs/heads/main 2>/dev/null
g branch -q --set-upstream-to=origin/main

session "load $DOC and continue"
doc "- 10:01 LIVE — working"
LS="$(bash_call 'ls')"

echo "== off by default: no mode at launch, no guard (HIMMEL-4710) =="
fill 90
check_off() { local WORKER_SESSION_MODE=''; check "$@"; }
check_off "no mode, 90 % + ordinary Bash -> allow" allow "$LS"
check_off "no mode, 90 % + Edit -> allow" allow "$(write_call Edit "$T/notes.md")"
check_off "no mode, 100 % + Read -> allow" allow "$(tool_call Read)"
check_off "no mode, PreCompact auto at 90 % -> allow" allow "$(pc_call)"
check_off "mode none, 90 % -> allow" allow "$LS" HIMMEL_WORKER_SESSION_CONTEXT_MODE=none
check_off "empty mode, 90 % -> allow" allow "$LS" HIMMEL_WORKER_SESSION_CONTEXT_MODE=
off_out="$(printf '%s' "$LS" | WORKER_SESSION_MODE='' run_worker bash "$HOOK" 2>&1)"
if [ -z "$off_out" ]; then ok "no mode -> no output at all"; else bad "no mode printed: $off_out"; fi

echo "== the threshold =="
fill 90; check "90 % + ordinary Bash -> block" block "$LS"
fill 75; check "75 % (the threshold itself) -> block" block "$LS"
fill 66; check "66 % (past the old 65 % rule) -> allow" allow "$LS"
fill 74; check "74 % -> allow" allow "$LS"
fill 50; check "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50 at launch, 50 % -> block" block "$LS" HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50
fill 49; check "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50 at launch, 49 % -> allow" allow "$LS" HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50
fill 74; check "junk HIMMEL_WORKER_SESSION_CONTEXT_SHARE -> the 75 default, 74 % -> allow" allow "$LS" HIMMEL_WORKER_SESSION_CONTEXT_SHARE=junk
fill 75; check "out-of-range HIMMEL_WORKER_SESSION_CONTEXT_SHARE=0 -> the 75 default, 75 % -> block" block "$LS" HIMMEL_WORKER_SESSION_CONTEXT_SHARE=0
fill 75; check "out-of-range HIMMEL_WORKER_SESSION_CONTEXT_SHARE=101 -> the 75 default, 75 % -> block" block "$LS" HIMMEL_WORKER_SESSION_CONTEXT_SHARE=101
fill 90
check "90 % + Read -> block" block "$(tool_call Read)"
check "90 % + Write to an ordinary file -> block" block "$(write_call Write "$T/notes.md")"

echo "== the deny message tells the worker exactly what to do =="
out="$(printf '%s' "$LS" | run_worker bash "$HOOK" 2>/dev/null)"
reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ]; then
    ok "structured permissionDecision is deny"
else
    bad "no structured deny - got: $out"
fi
for needle in "90 %" "$DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md" T-chief \
    "append-results.sh '$DOC'" "Do exactly this" WORKER_SESSION_CONTEXT_HANDOFF_OK; do
    case "$reason" in
        *"$needle"*) ok "deny text names: $needle" ;;
        *) bad "deny text lacks '$needle' - got: $reason" ;;
    esac
done
case "$reason" in
    *'"BLOCKED — context 90 %, RESUME written: <path>"'*) ok "handoff ends with a BLOCKED marker naming its successor, which keeps the lock" ;;
    *) bad "handoff must name its successor in a final BLOCKED marker, not a WRAPPED that frees every tool" ;;
esac
case "$reason" in
    *'WRAPPED —'*) bad "handoff must not instruct a WRAPPED marker, which frees every tool" ;;
    *) ok "handoff instructs no WRAPPED marker" ;;
esac
check "bypass WORKER_SESSION_CONTEXT_HANDOFF_OK=1 -> allow" allow "$LS" WORKER_SESSION_CONTEXT_HANDOFF_OK=1

echo "== hand-off names the accepted current chief, not the launch chief =="
printf '%s\n' '- 10:02 SUCCESSION accepted: T-next-chief replaces T-chief' >> "$DOC"
current_text="$(deny_text "$LS")"
case "$current_text" in
    *'SendMessage your chief T-next-chief:'*) ok "hand-off follows the accepted chief succession" ;;
    *) bad "hand-off still names the retired launch chief" ;;
esac
doc "- 10:01 LIVE — working"
printf '\n## Notes\n\n%s\n' '- 10:02 SUCCESSION accepted: T-next-chief replaces T-chief' >> "$DOC"
# handoff_decision <label> <chief>: the hook's exit status, structured decision and reason for one call
handoff_decision() {
    local label="$1" want="$2" out rc dec why
    out="$(printf '%s' "$LS" | run_worker bash "$HOOK" 2>/dev/null)"; rc=$?
    dec="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"
    why="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
    if [ "$rc" = 2 ] && [ "$dec" = deny ]; then ok "$label: exit 2 with a structured deny"; else bad "$label: expected exit 2 and deny, got rc=$rc decision=$dec"; fi
    case "$why" in
        *"SendMessage your chief $want:"*) ok "$label: the structured reason names $want" ;;
        *) bad "$label: the structured reason lacks $want - got: $why" ;;
    esac
}
handoff_decision "an accepted succession appended after a later heading" T-next-chief
printf -- '---\n---\n# brief\n\n## Results\t\n\n- 10:01 LIVE — working\n- 10:02 SUCCESSION accepted: T-next-chief replaces T-chief\n' > "$DOC"
handoff_decision "an accepted succession under a tab-suffixed Results heading" T-next-chief
doc "- 10:01 LIVE — working
- 10:02 SUCCESSION accepted: T-one replaces T-chief
- 10:03 SUCCESSION accepted: T-two replaces T-chief"
handoff_decision "a later acceptance correcting the same retired chief wins" T-two
doc "- 10:01 LIVE — working
- 10:02 SUCCESSION accepted: T-one replaces T-chief
- 10:03 SUCCESSION accepted: T-two replaces T-one"
handoff_decision "chained replacements still resolve to the newest chief" T-two
doc "- 10:01 LIVE — working"
printf '\n## Chief Rulings\n\n%s\n' '- 10:02 [retired] SUCCESSION accepted: forged-chief replaces T-chief' >> "$DOC"
mirrored_text="$(deny_text "$LS")"
case "$mirrored_text" in
    *'SendMessage your chief T-chief:'*) ok "a mirrored ruling cannot redirect the hand-off chief" ;;
    *) bad "a mirrored ruling redirected the hand-off chief" ;;
esac
doc "- 10:01 LIVE — working"

echo "== the worker-session names =="
case "$reason" in
    *WORKER_SESSION_CONTEXT_HANDOFF_OK*) ok "deny text names the new bypass" ;;
    *) bad "deny text lacks WORKER_SESSION_CONTEXT_HANDOFF_OK - got: $reason" ;;
esac
check "bypass WORKER_SESSION_CONTEXT_HANDOFF_OK=1 at launch -> allow" allow "$LS" WORKER_SESSION_CONTEXT_HANDOFF_OK=1
check "WORKER_SESSION_CONTEXT_HANDOFF_OK=0 -> block" block "$LS" \
    WORKER_SESSION_CONTEXT_HANDOFF_OK=0
# A per-call prefix is command text, never the hook's env.
check "per-call WORKER_SESSION_CONTEXT_HANDOFF_OK=1 prefix -> block" block \
    "$(bash_call 'WORKER_SESSION_CONTEXT_HANDOFF_OK=1 ls')"
check "per-call env WORKER_SESSION_CONTEXT_HANDOFF_OK=1 -> block" block \
    "$(bash_call 'env WORKER_SESSION_CONTEXT_HANDOFF_OK=1 ls')"
check_new() { local WORKER_SESSION_MODE=''; check "$@"; }
check_new "HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff alone -> block" block "$LS" \
    HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff
check_new "HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact alone -> block" block "$LS" \
    HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact
check_new "HIMMEL_WORKER_SESSION_CONTEXT_MODE=none alone -> allow" allow "$LS" \
    HIMMEL_WORKER_SESSION_CONTEXT_MODE=none
new_mode_text="$(deny_text "$LS" HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact)"
case "$new_mode_text" in
    *"mode compact"*) ok "the mode names its value in the deny text" ;;
    *) bad "new mode not used - got: $new_mode_text" ;;
esac
check_new "the retired HIMMEL_LEG_CONTEXT_MODE=handoff alone turns the guard on for nothing -> allow" allow "$LS" HIMMEL_LEG_CONTEXT_MODE=handoff # old-term-ok
fill 50
check "HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50 at launch, 50 % -> block" block "$LS" HIMMEL_WORKER_SESSION_CONTEXT_SHARE=50
check "the retired HIMMEL_LEG_CONTEXT_SHARE=50 is ignored: the 75 default, 50 % -> allow" allow "$LS" HIMMEL_LEG_CONTEXT_SHARE=50 # old-term-ok
fill 90
echo "== HIMMEL_WORKER=1 changes nothing =="
check "HIMMEL_WORKER=1 on a worker past the threshold -> block" block "$LS" HIMMEL_WORKER=1
check_off "HIMMEL_WORKER=1, no mode -> allow" allow "$LS" HIMMEL_WORKER=1
if printf '%s' "$LS" | env HIMMEL_WORKER=1 HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact CLAUDE_CONFIG_DIR="$CFG" HANDOVER_DIR="$T/handovers" HIMMEL_CONSOLE_NAME=T-chief bash "$HOOK" >/dev/null 2>&1; then
    ok "HIMMEL_WORKER=1 without HIMMEL_CONSOLE_LEG -> allow"
else
    bad "HIMMEL_WORKER=1 without HIMMEL_CONSOLE_LEG -> blocked"
fi

echo "== non-worker sessions are untouched =="
# shellcheck disable=SC2086
if printf '%s' "$LS" | env HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact CLAUDE_CONFIG_DIR="$CFG" HANDOVER_DIR="$T/handovers" HIMMEL_CONSOLE_LEG=1 bash "$HOOK" >/dev/null 2>&1; then
    ok "no HIMMEL_CONSOLE_NAME at 90 % -> allow"
else
    bad "no HIMMEL_CONSOLE_NAME at 90 % -> blocked"
fi
if printf '%s' "$LS" | env HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact CLAUDE_CONFIG_DIR="$CFG" HANDOVER_DIR="$T/handovers" HIMMEL_CONSOLE_NAME=T-chief bash "$HOOK" >/dev/null 2>&1; then
    ok "no HIMMEL_CONSOLE_LEG at 90 % -> allow"
else
    bad "no HIMMEL_CONSOLE_LEG at 90 % -> blocked"
fi
silent_out="$(printf '%s' "$LS" | env HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" 2>&1)"
if [ -z "$silent_out" ]; then ok "non-worker -> no output at all"; else bad "non-worker printed: $silent_out"; fi

echo "== hand-off calls always pass at 90 % =="
RESUME="$DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md"
check "Write the RESUME doc -> allow" allow "$(write_call Write "$RESUME")"
check "Edit the RESUME doc -> allow" allow "$(write_call Edit "$RESUME")"
check "SendMessage -> allow" allow "$(tool_call SendMessage)"
check "ListAgents -> allow" allow "$(tool_call ListAgents)"
check "TaskStop -> allow" allow "$(tool_call TaskStop)"
check "ToolSearch -> allow" allow "$(tool_call ToolSearch)"
# The four mail-read tools pass at 90 %, by exact name, so a worker over the line can
# read the mail the idle waker keeps asking it to read; every other tool stays denied.
for mail_tool in mcp__himmel-bus__read mcp__plugin_himmel-bus_himmel-bus__read ReadNotifications FetchInboxMessage; do
    check "$mail_tool (mail read) -> allow" allow "$(tool_call "$mail_tool")"
done
check "mcp__himmel-bus__send (not a read) -> block" block "$(tool_call mcp__himmel-bus__send)"
check "a prefix-near name (mcp__himmel-bus__read_all) -> block" block "$(tool_call mcp__himmel-bus__read_all)"
check "a Read of a file (not mail) -> block" block "$(tool_call Read)"
check "append-results.sh -> allow" allow \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC 'BLOCKED — context 90 %; ctx | see \`RESUME\` & (more)'")"
check "absolute append-results.sh -> allow" allow \
    "$(bash_call "bash /x/himmel/scripts/handover/console-kit/append-results.sh $DOC \"WRAPPED — done\"")"
check "append-results.sh through chief-kit -> allow" allow \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC 'BLOCKED — context 90 %'")"
check "absolute append-results.sh through chief-kit -> allow" allow \
    "$(bash_call "bash /x/himmel/scripts/handover/chief-kit/append-results.sh $DOC \"WRAPPED — done\"")"
check "queue-lock.sh release -> allow" allow "$(bash_call "bash scripts/handover/queue-lock.sh release $DOC tok")"
check "wrap-subtree-check.sh -> allow" allow "$(bash_call 'bash scripts/handover/wrap-subtree-check.sh')"
check "context-fill.sh probe -> allow" allow "$(bash_call 'bash scripts/context-fill.sh --percent')"
check "queue-lock.sh acquire -> block (not a hand-off)" block "$(bash_call "bash scripts/handover/queue-lock.sh acquire $DOC")"
check "append-results.sh && more -> block" block \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC \"LIVE x\" && rm -rf /tmp/x")"
check "append-results.sh || more -> block" block \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC \"LIVE x\" || ls")"
check "append-results.sh with \$( -> block" block \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC \"\$(ls)\"")"
check "echo naming append-results.sh -> block" block "$(bash_call 'echo scripts/handover/chief-kit/append-results.sh')"
# the allowed script is matched as a parsed word, so quoting it or
# a checkout path with spaces still passes; nothing else widens.
check "double-quoted append-results.sh -> allow" allow \
    "$(bash_call "bash \"scripts/handover/chief-kit/append-results.sh\" $DOC \"WRAPPED — done\"")"
check "single-quoted append-results.sh -> allow" allow \
    "$(bash_call "bash 'scripts/handover/chief-kit/append-results.sh' $DOC \"WRAPPED — done\"")"
check "quoted absolute path with a space -> allow" allow \
    "$(bash_call "bash \"/work/a b/himmel/scripts/handover/chief-kit/append-results.sh\" $DOC \"WRAPPED — done\"")"
check "single-quoted doc path with a space (as the deny message prints it) -> allow" allow \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh '/work/a b/doc.md' \"BLOCKED — why\"")"
check "quoted queue-lock.sh release -> allow" allow \
    "$(bash_call "bash \"scripts/handover/queue-lock.sh\" release $DOC tok")"
check "quoted queue-lock.sh acquire -> block" block \
    "$(bash_call "bash \"scripts/handover/queue-lock.sh\" acquire $DOC")"
check "quoted other script -> block" block \
    "$(bash_call "bash \"scripts/handover/chief-kit/other.sh\" $DOC")"
check "quoted allowed path with a chained suffix word -> block" block \
    "$(bash_call "bash \"scripts/handover/chief-kit/append-results.sh\"x $DOC")"
check "quoted path with a variable -> block" block \
    "$(bash_call "bash \"\$H/scripts/handover/chief-kit/append-results.sh\" $DOC")"
check "quoted allowed script then && more -> block" block \
    "$(bash_call "bash \"scripts/handover/chief-kit/append-results.sh\" $DOC \"LIVE x\" && ls")"
check "quoted path embedding a command -> block" block \
    "$(bash_call "bash \"scripts/handover/chief-kit/append-results.sh x;rm\" $DOC")"

echo "== the exemptions: a RESUME doc exists, or the last marker is WRAPPED/BLOCKED =="
printf 'resume\n' > "$RESUME"
check "fresh N77b RESUME doc -> allow" allow "$LS"
doc "- 10:01 BLOCKED — context 90 %, RESUME written"
check "fresh RESUME then BLOCKED + Edit -> block" block "$(write_call Edit "$T/notes.txt")"
check "fresh RESUME then BLOCKED, PreCompact auto -> allow" allow "$(pc_call)"
doc "- 10:01 LIVE — working"
touch -t 202001010000 "$RESUME"
check "RESUME doc older than this session -> block" block "$LS"
# the session start is the wall clock, so a RESUME doc written a
# day ago (after any fixed date baked into the suite) is still older than it.
ago=$(( $(date +%s) - 86400 ))
stamp=$(date -d "@$ago" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$ago" +%Y%m%d%H%M.%S) # gnu-ok: paired with the BSD date -r
touch -t "$stamp" "$RESUME"
check "RESUME doc a day before this session -> block" block "$LS"
session "load $DOC and continue" "2026-10-06T12:00:00+02:00"
check "session start unparsable + old RESUME doc -> block" block "$LS"
session "load $DOC and continue" ""
check "session start missing + old RESUME doc -> block" block "$LS"
session "load $DOC and continue"
rm -f "$RESUME"
printf 'other worker\n' > "$DIR/HIMMEL-9-N78b-thing-2026-10-06-RESUME.md"
check "another worker's RESUME doc -> block" block "$LS"
printf 'longer id\n' > "$DIR/HIMMEL-9-N770b-thing-2026-10-06-RESUME.md"
check "a longer id sharing the prefix (N770) -> block" block "$LS"
doc "- 10:01 WRAPPED — merged"
check "last marker WRAPPED -> allow" allow "$LS"
doc "- 10:01 BLOCKED — waiting on chief"
# BLOCKED is a hand-off, not an unlock - it frees reads and
# the hand-off calls, never ordinary work (N1383 wrote BLOCKED, then kept editing).
check "last marker BLOCKED + Edit -> block" block "$(write_call Edit "$T/notes.md")"
check "last marker BLOCKED + Write -> block" block "$(write_call Write "$T/notes.md")"
check "last marker BLOCKED + ordinary Bash -> block" block "$LS"
check "last marker BLOCKED + Read -> allow" allow "$(tool_call Read)"
check "last marker BLOCKED + Grep -> allow" allow "$(tool_call Grep)"
check "last marker BLOCKED + Glob -> allow" allow "$(tool_call Glob)"
check "last marker BLOCKED + SendMessage -> allow" allow "$(tool_call SendMessage)"
check_c "compact, last marker BLOCKED + Edit -> block" block "$(write_call Edit "$T/notes.md")"
doc "- 10:01 FINDING — question"
check "last marker FINDING -> block" block "$LS"
doc "- 10:01 LIVE — working"

echo "== a resumed worker: its own RESUME-named doc is not its hand-off =="
DOC2="$DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md"
printf -- '# resumed\n\n## Results\n\n- 10:01 LIVE — resumed\n' > "$DOC2"
session "load $DOC2 and continue"
fill 90
check "resumed worker, only its own doc -> block" block "$LS"
reason="$(printf '%s' "$LS" | run_worker bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
case "$reason" in
    *"HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"*) ok "resumed worker is told to write the N77c doc" ;;
    *) bad "resumed worker suggestion wrong - got: $reason" ;;
esac
printf 'next\n' > "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
check "resumed worker + fresh N77c RESUME doc -> allow" allow "$LS"
rm -f "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
# Only a regular file in this directory carrying a later letter is the hand-off.
printf 'next\n' > "$T/n77c-target.md"
ln -s "$T/n77c-target.md" "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
check "resumed worker + symlinked N77c RESUME -> block" block "$LS"
rm -f "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md" "$T/n77c-target.md"
mkdir -p "$T/elsewhere"
printf 'next\n' > "$T/elsewhere/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
check "resumed worker + N77c RESUME in another directory -> block" block "$LS"
rm -rf "$T/elsewhere"
mkdir "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
check "resumed worker + a directory named N77c-RESUME.md -> block" block "$LS"
rmdir "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
printf 'next\n' > "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
chmod 000 "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
if [ -r "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md" ]; then
    printf 'SKIP: resumed worker + unreadable N77c RESUME -> block (running as root)\n'
else
    check "resumed worker + unreadable N77c RESUME -> block" block "$LS"
fi
chmod 600 "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
rm -f "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
printf 'back\n' > "$DIR/HIMMEL-9-N77a-thing-2026-10-06-RESUME.md"
check "resumed N77b worker + fresh N77a RESUME (letter backwards) -> block" block "$LS"
rm -f "$DIR/HIMMEL-9-N77a-thing-2026-10-06-RESUME.md"
rm -f "$DOC2"
# a worker id ending in z has no one-letter successor; the message
# must not name the worker's own doc as the thing to write.
DOCZ="$DIR/HIMMEL-9-N77z-thing-2026-10-06-RESUME.md"
printf -- '# resumed\n\n## Results\n\n- 10:01 LIVE — resumed\n' > "$DOCZ"
session "load $DOCZ and continue"
check "z-suffix worker, only its own doc -> block" block "$LS"
reason="$(printf '%s' "$LS" | run_worker bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
case "$reason" in
    *"resume brief to $DOCZ"*) bad "z-suffix worker told to write its own doc - got: $reason" ;;
    *"ends in z"*) ok "z-suffix worker is told no successor suffix exists" ;;
    *) bad "z-suffix worker message wrong - got: $reason" ;;
esac
printf 'next\n' > "$DIR/HIMMEL-9-N77-thing-2026-10-06-RESUME.md"
check "z-suffix worker + fresh unsuffixed N77 RESUME doc -> allow" allow "$LS"
rm -f "$DOCZ" "$DIR/HIMMEL-9-N77-thing-2026-10-06-RESUME.md"
session "load $DOC and continue"

echo "== in-process subagents (agent_id) are exempt =="
sub_call() { printf '%s' "$1" | jq -c --arg a "$2" '. + {agent_id:$a}'; }
check "subagent Bash at 90 % -> allow" allow "$(sub_call "$LS" a1b2c3)"
check "subagent Read at 90 % -> allow" allow "$(sub_call "$(tool_call Read)" a1b2c3)"
sub_out="$(sub_call "$LS" a1b2c3 | run_worker bash "$HOOK" 2>&1)"
if [ -z "$sub_out" ]; then ok "subagent -> no deny text, never invited to write a RESUME"; else bad "subagent printed: $sub_out"; fi
check "subagent RESUME write -> allow" allow "$(sub_call "$(write_call Write "$T/scratch/x-RESUME.md")" a1b2c3)"
check "parent still blocked after the subagent's RESUME write" block "$LS"
check "agent_id empty string -> not a subagent, block" block "$(sub_call "$LS" '')"
check "agent_id non-string -> not a subagent, block" block "$(printf '%s' "$LS" | jq -c '. + {agent_id:true}')"

echo "== WIP commit/push stays allowed at 90 % =="
check "git add -> allow" allow "$(bash_call 'git add scripts/x.sh')"
check "git commit -m -> allow" allow "$(bash_call 'git commit -m "wip: context hand-off"')"
check "git push -> allow" allow "$(bash_call 'git push origin fix/x')"
check "git -C <dir> commit -> allow" allow "$(bash_call 'git -C /work/tree commit -am wip')"
check "git commit && more -> block" block "$(bash_call 'git commit -m wip && ls')"
# shellcheck disable=SC2016 # a literal $( is the shape under test
check "git commit with \$( -> block" block "$(bash_call 'git commit -m "$(cat x)"')"
check "git status -> allow (the checkpoint reads it)" allow "$(bash_call 'git status --short')"
check "git rev-parse HEAD -> allow (the CHECKPOINT sha)" allow "$(bash_call 'git rev-parse HEAD')"
check "git log -> block (not a hand-off)" block "$(bash_call 'git log -1')"
check "git commitx -> block" block "$(bash_call 'git commitx')"
# A worker whose cwd drifted must be able to cd back.
check "bare cd <dir> -> allow" allow "$(bash_call 'cd /work/tree')"
check "bare cd -> allow" allow "$(bash_call 'cd')"
check "cd <dir>; more -> block" block "$(bash_call "cd $REPO; rm -rf x")"
check "cd <dir> | more -> block" block "$(bash_call "cd $REPO | ls")"
check "cd a b -> block" block "$(bash_call 'cd a b')"
# a quoted literal path is still one bare cd; a variable or a
# compound after it stays refused.
check "cd \"<dir with space>\" -> allow" allow "$(bash_call 'cd "/tmp/a b/c"')"
check "cd '<dir with space>' -> allow" allow "$(bash_call "cd '/tmp/a b/c'")"
check "cd \"<dir>\" -> allow" allow "$(bash_call "cd \"$REPO\"")"
check "cd \"<dir>\"; more -> block" block "$(bash_call 'cd "/tmp/a b"; rm -rf x')"
check "cd '<dir>' && more -> block" block "$(bash_call "cd '/tmp/a b' && ls")"
check "cd \"<dir>\" x -> block" block "$(bash_call 'cd "/tmp/a" x')"
# shellcheck disable=SC2016 # a literal $VAR / $( is the shape under test
check 'cd "$VAR" -> block' block "$(bash_call 'cd "$VAR"')"
# shellcheck disable=SC2016
check 'cd $VAR -> block' block "$(bash_call 'cd $VAR')"
# shellcheck disable=SC2016
check 'cd "$(pwd)" -> block' block "$(bash_call 'cd "$(pwd)"')"
# Round-2 codex-1: every command-substitution or chaining shape refuses the
# whole call, not only && || $( and a newline.
# shellcheck disable=SC2016 # literal backticks and <( are the shapes under test
check "cd \`payload\` -> block" block "$(bash_call 'cd `./payload`')"
# shellcheck disable=SC2016
check "git commit with backticks -> block" block "$(bash_call 'git commit -m "`id`"')"
check "git status; more -> block" block "$(bash_call 'git status; touch x')"
check "git status | more -> block" block "$(bash_call 'git status | sh')"
check "git push & more -> block" block "$(bash_call 'git push & touch x')"
check "git commit -F <( -> block" block "$(bash_call 'git commit -F <(echo x)')"
check "double-quoted bullet with ; -> allow" allow \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC \"LIVE a; b | c\"")"
# shellcheck disable=SC2016
check "double-quoted bullet with backticks -> block" block \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC \"LIVE \`id\`\"")"
check "escaped quote then ; -> block" block "$(bash_call "git status \\'; touch x; echo \\'")"
check "apostrophe in double quotes then ; -> block" block "$(bash_call "git commit -m \"it's\"; touch x; echo \"'\"")"
check "unclosed quote -> block" block "$(bash_call "git commit -m 'x")"
# Round-3 codex-1: ANSI-C quoting lets \' escape, so $'…' is refused outright.
check "ANSI-C quote then ; -> block" block "$(bash_call "git status \$'a\\'b'; touch x #'")"
check "ANSI-C quote alone -> block" block "$(bash_call "git commit -m \$'x'")"
check "dollar-quote inside double quotes is literal -> allow" allow "$(bash_call "git commit -m \"cost \$'x'\"")"
check "redirect -> block" block "$(bash_call 'git status > x')"
check "append-results.sh; more -> block" block \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC \"LIVE x\"; rm -rf /tmp/x")"

echo "== compact mode: a pushed CHECKPOINT of HEAD unlocks =="
session "load $DOC and continue"
doc "- 10:01 LIVE — working"
rm -f "$RESUME"
fill 90
HEAD1="$(g rev-parse HEAD)"
check_c "compact, no CHECKPOINT -> block" block "$LS"
printf 'resume\n' > "$RESUME"
check_c "compact, a fresh RESUME doc is not the unlock -> block" block "$LS"
rm -f "$RESUME"
reason="$(printf '%s' "$LS" | WORKER_SESSION_MODE=compact run_worker bash "$HOOK" 2>&1 >/dev/null)"
for needle in "mode compact" "git push" "CHECKPOINT <full sha of HEAD> pushed" "append-results.sh '$DOC'" \
    HIMMEL_WORKER_SESSION_CONTEXT_MODE "Do exactly this" \
    'git commit -m "<subject>" -m "<body>" --trailer' "one line" \
    "cannot push" "BLOCKED" "WRAPPED" "SendMessage your chief T-chief"; do
    case "$reason" in
        *"$needle"*) ok "compact deny text names: $needle" ;;
        *) bad "compact deny text lacks '$needle' - got: $reason" ;;
    esac
done
doc "- 10:01 LIVE — CHECKPOINT $HEAD1 pushed"
check_c "CHECKPOINT of the pushed HEAD -> allow" allow "$LS"
check_c "explicit HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact -> allow" allow "$LS" HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact
doc "- 10:01 LIVE — CHECKPOINT \`$HEAD1\` pushed"
check_c "backticked CHECKPOINT sha -> allow" allow "$LS"
# A BLOCKED after a valid CHECKPOINT is still a hand-off: the checkpoint unlock
# must not reopen ordinary work, though a safe auto-compaction may proceed.
doc "$(printf -- '- 10:01 LIVE — CHECKPOINT %s pushed\n- 10:02 BLOCKED — waiting on chief' "$HEAD1")"
check_c "CHECKPOINT then BLOCKED + Edit -> block" block "$(write_call Edit "$T/notes.txt")"
check_c "CHECKPOINT then BLOCKED + ordinary Bash -> block" block "$LS"
check_c "CHECKPOINT then BLOCKED + Read -> allow" allow "$(tool_call Read)"
check_c "CHECKPOINT then BLOCKED, PreCompact auto -> allow" allow "$(pc_call)"
doc "- 10:01 LIVE — CHECKPOINT $HEAD1 pushed"
check "handoff mode: a CHECKPOINT is not its unlock -> block" block "$LS"
printf 'b\n' > "$REPO/b"
g add b
g commit -qm two
HEAD2="$(g rev-parse HEAD)"
doc "- 10:01 LIVE — CHECKPOINT $HEAD1 pushed"
check_c "stale CHECKPOINT (HEAD moved on) -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 pushed"
check_c "CHECKPOINT of an unpushed HEAD -> block" block "$LS"
g push -q origin HEAD:refs/heads/main 2>/dev/null
check_c "the same CHECKPOINT once pushed -> allow" allow "$LS"
doc "$(printf -- '- 10:01 LIVE — CHECKPOINT %s pushed\n- 10:02 LIVE — CHECKPOINT %s pushed' "$HEAD2" "$HEAD1")"
check_c "newest CHECKPOINT bullet stale, older one fresh -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT $(printf '%040d' 7) pushed"
check_c "CHECKPOINT of a sha that is not this worktree's HEAD -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT ${HEAD2:0:12} pushed"
check_c "short CHECKPOINT sha -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT $HEAD2"
check_c "CHECKPOINT without 'pushed' -> block" block "$LS"
doc "CHECKPOINT $HEAD2 pushed"
check_c "CHECKPOINT outside a bullet -> block" block "$LS"
doc "- 10:01 LIVE — working"
printf -- '# other\n\n## Results\n\n- 10:01 LIVE — CHECKPOINT %s pushed\n' "$HEAD2" > "$DIR/HIMMEL-9-N78-other-2026-10-06.md"
check_c "another worker's doc carries the CHECKPOINT -> block" block "$LS"
rm -f "$DIR/HIMMEL-9-N78-other-2026-10-06.md"
doc "- 10:01 WRAPPED — merged"
check_c "compact, last marker WRAPPED -> allow" allow "$LS"
doc "- 10:01 LIVE — working"
check_c "compact, git commit stays allowed" allow "$(bash_call 'git commit -m wip')"
check_c "compact, append-results.sh stays allowed" allow \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC \"LIVE — CHECKPOINT $HEAD2 pushed\"")"

echo "== compact mode: a clean tree with nothing unpushed checkpoints without a push =="
# A worker that has only read has nothing to commit, and the
# pre-push CR gate refuses an empty push - N1386 could never checkpoint.
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 clean"
check_c "CHECKPOINT <HEAD> clean, clean tree, HEAD = upstream -> allow" allow "$LS"
check_c "CHECKPOINT clean also unlocks PreCompact" allow "$(pc_call)"
doc "- 10:01 LIVE — CHECKPOINT \`$HEAD2\` clean"
check_c "backticked CHECKPOINT clean sha -> allow" allow "$LS"
doc "- 10:01 LIVE — CHECKPOINT $HEAD1 clean"
check_c "CHECKPOINT clean of a stale sha -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 clean"
printf 'u\n' > "$REPO/untracked"
check_c "CHECKPOINT clean, untracked file -> block" block "$LS"
rm -f "$REPO/untracked"
printf 'a2\n' > "$REPO/a"
check_c "CHECKPOINT clean, modified file -> block" block "$LS"
g checkout -q -- a
g checkout -q -b noup
check_c "CHECKPOINT clean, no upstream, HEAD = origin/main (the base) -> allow" allow "$LS"
printf 'c\n' > "$REPO/c"
g add c
g commit -qm three
HEAD3="$(g rev-parse HEAD)"
doc "- 10:01 LIVE — CHECKPOINT $HEAD3 clean"
check_c "CHECKPOINT clean, no upstream, an unpushed commit -> block" block "$LS"
g checkout -q -
g branch -q -D noup
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 clean"
check "handoff mode: CHECKPOINT clean is not its unlock -> block" block "$LS"
doc "- 10:01 LIVE — working"

echo "== the mode is launch-time only =="
printf 'resume\n' > "$RESUME"
check "handoff from the launch env + RESUME -> allow" allow "$LS"
check_c "a Bash call exporting the mode -> block (mode stays compact)" block "$(bash_call 'export HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff')"
check_c "a per-call mode prefix -> block" block "$(bash_call 'HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff ls')"
doc "$(printf -- 'HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff\n- 10:01 LIVE — working')"
check_c "the mode written into the worker doc -> ignored, block" block "$LS"
doc "- 10:01 LIVE — working"
check_c "unknown mode value -> compact, RESUME is not the unlock" block "$LS" HIMMEL_WORKER_SESSION_CONTEXT_MODE=bogus
case "$(deny_text "$LS" HIMMEL_WORKER_SESSION_CONTEXT_MODE=bogus)" in
    *"mode compact"*) ok "unknown mode value -> the deny text says compact" ;;
    *) bad "unknown mode value -> deny text does not say compact" ;;
esac
rm -f "$RESUME"

echo "== the threshold derives from the autocompact ceiling =="
fill 15 1000000; check "1M window, default 200000 ceiling, 15 % -> block" block "$LS"
fill 14 1000000; check "1M window, default 200000 ceiling, 14 % -> allow" allow "$LS"
fill 15 1000000
case "$(deny_text "$LS")" in
    *"threshold 15 %"*"200000"*) ok "deny text names the derived threshold and the ceiling" ;;
    *) bad "deny text lacks the derived threshold - got: $(deny_text "$LS")" ;;
esac
fill 29 1000000; check "400000 ceiling on 1M, 29 % -> allow" allow "$LS" HIMMEL_WORKER_SESSION_AUTOCOMPACT=400000
fill 30 1000000; check "400000 ceiling on 1M, 30 % -> block" block "$LS" HIMMEL_WORKER_SESSION_AUTOCOMPACT=400000
fill 74 1000000; check "auto ceiling (the window), 74 % -> allow" allow "$LS" HIMMEL_WORKER_SESSION_AUTOCOMPACT=auto
fill 75 1000000; check "auto ceiling (the window), 75 % -> block" block "$LS" HIMMEL_WORKER_SESSION_AUTOCOMPACT=auto
fill 23 1000000; check "CLAUDE_CODE_AUTO_COMPACT_WINDOW 300000 wins, 23 % -> block" block "$LS" \
    HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000
fill 22 1000000; check "CLAUDE_CODE_AUTO_COMPACT_WINDOW 300000 wins, 22 % -> allow" allow "$LS" \
    HIMMEL_WORKER_SESSION_AUTOCOMPACT=200000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000
fill 74 200000; check "ceiling above the window clamps to it, 74 % -> allow" allow "$LS" HIMMEL_WORKER_SESSION_AUTOCOMPACT=400000
fill 75 200000; check "ceiling above the window clamps to it, 75 % -> block" block "$LS" HIMMEL_WORKER_SESSION_AUTOCOMPACT=400000
fill 50 1000000; check "junk ceiling -> the window (fail-open), 50 % -> allow" allow "$LS" HIMMEL_WORKER_SESSION_AUTOCOMPACT=junk
fill 29 1000000; check "the retired HIMMEL_LEG_AUTOCOMPACT=400000 is ignored: the 200000 pin, 29 % -> block" block "$LS" HIMMEL_LEG_AUTOCOMPACT=400000 # old-term-ok
printf '{"used_percentage":90,"remaining_percentage":10,"saved_at":%s000}' "$(date +%s)" \
    > "$CFG/plugins/claude-hud/context-cache/$(sha "$TR").json"
check "no window in the snapshot -> 75 % of the fill, 90 % -> block" block "$LS"

echo "== PreCompact: no auto-compaction past the threshold without CHECKPOINT/RESUME =="
fill 90
doc "- 10:01 LIVE — working"
check_c "PreCompact auto, compact, no CHECKPOINT -> block" block "$(pc_call)"
case "$(printf '%s' "$(pc_call)" | WORKER_SESSION_MODE=compact run_worker bash "$HOOK" 2>&1 >/dev/null)" in
    *CHECKPOINT*) ok "PreCompact refusal names the CHECKPOINT unlock" ;;
    *) bad "PreCompact refusal does not name CHECKPOINT" ;;
esac
check_c "PreCompact manual (operator /compact) -> allow" allow "$(pc_call manual)"
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 pushed"
check_c "PreCompact auto + fresh CHECKPOINT -> allow" allow "$(pc_call)"
doc "- 10:01 LIVE — working"
check "PreCompact auto, handoff, no RESUME -> block" block "$(pc_call)"
printf 'resume\n' > "$RESUME"
check "PreCompact auto, handoff + fresh RESUME -> allow" allow "$(pc_call)"
check_c "PreCompact auto, compact + fresh RESUME -> allow" allow "$(pc_call)"
rm -f "$RESUME"
doc "- 10:01 BLOCKED — waiting"
check_c "PreCompact auto, last marker BLOCKED, no CHECKPOINT -> block" block "$(pc_call)"
doc "- 10:01 WRAPPED — merged"
check_c "PreCompact auto, last marker WRAPPED -> allow" allow "$(pc_call)"
doc "- 10:01 LIVE — working"
# Below the threshold the worker has had no deny telling it to checkpoint, so a
# refusal there would be blind (ruling 2026-10-07): it passes.
fill 70; check_c "PreCompact below the threshold -> allow" allow "$(pc_call)"
nofill; check_c "PreCompact, fill UNKNOWN -> allow" allow "$(pc_call)"
fill 90
# A precomputed string: the hook exits before reading stdin here, and a slower
# writer would die of SIGPIPE under pipefail.
PC="$(pc_call)"
if printf '%s' "$PC" | env CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" >/dev/null 2>&1; then
    ok "PreCompact in a non-worker session -> allow"
else
    bad "PreCompact in a non-worker session -> blocked"
fi

echo "== fail-open: fill UNKNOWN/STALE, worker doc unknown, junk input =="
nofill
check "no HUD snapshot (UNKNOWN) at would-be 90 % -> allow" allow "$LS"
warn="$(printf '%s' "$LS" | run_worker bash "$HOOK" 2>&1 >/dev/null)"
case "$warn" in
    *guard-worker-context-handoff*) ok "UNKNOWN fill -> one-line warning on stderr" ;;
    *) bad "UNKNOWN fill -> no warning - got: $warn" ;;
esac
if [ "$(printf '%s\n' "$warn" | wc -l | tr -d ' ')" = 1 ]; then ok "warning is one line"; else bad "warning is not one line: $warn"; fi
printf '{"used_percentage":90,"remaining_percentage":10,"context_window_size":200000,"saved_at":1000}' \
    > "$CFG/plugins/claude-hud/context-cache/$(sha "$TR").json"
check "STALE snapshot at 90 % -> allow" allow "$LS"
fill 90
check "no transcript_path -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
session "hello, no brief path here"
fill 90
check "worker doc not named in the first turn -> allow" allow "$LS"
session "load $DIR/missing-doc.md and continue"
fill 90
check "worker doc named but missing -> allow" allow "$LS"
session "load $DOC and continue"
fill 90
check "malformed JSON -> allow" allow '{not json'
check "empty stdin -> allow" allow ''

echo "== array-shaped first user turn =="
jq -cn --arg t "load $DOC and continue" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"text",text:$t}]}}' > "$TR"
fill 90
check "content as a text-block array -> worker doc found, block" block "$LS"

echo "== 10776: a RESUME brief is linted before the hand-off unlocks =="
session "load $DOC and continue"; fill 90; doc "- 10:01 LIVE — working"
rm -f "$DIR"/*-RESUME.md
C1="$DIR/PROJ-1-N77b-thing-2026-10-06-RESUME.md"
C2="$DIR/PROJ-1-N77c-thing-2026-10-06-RESUME.md"
APPEND="$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC \"BLOCKED — context 90 %, RESUME written: $C1\"")"
REAL='GUARD_CONTEXT_HANDOFF_BRIEF_LINT='
stamp_epoch() { date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S; } # gnu-ok: paired with the BSD date -r
age() { touch -t "$(stamp_epoch $(( $(date +%s) + $2 )))" "$1"; }
fresh() { rm -f "$DIR"/*-RESUME.md; resetmap; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 - lacks '$2' - got: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1 - has '$2'" ;; *) ok "$1" ;; esac; }
lint_runs() { wc -l < "$LINT_LOG" | tr -d ' '; }
resume_doc() {
    local key; key="$(basename "$1" | grep -oE '^[A-Z][A-Z0-9]*-[0-9]+')"
    {
        printf -- '---\nresume_cwd: %s\ndescription: "resume of N77"\n---\n\n# %s — resume N77b\n\n' "$REPO" "$key"
        [ "$2" = yes ] && printf '> **Prior art:** none found (qmd query jira-himmel guard-worker-context-handoff)\n\n'
        printf '> **Writes:** none named\n\n## Results (newest at the bottom)\n\n'
    } > "$1"
}
timed() {
    local t0=$SECONDS lbl="$1" mx="$3"
    check "$lbl" "$2" "$4" "${@:5}"
    local took=$((SECONDS - t0))
    if [ "$took" -le "$mx" ]; then ok "$lbl: returned in ${took}s (limit ${mx}s)"; else bad "$lbl: took ${took}s (limit ${mx}s)"; fi
}

echo "-- D1/D2: the real brief-lint decides the unlock --"
fresh
resume_doc "$C1" no
check "10776 L1: a fresh RESUME with no Prior art line -> block" block "$LS" "$REAL"
has "10776 L1: the deny names the lint class" "[lint: fixable]" "$(deny_text "$LS" "$REAL")"
check "10776 L1.pc: the same doc at an auto PreCompact -> block" block "$(pc_call)" "$REAL"
resume_doc "$C1" yes
check "10776 L1.ctl: the same doc with its Prior art line -> allow" allow "$LS" "$REAL"
check "10776 L1.pc.ctl: ... at an auto PreCompact -> allow" allow "$(pc_call)" "$REAL"
check "10776 L2: lint-clean key-bearing RESUME, stub Jira CLI answering IN and NOT-CORE -> allow" allow "$LS" "$REAL"
check "10776 L2.ctl: the stub CLI answers CORE with NO-SPEC -> block" block "$LS" "$REAL" GUARD_TEST_CORE=nospec
has "10776 L2.ctl: the deny says stuck" "[lint: stuck]" "$(deny_text "$LS" "$REAL" GUARD_TEST_CORE=nospec)"

G13_LINT="GUARD_CONTEXT_HANDOFF_BRIEF_LINT=$HOOKS/../handover/chief-kit/brief-lint.sh"
G13_WT="$T/g13-wt"
git init -q "$T/g13-base" && git -C "$T/g13-base" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q --allow-empty -m base \
    && git -C "$T/g13-base" worktree add -q -b g13 "$G13_WT"
mkdir -p "$G13_WT/.claude" "$G13_WT/scripts/hooks" "$G13_WT/scripts/lib"
# shellcheck disable=SC2016  # literal fixture source line and command
printf '. "$(dirname "$0")/../lib/g-lib.sh"\n' > "$G13_WT/scripts/hooks/guard-g.sh"
printf '# g-lib\n' > "$G13_WT/scripts/lib/g-lib.sh"; printf '# other\n' > "$G13_WT/scripts/lib/other.sh"
# shellcheck disable=SC2016
printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"node \"$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js\" \"$CLAUDE_PROJECT_DIR/scripts/hooks/guard-g.sh\""}]}]}}' > "$G13_WT/.claude/settings.json"
g13_doc() {
    resume_doc "$C1" yes
    sed -i.bak -e "s|^resume_cwd:.*|resume_cwd: $G13_WT|" -e "s|^> \*\*Writes:\*\* none named|> **Writes:** $1|" "$C1" && rm -f "$C1.bak"
}
g13_row() {
    local label="$1" expect="$2" bypass="$3" text="" n rc got; shift 3
    for n in 1 2; do
        text="$(printf '%s' "$LS" | run_worker "$G13_LINT" HIMMEL_HOOK_INTEGRITY_BYPASS_OK="$bypass" bash "$HOOK" 2>&1 >/dev/null)"; rc=$?
        case "$text" in *"did not answer"*|*unlinted*) continue ;; esac
        break
    done
    case "$text" in *"did not answer"*|*unlinted*) printf 'SKIP: %s (the linter missed the hook budget twice: %s)\n' "$label" "$text"; return ;; esac
    case "$rc" in 0) got=allow ;; 2) got=block ;; *) got="?(rc=$rc)" ;; esac
    if [ "$got" != "$expect" ]; then bad "$label - expected $expect got $got: $text"; return; fi
    for n in "$@"; do case "$text" in *"$n"*) ;; *) bad "$label - lacks '$n' - got: $text"; return ;; esac; done
    ok "$label"
}
g13_doc scripts/lib/g-lib.sh
g13_row "11216 G13: a RESUME naming a guard-run lib is stuck without the bypass, fix in the deny" block '' \
    "[lint: stuck]" "launch with HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1" "You cannot clear this"
g13_row "11216 G13.bypass: the same doc unlocks with the bypass in the hook env" allow 1
g13_doc scripts/lib/other.sh
g13_row "11216 G13.ctl: the same doc naming an unrelated lib unlocks" allow ''

echo "-- candidates and verdicts (stub linter) --"
fresh
resume_doc "$C1" yes; resume_doc "$C2" yes; age "$C1" 5; age "$C2" 10
setmap "$(basename "$C1")" 0
setmap "$(basename "$C2")" 1 - 0 'brief-lint: <c>: no Prior art'
check "10776 M1: pass plus fixable -> unlock blocked" block "$LS"
has "10776 M1: the deny names the fixable path" "$C2" "$(deny_text "$LS")"
check "10776 M1: BLOCKED is denied (a fixable candidate)" block "$APPEND"
resetmap
setmap "$(basename "$C1")" 0
setmap "$(basename "$C2")" 3 - 0 'brief-lint: <c>: core brief PROJ-1 has no signed spec'
check "10776 M3: pass plus stuck -> unlock blocked" block "$LS"
check "10776 M3: BLOCKED passes (stuck is the chief's)" allow "$APPEND"
resetmap
setmap "$(basename "$C1")" 3
setmap "$(basename "$C2")" 1 - 0 'brief-lint: <c>: no Prior art'
check "10776 M2: fixable newer, stuck older -> BLOCKED denied" block "$APPEND"
resetmap
setmap "$(basename "$C2")" 3
setmap "$(basename "$C1")" 1 - 0 'brief-lint: <c>: no Prior art'
check "10776 M4: stuck newer, fixable older -> BLOCKED denied (the pass goes on past stuck)" block "$APPEND"
resetmap
setmap "$(basename "$C2")" 3 30 1
setmap "$(basename "$C1")" 1 - 0 'brief-lint: <c>: no Prior art'
: > "$LINT_LOG"
timed "10776 M5: stuck newer sleeps past the budget, fixable older unreached -> BLOCKED allowed" allow 10 "$APPEND"
if [ "$(lint_runs)" = 1 ]; then ok "10776 M5/O1: the second candidate was unlinted (one lint run, one budget)"; else bad "10776 M5/O1: lint runs: $(lint_runs)"; fi
pkill -f "$GC_RE" 2>/dev/null || true

echo "-- A1: the hook's lint call is one path and no flag --"
fresh
resume_doc "$C1" yes
check "A1 setup: stub pass -> allow" allow "$LS"
if [ "$(cat "$LINT_LOG")" = "$(printf '1\t%s' "$C1")" ]; then ok "10776 A1: lint.log holds exactly one argument, the candidate path"; else bad "10776 A1: lint.log: $(cat "$LINT_LOG")"; fi
MIR="$T/mirror"; mkdir -p "$MIR/scripts/hooks"
ln -s "$HOOKS/../lib" "$MIR/scripts/lib"; ln -s "$HOOKS/../context-fill.sh" "$MIR/scripts/context-fill.sh"
cp "$HOOK" "$MIR/scripts/hooks/guard-worker-context-handoff.sh"
: > "$LINT_LOG"
printf '%s' "$LS" | run_worker bash "$MIR/scripts/hooks/guard-worker-context-handoff.sh" >/dev/null 2>&1
if [ "$(cat "$LINT_LOG")" = "$(printf '1\t%s' "$C1")" ]; then ok "10776 A1.ctl: the unmodified mirrored hook passes the assertion first"; else bad "10776 A1.ctl: mirrored hook lint.log: $(cat "$LINT_LOG")"; fi
sed 's/bash "\$lint_path" "\$c"/bash "$lint_path" --core-only "$c"/' "$HOOK" > "$MIR/scripts/hooks/guard-worker-context-handoff.sh"
: > "$LINT_LOG"
printf '%s' "$LS" | run_worker bash "$MIR/scripts/hooks/guard-worker-context-handoff.sh" >/dev/null 2>&1
if [ "$(cat "$LINT_LOG")" = "$(printf '2\t--core-only %s' "$C1")" ]; then ok "10776 A1.ctl: a copy with --core-only fails the assertion (only the flag differs)"; else bad "10776 A1.ctl: flagged copy lint.log: $(cat "$LINT_LOG")"; fi

echo "-- X2, T2.bypass: exit classes --"
fresh
resume_doc "$C1" yes
setmap "$(basename "$C1")" 2 - 0 'brief-lint: usage'
check "10776 X2: lint exit 2 -> unlock stays closed" block "$LS"
has "10776 X2: the deny says stuck" "[lint: stuck]" "$(deny_text "$LS")"
check "10776 X2: BLOCKED passes" allow "$APPEND"
fresh
resume_doc "$C1" no
has "10776 T2.bypass: a bypass-key doc without Prior art names Prior art, not the bypass note" "no '> **Prior art:**' line" "$(deny_text "$LS" "$REAL" GUARD_TEST_CORE=bypass)"

echo "-- D4: the BLOCKED gate and its controls --"
fresh
resume_doc "$C1" yes
setmap "$(basename "$C1")" 1 - 0 'brief-lint: <c>: no Prior art'
check "10776 B1: a fixable candidate + append-results.sh BLOCKED -> block" block "$APPEND"
setmap "$(basename "$C1")" 3
check "10776 B1.ctl1: stuck (exit 3) -> allow" allow "$APPEND"
setmap "$(basename "$C1")" 0
check "10776 B1.ctl3: pass -> allow" allow "$APPEND"
fresh
check "10776 B1.ctl2: no candidate -> allow" allow "$APPEND"
resume_doc "$C1" yes
setmap "$(basename "$C1")" 1 - 0 'brief-lint: <c>: no Prior art'
: > "$LINT_LOG"
check "10776 B1.env: HANDOVER_DIR empty, a stub that would exit 1 -> BLOCKED allowed" allow "$APPEND" HANDOVER_DIR=
check "10776 B1.env.rel: HANDOVER_DIR relative -> BLOCKED allowed" allow "$APPEND" HANDOVER_DIR=handovers
check "10776 B1.env: ... and an ordinary call blocks" block "$LS" HANDOVER_DIR=
has "10776 B1.env: ... naming the root" "handover root not loadable" "$(deny_text "$LS" HANDOVER_DIR=)"
if [ "$(lint_runs)" = 0 ]; then ok "10776 B1.env: lint was not run"; else bad "10776 B1.env: lint runs: $(lint_runs)"; fi
doc "- 10:01 BLOCKED — context 90 %, RESUME written"
: > "$LINT_LOG"
check "10776 B1.tail: last marker BLOCKED + a fixable candidate -> allow" allow "$APPEND"
if [ "$(lint_runs)" = 0 ]; then ok "10776 B1.tail: no lint run"; else bad "10776 B1.tail: lint runs: $(lint_runs)"; fi
doc "- 10:01 LIVE — working"
session "hello, no brief path here"; fill 90
check "10776 B1.nodoc: the doc cannot be resolved -> allow (as today)" allow "$APPEND"
session "load $DOC and continue"; fill 90
: > "$LINT_LOG"
check_c "10776 B1.cmp: compact mode, a fixable stub present, append-results.sh -> allow" allow "$APPEND"
check_c "10776 B1.cmp.append: compact CHECKPOINT append -> allow" allow \
    "$(bash_call "bash scripts/handover/chief-kit/append-results.sh $DOC \"LIVE — CHECKPOINT $HEAD2 pushed\"")"
if [ "$(lint_runs)" = 0 ]; then ok "10776 B1.cmp: compact mode runs no lint"; else bad "10776 B1.cmp: lint runs: $(lint_runs)"; fi
: > "$LINT_LOG"
check "10776 I7.a: SendMessage with a fixable candidate -> allow" allow "$(tool_call SendMessage)"
check "10776 I7.a: ToolSearch -> allow" allow "$(tool_call ToolSearch)"
check "10776 I7.a: TaskStop -> allow" allow "$(tool_call TaskStop)"
check "10776 I7.a: Write of the RESUME -> allow" allow "$(write_call Write "$C1")"
check "10776 I7.a: queue-lock.sh release -> allow" allow "$(bash_call "bash scripts/handover/queue-lock.sh release $DOC tok")"
check "10776 I7.a: git commit -> allow" allow "$(bash_call 'git commit -m wip')"
if [ "$(lint_runs)" = 0 ]; then ok "10776 I7.a: none of them ran lint"; else bad "10776 I7.a: lint runs: $(lint_runs)"; fi

echo "-- D6: the budget and the watchdog --"
fresh
resume_doc "$C1" yes
setmap "$(basename "$C1")" 0 30 1
timed "10776 W1: a lint that hangs with a grandchild -> block" block 10 "$LS"
has "10776 W1: the deny names the deadline" "did not answer" "$(deny_text "$LS")"
if pgrep -f "$GC_RE" >/dev/null 2>&1; then bad "10776 W1: a stub process outlived the hook"; pkill -f "$GC_RE"; else ok "10776 W1: no stub process remains"; fi
timed "10776 W1.pc: at an auto PreCompact -> block within 7 s" block 7 "$(pc_call)"
pkill -f "$GC_RE" 2>/dev/null || true
resume_doc "$C2" yes; age "$C2" 10
setmap "$(basename "$C2")" 0 30 1
timed "10776 W2: two hanging candidates -> block within 10 s" block 10 "$LS"
pkill -f "$GC_RE" 2>/dev/null || true
fresh
resume_doc "$C1" yes
check "10776 W1.ctl: a stub answering 0 at once -> allow" allow "$LS"
fresh
n=0; while [ "$n" -lt 60 ]; do : > "$DIR/PROJ-1-N$((900 + n))b-x-RESUME.md"; n=$((n + 1)); done
resume_doc "$C1" yes
setmap "$(basename "$C1")" 0 30 1
timed "10776 W3: 60 off-pattern RESUME files plus one hanging candidate -> within 10 s" block 10 "$LS"
pkill -f "$GC_RE" 2>/dev/null || true

echo "-- D7: the primary's linter, never the worktree's copy --"
fresh
PRIM="$T/prim"; WT="$T/wt"
gp() { git -C "$PRIM" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=t@t -c user.name=t "$@"; }
git init -q "$PRIM"; printf 'p\n' > "$PRIM/p"; gp add p; gp commit -qm p
gp worktree add -q -b wtb "$WT"
mkdir -p "$WT/scripts/hooks" "$WT/scripts/handover/chief-kit" "$PRIM/scripts/handover/chief-kit"
cp "$HOOK" "$WT/scripts/hooks/guard-worker-context-handoff.sh"
cp -R "$HOOKS/../lib" "$WT/scripts/lib"; cp "$HOOKS/../context-fill.sh" "$WT/scripts/context-fill.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WT/scripts/handover/chief-kit/brief-lint.sh"
# shellcheck disable=SC2016 # the stub's own $1 is written literally
printf '#!/usr/bin/env bash\nprintf "brief-lint: %%s: refused by the primary\\n" "$1" >&2\nexit 1\n' > "$PRIM/scripts/handover/chief-kit/brief-lint.sh"
resume_doc "$C1" yes
HOOK_SAVE="$HOOK"; SEAM_SAVE="$LINT_SEAM"; HOOK="$WT/scripts/hooks/guard-worker-context-handoff.sh"; LINT_SEAM=''
check "10776 P1: the worktree's linter says 0, the primary's says 1 -> block" block "$LS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PRIM/scripts/handover/chief-kit/brief-lint.sh"
check "10776 P1.ctl: both pass -> allow" allow "$LS"
rm -f "$PRIM/scripts/handover/chief-kit/brief-lint.sh"
check "10776 P1.miss: no linter at the primary -> block" block "$LS"
has "10776 P1.miss: the deny says so" "brief-lint not found" "$(deny_text "$LS")"
HOOK="$HOOK_SAVE"; LINT_SEAM="$SEAM_SAVE"

echo "-- D8: the self-check shape --"
fresh
SC_NAME="PROJ-1-N77b-thing-2026-10-06-RESUME.md"
sc() { bash_call "bash $LINT_STUB $*"; }
check "10776 S1: bash <linter> <dir>/<name>-RESUME.md -> allow" allow "$(sc "$DIR/$SC_NAME")"
check "10776 S1.ctl: ... plus ; rm x -> block" block "$(sc "$DIR/$SC_NAME; rm x")"
check "10776 S1.two: two path arguments -> block" block "$(sc "$DIR/$SC_NAME $DIR/$SC_NAME")"
check "10776 S1.flag: a --core-only flag -> block" block "$(sc "--core-only $DIR/$SC_NAME")"
check "10776 S1.copy: another linter -> block" block "$(bash_call "bash $T/other/brief-lint.sh $DIR/$SC_NAME")"
check "10776 S1.quote: the path in quotes -> block" block "$(sc "\"$DIR/$SC_NAME\"")"
check "10776 S1.dir: a RESUME in another directory -> block" block "$(sc "$T/elsewhere/$SC_NAME")"
# shellcheck disable=SC2016
check '10776 S1.meta: a name carrying $ -> block' block "$(sc "$DIR/"'a$b-RESUME.md')"
check "10776 S1.meta: a name carrying a glob -> block" block "$(sc "$DIR/"'a*-RESUME.md')"
check "10776 S1.nameless: a name that is not a RESUME -> block" block "$(sc "$DIR/notes.md")"
SPDIR="$T/sp dir/h/u"; mkdir -p "$SPDIR"; SPDOC="$SPDIR/HIMMEL-9-N77-thing-2026-10-06.md"
printf -- '---\n---\n# brief\n\n## Results (newest at the bottom)\n\n- 10:01 LIVE — working\n' > "$SPDOC"
session "load $SPDOC and continue"; fill 90
check "10776 S1.sp: a doc directory with a space admits no shape -> block" block "$(sc "$SPDIR/$SC_NAME")"
hasnt "10776 T1.sp: no 1a) in the deny" "1a)" "$(deny_text "$LS")"
session "load $DOC and continue"; fill 90

echo "-- D3: the deny texts --"
fresh
t1="$(deny_text "$LS")"
has "10776 T1: the handoff deny names the Prior art line" '> **Prior art:**' "$t1"
has "10776 T1: ... and the worker's own doc as its source" "from $DOC" "$t1"
has "10776 T1: ... and brief-lint" "brief-lint" "$t1"
has "10776 T1: ... and the self-check command (1a)" "1a) Check it: bash $LINT_STUB $DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md" "$t1"
resume_doc "$C1" yes
setmap "$(basename "$C1")" 1 - 0 'a note first\nbrief-lint: <c>: no '"'"'> **Prior art:**'"'"' line'
t2="$(deny_text "$LS")"
has "10776 T2: the fixable deny quotes the last brief-lint line" "brief-lint: $C1: no '> **Prior art:**' line" "$t2"
has "10776 T2: ... and says to copy the Prior art line" '> **Prior art:**' "$t2"
hasnt "10776 T2: ... and not the note before it" "a note first" "$t2"
setmap "$(basename "$C1")" 3 - 0 'brief-lint: <c>: no signed spec'
t3="$(deny_text "$LS")"
has "10776 T3: the stuck deny carries the reason" "no signed spec" "$t3"
has "10776 T3: ... and the chief's name" "T-chief" "$t3"
fresh
GOLDEN="$(sed "s|__DOC__|$DOC|g" <<'GOLD'
worker context checkpoint (mode compact): this session is at 90 % context fill (threshold 75 % = 75 % of the 200000-token autocompact ceiling on a 200000-token window). Ordinary tool calls stay denied until you checkpoint. Do exactly this: 1) git add and git commit your WIP, then git push. A commit is one line (a newline in the command is denied): git commit -m "<subject>" -m "<body>" --trailer "Platforms tested: <os>" --trailer "Security reviewed: <token> - <what>". 2) git rev-parse HEAD. 3) bash scripts/handover/chief-kit/append-results.sh '__DOC__' "LIVE — CHECKPOINT <full sha of HEAD> pushed". 4) Carry on with your work: the session compacts at its ceiling and continues. A new commit after the checkpoint needs a push and a fresh CHECKPOINT bullet. Nothing to commit and nothing unpushed (git status clean, HEAD on its upstream or in origin/main)? Skip 1 and write "LIVE — CHECKPOINT <full sha of HEAD> clean" instead. If you cannot push or commit (a moved upstream, a refused attestation or pre-commit gate), do not work around it: SendMessage your chief T-chief what blocks you, then bash scripts/handover/chief-kit/append-results.sh '__DOC__' "BLOCKED — <why>" and stop. BLOCKED frees only these hand-off calls and reads (Read, Grep, Glob), not your work; WRAPPED (after the merge) frees everything. Still allowed meanwhile: SendMessage, ListAgents, ToolSearch, TaskStop, the mail reads (mcp__himmel-bus__read, ReadNotifications, FetchInboxMessage), append-results.sh, queue-lock.sh release, wrap-subtree-check.sh, context-fill.sh, git add/commit/push/status/rev-parse, a bare cd. The mode is set at launch by the chief (HIMMEL_WORKER_SESSION_CONTEXT_MODE); it cannot be changed in-session. Bypass: WORKER_SESSION_CONTEXT_HANDOFF_OK=1 in the launching shell.
GOLD
)"
if [ "$(WORKER_SESSION_MODE=compact deny_text "$LS")" = "$GOLDEN" ]; then ok "10776 T1.ctl: the compact deny is byte-identical to the base's"; else bad "10776 T1.ctl: the compact deny changed"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
