#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-compacted-check.sh
# scripts/handover/chief-kit/test-append-results.sh - suite for
# append-results.sh, the helper that appends a worker's marker
# bullet at a handover doc's true EOF so it can never land mid-doc (the
# Edit-tool-anchors-on-an-old-bullet failure close-wrapped-worker.sh hit twice
# in one shift):
#   1. doc whose Results section is last  -> bullet appended at EOF, `- HH:MM ` prefix
#   2. doc with no trailing newline        -> bullet still lands as its own line
#   3. missing doc                        -> rc != 0, nothing written
#   4. doc with no `## Results` heading   -> rc != 0, doc unchanged
#   5. close-wrapped-worker.sh's WRAPPED gate (worker_tail_status, the shared
#      parser) accepts a WRAPPED bullet the helper appended AFTER older
#      out-of-order bullets, first try
#   6. a `## Results-old` heading (grep -q's old prefix match)
#      is rejected -> rc != 0, doc unchanged (word-boundary match only)
#
# Hermetic: temp dir only. Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/append-results.sh"
TAIL_STATUS_LIB="$HERE/../../lib/worker-tail-status.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/append-results-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
# bucket-gitleaks.sh scans every bullet against the vault's config: point it
# at a temp vault holding the template's.
mkdir -p "$tmp/vault/.git"
cp "$HERE/../../../templates/luna-second-brain/.gitleaks.toml" "$tmp/vault/.gitleaks.toml"
export TICK_VAULT_DIR="$tmp/vault"
# The himmel-bus CLI a SUCCESSION acknowledgement adopts through: never the real one here.
# shellcheck disable=SC2016  # $* and $2 expand in the stub, not here
printf '#!/bin/sh\necho "$*" >> "%s/bus.log"\necho "adopted: legx chief old -> $2"\n' "$tmp" > "$tmp/bus"
chmod +x "$tmp/bus"
export APPEND_RESULTS_BUS="$tmp/bus"
# The worker's own bus identity: without one, the acknowledgement adopts nothing.
export HIMMEL_BUS_NAME=legx
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }

# --- 1. doc whose Results section is last -------------------------------
d1="$tmp/d1.md"
printf '# worker\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE fixture\n' > "$d1"
rc=0; bash "$SCRIPT" "$d1" "READY fixture" >/dev/null 2>&1 || rc=$?
check "1: appends rc 0" "$rc" 0
last_line="$(tail -n 1 "$d1")"
contains "1: last line is the new bullet body" "$last_line" "READY fixture"
case "$last_line" in
    "- "[0-9][0-9]:[0-9][0-9]" READY fixture") echo "ok - 1: last line has - HH:MM prefix" ;;
    *) echo "FAIL - 1: last line has no - HH:MM prefix: [$last_line]"; fails=$((fails+1)) ;;
esac
bullet_count1="$(grep -c '^- ' "$d1")"
check "1: old bullet is still present (2 bullets total)" "$bullet_count1" 2

# --- 2. doc with no trailing newline -------------------------------------
d2="$tmp/d2.md"
printf '# worker\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE fixture' > "$d2"
rc=0; bash "$SCRIPT" "$d2" "WRAPPED fixture" >/dev/null 2>&1 || rc=$?
check "2: appends rc 0 despite missing trailing newline" "$rc" 0
contains "2: original last line preserved intact" "$(sed -n '5p' "$d2")" "- 10:00 LIVE fixture"
last_line2="$(tail -n 1 "$d2")"
contains "2: new bullet is its own line" "$last_line2" "WRAPPED fixture"
bullet_count2="$(grep -c '^- ' "$d2")"
check "2: two distinct bullets (not glued together)" "$bullet_count2" 2

# --- 3. missing doc -------------------------------------------------------
rc=0; bash "$SCRIPT" "$tmp/does-not-exist.md" "LIVE fixture" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && echo "ok - 3: missing doc rc != 0" || { echo "FAIL - 3: missing doc rc == 0"; fails=$((fails+1)); }
[ -e "$tmp/does-not-exist.md" ] && { echo "FAIL - 3: missing doc got created"; fails=$((fails+1)); } || echo "ok - 3: nothing written"

