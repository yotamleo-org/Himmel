#!/usr/bin/env bash
# test-steering-cull-cadence.sh - steering-cull-cadence.sh (HIMMEL-5634): the
# weekly read-only steering-file cull run, its proposal doc, the console
# escalation line and the cron arm/disarm.
# Hermetic: HOME, state, crontab, runner dir, inbox, preflight and claude are
# all stubs inside a mktemp dir. Never arms anything on the real station and
# never calls a model.
# Exit: 0 = all pass, 1 = a case failed.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_ROOT="$(cd "$DIR/../.." && pwd)"
PASSED=0; FAILED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
# check <label> <expected> <actual>
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (no '$2' in $3)"; fi; }
hasnt() { if grep -qF -- "$2" "$3" 2>/dev/null; then fail "$1 ('$2' present in $3)"; else pass "$1"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/steercull-cad.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME/.claude"
export HIMMEL_FLOW_RUNS_LEDGER="$W/flow-runs.jsonl"

# A primary checkout carrying the script under test and the alert sink.
P="$W/primary"
mkdir -p "$P/scripts/cleanup" "$P/scripts/luna"
git init -q "$P"
cp "$DIR/steering-cull-cadence.sh" "$P/scripts/cleanup/" 2>/dev/null || true
cp "$REAL_ROOT/scripts/luna/cadence-alert.sh" "$P/scripts/luna/"
printf '# project rules\n' > "$P/CLAUDE.md"
git -C "$P" add -A
git -C "$P" -c user.name=t -c user.email=t@t commit -q -m fixture
CAD="$P/scripts/cleanup/steering-cull-cadence.sh"

printf '# global\n' > "$HOME/.claude/CLAUDE.md"
printf '# rtk\n' > "$HOME/.claude/RTK.md"

# Stub claude: logs argv + cwd, prints $W/claude.json, exits $W/claude.rc.
cat > "$W/claude.sh" <<'SH'
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "$PWD"; printf 'arg=%s\n' "$@"; } >> "$STUB_DIR/argv"
cat "$STUB_DIR/claude.json"
exit "$(cat "$STUB_DIR/claude.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$W/claude.sh"
# Stub preflight: prints $W/preflight (default PROCEED).
cat > "$W/preflight.sh" <<'SH'
#!/usr/bin/env bash
cat "$STUB_DIR/preflight" 2>/dev/null || echo PROCEED
SH
chmod +x "$W/preflight.sh"
export STUB_DIR="$W"

export STEERING_CULL_CLAUDE="$W/claude.sh"
export STEERING_CULL_PREFLIGHT_CMD="$W/preflight.sh"
export STEERING_CULL_STATE_DIR="$W/state"
export CADENCE_ALERT_FILE="$W/alerts.log"
export CADENCE_ALERT_DEDUPE_DIR="$W/alert-sent"
export CADENCE_ALERT_SEND_CMD="$W/send.sh"
printf '#!/bin/sh\nexit 0\n' > "$W/send.sh"; chmod +x "$W/send.sh"

PROP="$W/proposals"
INBOX_ROOT="$W/bridge"; mkdir -p "$INBOX_ROOT/consoles"
INBOX="$INBOX_ROOT/consoles/test-console.md"; : > "$INBOX"
export BRIDGE_ROOT="$INBOX_ROOT"

TODAY="2026-10-14"
export STEERING_CULL_DATE="$TODAY"

# ---- 1. completed run: doc written, escalation line names it -----------------
RESULT=$'## Proposal\n- [LOW] CLAUDE.md:10-12 — duplicate of a rule in docs\n- [LOW] CLAUDE.md:20 — stale pointer\n- [MEDIUM] CLAUDE.md:30-40 — behavioural rule, needs a judgement call\n- [LOW] /home/x/.claude/CLAUDE.md:5 — live file, always escalates\n- [LOW] ../outside/CLAUDE.md:1 — traversal, escalates\n- [LOW] misspelt.md:1 — not a repo file, escalates\n'
node -e 'console.log(JSON.stringify({type:"result",is_error:false,result:process.argv[1]}))' "$RESULT" > "$W/claude.json"
bash "$CAD" run --repo "$P" --proposal-dir "$PROP" --console test-console >"$W/run1.out" 2>&1
check "run exits 0" 0 $?
DOC="$PROP/steering-cull-$TODAY.md"
[ -f "$DOC" ] && pass "proposal doc written at the dated path" || fail "no proposal doc at $DOC"
has "doc carries the model output" "stale pointer" "$DOC"
has "doc counts 2 low repo cuts" "low: 2" "$DOC"
has "doc counts 4 escalated (medium, live, traversal, unknown path)" "escalated: 4" "$DOC"
has "console inbox line names the doc" "$DOC" "$INBOX"
has "console inbox line carries the counts" "2 low, 4 escalated" "$INBOX"

