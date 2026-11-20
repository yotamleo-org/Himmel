#!/usr/bin/env bash
# Fixture-gated acceptance test for tools/apply-clip-actions.mjs: the daily
# note's "Fold <clips> into <map>" and "Archive <clip>" actions apply
# themselves (bounded, idempotent, ledgered, revertible with a divergence
# guard), "Evaluate tool" / ticket actions are never applied, and the daily
# timeline stops listing an action once the vault shows it applied.
#
# Fixtures are synthetic. Day D0 lists 7 actions (2 folds, 1 evaluate, 4
# archives); day D lists 5 more (1 fold into a CRLF map, 3 archives, 1 ticket)
# and carries D0's 7 over: 10 actions are apply-eligible, 2 never are.

set -u -o pipefail
export TZ='Etc/GMT-2'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APPLY="$PLUGIN_DIR/tools/apply-clip-actions.mjs"
TIMELINE="$PLUGIN_DIR/tools/daily-timeline.mjs"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

D0="2026-06-27"
D="2026-06-28"
LEDGER_NAME=".apply-clip-actions.ledger.jsonl"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/apply-clip-actions.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
# Hash of every file under $1 except the ledger: one line, changes if any byte does.
tree_hash() {
    ( cd "$1" && find . -type f ! -name "$LEDGER_NAME" | LC_ALL=C sort \
        | while read -r f; do sha "$f"; done | sha | cut -d' ' -f1 )
}
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }
lines() { wc -l < "$1" | tr -d ' '; }

mkclip() { # name triaged_at tag extra-line
    local f="$P/Clippings/_evidence/$1.md"
    {
        echo "---"
        echo "title: \"Clip $1\""
        echo "type: article"
        echo "status: reviewed"
        echo "processed: true"
        echo "triaged_at: $2"
        echo "evidence_kind:"
        echo "  - concepts"
        if [ -n "${3:-}" ]; then echo "tags:"; echo "  - $3"; fi
        if [ -n "${4:-}" ]; then echo "$4"; fi
        echo "---"
        echo "Synthetic body for $1."
    } > "$f"
}

# ── pristine vault ───────────────────────────────────────────────────────────
P="$tmp/pristine"
mkdir -p "$P/Clippings/_evidence" "$P/60-Maps" "$P/50-Journal/Daily"

cat > "$P/60-Maps/Alpha-MOC.md" <<'EOF'
---
type: moc
title: "Alpha MOC"
tags:
  - alpha
  - moc
---

# Alpha

Intro.

## Evidence

- [[Clippings/_evidence/alpha-1|Clip alpha-1]] — seeded by hand

## Notes

Keep this section last.
EOF
cat > "$P/60-Maps/Beta-MOC.md" <<'EOF'
---
type: moc
title: "Beta MOC"
tags:
  - beta
  - moc
---

# Beta

No evidence section yet.
EOF
printf -- '---\r\ntype: moc\r\ntitle: "Gamma MOC"\r\ntags:\r\n  - gamma\r\n  - moc\r\n---\r\n\r\n# Gamma\r\n\r\n## Evidence\r\n\r\n- [[Clippings/_evidence/seed]] — seed\r\n' > "$P/60-Maps/Gamma-MOC.md"

for n in alpha-1 alpha-2 alpha-3; do mkclip "$n" "$D0" alpha; done
for n in beta-1 beta-2; do mkclip "$n" "$D0" beta; done
mkclip eval-1 "$D0" "" 'source: "https://github.com/example/tool"'
for n in arch-1 arch-2 arch-3 arch-4; do mkclip "$n" "$D0" ""; done
mkclip gamma-1 "$D" gamma
for n in arch-5 arch-6; do mkclip "$n" "$D" ""; done
mkclip arch-fail "$D" "" 'harvest_status: failed'
mkclip tick-1 "$D" himmel

node "$TIMELINE" --vault "$P" --date "$D0" >/dev/null 2>&1
node "$TIMELINE" --vault "$P" --date "$D" >/dev/null 2>&1
NOTE="$P/50-Journal/Daily/$D.md"

echo "Test group 0: fixture sanity"
assert "day note lists 12 open actions (5 today + 7 carried)" "12" "$(count '^- \[ \] ' "$NOTE")"

