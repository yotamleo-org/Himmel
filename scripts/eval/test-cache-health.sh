#!/usr/bin/env bash
# test-cache-health.sh - cache-health.py + cache-health-cadence.sh:
# crossing, no-crossing, recovery, no-repeat, failed-send retry, session-low,
# console/Telegram delivery and the cron arm/disarm.
# Hermetic: transcripts, state, bridge, crontab and senders are stubs in a mktemp
# dir. The transcript line shape (usage / cache_creation / id / timestamp,
# custom-title, compact_boundary) is copied from a real Claude Code session
# file. Never arms anything on the real station and never calls a model.
# Exit: 0 = all pass, 1 = a case failed.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${CH_PY:-$DIR/cache-health.py}"
CAD="$DIR/cache-health-cadence.sh"
PASSED=0; FAILED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (no '$2' in $3)"; fi; }
hasnt() { [ -r "$3" ] || { fail "$1 (cannot read $3)"; return; }; grep -qF -- "$2" "$3"; case $? in 0) fail "$1 ('$2' present in $3)";; 1) pass "$1";; *) fail "$1 (grep error on $3)";; esac; }

W="$(mktemp -d "${TMPDIR:-/tmp}/cache-health.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
NOW=1760000000

# gen <dir> <leg-recent-read> <leg-recent-create>: baseline legs/console steady at
# 98 % hit; the leg role's RECENT turns carry the given read/create (per 1M turn).
cat > "$W/gen.py" <<'PY'
import json, os, sys, datetime
_dump = json.dumps
json.dumps = lambda o: _dump(o, separators=(",", ":"))  # compact, as Claude Code writes it
root, now, rd, cr = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
extra = sys.argv[5] if len(sys.argv) > 5 else ""
os.makedirs(root, exist_ok=True)
def iso(t): return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def turn(i, t, rd_, cr_, inp=2):
    return json.dumps({"type": "assistant", "uuid": "u%d" % i, "timestamp": iso(t), "message": {
        "model": "claude-haiku-5-5", "id": "msg_%d_%d" % (i, t), "role": "assistant",
        "usage": {"input_tokens": inp, "cache_creation_input_tokens": cr_, "cache_read_input_tokens": rd_,
                  "output_tokens": 5, "cache_creation": {"ephemeral_1h_input_tokens": cr_, "ephemeral_5m_input_tokens": 0}}}})
def session(name, title, turns, comps=()):
    with open(os.path.join(root, name + ".jsonl"), "w") as f:
        f.write(json.dumps({"type": "custom-title", "customTitle": title}) + "\n")
        for i, (t, r, c) in enumerate(turns):
            f.write(turn(i, t, r, c) + "\n")
            f.write(turn(i, t, r, c) + "\n")  # duplicate row: must be deduped by message id
        for t in comps:
            f.write(json.dumps({"type": "system", "subtype": "compact_boundary", "timestamp": iso(t)}) + "\n")
    os.utime(os.path.join(root, name + ".jsonl"), (now, now))
H = 3600
base = [(now - 48 * H - k * H, 980000, 20000) for k in range(6)]
steady = [(now - 2 * H - k * H, 980000, 20000) for k in range(6)]
recent_leg = [] if extra == "legsilent" else [(now - 2 * H - k * H, rd, cr) for k in range(6)]
session("c1", "HIMMEL-nextleg-console", base + steady)
session("l1", "HIMMEL-5-foo-N12", base + recent_leg, comps=[now - H] * (9 if extra == "compactions" else 1))
if extra == "lowsession":
    session("l2", "HIMMEL-6-bar-N13", [(now - 3 * H - k * H, 850000, 150000) for k in range(2)])
PY
R="$W/proj"
STATE="$W/state"
SEND="$W/send.sh"
cat > "$SEND" <<'SH'
#!/usr/bin/env bash
printf '%s\n--\n' "$1" >> "$STUB_DIR/sent"
exit "$(cat "$STUB_DIR/send.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$SEND"; export STUB_DIR="$W"
run() { python3 -I "$PY" check --root "$R" --state-dir "$STATE" --now "$NOW" --notify-cmd "$SEND" "$@" >"$W/run.out" 2>&1; }
sends() { grep -c '^--$' "$W/sent" 2>/dev/null || echo 0; }

