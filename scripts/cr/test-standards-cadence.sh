#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C intentional in check() and the final assert
# Test harness for standards-cadence.sh: a recurring class yields a proposals file naming exactly one target,
# promoted classes show before/after rates, stale proposals expire and re-fire, known-findings.json is untouched.
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }   # no pipeline: see test-cr-tune.sh (HIMMEL-1430)
HERE="$(cd "$(dirname "$0")" && pwd)"; SCRIPT="$HERE/standards-cadence.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sc-test.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fails=0
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
not_contains() { grepq "$2" -F -e "$3" && { echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

TODAY="2026-10-19"
mkdir -p "$tmp/handovers"
cat > "$tmp/kf.json" <<'EOF'
{"classes":[
 {"id":"jq-bool","title":"jq swallows false","kind":"fix","rung":"prompt","source":"ledger","globs":["scripts/**"],"match":"jq","canonical":"x","prompt":false,"detector":null},
 {"id":"stub-fidelity","title":"stub fidelity","kind":"rebuttal","rung":"human","source":"coderabbit-learning","globs":["scripts/**"],"match":"stub","canonical":"x","prompt":false,"detector":null},
 {"id":"fence-lang","title":"fence lang","kind":"checklist","rung":"prompt","source":"cr-app-comments","globs":["docs/**"],"match":"fence","canonical":"x","prompt":false,"detector":null},
 {"id":"quiet-class","title":"never recurs","kind":"fix","rung":"advisory","source":"ledger","globs":["scripts/**"],"match":"nevermatches","canonical":"x","prompt":false,"detector":null},
 {"id":"promoted-ok","title":"promoted, fell","kind":"fix","rung":"gate","rung_since":"2026-10-05","source":"ledger","globs":["lib/**"],"match":"fell","canonical":"x","prompt":false,"detector":null},
 {"id":"promoted-flat","title":"promoted, flat","kind":"fix","rung":"gate","rung_since":"2026-10-05","source":"ledger","globs":["lib/**"],"match":"flat","canonical":"x","prompt":false,"detector":null}
]}
EOF
row() { printf '{"kind":"finding","ts":"%s","branch":"%s","head":"%s","model":"m","finding_id":"%s","file":"%s","verdict":"agreed","text":"%s"}\n' "$@"; }
{
  # jq-bool: 3 real findings over 3 branches inside the window
  row 2026-10-15T10:00:00Z b1 aaaaaaa f1 scripts/a.sh "jq swallows false"
  row 2026-10-16T10:00:00Z b2 bbbbbbb f2 scripts/b.sh "jq swallows false again"
  row 2026-10-17T10:00:00Z b3 ccccccc f3 scripts/c.sh "jq alternative"
  # stub-fidelity (human->prompt): 3 across 2 branches
  row 2026-10-15T11:00:00Z b1 aaaaaaa s1 scripts/a.sh "stub fidelity"
  row 2026-10-16T11:00:00Z b2 bbbbbbb s2 scripts/b.sh "stub fidelity"
  row 2026-10-17T11:00:00Z b2 ccccccc s3 scripts/c.sh "stub over-verification"
  # fence-lang (prompt->advisory): 3 across 2 branches
  row 2026-10-15T12:00:00Z b1 aaaaaaa g1 docs/a.md "fence without lang"
  row 2026-10-16T12:00:00Z b2 bbbbbbb g2 docs/b.md "fence without lang"
  row 2026-10-17T12:00:00Z b2 ccccccc g3 docs/c.md "fence no lang"
  # promoted-ok: 4 before promotion (2026-10-05), 1 after; promoted-flat: 1 before, 3 after
  row 2026-09-28T10:00:00Z b1 aaaaaaa p1 lib/a.sh "fell once"
  row 2026-09-29T10:00:00Z b1 aaaaaaa p2 lib/a.sh "fell twice"
  row 2026-09-30T10:00:00Z b1 aaaaaaa p3 lib/a.sh "fell thrice"
  row 2026-10-01T10:00:00Z b1 aaaaaaa p4 lib/a.sh "fell again"
  row 2026-10-12T10:00:00Z b1 aaaaaaa p5 lib/a.sh "fell late"
  row 2026-10-01T11:00:00Z b1 aaaaaaa q1 lib/a.sh "flat early"
  row 2026-10-10T11:00:00Z b1 aaaaaaa q2 lib/a.sh "flat later"
  row 2026-10-11T11:00:00Z b1 aaaaaaa q3 lib/a.sh "flat later too"
  row 2026-10-12T11:00:00Z b1 aaaaaaa q4 lib/a.sh "flat latest"
} > "$tmp/ledger.jsonl"
cp "$tmp/kf.json" "$tmp/kf.before.json"

run() { HANDOVER_DIR="$tmp/handovers" KNOWN_FINDINGS_FILE="$tmp/kf.json" CR_LEDGER="$tmp/ledger.jsonl" STANDARDS_CADENCE_TODAY="$1" bash "$SCRIPT" --since 7d 2>&1; }

# RED today: no script, so no file and no target
out="$(run "$TODAY")"; rc=$?
check "run: exit 0" "$rc" "0"
f="$tmp/handovers/cr-tune/proposals-$TODAY.md"
[ -f "$f" ] && echo "ok - proposals file written" || { echo "FAIL - proposals file missing: $f"; fails=$((fails+1)); }
body="$(cat "$f" 2>/dev/null)"
contains "file: names the window"                       "$body" "window: 7d"
contains "file: expiry date is today + 14d"             "$body" "expires: 2026-11-02"
contains "file: kind fix -> lint or check" "$body" "- [jq-bool] target: lint or check"
contains "file: human->prompt rebuttal from coderabbit -> CodeRabbit rule" "$body" "- [stub-fidelity] target: CodeRabbit rule"
contains "file: checklist -> standard line"             "$body" "- [fence-lang] target: standard line"
contains "file: operator approves CodeRabbit rule"      "$body" "approval: operator"
contains "file: console GO + opus judge for lints"      "$body" "approval: console GO + opus judge"
not_contains "file: a class that never recurs is absent" "$body" "[quiet-class]"
check "file: exactly one target per proposal" "$(grep -c '^- \[' <<< "$(sed -n '/^## Proposals/,/^## /p' "$f")")" "$(grep -c 'target:' <<< "$(sed -n '/^## Proposals/,/^## /p' "$f")")"
contains "file: promoted class shows before rate"       "$body" "- [promoted-ok] promoted 2026-10-05 before=4 after=1"
contains "file: falling rate is kept"                   "$body" "- [promoted-ok] promoted 2026-10-05 before=4 after=1 per-week-before=4.00 per-week-after=0.50 falling"
contains "file: flat rate is demoted to restructure"    "$body" "[promoted-flat] promoted 2026-10-05 before=1 after=3"
contains "file: flat rate names restructure (S5)"       "$body" "not falling: demote to restructure (S5)"
contains "stdout: prints the written path"              "$out" "$f"
check "known-findings.json untouched" "$(cmp -s "$tmp/kf.json" "$tmp/kf.before.json" && echo same)" "same"

# Expiry: a 20-day-old file whose class still recurs re-fires; one whose class stopped recurring expires.
mkdir -p "$tmp/handovers/cr-tune"
printf '# CR standards proposals 2026-09-29\nproposed: 2026-09-29\nexpires: 2026-10-13\n\n## Proposals\n- [jq-bool] target: lint or check\n- [quiet-class] target: lint or check\n' > "$tmp/handovers/cr-tune/proposals-2026-09-29.md"
run "$TODAY" > /dev/null
body="$(cat "$f")"
contains "expiry: still-recurring class re-fires"       "$body" "REFIRED [jq-bool] first proposed 2026-09-29"
contains "expiry: quiet class is listed as expired"     "$body" "EXPIRED [quiet-class] first proposed 2026-09-29"
printf '# CR standards proposals 2026-10-15\nproposed: 2026-10-15\nexpires: 2026-10-29\n\n## Proposals\n- [quiet-class] target: lint or check\n' > "$tmp/handovers/cr-tune/proposals-2026-10-15.md"
run "$TODAY" > /dev/null
contains "expiry: an unexpired proposal is not re-listed" "$(cat "$f")" "EXPIRED [quiet-class] first proposed 2026-09-29"
not_contains "expiry: a 4-day-old proposal is not expired" "$(cat "$f")" "first proposed 2026-10-15"

# A same-day file written by /cr-tune step 4 is never overwritten
rm -f "$f"; printf '# hand-written cr-tune proposals\n' > "$f"
run "$TODAY" > /dev/null
check "clobber: foreign same-day file kept" "$(cat "$f")" "# hand-written cr-tune proposals"
[ -f "$tmp/handovers/cr-tune/proposals-$TODAY-standards.md" ] && echo "ok - cadence wrote the -standards sibling" || { echo "FAIL - sibling file missing"; fails=$((fails+1)); }

# Usage contract
out="$(HANDOVER_DIR="$tmp/handovers" bash "$SCRIPT" --since 7x 2>&1)"; rc=$?
check "usage: bad --since exits 2" "$rc" "2"
out="$(HANDOVER_DIR="$tmp/handovers" bash "$SCRIPT" --bogus 2>&1)"; rc=$?
check "usage: unknown flag exits 2" "$rc" "2"

[ "$fails" -eq 0 ] && { echo "all ok"; exit 0; } || { echo "$fails failure(s)"; exit 1; }
