#!/usr/bin/env bash
# test-steering-cull-cadence.sh - steering-cull-cadence.sh: the
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
mkdir -p "$P/scripts/cleanup" "$P/scripts/luna" "$P/scripts/lib"
git init -q "$P"
cp "$DIR/steering-cull-cadence.sh" "$P/scripts/cleanup/" 2>/dev/null || true
cp "$REAL_ROOT/scripts/luna/cadence-alert.sh" "$P/scripts/luna/"
cp "$REAL_ROOT/scripts/lib/llm-backend.sh" "$P/scripts/lib/"
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
check "arm without --console is accepted (resolved at run time)" 0 $?
hasnt "runner armed without --console bakes none" "--console" "$W/runner/steering-cull-cadence.sh"
( cd "$W" && bash "$CAD" arm --force --console test-console --proposal-dir rel/props ) >"$W/arm4.out" 2>&1
has "arm resolves a relative --proposal-dir to an absolute path" "$W/rel/props" "$W/runner/steering-cull-cadence.sh"
bash "$CAD" status >"$W/st.out" 2>&1
has "status reports ARMED" "ARMED" "$W/st.out"
bash "$CAD" disarm >"$W/dis.out" 2>&1
check "disarm exits 0" 0 $?
hasnt "disarm removes the entry" "HIMMEL-SteeringCull" "$W/crontab.txt"

# ---- 7. console resolved at RUN time ---------------------------
node -e 'console.log(JSON.stringify({type:"result",is_error:false,result:"- [LOW] CLAUDE.md:1 - x\n"}))' > "$W/claude.json"
cat > "$W/sweep.sh" <<'SH'
#!/usr/bin/env bash
cat "$STUB_DIR/sweep.txt" 2>/dev/null
exit 20
SH
chmod +x "$W/sweep.sh"
export STEERING_CULL_SWEEP_CMD="$W/sweep.sh"
INB_A="$INBOX_ROOT/consoles/old-console.md"; INB_B="$INBOX_ROOT/consoles/new-console.md"
: > "$INB_A"; : > "$INB_B"
cat > "$W/sweep.txt" <<'EOF'
slug=u__himmel__HIMMEL-5000-leg-2026-10-14 session=s host=h age=5s status=OK
slug=u__himmel__old-console session=s host=h age=9000s status=IDLE-HELD?
slug=u__himmel__new-console session=s host=h age=40s status=OK
slug=u__himmel__dead-console session=s host=h age=1s status=STALE-DEAD
slug=u__himmel__nostatus-console session=s host=h age=2s
slug=u__himmel__odd-console session=s host=h age=3s status=WEIRD
EOF
: > "$W/alerts.log"
bash "$CAD" run --repo "$P" --proposal-dir "$PROP" >"$W/run7.out" 2>&1
check "run without --console exits 0" 0 $?
has "newest held console (B) gets the line" "[steering-cull]" "$INB_B"
hasnt "older console (A) gets nothing" "[steering-cull]" "$INB_A"
hasnt "a dead console is never chosen" "no-inbox" "$W/alerts.log"

: > "$INB_B"
bash "$CAD" run --repo "$P" --proposal-dir "$PROP" --console old-console >"$W/run7b.out" 2>&1
has "explicit --console wins over the live console" "[steering-cull]" "$INB_A"
hasnt "override leaves the live console alone" "[steering-cull]" "$INB_B"

: > "$INB_A"
printf 'slug=u__himmel__HIMMEL-5000-leg-2026-10-14 session=s host=h age=5s status=OK\n' > "$W/sweep.txt"
: > "$W/alerts.log"
bash "$CAD" run --repo "$P" --proposal-dir "$PROP" >"$W/run7c.out" 2>&1
check "no live console exits 1 (alert path)" 1 $?
has "no live console delivers via the shared cadence alert" "no-console" "$W/alerts.log"
has "no live console: the alert names the proposal doc" "$DOC" "$W/alerts.log"

