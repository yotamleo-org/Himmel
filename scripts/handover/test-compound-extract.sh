#!/usr/bin/env bash
# test-compound-extract.sh — hermetic: a scratch handover root and a scratch Jira mirror.
# Never touches the live vault.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/handover/compound-extract.sh"
PASS=0; FAIL=0
W="$(mktemp -d -t compound-extract.XXXXXX)" || exit 1; trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

age() {
  local d="$1" stamp; shift
  stamp="$(python3 -I -c 'import sys,time; print(time.strftime("%Y%m%d%H%M", time.localtime(time.time()-int(sys.argv[1])*86400)))' "$d")"
  touch -t "$stamp" "$@"
}
# rec <jsonl> <key> <python expr over r>: print one field of the record for <key>
rec() { python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["key"] == sys.argv[2]:
        print(eval(sys.argv[3]))
        break' "$1" "$2" "$3"; }

R="$W/handovers"; B="$R/u/himmel"; MIR="$W/mirror"
mkdir -p "$B" "$R/.locks/queue" "$MIR"
SHA="0123456789abcdef0123456789abcdef01234567"; K1=HIMMEL-1; K2=HIMMEL-2; K3=HIMMEL-3

cat > "$B/HIMMEL-1-first-2026-10-20.md" <<EOF
# $K1 first

BODYSECRET-one: a long narrative paragraph that must never be extracted.

## Results

- 10:00 LIVE — started, nothing to keep
- 10:10 FINDING — the guard over-denies a read-only grep
- 10:20 RESOLVED — ruling received, see console message
- 10:30 READY — 3713 $SHA GREEN
- 10:40 WRAPPED — PR #3713 merged, sha $SHA
EOF
cat > "$B/HIMMEL-2-second-2026-10-21.md" <<EOF
# $K2 second

BODYSECRET-two

## Results

- 09:00 LIVE — x
- 09:05 BLOCKED — the VM queue is full
- 09:10 HALTED — console halted the leg
EOF
cat > "$B/HIMMEL-3-third-2026-10-22.md" <<EOF
# $K3 third

## Results

- 08:00 WRAPPED — done, PR #4001
EOF
cat > "$B/HIMMEL-3-third-2026-10-22-b.md" <<EOF
# $K3 third, second leg

## Results

- 11:00 FINDING — follow-up needed
- 11:05 WRAPPED — PR #4002
EOF
printf '# t\n\n## Results\n\n- 10:00 LIVE — still going\n' > "$B/HIMMEL-4-unfinished-2026-10-22.md"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — but locked\n' > "$B/HIMMEL-5-locked-2026-10-22.md"
mkdir -p "$R/.locks/queue/u__himmel__HIMMEL-5-locked-2026-10-22.lock"
printf '# t\n\n## Results\n\n- 10:00 LIVE — still going\n' > "$B/HIMMEL-7-grp-2026-10-22.md"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — a side file of a locked group\n' > "$B/HIMMEL-7-grp-2026-10-22-RESUME.md"
mkdir -p "$R/.locks/queue/u__himmel__HIMMEL-7-grp-2026-10-22.lock"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — console\n' > "$B/HIMMEL-nextleg-2026-10-22-console.md"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — old\n' > "$B/HIMMEL-6-old-2026-10-01.md"
age 20 "$B/HIMMEL-6-old-2026-10-01.md"
age 2 "$B"/HIMMEL-1-*.md "$B"/HIMMEL-2-*.md "$B"/HIMMEL-3-*.md "$B"/HIMMEL-4-*.md "$B"/HIMMEL-5-*.md "$B"/HIMMEL-7-*.md
age 1 "$B/HIMMEL-3-third-2026-10-22-b.md"   # the newer leg of the third key
mkdir -p "$B/specs/plans"; printf '# plan\n\n- 10:00 WRAPPED — a spec\n' > "$B/specs/plans/p.md"

cat > "$MIR/HIMMEL-1.md" <<EOF
---
key: "HIMMEL-1"
statusCategory: "Done"
---

# $K1: first

## Description

d

## Comments

### A — 2026-10-20T01:00:00.000+0200

first comment, not the closing one

### A — 2026-10-21T01:00:00.000+0200

second to last comment

### A — 2026-10-22T01:00:00.000+0200

closing comment: shipped as PR 3713
EOF

OUT="$W/out.jsonl"
run() { bash "$SUT" --root "$R" --bucket "$B" --mirror "$MIR" "$@"; }

# --- RED: today there is no extractor ------------------------------------------
[ -f "$SUT" ] || { check "RED: compound-extract.sh exists" yes no; echo "pass=$PASS fail=$FAIL"; exit 1; }

run > "$OUT" 2> "$W/err"; check "default run exits 0" 0 "$?"
check "one record per ticket key (HIMMEL-1, 2, 3; not 4 unfinished, 5 locked, 6 old, 7 an unlocked side file of a locked group, console)" \
  "HIMMEL-1 HIMMEL-2 HIMMEL-3" "$(python3 -I -c 'import json,sys; print(" ".join(json.loads(l)["key"] for l in open(sys.argv[1])))' "$OUT")"
check "every line is one JSON object" 3 "$(python3 -I -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if isinstance(json.loads(l), dict)))' "$OUT")"

# --- marker bullets only --------------------------------------------------------
check "HIMMEL-1 keeps FINDING RESOLVED READY WRAPPED, drops LIVE" "FINDING RESOLVED READY WRAPPED" \
  "$(rec "$OUT" HIMMEL-1 '" ".join(b.split()[2] for b in r["bullets"])')"
check "HIMMEL-2 keeps BLOCKED and HALTED" "BLOCKED HALTED" "$(rec "$OUT" HIMMEL-2 '" ".join(b.split()[2] for b in r["bullets"])')"
check "no doc body text is extracted" 0 "$(grep -c 'BODYSECRET\|narrative paragraph' "$OUT")"
check "the doc name is recorded" "HIMMEL-1-first-2026-10-20.md" "$(rec "$OUT" HIMMEL-1 'r["docs"][0]')"
check "the PR number is extracted" 3713 "$(rec "$OUT" HIMMEL-1 'r["pr"]')"
check "the full head sha is extracted" "$SHA" "$(rec "$OUT" HIMMEL-1 'r["sha"]')"
check "a key with no PR or sha records empty fields" "|" "$(rec "$OUT" HIMMEL-2 'r["pr"] + "|" + r["sha"]')"

# --- two docs of one key merge --------------------------------------------------
check "two docs of one key become one record with both docs" 2 "$(rec "$OUT" HIMMEL-3 'len(r["docs"])')"
check "and both docs' marker bullets" 3 "$(rec "$OUT" HIMMEL-3 'len(r["bullets"])')"
check "the later PR wins" 4002 "$(rec "$OUT" HIMMEL-3 'r["pr"]')"

# --- closing comments from the mirror -------------------------------------------
check "the last two mirror comments are kept" 2 "$(rec "$OUT" HIMMEL-1 'len(r["comments"])')"
check "the newest comment is last" yes "$(rec "$OUT" HIMMEL-1 '"yes" if "closing comment" in r["comments"][-1] else "no"')"
check "an older comment is dropped" 0 "$(grep -c 'not the closing one' "$OUT")"
check "a key with no mirror file has no comments" 0 "$(rec "$OUT" HIMMEL-2 'len(r["comments"])')"

# --- window and exclusions ------------------------------------------------------
check "specs tree is never read" 0 "$(grep -c 'a spec' "$OUT")"
run --since-days 0 > "$W/all.jsonl" 2>/dev/null
check "--since-days 0 takes every finished doc (adds HIMMEL-6)" "HIMMEL-1 HIMMEL-2 HIMMEL-3 HIMMEL-6" \
  "$(python3 -I -c 'import json,sys; print(" ".join(json.loads(l)["key"] for l in open(sys.argv[1])))' "$W/all.jsonl")"
check "a Done ticket with a non-wrapped tail counts as finished" yes \
  "$(printf '# t\n\n## Results\n\n- 10:00 FINDING — q\n' > "$B/HIMMEL-7-done-open-2026-10-22.md"; age 2 "$B/HIMMEL-7-done-open-2026-10-22.md"
     printf -- '---\nkey: "HIMMEL-7"\nstatusCategory: "Done"\n---\n\n# HIMMEL-7: x\n' > "$MIR/HIMMEL-7.md"
     [ "$(run 2>/dev/null | grep -c '"key": "HIMMEL-7"')" = 1 ] && echo yes || echo no)"

