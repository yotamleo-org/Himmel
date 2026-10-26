#!/usr/bin/env bash
# vm-7004: the failure-review cadence arms one cron line, fires, writes its digest, disarms.
source "$(dirname "$0")/_lib.sh"
SHA=e88de305133888ddd39be9ba1c3954665d1adb89
vm_fresh
# shellcheck disable=SC2088 # the guest shell expands the tilde
out="$(stage "$SHA" '~/himmel-7004')"; expect head "$out" "$SHA"
cat >"$WORK/p.sh" <<'EOF'
ck() { if [ "$2" = 0 ]; then echo "CHECK $1 PASS"; else echo "CHECK $1 FAIL ${3:-}"; fi; }
cd ~/himmel-7004 || exit 1
F=scripts/eval/leg-digest/failure-review-cadence.sh
[ "$(git rev-parse HEAD)" = e88de305133888ddd39be9ba1c3954665d1adb89 ]; ck a-head $?
s="$(bash $F status 2>&1)"; echo "$s"; printf '%s' "$s" | grep -q 'not armed'; ck b-status-not-armed $?
mkdir -p /tmp/fr-vault/50-Journal/Daily; ck c-vault $?
d="$(bash $F arm --dry-run --vault /tmp/fr-vault 2>&1)"; echo "$d"; printf '%s' "$d" | grep -q 'HIMMEL-FailureReview'; ck d-dry-run $?
t="$(date -d '+2 min' +%H:%M)"  # gnu-ok: the proof runs on a Linux host only
a="$(bash $F arm --time "$t" --vault /tmp/fr-vault 2>&1)"; rc=$?; echo "$a"; ck e-arm $rc
n="$(crontab -l 2>/dev/null | grep -c HIMMEL-FailureReview)"; [ "$n" = 1 ]; ck f-one-cron-line $? "count=$n"
bash $F status 2>&1 | grep -q 'ARMED'; ck f-status-armed $?
L=~/.claude/failure-review-cadence/failure-review-cadence.log
for _ in $(seq 1 24); do grep -q 'wrote' "$L" 2>/dev/null && break; sleep 15; done
cat "$L" 2>/dev/null; grep -q 'wrote' "$L" 2>/dev/null; ck g-cron-fired $?
ls -la ~/.himmel/state ~/.himmel/state/failure-review ~/.himmel/eval-changes.jsonl /tmp/fr-vault/50-Journal/Daily 2>&1
[ -e ~/.himmel/eval-changes.jsonl ]; ck h-eval-changes-present $?
ls /tmp/fr-vault/50-Journal/Daily/failure-review-*.md >/dev/null 2>&1; ck h-digest-in-daily $?
head -40 /tmp/fr-vault/50-Journal/Daily/failure-review-*.md 2>&1 | head -40
bash $F disarm 2>&1; n="$(crontab -l 2>/dev/null | grep -c HIMMEL-FailureReview)"; [ "$n" = 0 ]; ck i-disarmed $? "count=$n"
EOF
tally "$(guest_script p.sh 900)"
final
