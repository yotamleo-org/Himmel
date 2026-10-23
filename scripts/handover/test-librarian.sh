#!/usr/bin/env bash
# test-librarian.sh — hermetic: a scratch handover root that is its own git repo,
# a scratch Jira mirror and a scratch sessions dir. Never touches the live vault.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/handover/librarian.sh"
PASS=0; FAIL=0
W="$(mktemp -d -t librarian.XXXXXX)" || exit 1; trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# age <days> <file...>: set mtime N days back (portable: touch -t from python)
age() {
  local d="$1" stamp; shift
  stamp="$(python3 -I -c 'import sys,time; print(time.strftime("%Y%m%d%H%M", time.localtime(time.time()-int(sys.argv[1])*86400)))' "$d")"
  touch -t "$stamp" "$@"
}
ym() { python3 -I -c 'import sys,time; print(time.strftime("%Y-%m", time.localtime(time.time()-int(sys.argv[1])*86400)))' "$1"; }
here() { [ -e "$1" ] && echo yes || echo no; }

R="$W/handovers"; B="$R/u/himmel"; MIR="$W/mirror"; SES="$W/sessions"
mkdir -p "$B/specs/plans" "$R/.locks/queue" "$MIR" "$SES/_archive"
mirror() { printf -- '---\nkey: "%s"\nstatus: "%s"\nstatusCategory: "%s"\n---\n' "$1" "$2" "$3" > "$MIR/$1.md"; }
mirror HIMMEL-1 Done Done; mirror HIMMEL-2 Done Done; mirror HIMMEL-3 Done Done
mirror HIMMEL-4 Done Done; mirror HIMMEL-5 "In Progress" "In Progress"; mirror HIMMEL-6 "Won't Do" Done
leg() {  # leg <file> <tail marker> <age days>
  printf '# t\n\n## Results\n\n- 10:00 LIVE — x\n- 10:05 %s — y\n' "$2" > "$B/$1"; age "$3" "$B/$1"
}

leg HIMMEL-1-old-wrapped-2026-01-01.md WRAPPED 60
printf '# resume\n' > "$B/HIMMEL-1-old-wrapped-2026-01-01-RESUME.md"; age 60 "$B/HIMMEL-1-old-wrapped-2026-01-01-RESUME.md"
printf '# j\n' > "$B/HIMMEL-1-old-wrapped-2026-01-01-judge-J1.md"; age 60 "$B/HIMMEL-1-old-wrapped-2026-01-01-judge-J1.md"
printf 'log\n' > "$B/HIMMEL-1-old-wrapped-2026-01-01.launch.log"; age 60 "$B/HIMMEL-1-old-wrapped-2026-01-01.launch.log"
leg HIMMEL-2-locked-2026-01-01.md WRAPPED 60
mkdir -p "$R/.locks/queue/u__himmel__HIMMEL-2-locked-2026-01-01.lock"
leg HIMMEL-3-young-2026-10-20.md WRAPPED 3
leg HIMMEL-4-done-no-wrapped-2026-01-01.md LIVE 60
leg HIMMEL-5-open-no-wrapped-2026-01-01.md LIVE 60
leg HIMMEL-6-wontdo-no-wrapped-2026-01-01.md BLOCKED 60
leg HIMMEL-7-mid-aged-2026-01-01.md WRAPPED 20
leg HIMMEL-8-halted-2026-01-01.md HALTED 60
leg HIMMEL-nextleg-2026-01-01-console.md WRAPPED 60
printf '# plan\n' > "$B/specs/plans/p.md"; age 90 "$B/specs/plans/p.md"
printf '{}\n' > "$R/arms.jsonl"; age 90 "$R/arms.jsonl"
printf '{}\n' > "$R/admissions-ledger.jsonl"; age 90 "$R/admissions-ledger.jsonl"
printf '# s\n' > "$R/auto-arm-status-old.md"; age 30 "$R/auto-arm-status-old.md"
printf '# s\n' > "$R/auto-arm-status-new.md"; age 2 "$R/auto-arm-status-new.md"
printf '# s\n' > "$SES/old-session.md"; age 60 "$SES/old-session.md"
printf '# s\n' > "$SES/new-session.md"; age 5 "$SES/new-session.md"
printf '# s\n' > "$SES/_archive/already.md"; age 400 "$SES/_archive/already.md"
printf '# live\n' > "$B/HIMMEL-9-live-2026-10-22.md"; age 1 "$B/HIMMEL-9-live-2026-10-22.md"
# links: the old doc points at a live doc and at its own RESUME; a live doc points back at the old doc
printf '# t\n\n- 10:05 WRAPPED — [live](HIMMEL-9-live-2026-10-22.md) [r](HIMMEL-1-old-wrapped-2026-01-01-RESUME.md) [web](https://x.test/a.md) [wiki]([[n]])\n' > "$B/HIMMEL-1-old-wrapped-2026-01-01.md"
age 60 "$B/HIMMEL-1-old-wrapped-2026-01-01.md"
printf '# live\n\nsee [old](HIMMEL-1-old-wrapped-2026-01-01.md)\n' > "$B/HIMMEL-9-live-2026-10-22.md"; age 1 "$B/HIMMEL-9-live-2026-10-22.md"

