#!/usr/bin/env bash
# test-denied-launch-alert.sh — Exercises denied-launch-alert.sh: one operator
# alert per classifier-denied leg launch, deduplicated across scans, and an
# alert text that never carries the denied command or the denial reason.
# Scratch dirs only (log, sentinel dir, sender seam); never the real ~/.himmel.
#
# Run: bash scripts/handover/console-kit/test-denied-launch-alert.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${DENIED_LAUNCH_ALERT:-$HERE/denied-launch-alert.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/denied-launch-alert-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# The sender seam records each call; the access.json supplies the operator id.
cat > "$WORK/sender.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$SENT_LOG"
EOF
chmod +x "$WORK/sender.sh"
printf '{"allowFrom":["4242"]}\n' > "$WORK/access.json"
export TELEGRAM_ACCESS_PATH="$WORK/access.json"
export MERGE_BLOCK_ALERT_CMD="$WORK/sender.sh"
export HIMMEL_DENIAL_ALERT_DIR="$WORK/sentinels"
export HIMMEL_CLASSIFIER_DENIALS_LOG="$WORK/denials.jsonl"
export SENT_LOG="$WORK/sent.log"
: > "$SENT_LOG"

mkrow() { # <mins-ago> <session_title> <session_id> <tool> <input_head> <input_sha>
    local ts
    ts="$(date -u -d "-${1} minutes" +%Y-%m-%dT%H:%M:%SZ)"  # gnu-ok: Linux-only kit
    printf '{"ts":"%s","session_id":"%s","session_title":"%s","cwd":"/x/.claude/worktrees/%s","tool":"%s","reason_tag":"SECRETREASON","input_sha":"%s","input_head":"%s"}\n' \
        "$ts" "$3" "$2" "$2" "$4" "$6" "$5" >> "$HIMMEL_CLASSIFIER_DENIALS_LOG"
}
has() { grep -q "$@"; case $? in 0) echo yes ;; 1) echo no ;; *) echo error ;; esac; }  # a grep error is neither yes nor no
sent() { wc -l < "$SENT_LOG" | tr -d ' '; }

# --- (a) a denied launch alerts once -----------------------------------------
mkrow 2 feat+leg-a sid-a Bash 'bash scripts/handover/console-kit/headed-arm-leg.sh --token SECRETCMD' sha-a
bash "$SUT" >/dev/null 2>&1; rc=$?
check "(a) the scan exits 0" "0" "$rc"
check "(a) one alert for one denied launch" "1" "$(sent)"
check "(a) it names the leg" "yes" "$(grep -q 'feat+leg-a' "$SENT_LOG" && echo yes)"
check "(a) it says launch denied" "yes" "$(grep -qi 'launch denied' "$SENT_LOG" && echo yes)"
check "(a) it names the tool" "yes" "$(grep -q 'Bash' "$SENT_LOG" && echo yes)"
check "(a) it points at the local log path" "yes" "$(grep -qF "$HIMMEL_CLASSIFIER_DENIALS_LOG" "$SENT_LOG" && echo yes)"
check "(a) it carries no command text" "no" "$(has 'SECRETCMD\|headed-arm-leg' "$SENT_LOG")"
check "(a) it carries no reason" "no" "$(has 'SECRETREASON' "$SENT_LOG")"

# --- (b) a repeat scan is deduplicated ---------------------------------------
bash "$SUT" >/dev/null 2>&1
check "(b) a second scan of the same row sends nothing" "1" "$(sent)"

# --- (c) a new denied launch alerts again; a non-launch denial does not -------
mkrow 1 feat+leg-b sid-b Bash 'bash scripts/handover/console-kit/headed-arm-leg.sh --other' sha-b
mkrow 1 feat+leg-c sid-c Bash 'git push origin main' sha-c
bash "$SUT" >/dev/null 2>&1
check "(c) the new launch alerts, the push denial does not" "2" "$(sent)"

# --- (d) a launch denied before the window is not replayed --------------------
mkrow 120 feat+leg-old sid-old Bash 'bash scripts/handover/console-kit/headed-arm-leg.sh --old' sha-old
bash "$SUT" >/dev/null 2>&1
check "(d) an out-of-window launch denial sends nothing" "2" "$(sent)"

