#!/usr/bin/env bash
# test-librarian-cadence.sh — hermetic: a fake crontab file, a scratch runner
# dir, a scratch HOME (registry, ledger, alert file) and a scratch handover
# root. Arms nothing on the station and never touches the live bucket.
# shellcheck disable=SC2016  # the generated fake scripts keep their $1 literal
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/handover/librarian-cadence.sh"
PASS=0; FAIL=0
W="$(mktemp -d -t librarian-cadence.XXXXXX)" || exit 1; trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

[ -f "$SUT" ] && have=yes || have=no
check "RED: librarian-cadence.sh exists" yes "$have"
[ "$have" = yes ] || { echo "pass=$PASS fail=$FAIL"; exit 1; }

export HOME="$W/home"; mkdir -p "$HOME"
export HIMMEL_OBSERVABILITY_CONFIG="$HOME/observability.json"
export HIMMEL_FLOW_RUNS_LEDGER="$W/flow-runs.jsonl"
export CADENCE_ALERT_FILE="$W/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$W/alert-sent"
export CADENCE_ALERT_SEND_CMD="$W/send.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/sent.log"\n' "$W" > "$W/send.sh"; chmod +x "$W/send.sh"
export LIBRARIAN_RUNNER_DIR="$W/runner"
TAB="$W/crontab.txt"
printf '#!/usr/bin/env bash\ncase "${1:-}" in -l) [ -f "%s" ] && cat "%s" || { echo "no crontab for x" >&2; exit 1; } ;; -) cat > "%s" ;; esac\n' "$TAB" "$TAB" "$TAB" > "$W/crontab"
chmod +x "$W/crontab"; export LIBRARIAN_CRONTAB="$W/crontab"

run() { bash "$SUT" "$@" 2>&1; }

# --- not armed, dry-run arm installs nothing ----------------------------------
check "status before arming" "not armed  HIMMEL-Librarian" "$(run status | head -1)"
out="$(run arm --dry-run)"
check "arm --dry-run names the daily entry" 0 "$(grep -q '23 4 \* \* \* ' <<< "$out" && echo 0 || echo 1)"
check "arm --dry-run writes no crontab" no "$([ -e "$TAB" ] && echo yes || echo no)"

# --- arm: daily, dry-run runner, other cron lines kept ------------------------
printf '0 1 * * * /usr/bin/true # other-job\n' > "$TAB"
run arm >/dev/null; check "arm exits 0" 0 "$?"
check "the other cron line survives" 1 "$(grep -c '# other-job' "$TAB")"
check "one librarian entry, daily 04:23" 1 "$(grep -c '^23 4 \* \* \* .* # HIMMEL-Librarian$' "$TAB")"
R="$LIBRARIAN_RUNNER_DIR/librarian-cadence.sh"
check "the runner exists and is executable" yes "$([ -x "$R" ] && echo yes || echo no)"
check "the default runner is a dry run (no --apply)" 0 "$(grep -q -- '--apply' "$R" && echo 1 || echo 0)"
check "the runner calls librarian.sh" 1 "$(grep -c 'scripts/handover/librarian.sh' "$R")"
check "the registry holds a daily cadence" 1 "$(grep -c '"librarian"' "$HIMMEL_OBSERVABILITY_CONFIG")"
check "status reads ARMED" "ARMED      HIMMEL-Librarian (23 4 * * *)" "$(run status | head -1)"
run arm >/dev/null; check "a second arm without --force exits 3" 3 "$?"

# --- configurable cadence, explicit --apply -----------------------------------
run arm --force --every-days 3 --apply >/dev/null; check "arm --force --every-days 3 --apply exits 0" 0 "$?"
check "every 3 days is */3 on day-of-month" 1 "$(grep -c '^23 4 \*/3 \* \* ' "$TAB")"
check "still exactly one librarian entry" 1 "$(grep -c '# HIMMEL-Librarian$' "$TAB")"
check "--apply is baked into the runner" 1 "$(grep -c -- 'librarian.sh.* --apply' "$R")"
check "the dry-run preview names the mode plainly" 1 "$(run arm --force --apply --dry-run | grep -c ' (apply) and install')"
check "and the dry-run mode reads dry-run" 1 "$(run arm --force --dry-run | grep -c ' (dry-run) and install')"
for bad in 0 29 abc ""; do
  run arm --force --every-days "$bad" >/dev/null
  check "--every-days '$bad' is refused (exit 1)" 1 "$?"