# ── 1. dry run changes nothing ───────────────────────────────────────────────
echo "Test group 1: dry run (default mode)"
A="$tmp/A"; cp -R "$P" "$A"
h0="$(tree_hash "$A")"
out="$(node "$APPLY" --vault "$A" --date "$D" --limit 50 2>&1)"; rc=$?
assert "dry run exits 0" "0" "$rc"
assert "dry run leaves the tree byte-identical" "$h0" "$(tree_hash "$A")"
assert "dry run creates no ledger" "no" "$([ -e "$A/$LEDGER_NAME" ] && echo yes || echo no)"
assert "one 'would' line per apply-eligible action (10)" "10" "$(printf '%s\n' "$out" | grep -c '^would ')"
assert "3 folds would apply" "3" "$(printf '%s\n' "$out" | grep -c '^would fold ')"
assert "7 archives would apply" "7" "$(printf '%s\n' "$out" | grep -c '^would archive ')"
assert "evaluate clip never offered" "0" "$(printf '%s\n' "$out" | grep -c 'eval-1')"
assert "ticket clip never offered" "0" "$(printf '%s\n' "$out" | grep -c 'tick-1')"
out="$(node "$APPLY" --vault "$A" --date "$D" 2>&1)"
assert "default limit bounds a dry run to 5 lines" "5" "$(printf '%s\n' "$out" | grep -c '^would ')"
out="$(node "$APPLY" --vault "$A" --date "$D" --limit 3 2>&1)"
assert "--limit 3 bounds a dry run to 3 lines" "3" "$(printf '%s\n' "$out" | grep -c '^would ')"

# ── 2. apply: bounded, ledgered, idempotent ──────────────────────────────────
echo "Test group 2: apply --limit 5"
out="$(node "$APPLY" --vault "$A" --date "$D" --apply --limit 5 2>&1)"; rc=$?
L="$A/$LEDGER_NAME"
assert "apply exits 0" "0" "$rc"
assert "exactly 5 actions applied" "5" "$(printf '%s\n' "$out" | grep -c '^✓ ')"
assert "5 ledger lines appended" "5" "$(lines "$L")"
ids1="$(grep -o '"id":"[0-9a-f]*"' "$L" | sort)"
cp -R "$A" "$tmp/B"
out="$(node "$APPLY" --vault "$A" --date "$D" --apply --limit 5 2>&1)"
assert "second run applies the other 5" "5" "$(printf '%s\n' "$out" | grep -c '^✓ ')"
assert "ledger now holds 10 lines" "10" "$(lines "$L")"
assert "10 distinct action ids" "10" "$(grep -o '"id":"[0-9a-f]*"' "$L" | sort -u | wc -l | tr -d ' ')"
h1="$(tree_hash "$A")"
out="$(node "$APPLY" --vault "$A" --date "$D" --apply --limit 5 2>&1)"
assert "third run applies nothing" "0" "$(printf '%s\n' "$out" | grep -c '^✓ ')"
assert "third run leaves the tree byte-identical" "$h1" "$(tree_hash "$A")"
assert "third run adds no ledger line" "10" "$(lines "$L")"

echo "Test group 3: what an apply writes"
AR="$A/Clippings/_evidence/arch-1.md"
assert "archived clip carries archived: true" "1" "$(count '^archived: true$' "$AR")"
assert "archived clip carries archived_at: <apply date>" "1" "$(count "^archived_at: $D\$" "$AR")"
assert "archived clip keeps status: reviewed" "1" "$(count '^status: reviewed$' "$AR")"
assert "archived clip stays in _evidence/" "yes" "$([ -f "$AR" ] && echo yes || echo no)"
assert "evaluate clip is not stamped" "0" "$(count '^archived' "$A/Clippings/_evidence/eval-1.md")"
assert "ticket clip is not stamped" "0" "$(count '^archived' "$A/Clippings/_evidence/tick-1.md")"
AL="$A/60-Maps/Alpha-MOC.md"
assert "fold added the fresh clip links (alpha-2, alpha-3)" "2" "$(grep -cE 'alpha-[23]' "$AL")"
assert "fold did not repeat the seeded link" "1" "$(grep -c 'alpha-1' "$AL")"
assert "fold landed inside ## Evidence, before ## Notes" "yes" "$(awk '/alpha-3/{a=NR} /^## Notes/{n=NR} END{print (a && n && a<n) ? "yes" : "no"}' "$AL")"
BE="$A/60-Maps/Beta-MOC.md"
assert "map without Evidence gets one ## Evidence heading" "1" "$(grep -c '^## Evidence$' "$BE")"
assert "both beta clips linked" "2" "$(grep -cE 'beta-[12]' "$BE")"
GA="$A/60-Maps/Gamma-MOC.md"
assert "CRLF map stays CRLF on every line" "$(lines "$GA")" "$(grep -c $'\r' "$GA")"
assert "gamma clip linked" "1" "$(grep -c 'gamma-1' "$GA")"

# ── 4. the daily timeline stops listing applied actions ──────────────────────
echo "Test group 4: daily timeline after an apply"
# B = the vault after the FIRST 5 applied actions only.
node "$TIMELINE" --vault "$tmp/B" --date "$D" >/dev/null 2>&1
BN="$tmp/B/50-Journal/Daily/$D.md"
leak=0
for id in $(printf '%s\n' "$ids1" | sed 's/.*:"\(.*\)"/\1/'); do
    [ "$(grep -c "act:$id " "$BN")" = "0" ] || leak=$((leak+1))