# --- (e) a failed send is retried by the next scan, never doubled -------------
mkrow 1 feat+leg-e sid-e Bash 'bash scripts/handover/console-kit/headed-arm-leg.sh --e' sha-e
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/fail.sh"; chmod +x "$WORK/fail.sh"
MERGE_BLOCK_ALERT_CMD="$WORK/fail.sh" bash "$SUT" >/dev/null 2>&1
check "(e) a failed send records nothing sent" "2" "$(sent)"
bash "$SUT" >/dev/null 2>&1
check "(e) the next scan sends it once" "3" "$(sent)"
bash "$SUT" >/dev/null 2>&1
check "(e) and never again" "3" "$(sent)"

# --- (f) missing log / missing jq-free paths fail open ------------------------
HIMMEL_CLASSIFIER_DENIALS_LOG="$WORK/none.jsonl" bash "$SUT" >/dev/null 2>&1; rc=$?
check "(f) a missing log exits 0 and sends nothing" "0:3" "$rc:$(sent)"

# --- (g) sentinels are private -----------------------------------------------
check "(g) the sentinel dir is 0700" "700" "$(stat -c %a "$HIMMEL_DENIAL_ALERT_DIR" 2>/dev/null)"  # gnu-ok: Linux-only kit

# --- (h) a claim abandoned by a killed scan is reclaimed once it is stale ------
mkrow 1 feat+leg-h sid-h Bash 'bash scripts/handover/console-kit/headed-arm-leg.sh --h' sha-h
# shellcheck disable=SC2016  # the sender body expands when the sender runs
printf '#!/usr/bin/env bash\nkill -9 "$(ps -o ppid= -p "$PPID" | tr -d " ")"\n' > "$WORK/kill.sh"; chmod +x "$WORK/kill.sh"
MERGE_BLOCK_ALERT_CMD="$WORK/kill.sh" bash "$SUT" >/dev/null 2>&1
check "(h) a killed scan sent nothing" "3" "$(sent)"
bash "$SUT" >/dev/null 2>&1
check "(h) a fresh abandoned claim is not retried yet" "3" "$(sent)"
find "$HIMMEL_DENIAL_ALERT_DIR" -type f -size 0 -exec touch -d '-10 minutes' {} + 2>/dev/null
bash "$SUT" >/dev/null 2>&1
check "(h) a stale abandoned claim is sent once" "4" "$(sent)"
bash "$SUT" >/dev/null 2>&1
check "(h) and never again" "4" "$(sent)"

# --- (i) two scans racing on one stale claim alert exactly once ----------------
# A find shim widens the window between the stale check and the reclaim: the first
# caller waits 0.1s, the second 0.6s, so an unserialized second scan removes the
# first one's fresh claim and both send.
mkrow 1 feat+leg-i sid-i Bash 'bash scripts/handover/console-kit/headed-arm-leg.sh --i' sha-i
MERGE_BLOCK_ALERT_CMD="$WORK/kill.sh" bash "$SUT" >/dev/null 2>&1
find "$HIMMEL_DENIAL_ALERT_DIR" -type f -size 0 -exec touch -d '-10 minutes' {} + 2>/dev/null
mkdir -p "$WORK/shim"
cat > "$WORK/shim/find" <<'EOF'
#!/usr/bin/env bash
out="$("$REAL_FIND" "$@")"
if mkdir "$FIND_FIRST" 2>/dev/null; then sleep 0.1; else sleep 0.6; fi
[ -z "$out" ] || printf '%s\n' "$out"
EOF
chmod +x "$WORK/shim/find"
export REAL_FIND FIND_FIRST="$WORK/find-first"
REAL_FIND="$(command -v find)"
before="$(sent)"
PATH="$WORK/shim:$PATH" timeout 30 bash "$SUT" >/dev/null 2>&1 &
pid_a=$!
PATH="$WORK/shim:$PATH" timeout 30 bash "$SUT" >/dev/null 2>&1 &
pid_b=$!
wait "$pid_a" "$pid_b"
check "(i) two concurrent scans of one stale claim send once" "$((before + 1))" "$(sent)"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