# --- bounded bullet ---------------------------------------------------------------
LONG="$(python3 -I -c 'print("x"*5000)')"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — %s\n' "$LONG" > "$B/HIMMEL-8-long-2026-10-22.md"; age 2 "$B/HIMMEL-8-long-2026-10-22.md"
run > "$W/long.jsonl" 2>/dev/null
check "a very long bullet is capped" yes "$(rec "$W/long.jsonl" HIMMEL-8 '"yes" if len(r["bullets"][0]) <= 700 else "no"')"

# --- group lock: a dotted doc name is its own group, a locked dot sibling holds its primary ----------
G="$W/g"; GB="$G/u/himmel"; mkdir -p "$GB" "$G/.locks/queue"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — v1\n' > "$GB/HIMMEL-11-api.v1-2026-10-21.md"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — v2\n' > "$GB/HIMMEL-11-api.v2-2026-10-22.md"
mkdir -p "$G/.locks/queue/u__himmel__HIMMEL-11-api-v1-2026-10-21.lock"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — primary\n' > "$GB/HIMMEL-12-d-2026-10-22.md"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — side\n' > "$GB/HIMMEL-12-d-2026-10-22.notes.md"
mkdir -p "$G/.locks/queue/u__himmel__HIMMEL-12-d-2026-10-22-notes.lock"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — locked primary\n' > "$GB/HIMMEL-13-p-2026-10-22.md"
printf '# t\n\n## Results\n\n- 10:00 WRAPPED — unlocked side\n' > "$GB/HIMMEL-13-p-2026-10-22.notes.md"
mkdir -p "$G/.locks/queue/u__himmel__HIMMEL-13-p-2026-10-22.lock"
bash "$SUT" --root "$G" --bucket "$GB" --mirror "$MIR" --since-days 0 > "$W/g.jsonl" 2>/dev/null
check "a locked HIMMEL-11 v1 doc does not hold the v2 doc of the same key" "HIMMEL-11-api.v2-2026-10-22.md" "$(rec "$W/g.jsonl" HIMMEL-11 '" ".join(r["docs"])')"
check "a locked dot sibling holds its primary: HIMMEL-12 is not extracted" 0 "$(grep -c '"key": "HIMMEL-12"' "$W/g.jsonl")"
check "a locked primary holds its unlocked dot sibling: HIMMEL-13 is not extracted" 0 "$(grep -c '"key": "HIMMEL-13"' "$W/g.jsonl")"

# --- usage ------------------------------------------------------------------------
bash "$SUT" --root "$W/nope" --bucket "$B" >/dev/null 2>&1; check "missing root exits 2" 2 "$?"
bash "$SUT" --bogus >/dev/null 2>&1; check "unknown flag exits 2" 2 "$?"
bash "$SUT" --since-days x --root "$R" --bucket "$B" >/dev/null 2>&1; check "a non-numeric --since-days exits 2" 2 "$?"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