git -C "$R" init -q . && git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$SES" init -q . && git -C "$SES" add -A && git -C "$SES" -c user.email=t@t -c user.name=t commit -q -m seed
HEAD0="$(git -C "$R" rev-parse HEAD)"

run() { bash "$SUT" --root "$R" --bucket "$B" --sessions-dir "$SES" --mirror "$MIR" "$@"; }
M60="$(ym 60)"; M30="$(ym 30)"; A="$B/archive/$M60"

# --- RED: today nothing moves (the script does not exist yet) ----------------
[ -f "$SUT" ] || { check "RED: librarian.sh exists" yes no; echo "pass=$PASS fail=$FAIL"; exit 1; }

# --- dry run is the default and changes nothing -------------------------------
out="$(run 2>&1)"; check "default run exits 0" 0 "$?"
check "default run is a dry run" yes "$(printf '%s' "$out" | grep -q 'dry-run' && echo yes || echo no)"
check "dry run lists the wrapped doc as a move" yes "$(printf '%s' "$out" | grep -q '^MOVE .*HIMMEL-1-old-wrapped' && echo yes || echo no)"
check "dry run names the locked doc as skipped" yes "$(printf '%s' "$out" | grep -q '^SKIP locked .*HIMMEL-2-locked' && echo yes || echo no)"
check "dry run moves nothing" "$HEAD0" "$(git -C "$R" rev-parse HEAD)"
check "dry run leaves the tree clean" "" "$(git -C "$R" status --porcelain)"
check "dry run creates no archive dir" no "$(here "$B/archive")"
out2="$(run --dry-run 2>&1)"; check "explicit --dry-run matches the default" "$out" "$out2"

# --- apply --------------------------------------------------------------------
run --apply >/dev/null 2>&1; check "apply exits 0" 0 "$?"
check "wrapped old doc moved" yes "$(here "$A/HIMMEL-1-old-wrapped-2026-01-01.md")"
check "wrapped old doc left the bucket root" no "$(here "$B/HIMMEL-1-old-wrapped-2026-01-01.md")"
check "RESUME sibling travelled" yes "$(here "$A/HIMMEL-1-old-wrapped-2026-01-01-RESUME.md")"
check "judge sibling travelled" yes "$(here "$A/HIMMEL-1-old-wrapped-2026-01-01-judge-J1.md")"
check "side file (launch.log) travelled" yes "$(here "$A/HIMMEL-1-old-wrapped-2026-01-01.launch.log")"
check "HALTED old doc moved" yes "$(here "$A/HIMMEL-8-halted-2026-01-01.md")"
check "Done ticket without WRAPPED moved" yes "$(here "$A/HIMMEL-4-done-no-wrapped-2026-01-01.md")"
check "locked doc stayed" yes "$(here "$B/HIMMEL-2-locked-2026-01-01.md")"
check "young doc stayed" yes "$(here "$B/HIMMEL-3-young-2026-10-20.md")"
check "doc 20 days old stayed under the 30 day default" yes "$(here "$B/HIMMEL-7-mid-aged-2026-01-01.md")"
check "open ticket without WRAPPED stayed" yes "$(here "$B/HIMMEL-5-open-no-wrapped-2026-01-01.md")"
check "BLOCKED tail with a Won't Do ticket moved" yes "$(here "$A/HIMMEL-6-wontdo-no-wrapped-2026-01-01.md")"
check "console doc stayed" yes "$(here "$B/HIMMEL-nextleg-2026-01-01-console.md")"
check "specs tree untouched" yes "$(here "$B/specs/plans/p.md")"
check "arms.jsonl untouched" yes "$(here "$R/arms.jsonl")"
check "admissions-ledger.jsonl untouched" yes "$(here "$R/admissions-ledger.jsonl")"
check "old auto-arm-status moved" yes "$(here "$R/archive/auto-arm-status/$M30/auto-arm-status-old.md")"
check "young auto-arm-status stayed" yes "$(here "$R/auto-arm-status-new.md")"
check "old session moved" yes "$(here "$SES/_archive/$M60/old-session.md")"
check "young session stayed" yes "$(here "$SES/new-session.md")"
check "old _archive session untouched" yes "$(here "$SES/_archive/already.md")"