# --- 4. no `## Results` heading -------------------------------------------
d4="$tmp/d4.md"
printf '# worker\n\nno results section here\n' > "$d4"
before_d4="$(cat "$d4")"
rc=0; bash "$SCRIPT" "$d4" "LIVE fixture" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && echo "ok - 4: no Results heading rc != 0" || { echo "FAIL - 4: no Results heading rc == 0"; fails=$((fails+1)); }
after_d4="$(cat "$d4")"
check "4: doc unchanged" "$after_d4" "$before_d4"

# --- 5. close-wrapped-worker.sh's WRAPPED gate accepts it first try ----------
d5="$tmp/d5.md"
printf '# worker\n\n## Results (newest at the bottom)\n\n- 09:00 LIVE start\n- 09:30 FINDING q1\n- 09:35 RESOLVED ruled\n- 09:40 READY 123 abc GREEN\n' > "$d5"
rc=0; bash "$SCRIPT" "$d5" "WRAPPED merged" >/dev/null 2>&1 || rc=$?
check "5: append succeeds rc 0" "$rc" 0
# shellcheck source=scripts/lib/worker-tail-status.sh
# shellcheck disable=SC1090,SC1091
. "$TAIL_STATUS_LIB"
marker="$(worker_tail_status "$d5")"
check "5: worker_tail_status reads WRAPPED first try" "$marker" "WRAPPED"

# --- 6. `## Results-old` is a prefix match, not the heading ---
d6="$tmp/d6.md"
printf '# worker\n\n## Results-old\n\nstale content\n' > "$d6"
before_d6="$tmp/d6.before"
cp "$d6" "$before_d6"
rc=0; bash "$SCRIPT" "$d6" "LIVE fixture" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] && echo "ok - 6: '## Results-old' heading rc == 4 (no-heading refusal, not a real Results heading)" || { echo "FAIL - 6: '## Results-old' heading rc == $rc, want 4"; fails=$((fails+1)); }
cmp -s "$d6" "$before_d6" && echo "ok - 6: doc unchanged" || { echo "FAIL - 6: doc unchanged"; fails=$((fails+1)); }

# --- 7. PARKED-BANK / RESUMED are vocabulary; a coined marker is refused ---
d7="$tmp/d7.md"
printf '# worker\n\nYour RETASK token is X-1.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE working\n' > "$d7"
rc=0; bash "$SCRIPT" "$d7" "PARKED-BANK committed and pushed, waiting for RESUME" >/dev/null 2>&1 || rc=$?
check "7: PARKED-BANK append rc 0" "$rc" 0
check "7: worker_tail_status reads PARKED-BANK, not the earlier LIVE" "$(worker_tail_status "$d7")" "PARKED-BANK"
bash "$SCRIPT" "$d7" "RESUMED bank lifted" >/dev/null 2>&1
check "7: worker_tail_status reads RESUMED" "$(worker_tail_status "$d7")" "RESUMED"
rc=0; bash "$SCRIPT" "$d7" "PARKED-USAGE committed and pushed, waiting for RESUME" >/dev/null 2>&1 || rc=$?
check "7: PARKED-USAGE append rc 0" "$rc" 0
check "7: worker_tail_status reads PARKED-USAGE, not the earlier RESUMED" "$(worker_tail_status "$d7")" "PARKED-USAGE"
bash "$SCRIPT" "$d7" "RESUMED usage lifted" >/dev/null 2>&1
before_d7="$tmp/d7.before"; cp "$d7" "$before_d7"
rc=0; bash "$SCRIPT" "$d7" "SHIPPED the thing" >/dev/null 2>&1 || rc=$?
check "7: a coined leading marker is refused rc 6" "$rc" 6
cmp -s "$d7" "$before_d7" && echo "ok - 7: refused doc unchanged" || { echo "FAIL - 7: refused doc unchanged"; fails=$((fails+1)); }
for ok in "CONSULT design :: q :: read: x" "SUCCESSION accepted: a replaces b" "MAIN-RED job case" "ANSWER use easing X" "Released the lock"; do
    rc=0; bash "$SCRIPT" "$d7" "$ok" >/dev/null 2>&1 || rc=$?
    check "7: non-status bullet '${ok%% *}' still appends" "$rc" 0
done