# ---- 8. backend switch: claude-api runs on the API lane, not the bank ---------
# Stub lane: logs argv, the tool grant and the account; prints $W/claude.json.
cat > "$W/lane.sh" <<'SH'
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "$PWD"; printf 'arg=%s\n' "$@"; printf 'tools=%s\n' "${HIMMEL_API_TOOLS:-}"; printf 'acct=%s\n' "${HIMMEL_API_ACCOUNT:-}"; } >> "$STUB_DIR/lane-argv"
cat "$STUB_DIR/claude.json"
SH
chmod +x "$W/lane.sh"
export STEERING_CULL_API_LANE="$W/lane.sh"
node -e 'console.log(JSON.stringify({type:"result",is_error:false,result:"- [LOW] CLAUDE.md:1 - x\n"}))' > "$W/claude.json"
rm -f "$W/argv" "$W/lane-argv"
: > "$INB_B"; : > "$W/alerts.log"
printf 'slug=u__himmel__new-console session=s host=h age=40s status=OK\n' > "$W/sweep.txt"

STEERING_CULL_BACKEND=bogus bash "$CAD" run --repo "$P" --proposal-dir "$PROP" >"$W/run8a.out" 2>&1
check "unknown backend exits 1" 1 $?
[ ! -e "$W/argv" ] && [ ! -e "$W/lane-argv" ] && pass "unknown backend calls no model" || fail "model called for an unknown backend"

STEERING_CULL_BACKEND=claude-api bash "$CAD" run --repo "$P" --proposal-dir "$PROP" >"$W/run8b.out" 2>&1
check "claude-api with the lane off exits 1" 1 $?
has "lane-off refusal says no fallback" "no claude-cli fallback" "$W/run8b.out"
[ ! -e "$W/argv" ] && [ ! -e "$W/lane-argv" ] && pass "lane-off calls no model, no subscription fallback" || fail "model called with the lane off"

echo "HOLD bank at 91%" > "$W/preflight"
HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=B STEERING_CULL_BACKEND=api bash "$CAD" run --repo "$P" --proposal-dir "$PROP" >"$W/run8c.out" 2>&1
check "api backend runs even while the bank is held" 0 $?
rm -f "$W/preflight"
has "lane gets -p" "arg=-p" "$W/lane-argv"
has "lane gets json output" "arg=json" "$W/lane-argv"
has "lane gets plan permission mode" "arg=plan" "$W/lane-argv"
has "lane gets a budget cap" "arg=--max-budget-usd" "$W/lane-argv"
has "lane tool grant is Read only" "tools=Read" "$W/lane-argv"
has "lane runs on the chosen account" "acct=B" "$W/lane-argv"
hasnt "lane argv never carries bypassPermissions" "bypassPermissions" "$W/lane-argv"
hasnt "lane argv never carries --tools (the lane adds its own)" "arg=--tools" "$W/lane-argv"
[ ! -e "$W/argv" ] && pass "api backend never runs the subscription claude" || fail "subscription claude ran on the api backend"
has "api run still delivers to the console" "[steering-cull]" "$INB_B"

bash "$CAD" arm --force --console test-console --proposal-dir "$PROP" --backend claude-api >"$W/arm8a.out" 2>&1
check "arm --backend claude-api without an account is refused" 1 $?
bash "$CAD" arm --force --console test-console --proposal-dir "$PROP" --backend claude-api --api-account B >"$W/arm8b.out" 2>&1
check "arm --backend claude-api --api-account B exits 0" 0 $?
has "runner bakes the backend" "STEERING_CULL_BACKEND=claude-api" "$W/runner/steering-cull-cadence.sh"
has "runner bakes the lane switch" "HIMMEL_API_LANE=on" "$W/runner/steering-cull-cadence.sh"
has "runner bakes the account" "HIMMEL_API_ACCOUNT=B" "$W/runner/steering-cull-cadence.sh"
bash "$CAD" arm --force --console test-console --proposal-dir "$PROP" >"$W/arm8c.out" 2>&1
hasnt "a default arm bakes no backend" "STEERING_CULL_BACKEND" "$W/runner/steering-cull-cadence.sh"
bash "$CAD" arm --force --console test-console --proposal-dir "$PROP" --backend claude-cli >"$W/arm8d.out" 2>&1
check "arm --backend claude-cli exits 0" 0 $?
has "an explicit claude-cli arm pins the backend against an inherited env" "STEERING_CULL_BACKEND=claude-cli" "$W/runner/steering-cull-cadence.sh"
bash "$CAD" disarm >/dev/null 2>&1

echo "steering-cull-cadence: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