# ---- 1. no crossing: steady cache -> no message, metrics written -------------
python3 -I "$W/gen.py" "$R" "$NOW" 980000 20000
run; check "steady run exits 0" 0 $?
check "no-crossing sends nothing" 0 "$(sends)"
[ -f "$STATE/metrics.json" ] && pass "metrics.json written" || fail "no metrics.json"
python3 -I -c '
import json,sys
m=json.load(open(sys.argv[1]))
l=m["roles"]["leg"]
ok = m["schema"]==1 and set(m["roles"])=={"console","leg","subagent","bridge","other"} and l["sessions"]==1 and l["tokens"]==6000012 and l["hit_pct"]==98.0 and l["baseline_hit_pct"]==98.0 and l["compactions"]==1
sys.exit(0 if ok else 1)' "$STATE/metrics.json" && pass "metrics schema + deduped per-role numbers" || fail "metrics.json content wrong"
[ "$(( $(wc -l < "$STATE/history.jsonl") ))" = 1 ] && pass "history has one row" || fail "history rows"

# ---- 2. crossing: legs fall to 90 % -> exactly one alert ---------------------
rm -f "$W/sent"
python3 -I "$W/gen.py" "$R" "$NOW" 900000 100000
run; check "crossing run exits 0" 0 $?
check "crossing sends exactly one message" 1 "$(sends)"
has "alert names the role" "leg hit rate 90.0%" "$W/sent"
has "alert names the baseline" "98.0% baseline" "$W/sent"
has "active state holds the crossing" "role-drop:leg" "$STATE/alert-state.json"

# ---- 3. no repeat: still crossed -> silent -----------------------------------
rm -f "$W/sent"
run
check "still-crossed run sends nothing" 0 "$(sends)"

# ---- 4. recovery: back to steady -> one recovery message, then silence -------
python3 -I "$W/gen.py" "$R" "$NOW" 980000 20000
run
check "recovery sends exactly one message" 1 "$(sends)"
has "recovery message" "cache-health RECOVERED: role-drop leg" "$W/sent"
rm -f "$W/sent"
run
check "after recovery nothing repeats" 0 "$(sends)"

# ---- 5. hysteresis: 2.5 pts below baseline is inside the clear margin --------
python3 -I "$W/gen.py" "$R" "$NOW" 900000 100000
run; rm -f "$W/sent"
python3 -I "$W/gen.py" "$R" "$NOW" 955000 45000   # 95.5 % = 2.5 below 98
run
check "inside the clear margin: no recovery yet" 0 "$(sends)"
has "still active inside the margin" "role-drop:leg" "$STATE/alert-state.json"

# ---- 6. failed send keeps the crossing pending (retry next run) --------------
rm -rf "$STATE" "$W/sent"
python3 -I "$W/gen.py" "$R" "$NOW" 900000 100000
echo 1 > "$W/send.rc"
run; check "failed send exits non-zero" 3 $?
check "failed send tried once" 1 "$(sends)"
hasnt "failed send is not recorded as active" "role-drop:leg" "$STATE/alert-state.json"
rm -f "$W/send.rc" "$W/sent"
run
check "retry after the failure delivers" 1 "$(sends)"

# ---- 6b. a missing transcript root is an error, never "no data" --------------
python3 -I "$PY" check --root "$W/no-such-root" --state-dir "$STATE" --now "$NOW" --notify-cmd "$SEND" >"$W/run.out" 2>&1
check "missing root exits 2" 2 $?
has "missing root names the path" "transcript root not found" "$W/run.out"
has "missing root leaves the active alert alone" "role-drop:leg" "$STATE/alert-state.json"