# bash 3.2 (macOS) matches a [A-Z] range by locale collation, so it takes lowercase
# letters; bash 5 defaults to ASCII ranges, so the row switches that off.
printf 'shopt -u globasciiranges 2>/dev/null\n' > "$tmp/collate.env"
rc=0; LC_ALL=en_US.UTF-8 BASH_ENV="$tmp/collate.env" bash "$SCRIPT" "$d7" "Released the lock" >/dev/null 2>&1 || rc=$?
check "7: a collating locale does not read a capitalised word as a coined marker" "$rc" 0

# --- 8. the refusal is worker-doc only; a chief doc takes any bullet ---
# A worker doc carries its brief's "RETASK token" line; a chief doc (name ends
# -chief.md) and a doc with no worker brief accept the bullets chief-template.md
# tells the chief to write with this script.
d8="$tmp/HIMMEL-9-roadmap-chief.md"
printf '# chief\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d8"
d8b="$tmp/no-worker-label.md"
cp "$d8" "$d8b"
d8leg="$tmp/HIMMEL-9-N1-fixture-2026-10-06.md"
printf '# worker\n\nYour RETASK token is X-1.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d8leg"
for ok in "MERGED #12 → abc123" "VERDICT go on 12" "OPERATOR approved" "READY-STAGE 12" "HIMMEL-9 follow-up filed" "free text bullet"; do
    for doc in "$d8" "$d8b"; do
        rc=0; bash "$SCRIPT" "$doc" "$ok" >/dev/null 2>&1 || rc=$?
        check "8: '${ok%% *}' on ${doc##*/} rc 0" "$rc" 0
    done
done
rc=0; bash "$SCRIPT" "$d8leg" "SHIPPED the thing" >/dev/null 2>&1 || rc=$?
check "8: a worker doc still refuses a coined marker rc 6" "$rc" 6
rc=0; bash "$SCRIPT" "$d8leg" "MERGED #12 → abc123" >/dev/null 2>&1 || rc=$?
check "8: a worker doc refuses MERGED (not worker vocabulary) rc 6" "$rc" 6
# A chief doc (name ends -chief.md) takes any bullet even though it quotes worker tokens.
d8chief="$tmp/HIMMEL-nextleg-2026-10-25A-roadmap-chief.md"
printf '# chief\n\nN1 RETASK token is X-1.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d8chief"
rc=0; bash "$SCRIPT" "$d8chief" "MERGED #12 → abc123" >/dev/null 2>&1 || rc=$?
check "8: a chief doc takes MERGED rc 0" "$rc" 0

# --- 9. a short coined all-caps marker (WIP) is refused too; the real markers still append ---
d9="$tmp/HIMMEL-9-N2-fixture-2026-10-06.md"
printf '# worker\n\nYour RETASK token is X-1.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d9"
before_d9="$tmp/d9.before"; cp "$d9" "$before_d9"
for coined in "WIP halfway" "OK done" "PR 12 open" "WIP"; do
    rc=0; bash "$SCRIPT" "$d9" "$coined" >/dev/null 2>&1 || rc=$?
    check "9: short coined '${coined%% *}' refused rc 6" "$rc" 6
done
cmp -s "$d9" "$before_d9" && echo "ok - 9: refused doc unchanged" || { echo "FAIL - 9: refused doc unchanged"; fails=$((fails+1)); }
for real in LIVE FINDING RESOLVED READY BLOCKED HALTED WRAPPED PARKED-BANK PARKED-USAGE RESUMED; do
    rc=0; bash "$SCRIPT" "$d9" "$real x" >/dev/null 2>&1 || rc=$?
    check "9: marker $real still appends" "$rc" 0
done
rc=0; bash "$SCRIPT" "$d9" "A single capital then prose" >/dev/null 2>&1 || rc=$?
check "9: a one-letter lead is prose, appends" "$rc" 0