done

# --- the runner: a flow-run row, an alert on failure, a clear on success ------
export USER_SLUG=u
mk_bucket() {  # mk_bucket <root> : a committed, 60-day-old doc that ends WRAPPED, so an --apply fire would move it
  mkdir -p "$1/u/himmel" "$W/sessions"; git -C "$1" init -q 2>/dev/null
  printf '# d\n\n- 10:05 WRAPPED — done\n' > "$1/u/himmel/HIMMEL-9-x-2026-01-01.md"
  python3 -I -c 'import os, sys, time; t = time.time() - 60 * 86400; os.utime(sys.argv[1], (t, t))' "$1/u/himmel/HIMMEL-9-x-2026-01-01.md"
  git -C "$1" add -A && git -C "$1" -c user.email=t@t -c user.name=t commit -q -m seed
}
H="$W/handovers"; mk_bucket "$H"
run arm --force >/dev/null
HANDOVER_DIR="$H" bash "$R" >/dev/null 2>&1
check "a good fire logs the summary line" 1 "$(grep -c '^librarian: dry-run' "$LIBRARIAN_RUNNER_DIR/librarian.log")"
check "and exit rc=0" 1 "$(grep -c '^\[exit rc=0\]' "$LIBRARIAN_RUNNER_DIR/librarian.log")"
check "and one complete flow-run row" 1 "$(grep -c '"outcome":"complete"' "$HIMMEL_FLOW_RUNS_LEDGER" 2>/dev/null)"
check "and no alert" no "$([ -s "$CADENCE_ALERT_FILE" ] && echo yes || echo no)"
check "the dry run moved nothing" yes "$([ -e "$H/u/himmel/HIMMEL-9-x-2026-01-01.md" ] && echo yes || echo no)"
HANDOVER_DIR="$W/nowhere" bash "$R" >/dev/null 2>&1
check "a failed fire logs a nonzero exit" 1 "$(grep -c '^\[exit rc=[1-9]' "$LIBRARIAN_RUNNER_DIR/librarian.log")"
check "and appends one alert line" 1 "$(grep -c ' librarian rc-' "$CADENCE_ALERT_FILE")"
check "and sends one Telegram message" 1 "$(grep -c 'cadence leg failed: librarian' "$W/sent.log")"
check "and an error flow-run row" 1 "$(grep -c '"outcome":"error"' "$HIMMEL_FLOW_RUNS_LEDGER" 2>/dev/null)"
HANDOVER_DIR="$H" bash "$R" >/dev/null 2>&1
check "a later good fire clears the alert dedupe" 0 "$(find "$W/alert-sent" -type f 2>/dev/null | wc -l | tr -d ' ')"

# --- cron has no HANDOVER_DIR: the runner carries the arm-time root ------------
HANDOVER_DIR="$H" run arm --force >/dev/null
check "the runner pins the arm-time handover root" 1 "$(grep -c 'HANDOVER_DIR=' "$R")"
env -u HANDOVER_DIR bash "$R" >/dev/null 2>&1
check "and a fire with no HANDOVER_DIR still resolves it" 0 "$(tail -n 3 "$LIBRARIAN_RUNNER_DIR/librarian.log" | grep -c '^\[exit rc=[1-9]')"

# --- positive control: an --apply fire does move the doc the dry run left ------
H2="$W/handovers2"; mk_bucket "$H2"
run arm --force --apply >/dev/null
HANDOVER_DIR="$H2" bash "$R" >/dev/null 2>&1
check "an --apply fire moves the finished doc" no "$([ -e "$H2/u/himmel/HIMMEL-9-x-2026-01-01.md" ] && echo yes || echo no)"

# --- disarm -------------------------------------------------------------------
run disarm >/dev/null; check "disarm exits 0" 0 "$?"
check "the librarian entry is gone, the other job stays" "1 0" "$(grep -c '# other-job' "$TAB") $(grep -c '# HIMMEL-Librarian' "$TAB")"
check "the runner is removed" no "$([ -e "$R" ] && echo yes || echo no)"
check "the registry entry is removed" 0 "$(grep -c '"librarian"' "$HIMMEL_OBSERVABILITY_CONFIG")"
check "disarm again is a no-op" 0 "$(run disarm >/dev/null; echo $?)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