# ---- 6c. input and invocation guards ------------------------------------------
python3 -I "$PY" check --root "$R" --state-dir "$STATE" --now "$NOW" >"$W/run.out" 2>&1
check "check without --notify-cmd exits 2" 2 $?
has "check without --notify-cmd says why" "needs --notify-cmd" "$W/run.out"
chmod 000 "$R/l1.jsonl"
python3 -I "$PY" check --root "$R" --state-dir "$STATE" --now "$NOW" --notify-cmd "$SEND" >"$W/run.out" 2>&1
rc=$?; chmod 644 "$R/l1.jsonl"
if [ "$(id -u)" = 0 ]; then pass "unreadable transcript (skipped as root)"; else check "unreadable transcript exits 2" 2 "$rc"; fi
python3 -I -c '
import fcntl, subprocess, sys
f = open(sys.argv[1] + "/lock", "w"); fcntl.flock(f, fcntl.LOCK_EX)
r = subprocess.run(["python3", "-I", sys.argv[2], "check", "--root", sys.argv[3], "--state-dir", sys.argv[1], "--now", sys.argv[4], "--notify-cmd", sys.argv[5]], capture_output=True, text=True)
sys.exit(0 if r.returncode == 0 and "holds the lock" in r.stderr else 1)' "$STATE" "$PY" "$R" "$NOW" "$SEND" && pass "a held lock skips the run" || fail "lock not honoured"
rm -rf "$W/dry-state"
python3 -I "$PY" check --root "$R" --state-dir "$W/dry-state" --now "$NOW" --dry-run >"$W/run.out" 2>&1
[ ! -e "$W/dry-state" ] && pass "dry run creates no state directory" || fail "dry run created the state directory"

# ---- 6d. too little data keeps an active alert, never recovers it ------------
rm -f "$W/sent"
python3 -I "$W/gen.py" "$R" "$NOW" 980000 20000 legsilent
run
check "thin data sends no recovery" 0 "$(sends)"
has "thin data keeps the active alert" "role-drop:leg" "$STATE/alert-state.json"

# ---- 6e. an unreadable directory is incomplete data: exit 2 ------------------
mkdir -p "$R/locked"; cp "$R/c1.jsonl" "$R/locked/x.jsonl"; chmod 000 "$R/locked"
python3 -I "$PY" check --root "$R" --state-dir "$STATE" --now "$NOW" --notify-cmd "$SEND" >"$W/run.out" 2>&1
rc=$?; chmod 755 "$R/locked"
if [ "$(id -u)" = 0 ]; then pass "unreadable directory (skipped as root)"; else check "unreadable directory exits 2" 2 "$rc"; fi
rm -rf "$R/locked"

# ---- 6f. a bridge greeting inside an array content block classifies as bridge -
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"You are Telegram bridge session x"}]}}' > "$W/br.jsonl"
cat > "$W/role.py" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("ch", sys.argv[1])
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.parse_session(sys.argv[2])[1])
PY
role="$(python3 -I "$W/role.py" "$PY" "$W/br.jsonl")"
check "array-form bridge greeting classifies as bridge" bridge "$role"

# ---- 7. session-low + compactions rules --------------------------------------
rm -rf "$STATE" "$W/sent" "$R"
python3 -I "$W/gen.py" "$R" "$NOW" 980000 20000 lowsession
run
has "session over 1M tokens under 90 % alerts" "session HIMMEL-6-bar-N13: 85.0% hit" "$W/sent"
rm -rf "$STATE" "$W/sent" "$R"
python3 -I "$W/gen.py" "$R" "$NOW" 980000 20000 compactions
run
has "legs above the compaction limit alert" "legs average 9.0 compactions" "$W/sent"

# ---- 8. dry run prints, sends nothing, writes nothing ------------------------
rm -rf "$STATE" "$W/sent" "$R"
python3 -I "$W/gen.py" "$R" "$NOW" 900000 100000
run --dry-run
has "dry run prints the would-send" "DRY notify:" "$W/run.out"
[ ! -e "$W/sent" ] && [ ! -e "$STATE/metrics.json" ] && pass "dry run sends and writes nothing" || fail "dry run had side effects"