# --- 10. a bullet gitleaks would refuse in the vault is refused before the write ---
if command -v gitleaks >/dev/null 2>&1; then
    d10="$tmp/d10.md"
    printf '# worker\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d10"
    lock_tok="cachyos-x8664""-pid2124755"
    rc=0; bash "$SCRIPT" "$d10" "LIVE — release-token: \`$lock_tok\`, base 96101f2c32c0ca668ba9e1e5f3415cb14db9572e" >/dev/null 2>&1 || rc=$?
    check "10: a grammar token and a sha append rc 0" "$rc" 0
    cp "$d10" "$tmp/d10.before"
    key="AKIA""Z4X7Q2M3KDLPW3NB"
    rc=0; err="$(bash "$SCRIPT" "$d10" "FINDING aws_access_key_id = $key" 2>&1 >/dev/null)" || rc=$?
    check "10: a secret-shaped bullet is refused rc 7" "$rc" 7
    contains "10: the refusal carries the reword hint" "$err" "reword the bullet"
    case "$err" in *"$key"*) echo "FAIL - 10: the refusal echoes the secret"; fails=$((fails+1)) ;; *) echo "ok - 10: the refusal never echoes the secret" ;; esac
    cmp -s "$d10" "$tmp/d10.before" && echo "ok - 10: refused doc unchanged" || { echo "FAIL - 10: refused doc unchanged"; fails=$((fails+1)); }
else
    echo "ok - 10: skipped (gitleaks not installed)"
fi
mkdir -p "$tmp/badgl"
printf '#!/bin/sh\nexit 3\n' > "$tmp/badgl/gitleaks"; chmod +x "$tmp/badgl/gitleaks"
d10b="$tmp/d10b.md"
printf '# worker\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d10b"
rc=0; PATH="$tmp/badgl:$PATH" bash "$SCRIPT" "$d10b" "READY unscanned" >/dev/null 2>&1 || rc=$?
check "10: an unusable gitleaks still appends rc 0" "$rc" 0

# --- 11. a worker's SUCCESSION acknowledgement also adopts the new chief on the bus ---
d11="$tmp/HIMMEL-9-N2-fixture-2026-10-21.md"
printf '# worker\n\nYour RETASK token is X-2.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d11"
: > "$tmp/bus.log"
rc=0; bash "$SCRIPT" "$d11" "SUCCESSION accepted: CON-B-chief replaces CON-A-chief" >/dev/null 2>&1 || rc=$?
check "11: the acknowledgement appends rc 0" "$rc" 0
check "11: the bus adopts the new chief" "$(cat "$tmp/bus.log")" "adopt CON-B-chief"
check "11: the adopt result is a bullet, its arrow never a '>'" "$(grep -c '^- [0-9:]* bus-adopt: adopted: legx chief old → CON-B-chief$' "$d11")" 1
check "11: the SUCCESSION bullet stays the newest line" "$(tail -n 1 "$d11" | sed 's/^- [0-9:]* //')" "SUCCESSION accepted: CON-B-chief replaces CON-A-chief"
printf '#!/bin/sh\necho "bus: CON-C-chief does not succeed CON-B-chief" >&2\nexit 1\n' > "$tmp/bus"
rc=0; bash "$SCRIPT" "$d11" "SUCCESSION accepted: CON-C-chief replaces CON-B-chief" >/dev/null 2>&1 || rc=$?
check "11: a refused adopt still appends rc 0" "$rc" 0
check "11: a refused adopt is recorded with its reason" "$(grep -c '^- [0-9:]* bus-adopt: refused (bus: CON-C-chief does not succeed CON-B-chief)$' "$d11")" 1
check "11: after a refusal the SUCCESSION bullet stays the newest line" "$(tail -n 1 "$d11" | sed 's/^- [0-9:]* //')" "SUCCESSION accepted: CON-C-chief replaces CON-B-chief"
printf '#!/bin/sh\necho "$*" >> "%s/bus.log"\n' "$tmp" > "$tmp/bus"
: > "$tmp/bus.log"
bash "$SCRIPT" "$d11" "SUCCESSION accepted: CON-D-chief replaces CON-C-chief and more" >/dev/null 2>&1
bash "$SCRIPT" "$d8" "SUCCESSION accepted: CON-D-chief replaces CON-C-chief" >/dev/null 2>&1
check "11: no adopt for trailing text or a chief doc" "$(cat "$tmp/bus.log")" ""
HIMMEL_BUS_NAME='' bash "$SCRIPT" "$d11" "SUCCESSION accepted: CON-E-chief replaces CON-D-chief" >/dev/null 2>&1
check "11: a worker with no bus identity runs no adopt" "$(cat "$tmp/bus.log")" ""
check "11: a worker with no bus identity gets no bus-adopt bullet" "$(tail -n 2 "$d11" | grep -c 'bus-adopt:')" 0
printf '#!/bin/sh\nexec sleep 30\n' > "$tmp/bus"
rc=0; APPEND_RESULTS_BUS_TIMEOUT=1 bash "$SCRIPT" "$d11" "SUCCESSION accepted: CON-F-chief replaces CON-E-chief" >/dev/null 2>&1 || rc=$?
check "11: a stalled adopt still appends rc 0" "$rc" 0
check "11: a stalled adopt is recorded as timed out" "$(grep -c '^- [0-9:]* bus-adopt: refused (timed out after 1s)$' "$d11")" 1
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "%s/bus.log"\necho "adopted: legx chief $2 -> $2"\n' "$tmp" > "$tmp/bus"
: > "$tmp/bus.log"
before11="$(grep -c 'bus-adopt:' "$d11")"
bash "$SCRIPT" "$d11" "SUCCESSION accepted: CON-F-chief replaces CON-E-chief" >/dev/null 2>&1
check "11: a repeated acknowledgement still runs the adopt" "$(cat "$tmp/bus.log")" "adopt CON-F-chief"
check "11: an unchanged chief writes no bus-adopt bullet" "$(grep -c 'bus-adopt:' "$d11")" "$before11"