done
assert "none of the 5 applied actions is listed" "0" "$leak"
assert "the 7 unapplied actions are still listed" "7" "$(count '^- \[ \] ' "$BN")"
assert "the Evaluate tool action is still listed" "1" "$(count 'Evaluate tool' "$BN")"
# C = after all 10.
cp -R "$A" "$tmp/C"
node "$TIMELINE" --vault "$tmp/C" --date "$D" >/dev/null 2>&1
CN="$tmp/C/50-Journal/Daily/$D.md"
assert "no Fold or Archive action left once all applied" "0" "$(grep -cE '^- \[ \] (\([0-9]+d\) )?(Fold|Archive) ' "$CN")"
assert "Evaluate tool action still listed" "1" "$(count 'Evaluate tool' "$CN")"
assert "ticket action still listed" "1" "$(count 'File a ticket' "$CN")"
assert "timeline re-run is byte-identical" "$(sha "$CN" | cut -d' ' -f1)" "$(node "$TIMELINE" --vault "$tmp/C" --date "$D" >/dev/null 2>&1; sha "$CN" | cut -d' ' -f1)"

# ── 5. revert ────────────────────────────────────────────────────────────────
echo "Test group 5: revert"
out="$(node "$APPLY" --vault "$A" --date "$D" --revert "$L" 2>&1)"; rc=$?
assert "revert exits 0" "0" "$rc"
assert "revert restores the pristine vault byte for byte" "" "$(diff -r "$P" "$A" --exclude="$LEDGER_NAME" 2>&1)"
assert "revert reports 10 reverted" "1" "$(printf '%s\n' "$out" | grep -c ' 10 reverted')"
out="$(node "$APPLY" --vault "$A" --date "$D" --revert "$L" 2>&1)"; rc=$?
assert "a second revert exits 0" "0" "$rc"
assert "a second revert changes nothing" "" "$(diff -r "$P" "$A" --exclude="$LEDGER_NAME" 2>&1)"
assert "a second revert reports 10 already reverted" "1" "$(printf '%s\n' "$out" | grep -c ' 10 already-reverted')"

echo "Test group 6: divergence guard"
rm -f "$L"
node "$APPLY" --vault "$A" --date "$D" --apply --limit 50 >/dev/null 2>&1
assert "re-apply after a revert writes 10 ledger lines" "10" "$(lines "$L")"
printf 'hand edit\n' >> "$A/60-Maps/Alpha-MOC.md"
printf 'hand edit\n' >> "$A/Clippings/_evidence/arch-2.md"
out="$(node "$APPLY" --vault "$A" --date "$D" --revert "$L" 2>&1)"; rc=$?
assert "revert exits 3 when it refused something" "3" "$rc"
assert "revert refuses the 2 edited pages" "2" "$(printf '%s\n' "$out" | grep -c '^⊘ .*diverged')"
assert "edited map keeps its hand edit" "1" "$(grep -c 'hand edit' "$A/60-Maps/Alpha-MOC.md")"
assert "edited map keeps the folded links" "1" "$(grep -c 'alpha-3' "$A/60-Maps/Alpha-MOC.md")"
assert "edited clip keeps its stamp" "1" "$(count '^archived: true$' "$A/Clippings/_evidence/arch-2.md")"
assert "untouched map is restored" "" "$(diff "$P/60-Maps/Beta-MOC.md" "$A/60-Maps/Beta-MOC.md")"
assert "untouched CRLF map is restored" "" "$(diff "$P/60-Maps/Gamma-MOC.md" "$A/60-Maps/Gamma-MOC.md")"
assert "untouched clip is restored" "" "$(diff "$P/Clippings/_evidence/arch-1.md" "$A/Clippings/_evidence/arch-1.md")"

# ── 7. argument validation ───────────────────────────────────────────────────
echo "Test group 7: arguments"
node "$APPLY" --vault "$A" --date "$D" --limit 0 >/dev/null 2>&1; assert "--limit 0 is refused" "1" "$?"
node "$APPLY" --vault "$A" --date "$D" --limit abc >/dev/null 2>&1; assert "--limit abc is refused" "1" "$?"
node "$APPLY" --date "$D" >/dev/null 2>&1; assert "missing --vault is refused" "1" "$?"
node "$APPLY" --vault "$A" --date 2026-13-40 >/dev/null 2>&1; assert "an impossible --date is refused" "1" "$?"
node "$APPLY" --vault "$A" --date "$D" --revert "$tmp/none.jsonl" >/dev/null 2>&1; assert "a missing ledger is refused" "1" "$?"
printf '{"action":"fold","map":"../escape.md","map_sha256_before":"a","map_sha256":"b","at":0,"appended":"x"}\n' > "$tmp/evil.jsonl"
node "$APPLY" --vault "$A" --revert "$tmp/evil.jsonl" >/dev/null 2>&1; assert "a ledger path escaping the vault is refused" "1" "$?"

echo
echo "apply-clip-actions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