# ---- 2. claude is invoked read-only, headless, JSON ---------------------------
has "claude gets -p" "arg=-p" "$W/argv"
has "claude gets json output" "arg=json" "$W/argv"
has "claude gets plan permission mode" "arg=plan" "$W/argv"
has "claude is restricted to the Read tool" "arg=--tools" "$W/argv"
hasnt "claude never gets bypassPermissions" "bypassPermissions" "$W/argv"
has "claude runs in the repo" "cwd=$P" "$W/argv"

# ---- 3. bank-preflight not PROCEED: skip, no claude, no doc ------------------
rm -f "$W/argv" "$DOC"
echo "HOLD bank at 91%" > "$W/preflight"
bash "$CAD" run --repo "$P" --proposal-dir "$PROP" --console test-console >"$W/run3.out" 2>&1
check "held preflight exits 0" 0 $?
[ ! -e "$W/argv" ] && pass "held preflight never calls claude" || fail "claude called despite HOLD"
[ ! -e "$DOC" ] && pass "held preflight writes no doc" || fail "doc written despite HOLD"
rm -f "$W/preflight"

# ---- 4. claude error: alert, no doc, rc 1 ------------------------------------
printf '{"type":"result","is_error":true,"result":"boom"}\n' > "$W/claude.json"
: > "$W/alerts.log"
bash "$CAD" run --repo "$P" --proposal-dir "$PROP" --console test-console >"$W/run4.out" 2>&1
check "claude error exits 1" 1 $?
has "claude error alerts" "steering-cull" "$W/alerts.log"
[ ! -e "$DOC" ] && pass "claude error writes no doc" || fail "doc written on claude error"

printf '{"type":"result","is_error":false}\n' > "$W/claude.json"
: > "$W/alerts.log"
bash "$CAD" run --repo "$P" --proposal-dir "$PROP" --console test-console >"$W/run4b.out" 2>&1
check "success flag without a result exits 1" 1 $?
has "missing result alerts" "empty-result" "$W/alerts.log"
[ ! -e "$DOC" ] && pass "missing result writes no doc" || fail "doc written with no result"

# ---- 5. missing console inbox: doc still written, alert raised ----------------
node -e 'console.log(JSON.stringify({type:"result",is_error:false,result:"- [MEDIUM] CLAUDE.md:1 — x\n"}))' > "$W/claude.json"
: > "$W/alerts.log"
bash "$CAD" run --repo "$P" --proposal-dir "$PROP" --console no-such-console >"$W/run5.out" 2>&1
check "missing inbox exits 1" 1 $?
[ -f "$DOC" ] && pass "missing inbox still writes the doc" || fail "doc lost when the inbox is missing"
has "missing inbox alerts" "no-inbox" "$W/alerts.log"

# ---- 6. arm / status / disarm -------------------------------------------------
cat > "$W/crontab.sh" <<'SH'
#!/usr/bin/env bash
f="$STUB_DIR/crontab.txt"
if [ "${1:-}" = "-l" ]; then [ -s "$f" ] && cat "$f" || { echo "no crontab for t" >&2; exit 1; }
else cat > "$f"; fi
SH
chmod +x "$W/crontab.sh"
export STEERING_CULL_CRONTAB="$W/crontab.sh"
export STEERING_CULL_RUNNER_DIR="$W/runner"
bash "$CAD" arm --dry-run --console test-console --proposal-dir "$PROP" >"$W/arm0.out" 2>&1
has "dry-run shows a weekly entry (Monday 07:00)" "00 07 * * 1" "$W/arm0.out"
[ ! -s "$W/crontab.txt" ] && pass "dry-run installs nothing" || fail "dry-run touched the crontab"
bash "$CAD" arm --console test-console --proposal-dir "$PROP" >"$W/arm1.out" 2>&1
check "arm exits 0" 0 $?
has "crontab carries the tag" "# HIMMEL-SteeringCull" "$W/crontab.txt"
has "runner calls run with the console" "--console test-console" "$W/runner/steering-cull-cadence.sh"
bash "$CAD" arm --console test-console --proposal-dir "$PROP" >"$W/arm2.out" 2>&1
check "double arm refused" 3 $?
bash "$CAD" arm --proposal-dir "$PROP" --force >"$W/arm3.out" 2>&1
check "arm without --console refused" 1 $?
( cd "$W" && bash "$CAD" arm --force --console test-console --proposal-dir rel/props ) >"$W/arm4.out" 2>&1
has "arm resolves a relative --proposal-dir to an absolute path" "$W/rel/props" "$W/runner/steering-cull-cadence.sh"
bash "$CAD" status >"$W/st.out" 2>&1
has "status reports ARMED" "ARMED" "$W/st.out"
bash "$CAD" disarm >"$W/dis.out" 2>&1
check "disarm exits 0" 0 $?
hasnt "disarm removes the entry" "HIMMEL-SteeringCull" "$W/crontab.txt"

echo "steering-cull-cadence: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