# --- 12. a stranded worker re-adopts its newest accepted successor at its next marker bullet ---
d12="$tmp/HIMMEL-9-N3-fixture-2026-10-21.md"
printf '# worker\n\nYour RETASK token is X-3.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n- 10:05 SUCCESSION accepted: CON-B-chief replaces CON-A-chief\n- 10:09 SUCCESSION accepted: CON-C-chief replaces CON-B-chief\n' > "$d12"
# shellcheck disable=SC2016  # $* and $2 expand in the stub, not here
printf '#!/bin/sh\necho "$*" >> "%s/bus.log"\necho "adopted: legx chief CON-A-chief -> $2"\n' "$tmp" > "$tmp/bus"
: > "$tmp/bus.log"
rc=0; bash "$SCRIPT" "$d12" "LIVE working" >/dev/null 2>&1 || rc=$?
check "12: the marker bullet appends rc 0" "$rc" 0
check "12: the bus adopts the newest accepted successor" "$(cat "$tmp/bus.log")" "adopt CON-C-chief"
check "12: a changed chief is recorded as a bus-adopt bullet" "$(grep -c '^- [0-9:]* bus-adopt: adopted: legx chief CON-A-chief → CON-C-chief$' "$d12")" 1
check "12: the marker bullet stays the newest line" "$(tail -n 1 "$d12" | sed 's/^- [0-9:]* //')" "LIVE working"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "%s/bus.log"\necho "adopted: legx chief $2 -> $2"\n' "$tmp" > "$tmp/bus"
: > "$tmp/bus.log"
bash "$SCRIPT" "$d12" "READY 1 abc GREEN" >/dev/null 2>&1
check "12: an already-adopted worker still runs the idempotent adopt" "$(cat "$tmp/bus.log")" "adopt CON-C-chief"
check "12: no change writes no bus-adopt bullet" "$(grep -c 'bus-adopt:' "$d12")" 1
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "%s/bus.log"\necho "bus: chief CON-B-chief on the chain to CON-C-chief is still live" >&2\nexit 1\n' "$tmp" > "$tmp/bus"
: > "$tmp/bus.log"
rc=0; bash "$SCRIPT" "$d12" "BLOCKED waiting" >/dev/null 2>&1 || rc=$?
check "12: a refused re-adopt was attempted" "$(cat "$tmp/bus.log")" "adopt CON-C-chief"
check "12: a refused re-adopt still appends rc 0" "$rc" 0
check "12: a refused re-adopt writes no bullet" "$(grep -c 'bus-adopt:' "$d12")" 1
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "%s/bus.log"\n' "$tmp" > "$tmp/bus"
: > "$tmp/bus.log"
bash "$SCRIPT" "$d12" "CONSULT design :: q :: read: x" >/dev/null 2>&1
check "12: a non-marker bullet runs no adopt" "$(cat "$tmp/bus.log")" ""
d12b="$tmp/HIMMEL-9-N4-fixture-2026-10-21.md"
printf '# worker\n\nYour RETASK token is X-4.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d12b"
bash "$SCRIPT" "$d12b" "LIVE no succession yet" >/dev/null 2>&1
check "12: a doc with no accepted succession runs no adopt" "$(cat "$tmp/bus.log")" ""
HIMMEL_BUS_NAME='' bash "$SCRIPT" "$d12" "LIVE unbound" >/dev/null 2>&1
check "12: a worker with no bus identity runs no re-adopt" "$(cat "$tmp/bus.log")" ""