# --- index: one line per moved doc --------------------------------------------
IDX="$A/_index.md"
check "index file written" yes "$(here "$IDX")"
check "one index line per moved doc in the month (5 files of HIMMEL-1 group + 8, 4, 6 = 7)" 7 "$(grep -c '^- ' "$IDX")"
check "index line names the doc" yes "$(grep -q 'HIMMEL-1-old-wrapped-2026-01-01.md' "$IDX" && echo yes || echo no)"
check "index line carries the ticket" yes "$(grep -q 'HIMMEL-4' "$IDX" && echo yes || echo no)"

# --- git mv, not rm -----------------------------------------------------------
check "moves are staged renames (7 bucket + 1 auto-arm)" 8 "$(git -C "$R" status --porcelain | grep -c '^R')"
check "no deletion" 0 "$(git -C "$R" status --porcelain | grep -c '^ \?D')"
check "session move is a staged rename" 1 "$(git -C "$SES" status --porcelain | grep -c '^R')"

# --- links --------------------------------------------------------------------
check "moved doc's link to a live doc rewritten" yes "$(grep -q '](../../HIMMEL-9-live-2026-10-22.md)' "$A/HIMMEL-1-old-wrapped-2026-01-01.md" && echo yes || echo no)"
check "moved doc's link to its moved sibling kept" yes "$(grep -q '](HIMMEL-1-old-wrapped-2026-01-01-RESUME.md)' "$A/HIMMEL-1-old-wrapped-2026-01-01.md" && echo yes || echo no)"
check "web link left alone" yes "$(grep -q '](https://x.test/a.md)' "$A/HIMMEL-1-old-wrapped-2026-01-01.md" && echo yes || echo no)"
check "live doc's link to the moved doc rewritten" yes "$(grep -q "](archive/$M60/HIMMEL-1-old-wrapped-2026-01-01.md)" "$B/HIMMEL-9-live-2026-10-22.md" && echo yes || echo no)"

# --- idempotence --------------------------------------------------------------
before="$(git -C "$R" status --porcelain | sort | tr '\n' ' ')"
out3="$(run --apply 2>&1)"; check "second apply exits 0" 0 "$?"
check "second apply moves nothing" "$before" "$(git -C "$R" status --porcelain | sort | tr '\n' ' ')"
check "second apply adds no index line" 7 "$(grep -c '^- ' "$IDX")"
check "second apply reports zero moves" yes "$(printf '%s' "$out3" | grep -q 'moved=0' && echo yes || echo no)"

# --- an existing destination is never overwritten -----------------------------
leg HIMMEL-1-clash-2026-01-01.md WRAPPED 60; mkdir -p "$A"; printf 'keep\n' > "$A/HIMMEL-1-clash-2026-01-01.md"
git -C "$R" add -A; run --apply >/dev/null 2>&1
check "clash: destination kept" keep "$(head -1 "$A/HIMMEL-1-clash-2026-01-01.md")"
check "clash: source stayed" yes "$(here "$B/HIMMEL-1-clash-2026-01-01.md")"

# --- untracked doc is skipped, never plain-mv'd -------------------------------
leg HIMMEL-1-untracked-2026-01-01.md WRAPPED 60
out4="$(run --apply 2>&1)"
check "untracked doc stayed" yes "$(here "$B/HIMMEL-1-untracked-2026-01-01.md")"
check "untracked doc reported" yes "$(printf '%s' "$out4" | grep -q '^SKIP untracked .*HIMMEL-1-untracked' && echo yes || echo no)"

# --- usage --------------------------------------------------------------------
bash "$SUT" --root "$W/nope" --bucket "$B" >/dev/null 2>&1; check "missing root exits 2" 2 "$?"
bash "$SUT" --bogus >/dev/null 2>&1; check "unknown flag exits 2" 2 "$?"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