# ---- 9. cadence: Telegram + live console inbox -------------------------------
P="$W/primary"; mkdir -p "$P/scripts/eval" "$P/scripts/luna"
git init -q "$P"
cp "$DIR/cache-health-cadence.sh" "$DIR/cache-health.py" "$P/scripts/eval/"
cp "$DIR/../luna/cadence-alert.sh" "$P/scripts/luna/"
git -C "$P" add -A; git -C "$P" -c user.name=t -c user.email=t@t commit -q -m fixture
BR="$W/bridge"; mkdir -p "$BR/consoles"; : > "$BR/consoles/live-console.md"
printf '#!/bin/sh\nexit 0\n' > "$W/sweep.sh"; chmod +x "$W/sweep.sh"
cat > "$W/sweep.sh" <<'SH'
#!/bin/sh
echo "slug=u__r__old-console x age=900s status=OK"
echo "slug=u__r__live-console x age=10s status=OK"
echo "slug=u__r__some-leg x age=5s status=OK"
SH
cat > "$W/tg.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$STUB_DIR/tg"
SH
chmod +x "$W/tg.sh"
export BRIDGE_ROOT="$BR" CACHE_HEALTH_SWEEP_CMD="$W/sweep.sh" CACHE_HEALTH_TELEGRAM_CMD="$W/tg.sh"
export CACHE_HEALTH_STATE_DIR="$W/cstate" CACHE_HEALTH_ROOT="$R" CACHE_HEALTH_NOW="$NOW"
export CADENCE_ALERT_FILE="$W/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$W/alert-sent" CADENCE_ALERT_SEND_CMD="$W/send.sh"
bash "$P/scripts/eval/cache-health-cadence.sh" run --repo "$P" >"$W/cad.out" 2>&1
check "cadence run exits 0" 0 $?
has "Telegram got the alert" "cache-health ALERT" "$W/tg"
has "newest live console inbox got the alert line" "[cache-health] cache-health ALERT" "$BR/consoles/live-console.md"
[ ! -e "$BR/consoles/old-console.md" ] && pass "inbox is never created for another console" || fail "created a stray inbox"
check "inbox got one line" 1 "$(( $(wc -l < "$BR/consoles/live-console.md") ))"
rm -f "$W/tg"
# a dry run never touches the shared failure alert, even when the check fails
CACHE_HEALTH_ROOT="$W/no-such-root" bash "$P/scripts/eval/cache-health-cadence.sh" run --repo "$P" --dry-run >"$W/cadd.out" 2>&1
check "dry run with a failing check still exits non-zero" 2 $?
[ ! -e "$W/alerts.log" ] && pass "dry run raises no failure alert" || fail "dry run wrote an alert"
CACHE_HEALTH_ROOT="$W/no-such-root" bash "$P/scripts/eval/cache-health-cadence.sh" run --repo "$P" >"$W/cadf.out" 2>&1
check "real run with a failing check exits 1" 1 $?
has "real run raises the shared failure alert" "cache-health" "$W/alerts.log"
rm -f "$W/alerts.log"
bash "$P/scripts/eval/cache-health-cadence.sh" run --repo "$P" >"$W/cad2.out" 2>&1
[ ! -e "$W/tg" ] && pass "second cadence run is silent" || fail "cadence repeated the alert"

# ---- 10. arm / status / disarm (stub crontab) --------------------------------
cat > "$W/crontab" <<'SH'
#!/bin/sh
f="$STUB_DIR/crontab.txt"
if [ "$1" = "-l" ]; then [ -f "$f" ] && cat "$f" || { echo "no crontab for x" >&2; exit 1; }; else cat > "$f"; fi
SH
chmod +x "$W/crontab"
export CACHE_HEALTH_CRONTAB="$W/crontab" CACHE_HEALTH_RUNNER_DIR="$W/runner"
bash "$CAD" arm --dry-run >"$W/arm0.out" 2>&1
has "arm --dry-run shows the hourly entry" "7 * * * *" "$W/arm0.out"
[ ! -e "$W/crontab.txt" ] && pass "dry-run installs nothing" || fail "dry-run wrote a crontab"
bash "$CAD" arm --every-hours 5 --dry-run >"$W/arm5.out" 2>&1
check "arm refuses an interval that does not divide 24" 1 $?
bash "$CAD" arm >"$W/arm1.out" 2>&1
check "arm exits 0" 0 $?
has "crontab carries the task tag" "# HIMMEL-CacheHealth" "$W/crontab.txt"
bash "$CAD" arm >"$W/arm2.out" 2>&1
check "re-arm without --force refuses" 3 $?
bash "$CAD" status >"$W/st.out" 2>&1
has "status says ARMED" "ARMED" "$W/st.out"
has "runner is a generated script" "cache-health-cadence.sh" "$W/runner/cache-health-cadence.sh"
bash "$CAD" disarm >"$W/dis.out" 2>&1
hasnt "disarm removes the entry" "HIMMEL-CacheHealth" "$W/crontab.txt"

echo "---"; echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