# --- 13. adopt runs the anchor checkout's bus, not the worker worktree's own (possibly stale) copy ---
# A worker cut before the stamp fix carries a bus whose adopt cannot honour a stamp; the
# anchor's is current main's. The default resolution prefers the anchor and says which ran.
anc13="$tmp/anchor13"
mkdir -p "$anc13/scripts/handover/chief-kit" "$anc13/scripts/lib" "$anc13/marketplace/plugins/himmel-bus/bin"
for f13 in append-results.sh bucket-gitleaks.sh worker-doc-lock.sh; do cp "$HERE/$f13" "$anc13/scripts/handover/chief-kit/$f13"; done
cp "$HERE/../../lib/git-clean.sh" "$anc13/scripts/lib/git-clean.sh"
# shellcheck disable=SC2016  # $2 expands in the stub, not here
printf '#!/bin/sh\necho "adopted: legx chief CON-A-chief -> $2"\n' > "$anc13/marketplace/plugins/himmel-bus/bin/bus"
chmod +x "$anc13/marketplace/plugins/himmel-bus/bin/bus"
git13() { git -C "$anc13" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
git13 init -q
git13 add -A
git13 commit -q -m fixture
wt13="$tmp/wt13"
git13 worktree add -q "$wt13" -b leg13
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "bus: old chief CON-A-chief is not gone and sent no relay naming $2" >&2\nexit 1\n' > "$wt13/marketplace/plugins/himmel-bus/bin/bus"
d13="$tmp/HIMMEL-9-N5-fixture-2026-10-21.md"
printf '# worker\n\nYour RETASK token is X-5.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d13"
rc=0; env -u APPEND_RESULTS_BUS bash "$wt13/scripts/handover/chief-kit/append-results.sh" "$d13" "SUCCESSION accepted: CON-B-chief replaces CON-A-chief" >/dev/null 2>&1 || rc=$?
check "13: the acknowledgement appends rc 0" "$rc" 0
check "13: a stale worktree bus adopts through the anchor's" "$(grep -c '^- [0-9:]* bus-adopt: adopted: legx chief CON-A-chief → CON-B-chief \[via anchor\]$' "$d13")" 1
rm -f "$anc13/marketplace/plugins/himmel-bus/bin/bus"
d13b="$tmp/HIMMEL-9-N6-fixture-2026-10-21.md"
printf '# worker\n\nYour RETASK token is X-6.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d13b"
rc=0; env -u APPEND_RESULTS_BUS bash "$wt13/scripts/handover/chief-kit/append-results.sh" "$d13b" "SUCCESSION accepted: CON-B-chief replaces CON-A-chief" >/dev/null 2>&1 || rc=$?
check "13: no anchor bus still appends rc 0" "$rc" 0
check "13: no anchor bus falls back to the worktree copy and says so" "$(grep -c '^- [0-9:]* bus-adopt: refused (bus: old chief CON-A-chief is not gone and sent no relay naming CON-B-chief) \[via worktree\]$' "$d13b")" 1
d13c="$tmp/HIMMEL-9-N7-fixture-2026-10-21.md"
printf '# worker\n\nYour RETASK token is X-7.\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE up\n' > "$d13c"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "adopted: legx chief old -> $2"\n' > "$tmp/bus"
rc=0; bash "$wt13/scripts/handover/chief-kit/append-results.sh" "$d13c" "SUCCESSION accepted: CON-B-chief replaces CON-A-chief" >/dev/null 2>&1 || rc=$?
check "13: an explicit APPEND_RESULTS_BUS still wins and is not labelled" "$(grep -c '^- [0-9:]* bus-adopt: adopted: legx chief old → CON-B-chief$' "$d13c")" 1

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
